#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Setting up Vault Encryption Demo ===${NC}"

# Check if VAULT_ADDR and VAULT_TOKEN are set
if [ -z "$VAULT_ADDR" ]; then
    export VAULT_ADDR=https://127.0.0.1:8200
fi

if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${RED}ERROR: VAULT_TOKEN is not set${NC}"
    exit 1
fi

# Use master-demo namespace
export VAULT_NAMESPACE=master-demo

echo -e "\n${BLUE}Step 1: Renaming existing transit engine to master-demo-vso-transit-cache${NC}"
# Check if transit engine exists at old path
if vault secrets list | grep -q "^transit/"; then
    echo -e "${YELLOW}Moving transit/ to master-demo-vso-transit-cache/${NC}"
    vault secrets move transit/ master-demo-vso-transit-cache/ || echo -e "${YELLOW}Transit engine may already be moved${NC}"
else
    echo -e "${GREEN}Transit engine already at correct path or doesn't exist${NC}"
fi

echo -e "\n${BLUE}Step 2: Enabling Transit engine for encryption demo${NC}"
if vault secrets list | grep -q "^master-demo-encryption-transit/"; then
    echo -e "${YELLOW}Transit engine already enabled at master-demo-encryption-transit/${NC}"
else
    vault secrets enable -path=master-demo-encryption-transit transit
    echo -e "${GREEN}Transit engine enabled${NC}"
fi

echo -e "\n${BLUE}Step 3: Creating Transit encryption key${NC}"
if vault list master-demo-encryption-transit/keys 2>/dev/null | grep -q "customer-key"; then
    echo -e "${YELLOW}Transit key 'customer-key' already exists${NC}"
else
    vault write -f master-demo-encryption-transit/keys/customer-key
    echo -e "${GREEN}Transit key 'customer-key' created${NC}"
fi

echo -e "\n${BLUE}Step 4: Enabling Transform engine for tokenization${NC}"
if vault secrets list | grep -q "^master-demo-encryption-transform/"; then
    echo -e "${YELLOW}Transform engine already enabled at master-demo-encryption-transform/${NC}"
else
    vault secrets enable -path=master-demo-encryption-transform transform
    echo -e "${GREEN}Transform engine enabled${NC}"
fi

echo -e "\n${BLUE}Step 5: Creating Transform FPE transformation for credit cards${NC}"
# Create alphabet for credit card numbers (digits only)
if vault list master-demo-encryption-transform/alphabet 2>/dev/null | grep -q "creditcard-digits"; then
    echo -e "${YELLOW}Alphabet 'creditcard-digits' already exists${NC}"
else
    vault write master-demo-encryption-transform/alphabet/creditcard-digits alphabet="0123456789"
    echo -e "${GREEN}Alphabet 'creditcard-digits' created${NC}"
fi

# Create template for credit card (16 digits)
if vault list master-demo-encryption-transform/template 2>/dev/null | grep -q "creditcard-16"; then
    echo -e "${YELLOW}Template 'creditcard-16' already exists${NC}"
else
    vault write master-demo-encryption-transform/template/creditcard-16 \
        type=regex \
        pattern='(\d{4})(\d{4})(\d{4})(\d{4})' \
        alphabet=creditcard-digits
    echo -e "${GREEN}Template 'creditcard-16' created${NC}"
fi

# Create FPE transformation
if vault list master-demo-encryption-transform/transformation 2>/dev/null | grep -q "credit-card-fpe"; then
    echo -e "${YELLOW}Transformation 'credit-card-fpe' already exists${NC}"
else
    vault write master-demo-encryption-transform/transformation/credit-card-fpe \
        type=fpe \
        template=creditcard-16 \
        tweak_source=internal \
        allowed_roles=encryption-demo-role
    echo -e "${GREEN}Transformation 'credit-card-fpe' created${NC}"
fi

# Create role
if vault list master-demo-encryption-transform/role 2>/dev/null | grep -q "encryption-demo-role"; then
    echo -e "${YELLOW}Role 'encryption-demo-role' already exists${NC}"
else
    vault write master-demo-encryption-transform/role/encryption-demo-role \
        transformations=credit-card-fpe
    echo -e "${GREEN}Role 'encryption-demo-role' created${NC}"
fi

echo -e "\n${BLUE}Step 6: Creating policy for encryption demo${NC}"
vault policy write master-demo-encryption-policy - <<EOF
# Transit engine - encrypt, decrypt, rewrap
path "master-demo-encryption-transit/encrypt/customer-key" {
  capabilities = ["update"]
}

path "master-demo-encryption-transit/decrypt/customer-key" {
  capabilities = ["update"]
}

path "master-demo-encryption-transit/rewrap/customer-key" {
  capabilities = ["update"]
}

path "master-demo-encryption-transit/keys/customer-key/rotate" {
  capabilities = ["update"]
}

path "master-demo-encryption-transit/keys/customer-key" {
  capabilities = ["read"]
}

# Transform engine - encode, decode
path "master-demo-encryption-transform/encode/encryption-demo-role" {
  capabilities = ["update"]
}

path "master-demo-encryption-transform/decode/encryption-demo-role" {
  capabilities = ["update"]
}

# Read database credentials
path "master-demo-kv/data/encryption-db-creds" {
  capabilities = ["read"]
}
EOF
echo -e "${GREEN}Policy 'master-demo-encryption-policy' created${NC}"

echo -e "\n${BLUE}Step 7: Configuring Kubernetes authentication${NC}"
vault write auth/master-demo-auth/role/master-demo-auth-role-encryption \
    bound_service_account_names=encryption-demo-app \
    bound_service_account_namespaces=encryption-demo \
    policies=master-demo-encryption-policy \
    ttl=24h
echo -e "${GREEN}Kubernetes auth role configured${NC}"

echo -e "\n${BLUE}Step 8: Setting up PostgreSQL database for encryption demo${NC}"

# Wait for PostgreSQL to be ready
echo -e "${YELLOW}Waiting for PostgreSQL to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n postgres --timeout=120s 2>/dev/null || echo -e "${YELLOW}PostgreSQL may already be ready${NC}"

# Kill any stale port-forward processes
pkill -f "kubectl port-forward.*postgres.*9998" 2>/dev/null || true
sleep 2

# Check if port is accessible
if ! nc -z localhost 9998 2>/dev/null && ! timeout 1 bash -c "</dev/tcp/localhost/9998" 2>/dev/null; then
    # Start port-forward in background
    echo -e "${YELLOW}Starting PostgreSQL port-forward...${NC}"
    kubectl port-forward -n postgres svc/postgres-postgresql 9998:5432 > /dev/null 2>&1 &
    PF_PID=$!
    sleep 5
    
    # Test connection
    if ! nc -z localhost 9998 2>/dev/null && ! timeout 1 bash -c "</dev/tcp/localhost/9998" 2>/dev/null; then
        echo -e "${RED}Failed to establish port-forward to PostgreSQL${NC}"
        kill $PF_PID 2>/dev/null || true
        exit 1
    fi
    echo -e "${GREEN}Port-forward established (PID: $PF_PID)${NC}"
else
    echo -e "${GREEN}Port 9998 already accessible${NC}"
fi

# Create database and user using kubectl exec
echo -e "${YELLOW}Creating encryption_demo database and user...${NC}"

# Create database
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -c "CREATE DATABASE encryption_demo;" 2>/dev/null || echo "Database may already exist"

# Create user
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -c "CREATE USER encryption_user WITH PASSWORD 'encryption_pass';" 2>/dev/null || echo "User may already exist"

# Grant database privileges
echo -e "${YELLOW}Granting database privileges...${NC}"
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -d encryption_demo -c "GRANT ALL PRIVILEGES ON DATABASE encryption_demo TO encryption_user;" 2>/dev/null || echo "Privileges may already be granted"
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -d encryption_demo -c "GRANT ALL ON SCHEMA public TO encryption_user;" 2>/dev/null || echo "Schema privileges may already be granted"

# Create customers table
echo -e "${YELLOW}Creating customers table...${NC}"
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -d encryption_demo -c "CREATE TABLE IF NOT EXISTS customers (id SERIAL PRIMARY KEY, name VARCHAR(255) NOT NULL, ssn TEXT NOT NULL, address TEXT NOT NULL, credit_card TEXT NOT NULL, region VARCHAR(20) NOT NULL, key_version INTEGER DEFAULT 1, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"

# Grant table privileges
echo -e "${YELLOW}Granting table privileges...${NC}"
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -d encryption_demo -c "GRANT ALL PRIVILEGES ON TABLE customers TO encryption_user;"
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -d encryption_demo -c "GRANT USAGE, SELECT ON SEQUENCE customers_id_seq TO encryption_user;"

# Create indexes
echo -e "${YELLOW}Creating indexes...${NC}"
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -d encryption_demo -c "CREATE INDEX IF NOT EXISTS idx_customers_region ON customers(region);"
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -d encryption_demo -c "CREATE INDEX IF NOT EXISTS idx_customers_created_at ON customers(created_at DESC);"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Database and table created successfully${NC}"
else
    echo -e "${RED}Failed to create database${NC}"
    exit 1
fi

echo -e "\n${BLUE}Step 9: Storing database credentials in Vault KV${NC}"
vault kv put master-demo-kv/encryption-db-creds \
    username=encryption_user \
    password=encryption_pass \
    database=encryption_demo \
    host=postgres-postgresql.postgres.svc.cluster.local \
    port=5432
echo -e "${GREEN}Database credentials stored in Vault${NC}"

echo -e "\n${GREEN}=== Encryption Demo Vault Setup Complete! ===${NC}"
echo -e "\n${YELLOW}Summary:${NC}"
echo -e "  ✓ Transit engine: ${BLUE}master-demo-encryption-transit${NC}"
echo -e "  ✓ Transit key: ${BLUE}customer-key${NC}"
echo -e "  ✓ Transform engine: ${BLUE}master-demo-encryption-transform${NC}"
echo -e "  ✓ Transform role: ${BLUE}encryption-demo-role${NC}"
echo -e "  ✓ FPE transformation: ${BLUE}credit-card-fpe${NC}"
echo -e "  ✓ Database: ${BLUE}encryption_demo${NC}"
echo -e "  ✓ Table: ${BLUE}customers${NC}"
echo -e "  ✓ Policy: ${BLUE}master-demo-encryption-policy${NC}"
echo -e "  ✓ K8s auth role: ${BLUE}master-demo-auth-role-encryption${NC}"
echo -e "\n${YELLOW}Next steps:${NC}"
echo -e "  1. Deploy encryption demo: ${BLUE}kubectl apply -f encryption-secrets/${NC}"
echo -e "  2. Check status: ${BLUE}kubectl get pods -n encryption-demo${NC}"
echo -e "  3. Port-forward: ${BLUE}kubectl port-forward -n encryption-demo svc/encryption-demo-ui 10004:8080${NC}"
echo -e "  4. Access UI: ${BLUE}http://localhost:10004${NC}"

# Made with Bob