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

# Policy for ops team (can authorize requests)
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
EOF
echo -e "${GREEN}✓ Ops policy created${NC}"

# Policy for security team (can authorize requests)
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

# Made with Bob
