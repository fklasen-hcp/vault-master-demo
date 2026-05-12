#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Enabling Vault Audit Log Rotation ===${NC}"

# Check if VAULT_ADDR and VAULT_TOKEN are set
if [ -z "$VAULT_ADDR" ]; then
    echo -e "${YELLOW}VAULT_ADDR not set. Using default: https://127.0.0.1:8200${NC}"
    export VAULT_ADDR=https://127.0.0.1:8200
fi

if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${RED}ERROR: VAULT_TOKEN is not set. Please set it to your Vault root token.${NC}"
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

AUDIT_LOG_PATH="$HOME/audit.log"

# Check if audit device exists
echo -e "\n${BLUE}Checking for existing audit device...${NC}"
if vault audit list | grep -q "file/"; then
    echo -e "${YELLOW}Disabling existing file audit device...${NC}"
    vault audit disable file/ || {
        echo -e "${RED}Failed to disable audit device${NC}"
        exit 1
    }
    echo -e "${GREEN}✓ Existing audit device disabled${NC}"
else
    echo -e "${YELLOW}No existing file audit device found${NC}"
fi

# Enable audit device with rotation
echo -e "\n${GREEN}Enabling audit device with log rotation...${NC}"
echo -e "${BLUE}Configuration:${NC}"
echo -e "  - File path: $AUDIT_LOG_PATH"
echo -e "  - Rotate at: 100MB"
echo -e "  - Max files: 1 (keeps current + 1 rotated file)"
echo -e "  - Rotate duration: 24h"

vault audit enable file \
    file_path="$AUDIT_LOG_PATH" \
    rotate_bytes=104857600 \
    rotate_max_files=1 \
    rotate_duration=24h || {
    echo -e "${RED}Failed to enable audit device with rotation${NC}"
    exit 1
}

echo -e "${GREEN}✓ Audit device enabled with log rotation${NC}"

# Restart audit exporter pod if it exists
echo -e "\n${BLUE}Checking for audit exporter pod...${NC}"
if kubectl get namespace audit-monitoring > /dev/null 2>&1; then
    if kubectl get pods -n audit-monitoring -l app=vault-audit-exporter > /dev/null 2>&1; then
        echo -e "${YELLOW}Restarting audit exporter pod...${NC}"
        kubectl delete pod -n audit-monitoring -l app=vault-audit-exporter
        sleep 5
        echo -e "${GREEN}✓ Audit exporter pod restarted${NC}"
    else
        echo -e "${YELLOW}No audit exporter pod found (this is OK if audit monitoring isn't set up yet)${NC}"
    fi
else
    echo -e "${YELLOW}Audit monitoring namespace not found (this is OK if audit monitoring isn't set up yet)${NC}"
fi

echo -e "\n${GREEN}=== Log Rotation Enabled Successfully ===${NC}"
echo -e "${BLUE}Rotation settings:${NC}"
echo -e "  - Logs will rotate when they reach 100MB"
echo -e "  - Keeps 1 rotated file (audit.log.1) plus current file"
echo -e "  - Logs will also rotate every 24 hours"
echo -e "  - Maximum disk usage: ~200MB (current + 1 rotated file)"
echo -e "\n${YELLOW}Note: Vault Enterprise handles rotation automatically - no cron or logrotate needed!${NC}"

# Made with Bob
