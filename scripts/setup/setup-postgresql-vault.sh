#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Configuring PostgreSQL in Vault ===${NC}"

# Check if VAULT_ADDR and VAULT_TOKEN are set
if [ -z "$VAULT_ADDR" ]; then
    export VAULT_ADDR=https://127.0.0.1:8200
fi

if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${RED}ERROR: VAULT_TOKEN is not set${NC}"
    exit 1
fi

# Create and use master-demo namespace
echo -e "\n${GREEN}Checking for master-demo namespace...${NC}"

# Temporarily unset VAULT_NAMESPACE to work from root
SAVED_NAMESPACE=$VAULT_NAMESPACE
unset VAULT_NAMESPACE

# Check if namespace exists
if vault namespace list 2>/dev/null | grep -q "^master-demo/$"; then
    echo -e "${YELLOW}Namespace 'master-demo' already exists${NC}"
else
    echo -e "${GREEN}Creating master-demo namespace from root...${NC}"
    if vault namespace create master-demo; then
        echo -e "${GREEN}✓ Namespace 'master-demo' created${NC}"
    else
        echo -e "${RED}ERROR: Failed to create namespace 'master-demo'${NC}"
        echo -e "${RED}Make sure you have admin privileges in Vault${NC}"
        exit 1
    fi
fi

# Now set the namespace for all subsequent operations
export VAULT_NAMESPACE=master-demo

# Wait for PostgreSQL to be ready
echo -e "\n${GREEN}Waiting for PostgreSQL to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n postgres --timeout=120s

# Additional wait for PostgreSQL to fully start accepting connections
echo -e "${YELLOW}Waiting for PostgreSQL to accept connections...${NC}"
sleep 10

# Get minikube IP for local Vault to connect to PostgreSQL
MINIKUBE_IP=$(minikube ip)
POSTGRES_PORT=$(kubectl get svc postgres-postgresql -n postgres -o jsonpath='{.spec.ports[0].nodePort}')

# If NodePort is not available, we need to use port-forward
if [ -z "$POSTGRES_PORT" ]; then
    echo -e "${YELLOW}PostgreSQL is using ClusterIP. Setting up port-forward...${NC}"
    echo -e "${YELLOW}Note: This requires keeping the port-forward running in the background${NC}"
    
    # Kill any stale port-forward processes first
    pkill -f "kubectl port-forward.*postgres.*9998" 2>/dev/null || true
    sleep 2
    
    # Check if port is actually accessible (not just if process exists)
    PORT_ACCESSIBLE=false
    if nc -z 127.0.0.1 9998 2>/dev/null || timeout 1 bash -c "</dev/tcp/127.0.0.1/9998" 2>/dev/null; then
        echo -e "${GREEN}Port 9998 is already accessible, reusing existing connection${NC}"
        PORT_ACCESSIBLE=true
    fi
    
    # Start port-forward if port is not accessible
    if [ "$PORT_ACCESSIBLE" = false ]; then
        echo -e "${YELLOW}Starting port-forward to PostgreSQL...${NC}"
        kubectl port-forward -n postgres svc/postgres-postgresql 9998:5432 > /dev/null 2>&1 &
        PORT_FORWARD_PID=$!
        echo -e "${GREEN}Port-forward started with PID: $PORT_FORWARD_PID${NC}"
        
        # Wait for port-forward to be ready and test connection
        echo -e "${YELLOW}Waiting for port-forward to be ready...${NC}"
        sleep 5
        
        # Test if port is actually listening
        for i in {1..10}; do
            if nc -z 127.0.0.1 9998 2>/dev/null || timeout 1 bash -c "</dev/tcp/127.0.0.1/9998" 2>/dev/null; then
                echo -e "${GREEN}✓ Port-forward is ready${NC}"
                break
            fi
            if [ $i -eq 10 ]; then
                echo -e "${RED}Port-forward failed to become ready${NC}"
                exit 1
            fi
            echo -e "${YELLOW}Waiting for port-forward... (attempt $i/10)${NC}"
            sleep 2
        done
    fi
    
    # When using port-forward, Vault is running locally on the host
    # So it connects to 127.0.0.1 (the port-forward endpoint)
    POSTGRES_HOST="127.0.0.1"
    POSTGRES_PORT="9998"
else
    POSTGRES_HOST="$MINIKUBE_IP"
fi

POSTGRES_PASSWORD="secret-pass"

echo -e "${GREEN}PostgreSQL connection details:${NC}"
echo -e "  Host: $POSTGRES_HOST"
echo -e "  Port: $POSTGRES_PORT"

echo -e "\n${GREEN}Enabling database secrets engine...${NC}"
# Enable database secrets engine if not already enabled
if ! vault secrets list | grep -q "^master-demo-db/"; then
    vault secrets enable -path=master-demo-db database
    echo -e "${GREEN}✓ Database secrets engine enabled at master-demo-db/${NC}"
else
    echo -e "${YELLOW}Database secrets engine already enabled${NC}"
fi

echo -e "\n${GREEN}Configuring Vault database connection...${NC}"

# Retry logic for database connection (PostgreSQL might need a moment to fully start)
MAX_RETRIES=5
RETRY_COUNT=0
RETRY_DELAY=5

# Temporarily disable exit on error for retry loop
set +e

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo -e "${YELLOW}Attempting to configure Vault database connection...${NC}"
    echo -e "${YELLOW}Connection URL: postgresql://postgres:***@${POSTGRES_HOST}:${POSTGRES_PORT}/postgres?sslmode=disable${NC}"
    
    VAULT_OUTPUT=$(vault write master-demo-db/config/master-demo-db \
       plugin_name=postgresql-database-plugin \
       allowed_roles="dev-postgres" \
       connection_url="postgresql://{{username}}:{{password}}@${POSTGRES_HOST}:${POSTGRES_PORT}/postgres?sslmode=disable" \
       username="postgres" \
       password="$POSTGRES_PASSWORD" 2>&1)
    VAULT_EXIT_CODE=$?
    
    if [ $VAULT_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ Database connection configured successfully${NC}"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo -e "${RED}Vault error: $VAULT_OUTPUT${NC}"
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo -e "${YELLOW}Database connection failed, retrying in ${RETRY_DELAY}s... (attempt $RETRY_COUNT/$MAX_RETRIES)${NC}"
            sleep $RETRY_DELAY
        else
            echo -e "${RED}Failed to configure database connection after $MAX_RETRIES attempts${NC}"
            echo -e "${YELLOW}PostgreSQL might not be fully ready. Try running the script again.${NC}"
            set -e  # Re-enable exit on error
            exit 1
        fi
    fi
done

# Re-enable exit on error after retry loop
set -e

echo -e "\n${GREEN}Creating database role...${NC}"
vault write master-demo-db/roles/dev-postgres \
   db_name=master-demo-db \
   creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
      GRANT ALL PRIVILEGES ON DATABASE postgres TO \"{{name}}\"; \
      GRANT ALL ON SCHEMA public TO \"{{name}}\"; \
      GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; \
      GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\"; \
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"{{name}}\"; \
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"{{name}}\";" \
   revocation_statements="ALTER DEFAULT PRIVILEGES FOR ROLE \"{{name}}\" IN SCHEMA public REVOKE ALL ON TABLES FROM \"{{name}}\"; \
      ALTER DEFAULT PRIVILEGES FOR ROLE \"{{name}}\" IN SCHEMA public REVOKE ALL ON SEQUENCES FROM \"{{name}}\"; \
      ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM \"{{name}}\"; \
      ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM \"{{name}}\"; \
      REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\"; \
      REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM \"{{name}}\"; \
      REVOKE ALL ON SCHEMA public FROM \"{{name}}\"; \
      REVOKE ALL ON DATABASE postgres FROM \"{{name}}\"; \
      DROP ROLE IF EXISTS \"{{name}}\";" \
   default_ttl="30s" \
   max_ttl="1m"

echo -e "\n${GREEN}Testing database connection...${NC}"

# Retry logic for credential generation test
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if vault read master-demo-db/creds/dev-postgres 2>/dev/null; then
        echo -e "${GREEN}✓ Database credentials generated successfully${NC}"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo -e "${YELLOW}Credential generation failed, retrying in ${RETRY_DELAY}s... (attempt $RETRY_COUNT/$MAX_RETRIES)${NC}"
            sleep $RETRY_DELAY
        else
            echo -e "${RED}Failed to generate credentials after $MAX_RETRIES attempts${NC}"
            echo -e "${YELLOW}Configuration may be incomplete. Check PostgreSQL connectivity.${NC}"
            exit 1
        fi
    fi
done

echo -e "\n${GREEN}=== PostgreSQL Configuration Complete ===${NC}"
echo -e "${GREEN}✓ Database connection configured${NC}"
echo -e "${GREEN}✓ Role created with 30s default TTL, 1m max TTL${NC}"
echo ""
echo -e "${YELLOW}Next step:${NC}"
echo "  Deploy dynamic secrets application: make deploy-dynamic-secrets-local"

# Made with Bob
