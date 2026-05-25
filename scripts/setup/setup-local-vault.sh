#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Setting up Local Vault for Kubernetes Integration ===${NC}"

# Check if VAULT_ADDR and VAULT_TOKEN are set
if [ -z "$VAULT_ADDR" ]; then
    echo -e "${YELLOW}VAULT_ADDR not set. Using default: https://127.0.0.1:8200${NC}"
    export VAULT_ADDR=https://127.0.0.1:8200
fi

if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${RED}ERROR: VAULT_TOKEN is not set. Please set it to your Vault root token or appropriate token.${NC}"
    echo "Example: export VAULT_TOKEN=your-token-here"
    exit 1
fi

echo -e "${GREEN}Using Vault at: $VAULT_ADDR${NC}"

# Check Vault status
echo -e "\n${GREEN}Checking Vault status...${NC}"
if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to Vault at $VAULT_ADDR${NC}"
    echo "Please ensure:"
    echo "  1. Vault is running at $VAULT_ADDR"
    echo "  2. Vault is unsealed"
    echo "  3. VAULT_TOKEN is valid"
    exit 1
fi

echo -e "${GREEN}✓ Vault is accessible and unsealed${NC}"

# Create and use master-demo namespace
echo -e "\n${GREEN}Creating master-demo namespace...${NC}"
if vault namespace create master-demo 2>/dev/null; then
    echo "✓ Namespace 'master-demo' created"
else
    echo "Namespace 'master-demo' already exists"
fi

export VAULT_NAMESPACE=master-demo
echo -e "${GREEN}✓ Using namespace: $VAULT_NAMESPACE${NC}"

# Get Kubernetes configuration
echo -e "\n${GREEN}Getting Kubernetes configuration...${NC}"
KUBE_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.server}')
KUBE_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

echo "Kubernetes API: $KUBE_HOST"

# Create service account for Vault auth
echo -e "\n${GREEN}Creating Kubernetes service account for Vault authentication...${NC}"
kubectl create namespace vault-secrets-operator-system 2>/dev/null || echo "Namespace already exists"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth-reviewer
  namespace: vault-secrets-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-auth-reviewer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-auth-reviewer
  namespace: vault-secrets-operator-system
EOF

# Wait for service account token
echo "Waiting for service account token..."
sleep 5

# Get the token
TOKEN_REVIEWER_JWT=$(kubectl create token vault-auth-reviewer -n vault-secrets-operator-system --duration=87600h)

# Enable Kubernetes auth
echo -e "\n${GREEN}Enabling Kubernetes authentication...${NC}"
if vault auth enable -path master-demo-auth kubernetes 2>/dev/null; then
    echo "✓ Kubernetes auth method enabled"
    sleep 2
else
    echo "Auth method already enabled or failed to enable"
    # Check if it exists
    if vault auth list | grep -q "master-demo-auth"; then
        echo "✓ Auth method exists"
    else
        echo -e "${RED}ERROR: Failed to enable Kubernetes auth method${NC}"
        exit 1
    fi
fi

# Configure Kubernetes auth
echo -e "\n${GREEN}Configuring Kubernetes authentication...${NC}"
echo "Kubernetes Host: $KUBE_HOST"
vault write auth/master-demo-auth/config \
    kubernetes_host="$KUBE_HOST" \
    kubernetes_ca_cert="$KUBE_CA_CERT" \
    token_reviewer_jwt="$TOKEN_REVIEWER_JWT"

# Enable KV v2 secrets engine (used by GitLab demo)
echo -e "\n${GREEN}Enabling KV v2 secrets engine...${NC}"
vault secrets enable -path=master-demo-kv kv-v2 2>/dev/null || echo "KV v2 already enabled"

# Setup for dynamic secrets (PostgreSQL)
echo -e "\n${GREEN}Setting up dynamic secrets configuration...${NC}"

# Enable database secrets engine
vault secrets enable -path=master-demo-db database 2>/dev/null || echo "Database secrets engine already enabled"

# Note: PostgreSQL connection will be configured after PostgreSQL is deployed
echo -e "${YELLOW}Note: PostgreSQL database connection will be configured after PostgreSQL pod is deployed${NC}"

# Create policy for dynamic secrets
vault policy write master-demo-auth-policy-db - <<EOF
path "master-demo-db/creds/dev-postgres" {
   capabilities = ["read"]
}
EOF

# Create role for dynamic secrets
vault write auth/master-demo-auth/role/master-demo-auth-role \
   bound_service_account_names=demo-dynamic-app \
   bound_service_account_namespaces=db-demo \
   token_ttl=0 \
   token_period=120 \
   token_policies=master-demo-auth-policy-db \
   audience=vault

# Setup transit encryption for VSO client cache
echo -e "\n${GREEN}Setting up transit encryption for VSO...${NC}"
vault secrets enable -path=master-demo-transit transit 2>/dev/null || echo "Transit engine already enabled"
vault write -force master-demo-transit/keys/vso-client-cache

vault policy write master-demo-auth-policy-operator - <<EOF
path "master-demo-transit/encrypt/vso-client-cache" {
   capabilities = ["create", "update"]
}
path "master-demo-transit/decrypt/vso-client-cache" {
   capabilities = ["create", "update"]
}
EOF

vault write auth/master-demo-auth/role/master-demo-auth-role-operator \
   bound_service_account_names=vault-secrets-operator-controller-manager \
   bound_service_account_namespaces=vault-secrets-operator-system \
   token_ttl=0 \
   token_period=120 \
   token_policies=master-demo-auth-policy-operator \
   audience=vault

# Setup userpass auth for UI access
echo -e "\n${GREEN}Setting up userpass authentication for UI access...${NC}"
vault auth enable -path=userpass userpass 2>/dev/null || echo "Userpass auth already enabled"

# Create a policy that allows full access to the master-demo namespace
vault policy write master-demo-admin - <<EOF
# Allow authentication and token operations
path "auth/token/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

# Allow listing auth methods
path "sys/auth" {
  capabilities = ["read", "list"]
}

# Allow listing secrets engines
path "sys/mounts" {
  capabilities = ["read", "list"]
}

# Allow listing policies
path "sys/policies/acl" {
  capabilities = ["list"]
}

path "sys/policies/acl/*" {
  capabilities = ["read", "list"]
}

# Allow reading telemetry metrics (for Prometheus scraping)
path "sys/metrics" {
  capabilities = ["read"]
}

# KV v2 secrets engine - full access
path "master-demo-kv/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "master-demo-kv/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "master-demo-kv/metadata/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Database secrets engine - full access
path "master-demo-db/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# PKI secrets engines - full access
path "master-demo-pki-root/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "master-demo-pki-issuing/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Transit secrets engine - full access
path "master-demo-transit/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Auth methods in this namespace
path "auth/master-demo-auth/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/userpass/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Allow identity operations for the UI
path "identity/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Wildcard for any other paths
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

# Create a demo user
vault write auth/userpass/users/demo \
    password=demo123 \
    policies=master-demo-admin

echo -e "${GREEN}✓ Userpass auth configured${NC}"
echo -e "${GREEN}✓ Demo user created (username: demo, password: demo123)${NC}"

echo -e "\n${GREEN}=== Vault Configuration Complete ===${NC}"
echo -e "${GREEN}✓ Using namespace: master-demo${NC}"
echo -e "${GREEN}✓ Kubernetes auth enabled and configured${NC}"
echo -e "${GREEN}✓ KV v2 secrets engine enabled${NC}"
echo -e "${GREEN}✓ Policies created${NC}"
echo -e "${GREEN}✓ Roles configured${NC}"
echo -e "${GREEN}✓ Transit encryption configured${NC}"
echo -e "${GREEN}✓ Userpass auth enabled for UI access${NC}"
echo ""
echo -e "${YELLOW}Vault UI Access (Option 1 - Recommended):${NC}"
echo "  URL: https://127.0.0.1:8200/ui/"
echo "  Method: Username"
echo "  Username: demo"
echo "  Password: demo123"
echo "  Namespace: master-demo"
echo ""
echo -e "${YELLOW}Vault UI Access (Option 2 - Root Token):${NC}"
echo "  URL: https://127.0.0.1:8200/ui/vault/secrets?namespace=master-demo"
echo "  Method: Token"
echo "  Token: \$VAULT_TOKEN"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  Run 'make master-demo' to deploy all demos, or run individual targets:"
echo "  - make install-vso-local          # Install Vault Secrets Operator"
echo "  - make install-postgresql-pod     # Install PostgreSQL"
echo "  - make setup-postgresql-local     # Configure PostgreSQL in Vault"
echo "  - make deploy-db-ui               # Deploy dynamic secrets demo"
echo "  - make setup-pki-vault            # Setup PKI"
echo "  - make deploy-pki-secrets         # Deploy PKI demo"
echo "  - make setup-gitlab-demo          # Deploy GitLab CI/CD demo"
echo "  - make setup-audit-monitoring     # Deploy audit monitoring"

# Made with Bob
