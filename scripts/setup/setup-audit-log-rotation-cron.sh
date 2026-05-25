#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Setting Up Automatic Audit Log Rotation ===${NC}"

# Get the absolute path to the project directory
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROTATION_SCRIPT="$PROJECT_DIR/scripts/setup/auto-rotate-audit-log.sh"
CRON_JOB="0 */6 * * * $ROTATION_SCRIPT >> /tmp/vault-audit-rotation.log 2>&1"

echo -e "${BLUE}Project directory: $PROJECT_DIR${NC}"

# Check if the auto-rotation script exists
if [ ! -f "$ROTATION_SCRIPT" ]; then
    echo -e "${RED}ERROR: Auto-rotation script not found at $ROTATION_SCRIPT${NC}"
    exit 1
fi

# Make sure the script is executable
chmod +x "$ROTATION_SCRIPT"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "$ROTATION_SCRIPT"; then
    echo -e "${YELLOW}Cron job already exists. Removing old entry...${NC}"
    crontab -l 2>/dev/null | grep -v "$ROTATION_SCRIPT" | crontab -
fi

# Add the cron job
echo -e "${GREEN}Adding cron job to check audit log every 6 hours...${NC}"
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo -e "${GREEN}✓ Cron job added successfully${NC}"

# Display current crontab
echo -e "\n${BLUE}Current crontab:${NC}"
crontab -l | grep -A 1 -B 1 "$ROTATION_SCRIPT" || crontab -l

echo -e "\n${GREEN}=== Automatic Rotation Setup Complete ===${NC}"
echo -e "${BLUE}Configuration:${NC}"
echo -e "  - Check frequency: Every 6 hours"
echo -e "  - Rotation threshold: 100MB"
echo -e "  - Script location: $ROTATION_SCRIPT"
echo -e "  - Log file: /tmp/vault-audit-rotation.log"
echo -e "\n${YELLOW}The script will automatically rotate the audit log when it exceeds 100MB.${NC}"
echo -e "${YELLOW}Check rotation log: tail -f /tmp/vault-audit-rotation.log${NC}"
echo -e "\n${BLUE}To remove automatic rotation:${NC}"
echo -e "  crontab -e"
echo -e "  (Delete the line containing: $ROTATION_SCRIPT)"
echo -e "\n${BLUE}To manually trigger rotation now:${NC}"
echo -e "  make force-audit-rotation"

# Made with Bob