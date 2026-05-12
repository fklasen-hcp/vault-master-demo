#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Generating Vault Audit Traffic for Testing ===${NC}"

# Check if VAULT_ADDR and VAULT_TOKEN are set
if [ -z "$VAULT_ADDR" ]; then
    export VAULT_ADDR=https://127.0.0.1:8200
fi

if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${YELLOW}VAULT_TOKEN not set. Using root token from environment.${NC}"
fi

echo -e "${BLUE}Generating KV operations...${NC}"
# KV operations
vault kv put vso-demo-kv/test/data key1=value1 key2=value2 2>/dev/null || true
vault kv get vso-demo-kv/test/data 2>/dev/null || true
vault kv get vso-demo-kv/webapp/config 2>/dev/null || true
vault kv metadata get vso-demo-kv/webapp/config 2>/dev/null || true

echo -e "${BLUE}Generating database credential requests...${NC}"
# Database operations
vault read vso-demo-db/creds/dev-postgres 2>/dev/null || true
vault read vso-demo-db/creds/dev-postgres 2>/dev/null || true

echo -e "${BLUE}Generating PKI operations...${NC}"
# PKI operations
vault write vso-demo-pki-issuing/issue/vso-demo-cert-issuer \
  common_name="test.local" \
  ttl="30s" 2>/dev/null || true

vault write vso-demo-pki-issuing/issue/vso-demo-cert-issuer \
  common_name="demo.local" \
  alt_names="www.demo.local,api.demo.local" \
  ttl="30s" 2>/dev/null || true

echo -e "${BLUE}Generating token operations...${NC}"
# Token operations
vault token renew -self 2>/dev/null || true
vault token lookup -self 2>/dev/null || true

echo -e "${BLUE}Generating system operations...${NC}"
# System operations
vault read sys/health 2>/dev/null || true
vault read sys/mounts 2>/dev/null || true
vault list sys/auth 2>/dev/null || true

echo -e "${BLUE}Generating some intentional errors...${NC}"
# Generate some errors for testing error metrics
vault kv get vso-demo-kv/nonexistent/path 2>/dev/null || true
vault read vso-demo-db/creds/nonexistent-role 2>/dev/null || true

echo -e "${GREEN}✓ Test traffic generated${NC}"
echo -e "${YELLOW}Check the Grafana dashboard to see the metrics:${NC}"
echo -e "  ${BLUE}make grafana-port-forward${NC}"
echo -e "  ${BLUE}http://localhost:3000${NC}"

# Made with Bob
