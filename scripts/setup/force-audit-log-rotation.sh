#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Forcing Vault Audit Log Rotation ===${NC}"

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

export VAULT_NAMESPACE=master-demo

echo -e "${GREEN}Using Vault at: $VAULT_ADDR${NC}"

# Check Vault status
echo -e "\n${GREEN}Checking Vault status...${NC}"
if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to Vault at $VAULT_ADDR${NC}"
    exit 1
fi

AUDIT_LOG_PATH="$HOME/audit.log"

# Check current log size
if [ -f "$AUDIT_LOG_PATH" ]; then
    CURRENT_SIZE=$(du -h "$AUDIT_LOG_PATH" | cut -f1)
    CURRENT_SIZE_BYTES=$(stat -f%z "$AUDIT_LOG_PATH" 2>/dev/null || stat -c%s "$AUDIT_LOG_PATH" 2>/dev/null)
    echo -e "${BLUE}Current audit log size: ${CURRENT_SIZE} (${CURRENT_SIZE_BYTES} bytes)${NC}"
    
    # Check if size is over 100MB
    if [ "$CURRENT_SIZE_BYTES" -gt 104857600 ]; then
        echo -e "${YELLOW}⚠ Log file is larger than 100MB - rotation should have occurred${NC}"
    fi
else
    echo -e "${RED}ERROR: Audit log file not found at $AUDIT_LOG_PATH${NC}"
    exit 1
fi

# List existing rotated files
echo -e "\n${BLUE}Existing audit log files:${NC}"
ls -lh "$AUDIT_LOG_PATH"* 2>/dev/null || echo "Only audit.log exists"

# Manual rotation process
echo -e "\n${GREEN}Performing manual rotation...${NC}"

# Step 1: Disable audit device
echo -e "${YELLOW}1. Disabling master-demo audit device...${NC}"
vault audit disable master-demo-audit/ || {
    echo -e "${RED}Failed to disable audit device${NC}"
    exit 1
}
echo -e "${GREEN}✓ Master-demo audit device disabled${NC}"

# Step 2: Rotate the log file manually
echo -e "\n${YELLOW}2. Rotating log file manually...${NC}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# If audit.log.1 exists, remove it (we only keep 1 rotated file)
if [ -f "${AUDIT_LOG_PATH}.1" ]; then
    echo -e "${YELLOW}   Removing old rotated file: ${AUDIT_LOG_PATH}.1${NC}"
    rm -f "${AUDIT_LOG_PATH}.1"
fi

# Rename current log to .1
if [ -f "$AUDIT_LOG_PATH" ]; then
    echo -e "${YELLOW}   Moving ${AUDIT_LOG_PATH} to ${AUDIT_LOG_PATH}.1${NC}"
    mv "$AUDIT_LOG_PATH" "${AUDIT_LOG_PATH}.1"
    
    # Optionally compress the rotated file
    echo -e "${YELLOW}   Compressing rotated file...${NC}"
    gzip "${AUDIT_LOG_PATH}.1"
    echo -e "${GREEN}✓ Log file rotated and compressed${NC}"
else
    echo -e "${YELLOW}   No current log file to rotate${NC}"
fi

# Step 3: Re-enable audit device with rotation settings
echo -e "\n${YELLOW}3. Re-enabling master-demo audit device with rotation...${NC}"
vault audit enable -path=master-demo-audit file \
    file_path="$AUDIT_LOG_PATH" \
    rotate_bytes=104857600 \
    rotate_max_files=1 \
    rotate_duration=24h || {
    echo -e "${RED}Failed to re-enable audit device${NC}"
    exit 1
}
echo -e "${GREEN}✓ Audit device re-enabled${NC}"

# Step 4: Verify new log file was created
sleep 2
if [ -f "$AUDIT_LOG_PATH" ]; then
    NEW_SIZE=$(du -h "$AUDIT_LOG_PATH" | cut -f1)
    echo -e "${GREEN}✓ New audit log created (size: ${NEW_SIZE})${NC}"
else
    echo -e "${RED}ERROR: New audit log was not created${NC}"
    exit 1
fi

# Step 5: Restart audit exporter pod if it exists
echo -e "\n${YELLOW}4. Restarting audit exporter pod...${NC}"
if kubectl get namespace audit-monitoring > /dev/null 2>&1; then
    if kubectl get pods -n audit-monitoring -l app=vault-audit-exporter > /dev/null 2>&1; then
        kubectl delete pod -n audit-monitoring -l app=vault-audit-exporter
        sleep 5
        echo -e "${GREEN}✓ Audit exporter pod restarted${NC}"
    else
        echo -e "${YELLOW}No audit exporter pod found${NC}"
    fi
else
    echo -e "${YELLOW}Audit monitoring namespace not found${NC}"
fi

# Summary
echo -e "\n${GREEN}=== Rotation Complete ===${NC}"
echo -e "${BLUE}Current audit log files:${NC}"
ls -lh "$AUDIT_LOG_PATH"* 2>/dev/null

echo -e "\n${YELLOW}Note: Vault's built-in rotation doesn't always work reliably on macOS.${NC}"
echo -e "${YELLOW}You may need to run this script periodically to manually rotate logs.${NC}"
echo -e "\n${BLUE}To automate this, you can:${NC}"
echo -e "  1. Add to crontab: crontab -e"
echo -e "  2. Add this line to run daily at 2 AM:"
echo -e "     0 2 * * * cd $(pwd) && ./scripts/setup/force-audit-log-rotation.sh"
echo -e "\n${GREEN}Or run manually when needed: make force-audit-rotation${NC}"

# Made with Bob