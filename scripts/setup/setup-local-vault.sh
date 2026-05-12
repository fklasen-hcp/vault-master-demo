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

# Use root namespace (no child namespace)
echo -e "\n${GREEN}Using Vault root namespace${NC}"
unset VAULT_NAMESPACE

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
if vault auth enable -path vso-demo-auth kubernetes 2>/dev/null; then
    echo "✓ Kubernetes auth method enabled"
    sleep 2
else
    echo "Auth method already enabled or failed to enable"
    # Check if it exists
    if vault auth list | grep -q "vso-demo-auth"; then
        echo "✓ Auth method exists"
    else
        echo -e "${RED}ERROR: Failed to enable Kubernetes auth method${NC}"
        exit 1
    fi
fi

# Configure Kubernetes auth
echo -e "\n${GREEN}Configuring Kubernetes authentication...${NC}"
echo "Kubernetes Host: $KUBE_HOST"
vault write auth/vso-demo-auth/config \
    kubernetes_host="$KUBE_HOST" \
    kubernetes_ca_cert="$KUBE_CA_CERT" \
    token_reviewer_jwt="$TOKEN_REVIEWER_JWT"

# Enable KV v2 secrets engine (used by GitLab demo)
echo -e "\n${GREEN}Enabling KV v2 secrets engine...${NC}"
vault secrets enable -path=vso-demo-kv kv-v2 2>/dev/null || echo "KV v2 already enabled"

# Setup for dynamic secrets (PostgreSQL)
echo -e "\n${GREEN}Setting up dynamic secrets configuration...${NC}"

# Enable database secrets engine
vault secrets enable -path=vso-demo-db database 2>/dev/null || echo "Database secrets engine already enabled"

# Note: PostgreSQL connection will be configured after PostgreSQL is deployed
echo -e "${YELLOW}Note: PostgreSQL database connection will be configured after PostgreSQL pod is deployed${NC}"

# Create policy for dynamic secrets
vault policy write vso-demo-auth-policy-db - <<EOF
path "vso-demo-db/creds/dev-postgres" {
   capabilities = ["read"]
}
EOF

# Create role for dynamic secrets
vault write auth/vso-demo-auth/role/vso-demo-auth-role \
   bound_service_account_names=demo-dynamic-app \
   bound_service_account_namespaces=db-demo \
   token_ttl=0 \
   token_period=120 \
   token_policies=vso-demo-auth-policy-db \
   audience=vault

# Setup transit encryption for VSO client cache
echo -e "\n${GREEN}Setting up transit encryption for VSO...${NC}"
vault secrets enable -path=vso-demo-transit transit 2>/dev/null || echo "Transit engine already enabled"
vault write -force vso-demo-transit/keys/vso-client-cache

vault policy write vso-demo-auth-policy-operator - <<EOF
path "vso-demo-transit/encrypt/vso-client-cache" {
   capabilities = ["create", "update"]
}
path "vso-demo-transit/decrypt/vso-client-cache" {
   capabilities = ["create", "update"]
}
EOF

vault write auth/vso-demo-auth/role/vso-demo-auth-role-operator \
   bound_service_account_names=vault-secrets-operator-controller-manager \
   bound_service_account_namespaces=vault-secrets-operator-system \
   token_ttl=0 \
   token_period=120 \
   token_policies=vso-demo-auth-policy-operator \
   audience=vault

echo -e "\n${GREEN}=== Vault Configuration Complete ===${NC}"
echo -e "${GREEN}✓ Using root namespace${NC}"
echo -e "${GREEN}✓ Kubernetes auth enabled and configured${NC}"
echo -e "${GREEN}✓ KV v2 secrets engine enabled${NC}"
echo -e "${GREEN}✓ Policies created${NC}"
echo -e "${GREEN}✓ Roles configured${NC}"
echo -e "${GREEN}✓ Transit encryption configured${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  Run 'make all-local' to deploy all demos, or run individual targets:"
echo "  - make install-vso-local          # Install Vault Secrets Operator"
echo "  - make install-postgresql-pod     # Install PostgreSQL"
echo "  - make setup-postgresql-local     # Configure PostgreSQL in Vault"
echo "  - make deploy-db-ui               # Deploy dynamic secrets demo"
echo "  - make setup-pki-vault            # Setup PKI"
echo "  - make deploy-pki-secrets         # Deploy PKI demo"
echo "  - make setup-gitlab-demo          # Deploy GitLab CI/CD demo"
echo "  - make setup-audit-monitoring     # Deploy audit monitoring"

# Made with Bob
