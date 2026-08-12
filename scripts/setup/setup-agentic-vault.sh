#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Setting up Vault for Agentic AI Demo ===${NC}"

# Check if VAULT_ADDR and VAULT_TOKEN are set
if [ -z "$VAULT_ADDR" ]; then
    echo -e "${YELLOW}VAULT_ADDR not set, using default: https://127.0.0.1:8200${NC}"
    export VAULT_ADDR=https://127.0.0.1:8200
fi

if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${RED}ERROR: VAULT_TOKEN is not set${NC}"
    echo "Please set your Vault token:"
    echo "  export VAULT_TOKEN=your-vault-root-token"
    exit 1
fi

# Set VAULT_SKIP_VERIFY if not already set
if [ -z "$VAULT_SKIP_VERIFY" ]; then
    export VAULT_SKIP_VERIFY=true
fi

echo -e "\n${BLUE}Checking Vault connectivity...${NC}"
echo "  VAULT_ADDR: $VAULT_ADDR"
echo "  VAULT_SKIP_VERIFY: $VAULT_SKIP_VERIFY"

# Test Vault connectivity (portable approach without timeout command)
if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to Vault at $VAULT_ADDR${NC}"
    echo ""
    echo "Please ensure:"
    echo "  1. Vault is running and unsealed"
    echo "  2. VAULT_ADDR is correct (current: $VAULT_ADDR)"
    echo "  3. VAULT_TOKEN is valid"
    echo "  4. Network connectivity is working"
    echo ""
    echo "Try manually: vault status"
    echo ""
    echo "If 'vault status' works but this script fails, the issue may be with environment variables."
    echo "Make sure to export VAULT_ADDR, VAULT_TOKEN, and VAULT_SKIP_VERIFY before running this script."
    exit 1
fi
echo -e "${GREEN}✓ Vault is accessible${NC}"

# Mount audit log directory into Minikube
echo -e "\n${BLUE}Setting up audit log mount for Minikube...${NC}"
AUDIT_LOG_DIR="$HOME"
AUDIT_LOG_FILE="$HOME/audit.log"

# Ensure audit log file exists
if [ ! -f "$AUDIT_LOG_FILE" ]; then
    echo -e "${YELLOW}Creating audit log file...${NC}"
    touch "$AUDIT_LOG_FILE"
    chmod 640 "$AUDIT_LOG_FILE"
fi

# Verify /host-home mount is available (mounted at minikube start via --mount flag)
echo -e "${BLUE}Verifying /host-home mount in Minikube...${NC}"
if minikube ssh "test -d /host-home" 2>/dev/null; then
    echo -e "${GREEN}✓ Home directory available at /host-home in Minikube${NC}"
else
    echo -e "${RED}ERROR: /host-home is not mounted in minikube.${NC}"
    echo -e "${YELLOW}The mount is configured at minikube start time (--mount flag).${NC}"
    echo -e "${YELLOW}Run: minikube delete && make start-minikube${NC}"
    exit 1
fi

# Use master-demo namespace
export VAULT_NAMESPACE=master-demo
echo -e "${BLUE}Using Vault namespace: ${VAULT_NAMESPACE}${NC}"

echo -e "\n${BLUE}Step 1: Setting up Kubernetes authentication${NC}"
# Check if Kubernetes auth is enabled
if ! vault auth list 2>&1 | grep -q "master-demo-auth/"; then
    echo -e "${YELLOW}Enabling Kubernetes auth method at master-demo-auth...${NC}"
    
    # Get Kubernetes cluster info
    KUBE_HOST="https://$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||')"
    KUBE_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode)
    
    # Create namespace for vault auth if it doesn't exist
    if ! kubectl get namespace vault-secrets-operator-system 2>/dev/null; then
        echo -e "${YELLOW}Creating vault-secrets-operator-system namespace...${NC}"
        kubectl create namespace vault-secrets-operator-system
    fi
    
    # Create service account for Vault auth if it doesn't exist
    if ! kubectl get sa vault-auth-reviewer -n vault-secrets-operator-system 2>/dev/null; then
        kubectl create sa vault-auth-reviewer -n vault-secrets-operator-system
    fi
    
    # Create ClusterRole for token review if it doesn't exist
    if ! kubectl get clusterrole vault-auth-reviewer 2>/dev/null; then
        echo -e "${YELLOW}Creating ClusterRole for token review...${NC}"
        kubectl create clusterrole vault-auth-reviewer \
            --verb=create \
            --resource=tokenreviews.authentication.k8s.io
    fi
    
    # Create ClusterRoleBinding if it doesn't exist
    if ! kubectl get clusterrolebinding vault-auth-reviewer-binding 2>/dev/null; then
        echo -e "${YELLOW}Creating ClusterRoleBinding for token review...${NC}"
        kubectl create clusterrolebinding vault-auth-reviewer-binding \
            --clusterrole=vault-auth-reviewer \
            --serviceaccount=vault-secrets-operator-system:vault-auth-reviewer
    fi
    
    # Get the token
    TOKEN_REVIEWER_JWT=$(kubectl create token vault-auth-reviewer -n vault-secrets-operator-system --duration=87600h)
    
    # Enable Kubernetes auth
    if vault auth enable -path master-demo-auth kubernetes 2>&1; then
        echo -e "${GREEN}✓ Kubernetes auth method enabled${NC}"
        sleep 2
    else
        echo -e "${RED}ERROR: Failed to enable Kubernetes auth method${NC}"
        exit 1
    fi
    
    # Configure Kubernetes auth
    echo -e "${YELLOW}Configuring Kubernetes authentication...${NC}"
    vault write auth/master-demo-auth/config \
        kubernetes_host="$KUBE_HOST" \
        kubernetes_ca_cert="$KUBE_CA_CERT" \
        token_reviewer_jwt="$TOKEN_REVIEWER_JWT" \
        disable_local_ca_jwt=true || {
        echo -e "${RED}ERROR: Failed to configure Kubernetes auth${NC}"
        exit 1
    }
    echo -e "${GREEN}✓ Kubernetes auth configured${NC}"
else
    echo -e "${GREEN}✓ Kubernetes auth already enabled at master-demo-auth/${NC}"
fi

echo -e "\n${BLUE}Step 2: Creating base agent policy${NC}"
vault policy write master-demo-agentic-base - <<EOF
# Allow agent to read its own token info
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# Allow agent to renew its token
path "auth/token/renew-self" {
  capabilities = ["update"]
}

# Allow agent to read JWT signing key from KV
path "master-demo-kv/data/agentic/jwt-key" {
  capabilities = ["read"]
}
EOF
echo -e "${GREEN}✓ Base agent policy created${NC}"

echo -e "\n${BLUE}Step 3: Creating read-only policy${NC}"
vault policy write master-demo-agentic-readonly - <<EOF
# Read-only database credentials
path "master-demo-db/creds/agentic-readonly-role" {
  capabilities = ["read"]
}
EOF
echo -e "${GREEN}✓ Read-only policy created${NC}"

echo -e "\n${BLUE}Step 4: Creating admin policy${NC}"
vault policy write master-demo-agentic-admin - <<EOF
# Admin database credentials
path "master-demo-db/creds/agentic-admin-role" {
  capabilities = ["read"]
}
EOF
echo -e "${GREEN}✓ Admin policy created${NC}"

echo -e "\n${BLUE}Step 5: Creating Kubernetes auth role for agent base access${NC}"

# Create Kubernetes auth role for the AI agent base access (to fetch JWT key)
vault write auth/master-demo-auth/role/ai-agent-base \
    bound_service_account_names=ai-agent \
    bound_service_account_namespaces=agentic-demo \
    policies="master-demo-agentic-base" \
    ttl=24h \
    max_ttl=24h || {
    echo -e "${RED}ERROR: Failed to create Kubernetes auth role for agent base${NC}"
    exit 1
}
echo -e "${GREEN}✓ Agent base Kubernetes auth role created${NC}"
echo "  Service Account: ai-agent"
echo "  Namespace: agentic-demo"
echo "  Policies: master-demo-agentic-base"
echo "  TTL: 24h / Max TTL: 24h"

echo -e "\n${BLUE}Step 6: Enabling JWT auth method for user-based authorization${NC}"
# Enable JWT auth if not already enabled
if ! vault auth list 2>&1 | grep -q "master-demo-jwt/"; then
    echo -e "${YELLOW}Enabling JWT auth method at master-demo-jwt...${NC}"
    vault auth enable -path=master-demo-jwt jwt || {
        echo -e "${RED}ERROR: Failed to enable JWT auth method${NC}"
        exit 1
    }
    echo -e "${GREEN}✓ JWT auth enabled at master-demo-jwt/${NC}"
else
    echo -e "${GREEN}✓ JWT auth already enabled at master-demo-jwt/${NC}"
fi

echo -e "\n${BLUE}Step 8: Configuring JWT auth method${NC}"

# Enable KV v2 secrets engine if not already enabled
echo -e "${YELLOW}Enabling KV v2 secrets engine...${NC}"
if ! vault secrets list | grep -q "^master-demo-kv/"; then
    vault secrets enable -path=master-demo-kv kv-v2 || {
        echo -e "${RED}ERROR: Failed to enable KV v2 secrets engine${NC}"
        exit 1
    }
    echo -e "${GREEN}✓ KV v2 secrets engine enabled at master-demo-kv/${NC}"
else
    echo -e "${GREEN}✓ KV v2 secrets engine already enabled${NC}"
fi

# Check if JWT keys already exist in Vault KV
if vault kv get master-demo-kv/agentic/jwt-key >/dev/null 2>&1; then
    echo -e "${GREEN}✓ JWT keys already exist in Vault KV, reusing them${NC}"
    # Read existing public key
    JWT_PUBLIC_KEY=$(vault kv get -field=public_key master-demo-kv/agentic/jwt-key)
else
    # Generate RSA key pair for JWT signing (demo purposes)
    # In production, use proper key management
    echo -e "${YELLOW}Generating RSA key pair for JWT signing...${NC}"

    # Create temporary directory for keys
    TEMP_KEY_DIR=$(mktemp -d)
    ssh-keygen -t rsa -b 2048 -m PEM -f "$TEMP_KEY_DIR/jwt_key" -N "" -q

    # Convert public key to PEM format that Vault expects
    openssl rsa -in "$TEMP_KEY_DIR/jwt_key" -pubout -out "$TEMP_KEY_DIR/jwt_key.pub" 2>/dev/null

    # Read the public key
    JWT_PUBLIC_KEY=$(cat "$TEMP_KEY_DIR/jwt_key.pub")

    # Store private key in Vault KV for the UI to use
    echo -e "${YELLOW}Storing JWT keys in Vault KV...${NC}"
    vault kv put master-demo-kv/agentic/jwt-key \
        private_key="$(cat $TEMP_KEY_DIR/jwt_key)" \
        public_key="$JWT_PUBLIC_KEY" || {
        echo -e "${RED}ERROR: Failed to store JWT keys in Vault${NC}"
        rm -rf "$TEMP_KEY_DIR"
        exit 1
    }

    # Clean up temporary keys
    rm -rf "$TEMP_KEY_DIR"
    echo -e "${GREEN}✓ JWT keys generated and stored${NC}"
fi

# Configure JWT auth with RSA public key
echo -e "${YELLOW}Configuring JWT auth with RSA public key...${NC}"
vault write auth/master-demo-jwt/config \
    jwt_validation_pubkeys="$JWT_PUBLIC_KEY" \
    jwt_supported_algs="RS256" \
    bound_issuer="agentic-demo-ui" \
    default_role="agentic-user" || {
    echo -e "${RED}ERROR: Failed to configure JWT auth${NC}"
    exit 1
}

echo -e "${GREEN}✓ JWT auth configured with RSA256${NC}"

echo -e "\n${BLUE}Step 7: Creating UI policy and Kubernetes auth role${NC}"
# Create UI policy to read JWT private key
vault policy write master-demo-policy-agentic-ui - <<EOF
# Allow UI to read JWT private key for signing tokens
path "master-demo-kv/data/agentic/jwt-key" {
  capabilities = ["read"]
}

# Allow UI to read its own token info
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# Allow UI to renew its token
path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF

echo -e "${GREEN}✓ UI policy created${NC}"

# Create Kubernetes auth role for UI
vault write auth/master-demo-auth/role/master-demo-auth-role-agentic-ui \
    bound_service_account_names="agentic-ui" \
    bound_service_account_namespaces="agentic-demo" \
    policies="master-demo-policy-agentic-ui" \
    ttl="1h" || {
    echo -e "${RED}ERROR: Failed to create UI Kubernetes auth role${NC}"
    exit 1
}

echo -e "${GREEN}✓ UI Kubernetes auth role created${NC}"
echo "  Service Account: agentic-ui"
echo "  Namespace: agentic-demo"
echo "  Policies: master-demo-policy-agentic-ui"
echo "  TTL: 1h"
echo -e "${YELLOW}  Note: Private key stored in master-demo-kv/agentic/jwt-key${NC}"
echo -e "\n${BLUE}Step 8c: Configuring custom header auditing${NC}"
echo "Configuring Vault to audit agent context headers..."

# Temporarily unset namespace to configure audit at root level
TEMP_NAMESPACE=$VAULT_NAMESPACE
unset VAULT_NAMESPACE

# Configure custom headers to be audited (without HMAC hashing)
vault write sys/config/auditing/request-headers/x-agent-id hmac=false || {
    echo -e "${RED}ERROR: Failed to configure x-agent-id header auditing${NC}"
    export VAULT_NAMESPACE=$TEMP_NAMESPACE
    exit 1
}

vault write sys/config/auditing/request-headers/x-agent-type hmac=false || {
    echo -e "${RED}ERROR: Failed to configure x-agent-type header auditing${NC}"
    export VAULT_NAMESPACE=$TEMP_NAMESPACE
    exit 1
}

vault write sys/config/auditing/request-headers/x-agent-action hmac=false || {
    echo -e "${RED}ERROR: Failed to configure x-agent-action header auditing${NC}"
    export VAULT_NAMESPACE=$TEMP_NAMESPACE
    exit 1
}

vault write sys/config/auditing/request-headers/x-user-request hmac=false || {
    echo -e "${RED}ERROR: Failed to configure x-user-request header auditing${NC}"
    export VAULT_NAMESPACE=$TEMP_NAMESPACE
    exit 1
}

# Restore namespace
export VAULT_NAMESPACE=$TEMP_NAMESPACE

echo -e "${GREEN}✓ Custom header auditing configured${NC}"
echo "  Headers: x-agent-id, x-agent-type, x-agent-action, x-user-request"
echo "  HMAC: disabled (headers logged in plaintext)"


echo -e "\n${BLUE}Step 8: Creating Vault Identity groups and generic JWT auth role${NC}"

echo -e "${YELLOW}Looking up JWT auth accessor...${NC}"
JWT_AUTH_ACCESSOR=$(vault auth list -format=json | jq -r '."master-demo-jwt/".accessor')
if [ -z "$JWT_AUTH_ACCESSOR" ] || [ "$JWT_AUTH_ACCESSOR" = "null" ]; then
    echo -e "${RED}ERROR: Failed to determine JWT auth accessor for master-demo-jwt/${NC}"
    exit 1
fi
echo -e "${GREEN}✓ JWT auth accessor found${NC}"

echo -e "${YELLOW}Creating or updating external identity groups...${NC}"

READERS_GROUP_ID=$(vault read -format=json identity/group/name/agentic-readers 2>/dev/null | jq -r '.data.id // empty')
if [ -n "$READERS_GROUP_ID" ]; then
    vault write identity/group/id/"$READERS_GROUP_ID" \
        name="agentic-readers" \
        type="external" \
        policies="master-demo-agentic-readonly" >/dev/null || {
        echo -e "${RED}ERROR: Failed to update readers identity group${NC}"
        exit 1
    }
else
    READERS_GROUP_JSON=$(vault write -format=json identity/group \
        name="agentic-readers" \
        type="external" \
        policies="master-demo-agentic-readonly" 2>/dev/null) || {
        echo -e "${RED}ERROR: Failed to create readers identity group${NC}"
        exit 1
    }
    READERS_GROUP_ID=$(echo "$READERS_GROUP_JSON" | jq -r '.data.id // empty')
    if [ -z "$READERS_GROUP_ID" ]; then
        READERS_GROUP_ID=$(vault read -format=json identity/group/name/agentic-readers 2>/dev/null | jq -r '.data.id // empty')
    fi
fi
if [ -z "$READERS_GROUP_ID" ]; then
    echo -e "${RED}ERROR: Failed to resolve readers identity group ID${NC}"
    exit 1
fi

ADMINS_GROUP_ID=$(vault read -format=json identity/group/name/agentic-admins 2>/dev/null | jq -r '.data.id // empty')
if [ -n "$ADMINS_GROUP_ID" ]; then
    vault write identity/group/id/"$ADMINS_GROUP_ID" \
        name="agentic-admins" \
        type="external" \
        policies="master-demo-agentic-admin" >/dev/null || {
        echo -e "${RED}ERROR: Failed to update admins identity group${NC}"
        exit 1
    }
else
    ADMINS_GROUP_JSON=$(vault write -format=json identity/group \
        name="agentic-admins" \
        type="external" \
        policies="master-demo-agentic-admin" 2>/dev/null) || {
        echo -e "${RED}ERROR: Failed to create admins identity group${NC}"
        exit 1
    }
    ADMINS_GROUP_ID=$(echo "$ADMINS_GROUP_JSON" | jq -r '.data.id // empty')
    if [ -z "$ADMINS_GROUP_ID" ]; then
        ADMINS_GROUP_ID=$(vault read -format=json identity/group/name/agentic-admins 2>/dev/null | jq -r '.data.id // empty')
    fi
fi
if [ -z "$ADMINS_GROUP_ID" ]; then
    echo -e "${RED}ERROR: Failed to resolve admins identity group ID${NC}"
    exit 1
fi

echo -e "${GREEN}✓ External identity groups configured${NC}"

echo -e "${YELLOW}Creating or updating group aliases for JWT groups claim values...${NC}"

READERS_ALIAS_ID=$(vault list -format=json identity/group-alias/id 2>/dev/null | jq -r '.[]' | while read -r alias_id; do
    alias_json=$(vault read -format=json identity/group-alias/id/"$alias_id" 2>/dev/null || true)
    alias_name=$(echo "$alias_json" | jq -r '.data.name // empty')
    alias_accessor=$(echo "$alias_json" | jq -r '.data.mount_accessor // empty')
    if [ "$alias_name" = "readers" ] && [ "$alias_accessor" = "$JWT_AUTH_ACCESSOR" ]; then
        echo "$alias_id"
        break
    fi
done)

if [ -n "$READERS_ALIAS_ID" ]; then
    vault write identity/group-alias/id/"$READERS_ALIAS_ID" \
        name="readers" \
        mount_accessor="$JWT_AUTH_ACCESSOR" \
        canonical_id="$READERS_GROUP_ID" >/dev/null || {
        echo -e "${RED}ERROR: Failed to update readers group alias${NC}"
        exit 1
    }
else
    vault write identity/group-alias \
        name="readers" \
        mount_accessor="$JWT_AUTH_ACCESSOR" \
        canonical_id="$READERS_GROUP_ID" >/dev/null || {
        echo -e "${RED}ERROR: Failed to create readers group alias${NC}"
        exit 1
    }
fi

ADMINS_ALIAS_ID=$(vault list -format=json identity/group-alias/id 2>/dev/null | jq -r '.[]' | while read -r alias_id; do
    alias_json=$(vault read -format=json identity/group-alias/id/"$alias_id" 2>/dev/null || true)
    alias_name=$(echo "$alias_json" | jq -r '.data.name // empty')
    alias_accessor=$(echo "$alias_json" | jq -r '.data.mount_accessor // empty')
    if [ "$alias_name" = "admins" ] && [ "$alias_accessor" = "$JWT_AUTH_ACCESSOR" ]; then
        echo "$alias_id"
        break
    fi
done)

if [ -n "$ADMINS_ALIAS_ID" ]; then
    vault write identity/group-alias/id/"$ADMINS_ALIAS_ID" \
        name="admins" \
        mount_accessor="$JWT_AUTH_ACCESSOR" \
        canonical_id="$ADMINS_GROUP_ID" >/dev/null || {
        echo -e "${RED}ERROR: Failed to update admins group alias${NC}"
        exit 1
    }
else
    vault write identity/group-alias \
        name="admins" \
        mount_accessor="$JWT_AUTH_ACCESSOR" \
        canonical_id="$ADMINS_GROUP_ID" >/dev/null || {
        echo -e "${RED}ERROR: Failed to create admins group alias${NC}"
        exit 1
    }
fi

echo -e "${GREEN}✓ JWT group aliases configured${NC}"

echo -e "${YELLOW}Creating generic JWT auth role...${NC}"
vault write auth/master-demo-jwt/role/agentic-user \
    role_type="jwt" \
    bound_audiences="vault" \
    user_claim="sub" \
    groups_claim="groups" \
    ttl=1h || {
    echo -e "${RED}ERROR: Failed to create generic JWT auth role${NC}"
    exit 1
}
echo -e "${GREEN}✓ Generic JWT auth role created${NC}"

echo -e "\n${BLUE}Step 9: Updating database connection allowed roles${NC}"

# Check if database engine exists
if ! vault secrets list | grep -q "master-demo-db/"; then
    echo -e "${RED}ERROR: Database engine 'master-demo-db' not found${NC}"
    echo ""
    echo "The PostgreSQL database engine must be set up first."
    echo "Please run: make setup-postgresql-local"
    echo ""
    echo "Or run the full demo setup: make master-demo"
    exit 1
fi
echo -e "${GREEN}✓ Database engine 'master-demo-db' exists${NC}"

# Update the database connection to allow our agentic roles
# We need to read the existing config first to preserve the connection details
echo "Updating allowed_roles for database connection..."

# Get the existing connection details
EXISTING_CONFIG=$(vault read -format=json master-demo-db/config/master-demo-db)

# Extract connection details using jq if available, otherwise use a simpler approach
if command -v jq &> /dev/null; then
    CONNECTION_URL=$(echo "$EXISTING_CONFIG" | jq -r '.data.connection_details.connection_url')
    USERNAME=$(echo "$EXISTING_CONFIG" | jq -r '.data.connection_details.username')
else
    # Fallback: construct from what we know
    CONNECTION_URL="postgresql://{{username}}:{{password}}@127.0.0.1:9998/postgres?sslmode=disable"
    USERNAME="postgres"
fi

# Read the password from Kubernetes secret
POSTGRES_PASSWORD=$(kubectl get secret -n postgres postgres-postgresql -o jsonpath='{.data.postgres-password}' | base64 -d)

echo "Updating database connection with new allowed roles..."
vault write master-demo-db/config/master-demo-db \
    plugin_name=postgresql-database-plugin \
    allowed_roles="dev-postgres,agentic-readonly-role,agentic-admin-role" \
    connection_url="$CONNECTION_URL" \
    username="$USERNAME" \
    password="$POSTGRES_PASSWORD"
echo -e "${GREEN}✓ Database connection updated with allowed roles${NC}"

echo -e "\n${BLUE}Step 11: Creating database roles for Agentic AI${NC}"

# Read-only role for Alice
vault write master-demo-db/roles/agentic-readonly-role \
    db_name=master-demo-db \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT SELECT ON products TO \"{{name}}\"; \
        GRANT USAGE ON SEQUENCE products_id_seq TO \"{{name}}\";" \
    revocation_statements="REVOKE ALL PRIVILEGES ON products FROM \"{{name}}\"; \
        REVOKE ALL PRIVILEGES ON SEQUENCE products_id_seq FROM \"{{name}}\"; \
        DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl="30s" \
    max_ttl="1m"
echo -e "${GREEN}✓ Read-only database role created (SELECT only)${NC}"

# Admin role for Bob
vault write master-demo-db/roles/agentic-admin-role \
    db_name=master-demo-db \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT ALL PRIVILEGES ON products TO \"{{name}}\"; \
        GRANT ALL PRIVILEGES ON SEQUENCE products_id_seq TO \"{{name}}\";" \
    revocation_statements="REVOKE ALL PRIVILEGES ON products FROM \"{{name}}\"; \
        REVOKE ALL PRIVILEGES ON SEQUENCE products_id_seq FROM \"{{name}}\"; \
        DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl="30s" \
    max_ttl="1m"
echo -e "${GREEN}✓ Admin database role created${NC}"

echo -e "\n${BLUE}Step 12: Creating products table in PostgreSQL${NC}"

# Wait for PostgreSQL to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n postgres --timeout=120s 2>/dev/null || echo -e "${YELLOW}PostgreSQL may already be ready${NC}"

# Create products table
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -c "
CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    price DECIMAL(10, 2) NOT NULL,
    description TEXT,
    created_by VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);" 2>/dev/null || echo -e "${YELLOW}Table may already exist${NC}"

# Insert sample data
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -c "
INSERT INTO products (name, price, description, created_by) VALUES
('MacBook Pro 16\"', 2499.99, 'Apple M3 Max, 36GB RAM, 1TB SSD', 'system'),
('Dell XPS 15', 1899.99, 'Intel i9, 32GB RAM, 1TB SSD', 'system'),
('Sony WH-1000XM5', 399.99, 'Wireless noise-canceling headphones', 'system'),
('Logitech MX Master 3S', 99.99, 'Wireless ergonomic mouse', 'system'),
('Samsung 49\" Odyssey', 1199.99, 'Curved gaming monitor, 240Hz', 'system'),
('iPad Pro 12.9\"', 1099.99, 'M2 chip, 256GB, WiFi', 'system'),
('Keychron Q1 Pro', 189.99, 'Wireless mechanical keyboard', 'system'),
('Anker PowerCore 20K', 59.99, 'Portable charger, 20000mAh', 'system'),
('Bose SoundLink', 129.99, 'Portable Bluetooth speaker', 'system'),
('Apple AirPods Pro', 249.99, 'Active noise cancellation', 'system')
ON CONFLICT DO NOTHING;" 2>/dev/null || echo -e "${YELLOW}Sample data may already exist${NC}"

echo -e "${GREEN}✓ Products table created and populated${NC}"

# Enable PostgreSQL query logging for demo purposes
echo -e "\n${GREEN}Configuring PostgreSQL logging...${NC}"
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -c "ALTER SYSTEM SET log_statement = 'all';" 2>/dev/null || echo -e "${YELLOW}Logging may already be configured${NC}"
kubectl exec -n postgres postgres-postgresql-0 -- env PGPASSWORD=secret-pass psql -U postgres -c "SELECT pg_reload_conf();" >/dev/null 2>&1
echo -e "${GREEN}✓ PostgreSQL configured to log all SQL statements${NC}"

echo -e "\n${GREEN}=== Vault Configuration Complete ===${NC}"
echo -e "${GREEN}✓ Kubernetes auth configured for UI and Agent${NC}"
echo -e "${GREEN}✓ JWT auth configured for group-based identity authorization${NC}"
echo -e "${GREEN}✓ Policies created (base, alice, bob) and attached via identity groups${NC}"
echo -e "${GREEN}✓ Database roles created (readonly, admin)${NC}"
echo -e "${GREEN}✓ Products table ready${NC}"
echo -e ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Deploy Ollama: kubectl apply -f agentic-ai-demo/ollama/"
echo -e "  2. Deploy AI Agent: kubectl apply -f agentic-ai-demo/agent/"
echo -e "  3. Deploy Web UI: kubectl apply -f agentic-ai-demo/ui/"

# Made with Bob