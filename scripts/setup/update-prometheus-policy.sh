#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Updating Master-Demo Prometheus Policy ===${NC}"

# Check if VAULT_TOKEN is set
if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${RED}ERROR: VAULT_TOKEN is not set${NC}"
    echo "Please set your Vault root token:"
    echo "  export VAULT_TOKEN=your-token-here"
    exit 1
fi

# Check if VAULT_ADDR is set
if [ -z "$VAULT_ADDR" ]; then
    echo -e "${YELLOW}VAULT_ADDR not set. Using default: https://127.0.0.1:8200${NC}"
    export VAULT_ADDR=https://127.0.0.1:8200
fi

echo -e "${GREEN}Using Vault at: $VAULT_ADDR${NC}"

# Check Vault status
echo -e "\n${GREEN}Checking Vault status...${NC}"
if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to Vault at $VAULT_ADDR${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Vault is accessible${NC}"

# Update the master-demo-prometheus policy in root namespace
echo -e "\n${BLUE}Updating 'master-demo-prometheus' policy in root namespace...${NC}"
unset VAULT_NAMESPACE  # Ensure we're in root namespace
export VAULT_SKIP_VERIFY=true

vault policy write master-demo-prometheus - <<EOF
# Read-only access to telemetry metrics for Prometheus scraping
# This policy is created in the root namespace as sys/metrics is a global endpoint
path "sys/metrics" {
  capabilities = ["read"]
}

# Access to master-demo namespace metrics
path "master-demo/sys/metrics" {
  capabilities = ["read"]
}

# List capabilities for master-demo namespace
path "master-demo/sys/mounts" {
  capabilities = ["read", "list"]
}

path "master-demo/sys/auth" {
  capabilities = ["read", "list"]
}
EOF

unset VAULT_SKIP_VERIFY

echo -e "${GREEN}✓ 'master-demo-prometheus' policy updated successfully${NC}"

echo -e "\n${BLUE}Current policy contents:${NC}"
vault policy read master-demo-prometheus

echo -e "\n${GREEN}=== Policy Update Complete ===${NC}"
echo -e "${YELLOW}Note: Existing Prometheus tokens will automatically use the updated policy${NC}"
echo -e "${YELLOW}No need to restart Prometheus - the policy change takes effect immediately${NC}"

# Made with Bob