#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Cleaning all demo resources and destroying Minikube ===${NC}"

if [ -z "$VAULT_ADDR" ]; then
    echo -e "${YELLOW}VAULT_ADDR not set. Using default: https://127.0.0.1:8200${NC}"
    export VAULT_ADDR="https://127.0.0.1:8200"
fi

if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${RED}ERROR: VAULT_TOKEN is not set. Please set it to your Vault root token.${NC}"
    echo "Example: export VAULT_TOKEN=your-token-here"
    exit 1
fi

export VAULT_SKIP_VERIFY=true
unset VAULT_NAMESPACE

echo -e "\n${GREEN}Checking Vault connectivity...${NC}"
if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to Vault at $VAULT_ADDR${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Vault is accessible${NC}"

echo -e "\n${GREEN}Cleaning all Vault demo configuration...${NC}"

# Clean all roles
echo -e "${YELLOW}Deleting roles...${NC}"
vault delete auth/vso-demo-auth/role/vso-demo-gitlab-role 2>/dev/null && echo "✓ GitLab role deleted" || echo "  GitLab role not found"
vault delete auth/vso-demo-auth/role/vso-demo-pki-cert-issuer 2>/dev/null && echo "✓ PKI role deleted" || echo "  PKI role not found"
vault delete auth/vso-demo-auth/role/vso-demo-role1 2>/dev/null && echo "✓ Static secrets role deleted" || echo "  Static secrets role not found"
vault delete auth/vso-demo-auth/role/vso-demo-auth-role 2>/dev/null && echo "✓ Dynamic secrets role deleted" || echo "  Dynamic secrets role not found"
vault delete auth/vso-demo-auth/role/vso-demo-auth-role-operator 2>/dev/null && echo "✓ Transit operator role deleted" || echo "  Transit operator role not found"

# Clean all policies
echo -e "${YELLOW}Deleting policies...${NC}"
vault policy delete vso-demo-gitlab-policy 2>/dev/null && echo "✓ GitLab policy deleted" || echo "  GitLab policy not found"
vault policy delete vso-demo-pki-issuer 2>/dev/null && echo "✓ PKI policy deleted" || echo "  PKI policy not found"
vault policy delete vso-demo-webapp 2>/dev/null && echo "✓ Static secrets policy deleted" || echo "  Static secrets policy not found"
vault policy delete vso-demo-auth-policy-db 2>/dev/null && echo "✓ Dynamic secrets policy deleted" || echo "  Dynamic secrets policy not found"
vault policy delete vso-demo-auth-policy-operator 2>/dev/null && echo "✓ Transit policy deleted" || echo "  Transit policy not found"

# Clean database leases and configuration
echo -e "${YELLOW}Cleaning database secrets...${NC}"
vault lease revoke -force -prefix vso-demo-db/ 2>/dev/null || true
vault delete vso-demo-db/config/vso-demo-db 2>/dev/null || true
vault delete vso-demo-db/roles/dev-postgres 2>/dev/null || true

# Disable all secrets engines
echo -e "${YELLOW}Disabling secrets engines...${NC}"
vault secrets disable vso-demo-pki-issuing 2>/dev/null && echo "✓ PKI issuing engine disabled" || echo "  PKI issuing engine not found"
vault secrets disable vso-demo-pki-root 2>/dev/null && echo "✓ PKI root engine disabled" || echo "  PKI root engine not found"
vault secrets disable vso-demo-kv 2>/dev/null && echo "✓ KV v2 engine disabled" || echo "  KV v2 engine not found"
vault secrets disable vso-demo-db 2>/dev/null && echo "✓ Database engine disabled" || echo "  Database engine not found"
vault secrets disable vso-demo-transit 2>/dev/null && echo "✓ Transit engine disabled" || echo "  Transit engine not found"

# Disable auth method
echo -e "${YELLOW}Disabling auth methods...${NC}"
vault auth disable vso-demo-auth 2>/dev/null && echo "✓ Kubernetes auth disabled" || echo "  Kubernetes auth not found"

# Disable audit device
echo -e "${YELLOW}Disabling audit device...${NC}"
vault audit disable file 2>/dev/null && echo "✓ File audit device disabled" || echo "  File audit device not found"

echo -e "\n${GREEN}✓ All Vault configuration cleaned${NC}"

# Now nuke the entire Minikube cluster (removes all namespaces, pods, etc. in one go)
echo -e "\n${GREEN}Destroying Minikube cluster (nuking everything)...${NC}"
minikube delete

echo -e "\n${GREEN}=== Full cleanup complete ===${NC}"
echo "✓ Vault demo configuration removed"
echo "✓ Minikube cluster deleted (all Kubernetes resources removed)"

# Made with Bob