#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Seeding Control Groups entities into groups${NC}"
echo -e "${BLUE}========================================${NC}"

if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${RED}Error: VAULT_TOKEN is not set${NC}"
    exit 1
fi

export VAULT_NAMESPACE="master-demo"

POD=$(kubectl get pods -n controlgroups-demo -l app=controlgroups-demo-ui -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD" ]; then
    echo -e "${RED}ERROR: No controlgroups-demo pod found. Is the demo deployed?${NC}"
    exit 1
fi
echo -e "${YELLOW}Using pod: $POD${NC}"

echo -e "\n${BLUE}Getting entity ID from pod...${NC}"
ENTITY_ID=$(kubectl exec -n controlgroups-demo "$POD" -- python3 -c "
import hvac
client = hvac.Client(url='https://host.minikube.internal:8200', namespace='master-demo', verify=False)
with open('/var/run/secrets/kubernetes.io/serviceaccount/token') as f:
    jwt = f.read()
r = client.auth.kubernetes.login(role='master-demo-auth-role-controlgroups-ops', jwt=jwt, mount_point='master-demo-auth')
print(r['auth']['entity_id'])
" 2>/dev/null)

if [ -z "$ENTITY_ID" ]; then
    echo -e "${RED}ERROR: Could not retrieve entity ID from pod${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Entity ID: $ENTITY_ID${NC}"

echo -e "\n${BLUE}Adding entity to groups...${NC}"

echo -e "${YELLOW}Seeding ops-team...${NC}"
vault write identity/group/name/ops-team \
    type="internal" \
    policies="master-demo-controlgroups-ops" \
    member_entity_ids="$ENTITY_ID"
echo -e "${GREEN}✓ ops-team seeded${NC}"

echo -e "${YELLOW}Seeding security-team...${NC}"
vault write identity/group/name/security-team \
    type="internal" \
    policies="master-demo-controlgroups-security" \
    member_entity_ids="$ENTITY_ID"
echo -e "${GREEN}✓ security-team seeded${NC}"

echo -e "${YELLOW}Seeding policy-approvers...${NC}"
vault write identity/group/name/policy-approvers \
    type="internal" \
    policies="master-demo-policy-approver" \
    member_entity_ids="$ENTITY_ID"
echo -e "${GREEN}✓ policy-approvers seeded${NC}"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}All groups seeded successfully!${NC}"
echo -e "${GREEN}  Entity $ENTITY_ID is now in:${NC}"
echo -e "${GREEN}  ✓ ops-team${NC}"
echo -e "${GREEN}  ✓ security-team${NC}"
echo -e "${GREEN}  ✓ policy-approvers${NC}"
echo -e "${GREEN}========================================${NC}"
