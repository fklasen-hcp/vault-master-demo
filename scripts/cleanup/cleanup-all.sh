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

# Clean up demo namespaces (safer - preserves other user resources in cluster)
echo -e "\n${GREEN}Cleaning up demo namespaces...${NC}"
if minikube status | grep -q "host: Running"; then
    echo -e "${YELLOW}Deleting demo namespaces...${NC}"
    kubectl delete namespace db-demo --ignore-not-found=true 2>/dev/null && echo "✓ db-demo namespace deleted" || echo "  db-demo namespace not found"
    kubectl delete namespace pki-demo --ignore-not-found=true 2>/dev/null && echo "✓ pki-demo namespace deleted" || echo "  pki-demo namespace not found"
    kubectl delete namespace gitlab-demo --ignore-not-found=true 2>/dev/null && echo "✓ gitlab-demo namespace deleted" || echo "  gitlab-demo namespace not found"
    kubectl delete namespace audit-monitoring --ignore-not-found=true 2>/dev/null && echo "✓ audit-monitoring namespace deleted" || echo "  audit-monitoring namespace not found"
    kubectl delete namespace postgres --ignore-not-found=true 2>/dev/null && echo "✓ postgres namespace deleted" || echo "  postgres namespace not found"
    kubectl delete namespace vault-secrets-operator-system --ignore-not-found=true 2>/dev/null && echo "✓ vault-secrets-operator-system namespace deleted" || echo "  vault-secrets-operator-system namespace not found"
    
    # Wait a moment for namespaces to start terminating
    sleep 3
    
    # Force delete any stuck namespaces (common with operator namespaces)
    echo -e "${YELLOW}Checking for stuck namespaces...${NC}"
    for ns in vault-secrets-operator-system db-demo pki-demo gitlab-demo audit-monitoring postgres; do
        if kubectl get namespace $ns 2>/dev/null | grep -q "Terminating"; then
            echo -e "${YELLOW}Force deleting stuck namespace: $ns${NC}"
            kubectl get namespace $ns -o json | jq '.spec.finalizers = []' | kubectl replace --raw /api/v1/namespaces/$ns/finalize -f - 2>/dev/null && echo "✓ $ns force deleted" || echo "  $ns already gone"
        fi
    done
    
    # Clean up cluster-level resources
    echo -e "${YELLOW}Cleaning cluster-level resources...${NC}"
    kubectl delete clusterrolebinding vault-auth-reviewer-binding --ignore-not-found=true 2>/dev/null && echo "✓ ClusterRoleBinding deleted" || echo "  ClusterRoleBinding not found"
    
    echo -e "${GREEN}✓ All demo namespaces and resources cleaned${NC}"
else
    echo -e "${YELLOW}Minikube is not running, skipping namespace cleanup${NC}"
fi

echo -e "\n${GREEN}=== Cleanup complete ===${NC}"
echo "✓ Vault demo configuration removed"
echo "✓ Demo namespaces and resources deleted"
echo ""
echo -e "${YELLOW}Note: Minikube cluster preserved (only demo resources removed)${NC}"
echo -e "${YELLOW}To completely remove the cluster, run: minikube delete${NC}"

# Made with Bob