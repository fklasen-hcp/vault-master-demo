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
export VAULT_NAMESPACE=master-demo

echo -e "\n${GREEN}Checking Vault connectivity...${NC}"
if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to Vault at $VAULT_ADDR${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Vault is accessible${NC}"

echo -e "\n${GREEN}Cleaning all Vault demo configuration...${NC}"

# Disable audit device first (must be done in root namespace - audit devices are global)
echo -e "${YELLOW}Disabling audit device...${NC}"
unset VAULT_NAMESPACE
vault audit disable master-demo-audit 2>/dev/null && echo "✓ Master-demo audit device disabled" || echo "  Master-demo audit device not found"

# Delete the master-demo namespace (this removes ALL resources inside it automatically)
# Must be done from root namespace (VAULT_NAMESPACE already unset above)
echo -e "${YELLOW}Deleting master-demo namespace (removes all auth methods, secrets engines, policies, and roles)...${NC}"

# Delete Prometheus policy in root namespace FIRST (always, regardless of namespace existence)
echo -e "${YELLOW}Deleting Prometheus policy in root namespace...${NC}"
unset VAULT_NAMESPACE
vault policy delete master-demo-prometheus 2>/dev/null && echo "✓ Prometheus policy deleted" || echo "  Prometheus policy not found"

# Check if namespace exists
if vault namespace list 2>/dev/null | grep -q "master-demo/"; then
    
    # Now work within the namespace
    echo -e "${YELLOW}Revoking all leases in master-demo namespace...${NC}"
    export VAULT_NAMESPACE=master-demo
    
    # Specifically revoke database leases first (critical for DB engine cleanup)
    vault lease revoke -force -prefix master-demo-db/ 2>/dev/null && echo "✓ Database leases revoked" || echo "  No database leases found"
    
    # Then revoke all other leases
    vault lease revoke -prefix -force / 2>/dev/null && echo "✓ All remaining leases revoked" || echo "  No other active leases found"
    
    # Explicitly disable all secrets engines in the namespace
    echo -e "${YELLOW}Disabling all secrets engines in master-demo namespace...${NC}"
    vault secrets disable master-demo-db 2>/dev/null && echo "✓ Database engine disabled" || echo "  Database engine not found"
    vault secrets disable master-demo-kv 2>/dev/null && echo "✓ KV engine disabled" || echo "  KV engine not found"
    vault secrets disable master-demo-pki-root 2>/dev/null && echo "✓ PKI root disabled" || echo "  PKI root not found"
    vault secrets disable master-demo-pki-issuing 2>/dev/null && echo "✓ PKI issuing disabled" || echo "  PKI issuing not found"
    vault secrets disable master-demo-transit 2>/dev/null && echo "✓ Transit engine disabled" || echo "  Transit engine not found"
    vault secrets disable master-demo-encryption-transit 2>/dev/null && echo "✓ Encryption Transit engine disabled" || echo "  Encryption Transit engine not found"
    vault secrets disable master-demo-encryption-transform 2>/dev/null && echo "✓ Encryption Transform engine disabled" || echo "  Encryption Transform engine not found"
    
    # Disable auth methods
    echo -e "${YELLOW}Disabling auth methods in master-demo namespace...${NC}"
    vault auth disable master-demo-auth 2>/dev/null && echo "✓ Kubernetes auth disabled" || echo "  Kubernetes auth not found"
    vault auth disable userpass 2>/dev/null && echo "✓ Userpass auth disabled" || echo "  Userpass auth not found"
    
    # Delete all policies
    echo -e "${YELLOW}Deleting policies in master-demo namespace...${NC}"
    for policy in master-demo-webapp master-demo-auth-policy-db master-demo-pki-issuer master-demo-auth-policy-operator master-demo-admin master-demo-gitlab-policy; do
        vault policy delete "$policy" 2>/dev/null && echo "✓ Policy $policy deleted" || true
    done
    
    # Unset namespace before attempting to delete it
    unset VAULT_NAMESPACE
    
    # Try to delete the namespace
    DELETE_OUTPUT=$(vault namespace delete master-demo 2>&1)
    DELETE_EXIT_CODE=$?
    
    # Check if deletion was queued (Vault Enterprise async deletion)
    if echo "$DELETE_OUTPUT" | grep -q "Namespace deletion has been queued"; then
        echo "✓ master-demo namespace deletion queued (async deletion in progress)"
        echo "  Note: Vault Enterprise deletes namespaces asynchronously in the background"
    elif [ $DELETE_EXIT_CODE -eq 0 ]; then
        # Immediate deletion (Vault OSS or small namespace)
        echo "✓ master-demo namespace deleted with all resources"
    else
        # Actual error occurred
        if echo "$DELETE_OUTPUT" | grep -q "child namespaces"; then
            echo -e "${YELLOW}⚠ Namespace has child namespaces, attempting to delete them first...${NC}"
            # List and delete child namespaces
            CHILD_NAMESPACES=$(vault namespace list -namespace=master-demo 2>/dev/null | grep "/" | sed 's/\/$//')
            for child in $CHILD_NAMESPACES; do
                echo "  Deleting child namespace: master-demo/$child"
                vault namespace delete -namespace=master-demo "$child" 2>/dev/null || true
            done
            # Try deleting parent namespace again
            DELETE_OUTPUT=$(vault namespace delete master-demo 2>&1)
            if echo "$DELETE_OUTPUT" | grep -q "Namespace deletion has been queued"; then
                echo "✓ master-demo namespace deletion queued (async deletion in progress)"
            elif [ $? -eq 0 ]; then
                echo "✓ master-demo namespace deleted with all resources"
            else
                echo -e "${RED}✗ Failed to delete master-demo namespace${NC}"
                echo "  Error: $DELETE_OUTPUT"
                echo "  Try manually: vault namespace delete master-demo"
            fi
        else
            echo -e "${RED}✗ Failed to delete master-demo namespace${NC}"
            echo "  Error: $DELETE_OUTPUT"
            echo "  Try manually: vault namespace delete master-demo"
        fi
    fi
else
    echo "  master-demo namespace not found (already deleted)"
fi

echo -e "\n${GREEN}✓ All Vault configuration cleaned${NC}"

# Clean up demo namespaces (safer - preserves other user resources in cluster)
echo -e "\n${GREEN}Cleaning up demo namespaces...${NC}"
if minikube status | grep -q "host: Running"; then
    # Clean up VSO Custom Resources first (prevents namespace from getting stuck)
    echo -e "${YELLOW}Cleaning VSO Custom Resources...${NC}"
    kubectl delete vaultauth --all -n vault-secrets-operator-system --ignore-not-found=true 2>/dev/null && echo "✓ VaultAuth resources deleted" || echo "  No VaultAuth resources found"
    kubectl delete vaultconnection --all -n vault-secrets-operator-system --ignore-not-found=true 2>/dev/null && echo "✓ VaultConnection resources deleted" || echo "  No VaultConnection resources found"
    kubectl delete vaultdynamicsecret --all -n db-demo --ignore-not-found=true 2>/dev/null || true
    kubectl delete vaultdynamicsecret --all -n pki-demo --ignore-not-found=true 2>/dev/null || true
    kubectl delete vaultstaticsecret --all -n gitlab-demo --ignore-not-found=true 2>/dev/null || true
    kubectl delete vaultstaticsecret --all -n encryption-demo --ignore-not-found=true 2>/dev/null || true
    kubectl delete vaultpkisecret --all -n pki-demo --ignore-not-found=true 2>/dev/null || true
    
    echo -e "${YELLOW}Deleting demo namespaces...${NC}"
    kubectl delete namespace db-demo --ignore-not-found=true 2>/dev/null && echo "✓ db-demo namespace deleted" || echo "  db-demo namespace not found"
    kubectl delete namespace pki-demo --ignore-not-found=true 2>/dev/null && echo "✓ pki-demo namespace deleted" || echo "  pki-demo namespace not found"
    kubectl delete namespace gitlab-demo --ignore-not-found=true 2>/dev/null && echo "✓ gitlab-demo namespace deleted" || echo "  gitlab-demo namespace not found"
    kubectl delete namespace encryption-demo --ignore-not-found=true 2>/dev/null && echo "✓ encryption-demo namespace deleted" || echo "  encryption-demo namespace not found"
    kubectl delete namespace audit-monitoring --ignore-not-found=true 2>/dev/null && echo "✓ audit-monitoring namespace deleted" || echo "  audit-monitoring namespace not found"
    kubectl delete namespace postgres --ignore-not-found=true 2>/dev/null && echo "✓ postgres namespace deleted" || echo "  postgres namespace not found"
    kubectl delete namespace vault-secrets-operator-system --ignore-not-found=true 2>/dev/null && echo "✓ vault-secrets-operator-system namespace deleted" || echo "  vault-secrets-operator-system namespace not found"
    
    # Wait a moment for namespaces to start terminating
    sleep 3
    
    # Force delete any stuck namespaces (common with operator namespaces)
    echo -e "${YELLOW}Checking for stuck namespaces...${NC}"
    for ns in vault-secrets-operator-system db-demo pki-demo gitlab-demo encryption-demo audit-monitoring postgres; do
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