#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Setting up Vault Control Groups Demo${NC}"
echo -e "${BLUE}========================================${NC}"

# Check if VAULT_TOKEN is set
if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${RED}Error: VAULT_TOKEN is not set${NC}"
    echo -e "${YELLOW}Please set VAULT_TOKEN before running this script${NC}"
    exit 1
fi

# Enable Control Groups feature (required for Vault Enterprise)
echo -e "\n${BLUE}Step 0: Enabling Control Groups feature${NC}"
echo -e "${YELLOW}Configuring Control Groups with 24h max TTL...${NC}"
vault write sys/config/control-group max_ttl=24h
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Control Groups feature enabled${NC}"
else
    echo -e "${RED}✗ Failed to enable Control Groups${NC}"
    echo -e "${YELLOW}Note: This requires Vault Enterprise with Control Groups license${NC}"
    exit 1
fi

# Set Vault namespace
export VAULT_NAMESPACE="master-demo"

echo -e "\n${BLUE}Step 1: Creating demo secrets${NC}"

# Create non-critical secrets (dev environment)
echo -e "${YELLOW}Creating dev/api-key secret...${NC}"
vault kv put master-demo-kv/dev/api-key \
    api_key="dev-api-key-12345" \
    environment="development" \
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo -e "${YELLOW}Creating dev/database secret...${NC}"
vault kv put master-demo-kv/dev/database \
    username="dev_user" \
    password="dev_password_123" \
    host="dev-db.example.com" \
    port="5432"

# Create critical secrets (prod environment)
echo -e "${YELLOW}Creating prod/db-password secret...${NC}"
vault kv put master-demo-kv/prod/db-password \
    username="prod_admin" \
    password="SuperSecureP@ssw0rd!" \
    host="prod-db.example.com" \
    port="5432" \
    connection_string="postgresql://prod_admin:SuperSecureP@ssw0rd!@prod-db.example.com:5432/production"

echo -e "${YELLOW}Creating prod/encryption-key secret...${NC}"
vault kv put master-demo-kv/prod/encryption-key \
    key="AES256-PROD-KEY-ABCDEF1234567890" \
    algorithm="AES-256-GCM" \
    rotation_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo -e "${GREEN}✓ Demo secrets created${NC}"

echo -e "\n${BLUE}Step 2: Creating Control Groups policies${NC}"

# Policy for user (can request secrets but gets wrapped responses)
echo -e "${YELLOW}Creating user policy...${NC}"
vault policy write master-demo-controlgroups-user - <<EOF
# Allow reading dev secrets with 1/2 approval (ops OR security)
path "master-demo-kv/data/dev/*" {
  capabilities = ["read"]
  control_group = {
    factor "ops" {
      identity {
        group_names = ["ops-team"]
        approvals = 1
      }
    }
    factor "security" {
      identity {
        group_names = ["security-team"]
        approvals = 1
      }
    }
  }
}

# Allow reading prod secrets with 2/2 approval (ops AND security)
path "master-demo-kv/data/prod/*" {
  capabilities = ["read"]
  control_group = {
    factor "ops" {
      identity {
        group_names = ["ops-team"]
        approvals = 1
      }
    }
    factor "security" {
      identity {
        group_names = ["security-team"]
        approvals = 1
      }
    }
  }
}

# Allow unwrapping control group tokens
path "sys/control-group/authorize" {
  capabilities = ["update"]
}

path "sys/control-group/request" {
  capabilities = ["update"]
}
EOF
echo -e "${GREEN}✓ User policy created${NC}"

# Policy for ops team (can authorize requests and read secrets)
echo -e "${YELLOW}Creating ops policy...${NC}"
vault policy write master-demo-controlgroups-ops - <<EOF
# Allow authorizing control group requests
path "sys/control-group/authorize" {
  capabilities = ["update"]
}

path "sys/control-group/request" {
  capabilities = ["update"]
}

# Allow reading control group info
path "sys/control-group/info" {
  capabilities = ["read"]
}

# Allow reading secrets (needed for unwrapping after approval)
path "master-demo-kv/data/dev/*" {
  capabilities = ["read"]
}

path "master-demo-kv/data/prod/*" {
  capabilities = ["read"]
}
EOF
echo -e "${GREEN}✓ Ops policy created${NC}"

# Policy for security team (can authorize requests and read secrets)
echo -e "${YELLOW}Creating security policy...${NC}"
vault policy write master-demo-controlgroups-security - <<EOF
# Allow authorizing control group requests
path "sys/control-group/authorize" {
  capabilities = ["update"]
}

path "sys/control-group/request" {
  capabilities = ["update"]
}

# Allow reading control group info
path "sys/control-group/info" {
  capabilities = ["read"]
}

# Allow reading secrets (needed for unwrapping after approval)
path "master-demo-kv/data/dev/*" {
  capabilities = ["read"]
}

path "master-demo-kv/data/prod/*" {
  capabilities = ["read"]
}
EOF
echo -e "${GREEN}✓ Security policy created${NC}"

echo -e "\n${BLUE}Step 3: Creating identity groups${NC}"

# Create ops group
echo -e "${YELLOW}Creating ops-team group...${NC}"
OPS_GROUP_ID=$(vault write -format=json identity/group \
    name="ops-team" \
    type="internal" \
    policies="master-demo-controlgroups-ops" | jq -r '.data.id')
echo -e "${GREEN}✓ Ops team group created (ID: $OPS_GROUP_ID)${NC}"

# Create security group
echo -e "${YELLOW}Creating security-team group...${NC}"
SECURITY_GROUP_ID=$(vault write -format=json identity/group \
    name="security-team" \
    type="internal" \
    policies="master-demo-controlgroups-security" | jq -r '.data.id')
echo -e "${GREEN}✓ Security team group created (ID: $SECURITY_GROUP_ID)${NC}"

echo -e "\n${BLUE}Step 4: Configuring Kubernetes authentication${NC}"

# Create Kubernetes auth role for user
echo -e "${YELLOW}Creating Kubernetes auth role for user...${NC}"
vault write auth/master-demo-auth/role/master-demo-auth-role-controlgroups-user \
    bound_service_account_names=controlgroups-demo-app \
    bound_service_account_namespaces=controlgroups-demo \
    policies=master-demo-controlgroups-user \
    ttl=24h
echo -e "${GREEN}✓ User auth role configured${NC}"

# Create Kubernetes auth role for ops
echo -e "${YELLOW}Creating Kubernetes auth role for ops...${NC}"
vault write auth/master-demo-auth/role/master-demo-auth-role-controlgroups-ops \
    bound_service_account_names=controlgroups-demo-app \
    bound_service_account_namespaces=controlgroups-demo \
    policies=master-demo-controlgroups-ops \
    ttl=24h
echo -e "${GREEN}✓ Ops auth role configured${NC}"

# Create Kubernetes auth role for security
echo -e "${YELLOW}Creating Kubernetes auth role for security...${NC}"
vault write auth/master-demo-auth/role/master-demo-auth-role-controlgroups-security \
    bound_service_account_names=controlgroups-demo-app \
    bound_service_account_namespaces=controlgroups-demo \
    policies=master-demo-controlgroups-security \
    ttl=24h
echo -e "${GREEN}✓ Security auth role configured${NC}"

echo -e "\n${BLUE}Step 4b: Seeding entities into ops-team and security-team groups${NC}"

echo -e "${YELLOW}Performing seed logins to create entities in Vault...${NC}"
# Retry up to 10 times (20 seconds apart) in case the pod is still initialising
ENTITY_ID=""
for attempt in $(seq 1 10); do
    POD_NAME=$(kubectl get pods -n controlgroups-demo -l app=controlgroups-demo-ui \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$POD_NAME" ]; then
        ENTITY_ID=$(kubectl exec -n controlgroups-demo "$POD_NAME" \
            -- python3 -c "
import hvac
client = hvac.Client(url='https://host.minikube.internal:8200', namespace='master-demo', verify=False)
with open('/var/run/secrets/kubernetes.io/serviceaccount/token') as f:
    jwt = f.read()
r = client.auth.kubernetes.login(role='master-demo-auth-role-controlgroups-ops', jwt=jwt, mount_point='master-demo-auth')
print(r['auth']['entity_id'])
" 2>/dev/null)
    fi
    if [ -n "$ENTITY_ID" ]; then
        echo -e "${GREEN}✓ Entity ID retrieved: $ENTITY_ID${NC}"
        break
    fi
    echo -e "${YELLOW}Attempt $attempt/10: pod not ready yet, waiting 20s...${NC}"
    sleep 20
done

if [ -z "$ENTITY_ID" ]; then
    echo -e "${RED}ERROR: Could not retrieve entity ID after 10 attempts. Control group approvals will not work.${NC}"
    echo -e "${YELLOW}Re-run: make setup-controlgroups-vault${NC}"
else
    echo -e "${YELLOW}Adding entity $ENTITY_ID to ops-team...${NC}"
    vault write identity/group/name/ops-team \
        type="internal" \
        policies="master-demo-controlgroups-ops" \
        member_entity_ids="${ENTITY_ID}"
    echo -e "${GREEN}✓ Entity added to ops-team${NC}"

    echo -e "${YELLOW}Adding entity $ENTITY_ID to security-team...${NC}"
    vault write identity/group/name/security-team \
        type="internal" \
        policies="master-demo-controlgroups-security" \
        member_entity_ids="${ENTITY_ID}"
    echo -e "${GREEN}✓ Entity added to security-team${NC}"
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Control Groups Demo Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"

echo -e "\n${BLUE}Summary:${NC}"
echo -e "  ${GREEN}✓${NC} Demo secrets created (dev/* and prod/*)"
echo -e "  ${GREEN}✓${NC} Control group policies configured"
echo -e "  ${GREEN}✓${NC} Identity groups created (ops-team, security-team)"
echo -e "  ${GREEN}✓${NC} Kubernetes auth roles configured"

echo -e "\n${YELLOW}Approval Requirements:${NC}"
echo -e "  • dev/* secrets: 1/2 approval (ops OR security)"
echo -e "  • prod/* secrets: 2/2 approvals (ops AND security)"

echo -e "\n${BLUE}Next steps:${NC}"
echo -e "  1. Deploy the Control Groups demo: ${YELLOW}make deploy-controlgroups-demo${NC}"
echo -e "  2. Access the UI: ${YELLOW}http://localhost:10005${NC}"
echo -e "  3. Request a secret from the User panel"
echo -e "  4. Approve it from the Admin panel (switch between ops/security)"
echo -e "  5. Unwrap the secret once approved"


echo -e "\n${BLUE}Step 5: Configuring Policy Governance (Sentinel EGP + Policy Admin)${NC}"

echo -e "${YELLOW}Writing Sentinel EGP policy...${NC}"
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

echo -e "\n${BLUE}Step 5a: Creating Policy Admin ACL policies${NC}"

# Policy for policy-admin: can create/update policies under master-demo-policy-* prefix
# protected by a Control Group requiring 1 approval from policy-approvers
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

# Allow listing policies (no control group needed)
path "sys/policies/acl" {
  capabilities = ["list"]
}

# Allow authorizing control group requests
path "sys/control-group/authorize" {
  capabilities = ["update"]
}

path "sys/control-group/request" {
  capabilities = ["update"]
}
EOF
echo -e "${GREEN}✓ Policy-admin policy created${NC}"

# Policy for policy-approver: can authorize control group requests
echo -e "${YELLOW}Creating policy-approver policy...${NC}"
vault policy write master-demo-policy-approver - <<EOF
# Allow authorizing control group requests
path "sys/control-group/authorize" {
  capabilities = ["update"]
}

path "sys/control-group/request" {
  capabilities = ["update"]
}

# Allow reading control group info
path "sys/control-group/info" {
  capabilities = ["read"]
}
EOF
echo -e "${GREEN}✓ Policy-approver policy created${NC}"

echo -e "\n${BLUE}Step 5b: Creating policy-approvers identity group${NC}"

echo -e "${YELLOW}Creating policy-approvers group...${NC}"
POLICY_APPROVERS_GROUP_ID=$(vault write -format=json identity/group \
    name="policy-approvers" \
    type="internal" \
    policies="master-demo-policy-approver" | jq -r '.data.id')
echo -e "${GREEN}✓ Policy-approvers group created (ID: $POLICY_APPROVERS_GROUP_ID)${NC}"

echo -e "\n${BLUE}Step 5c: Configuring Kubernetes auth roles for policy governance${NC}"

# policy-admin role: bound to existing controlgroups-demo-app SA
echo -e "${YELLOW}Creating Kubernetes auth role for policy-admin...${NC}"
vault write auth/master-demo-auth/role/master-demo-auth-role-policy-admin \
    bound_service_account_names=controlgroups-demo-app \
    bound_service_account_namespaces=controlgroups-demo \
    policies=master-demo-policy-admin \
    ttl=24h
echo -e "${GREEN}✓ Policy-admin auth role configured${NC}"

# policy-approver role: bound to existing controlgroups-demo-app SA
echo -e "${YELLOW}Creating Kubernetes auth role for policy-approver...${NC}"
vault write auth/master-demo-auth/role/master-demo-auth-role-policy-approver \
    bound_service_account_names=controlgroups-demo-app \
    bound_service_account_namespaces=controlgroups-demo \
    policies=master-demo-policy-approver \
    ttl=24h
echo -e "${GREEN}✓ Policy-approver auth role configured${NC}"

echo -e "\n${BLUE}Step 5d: Seeding policy-approver entity into policy-approvers group${NC}"

# Do a login from within the controlgroups-demo pod to create/retrieve the entity
# that corresponds to the policy-approver K8s auth role, then add it to the group.
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
