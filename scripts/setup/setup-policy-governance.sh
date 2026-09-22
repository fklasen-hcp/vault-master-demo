#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Setting up Policy Governance (Sentinel + CG)${NC}"
echo -e "${BLUE}========================================${NC}"

if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${RED}Error: VAULT_TOKEN is not set${NC}"
    exit 1
fi

export VAULT_NAMESPACE="master-demo"

echo -e "\n${BLUE}Step 1: Writing Sentinel EGP policy${NC}"
# Rule: deny any policy write where the HCL body contains path "*" (root wildcard)
# Rule: only block on write operations (create/update) — reads and lists are unaffected.
# On a GET request.data.policy is null, so the original "not contains" check incorrectly
# blocked all policy reads. This ternary form is safe for all operations.
SENTINEL_POLICY_B64="IyBEZW5pZWQ6IFJvb3Qgd2lsZGNhcmQgKCcqJykgcGVybWlzc2lvbnMgYXJlIG5vdCBhbGxvd2VkLgptYWluID0gcnVsZSB7CiAgICByZXF1ZXN0Lm9wZXJhdGlvbiBub3QgaW4gWyJjcmVhdGUiLCAidXBkYXRlIl0gb3IKICAgIHJlcXVlc3QuZGF0YS5wb2xpY3kgaXMgbm90IGRlZmluZWQgb3IKICAgIHJlcXVlc3QuZGF0YS5wb2xpY3kgbm90IGNvbnRhaW5zICJwYXRoIFwiKlwiIgp9Cg=="

vault write sys/policies/egp/master-demo-sentinel-no-root-wildcard \
    policy="${SENTINEL_POLICY_B64}" \
    paths="sys/policies/acl/*" \
    enforcement_level="hard-mandatory"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Sentinel EGP policy written${NC}"
else
    echo -e "${RED}✗ Failed to write Sentinel EGP policy${NC}"
    echo -e "${YELLOW}Note: This requires Vault Enterprise with Sentinel license${NC}"
    exit 1
fi

echo -e "\n${BLUE}Step 2: Creating Policy Admin ACL policies${NC}"

echo -e "${YELLOW}Creating policy-admin policy...${NC}"
vault policy write master-demo-policy-admin - <<EOF
# Allow creating and updating policies under the master-demo-policy-* prefix
# Writes are gated by Control Groups — requires 1 approval from policy-approvers
path "sys/policies/acl/master-demo-policy-*" {
  capabilities = ["create", "update", "read", "delete", "list"]
  control_group = {
    factor "approver" {
      identity {
        group_names = ["policy-approvers"]
        approvals   = 1
      }
    }
  }
}

path "sys/policies/acl" {
  capabilities = ["list"]
}

path "sys/control-group/authorize" {
  capabilities = ["update"]
}

path "sys/control-group/request" {
  capabilities = ["update"]
}
EOF
echo -e "${GREEN}✓ Policy-admin policy created${NC}"

echo -e "${YELLOW}Creating policy-approver policy...${NC}"
vault policy write master-demo-policy-approver - <<EOF
path "sys/control-group/authorize" {
  capabilities = ["update"]
}

path "sys/control-group/request" {
  capabilities = ["update"]
}

path "sys/control-group/info" {
  capabilities = ["read"]
}
EOF
echo -e "${GREEN}✓ Policy-approver policy created${NC}"

echo -e "\n${BLUE}Step 3: Creating policy-approvers identity group${NC}"
POLICY_APPROVERS_GROUP_ID=$(vault write -format=json identity/group \
    name="policy-approvers" \
    type="internal" \
    policies="master-demo-policy-approver" | jq -r '.data.id')
echo -e "${GREEN}✓ Policy-approvers group created (ID: $POLICY_APPROVERS_GROUP_ID)${NC}"

echo -e "\n${BLUE}Step 4: Configuring Kubernetes auth roles${NC}"

vault write auth/master-demo-auth/role/master-demo-auth-role-policy-admin \
    bound_service_account_names=controlgroups-demo-app \
    bound_service_account_namespaces=controlgroups-demo \
    policies=master-demo-policy-admin \
    ttl=24h
echo -e "${GREEN}✓ Policy-admin auth role configured${NC}"

vault write auth/master-demo-auth/role/master-demo-auth-role-policy-approver \
    bound_service_account_names=controlgroups-demo-app \
    bound_service_account_namespaces=controlgroups-demo \
    policies=master-demo-policy-approver \
    ttl=24h
echo -e "${GREEN}✓ Policy-approver auth role configured${NC}"

echo -e "\n${BLUE}Step 5: Seeding policy-approver entity into policy-approvers group${NC}"

echo -e "${YELLOW}Performing seed login as policy-approver (creates entity in Vault)...${NC}"
APPROVER_ENTITY_ID=$(kubectl exec -n controlgroups-demo \
    "$(kubectl get pods -n controlgroups-demo -l app=controlgroups-demo-ui -o jsonpath='{.items[0].metadata.name}')" \
    -- python3 -c "
import hvac, json
client = hvac.Client(url='https://host.minikube.internal:8200', namespace='master-demo', verify=False)
with open('/var/run/secrets/kubernetes.io/serviceaccount/token') as f:
    jwt = f.read()
r = client.auth.kubernetes.login(role='master-demo-auth-role-policy-approver', jwt=jwt, mount_point='master-demo-auth')
print(r['auth']['entity_id'])
" 2>/dev/null)

if [ -z "$APPROVER_ENTITY_ID" ]; then
    echo -e "${RED}ERROR: Could not retrieve policy-approver entity ID. Is the controlgroups-demo pod running?${NC}"
    echo -e "${YELLOW}You can add the entity manually later with:${NC}"
    echo -e "  vault write identity/group/name/policy-approvers member_entity_ids=<entity-id>"
else
    echo -e "${YELLOW}Adding entity $APPROVER_ENTITY_ID to policy-approvers group...${NC}"
    vault write identity/group/name/policy-approvers \
        type="internal" \
        policies="master-demo-policy-approver" \
        member_entity_ids="${APPROVER_ENTITY_ID}"
    echo -e "${GREEN}✓ Entity $APPROVER_ENTITY_ID added to policy-approvers group${NC}"
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Policy Governance Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "  ${GREEN}✓${NC} Sentinel EGP: master-demo-sentinel-no-root-wildcard"
echo -e "  ${GREEN}✓${NC} ACL policy: master-demo-policy-admin (with Control Group)"
echo -e "  ${GREEN}✓${NC} ACL policy: master-demo-policy-approver"
echo -e "  ${GREEN}✓${NC} Identity group: policy-approvers"
echo -e "  ${GREEN}✓${NC} K8s auth role: master-demo-auth-role-policy-admin"
echo -e "  ${GREEN}✓${NC} K8s auth role: master-demo-auth-role-policy-approver"

# Made with Bob
