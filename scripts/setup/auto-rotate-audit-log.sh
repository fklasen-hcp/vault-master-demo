#!/bin/bash

# Automatic Audit Log Rotation Script using logrotate
# This script rotates the audit log file without requiring Vault CLI access
# Designed to be run via cron

# Configuration
AUDIT_LOG_PATH="$HOME/audit.log"
MAX_SIZE_BYTES=104857600  # 100MB
LOG_FILE="/tmp/vault-audit-rotation.log"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Main execution
log_message "=== Audit Log Rotation Check Started ==="

# Check if audit log exists
if [ ! -f "$AUDIT_LOG_PATH" ]; then
    log_message "Audit log file not found at $AUDIT_LOG_PATH. Exiting."
    exit 0
fi

# Get current file size
CURRENT_SIZE=$(stat -f%z "$AUDIT_LOG_PATH" 2>/dev/null || stat -c%s "$AUDIT_LOG_PATH" 2>/dev/null || echo "0")
CURRENT_SIZE_MB=$((CURRENT_SIZE / 1024 / 1024))

log_message "Current audit log size: ${CURRENT_SIZE_MB}MB"

# Check if rotation is needed
if [ "$CURRENT_SIZE" -gt "$MAX_SIZE_BYTES" ]; then
    log_message "Audit log exceeds 100MB threshold (${CURRENT_SIZE_MB}MB). Starting rotation..."
    
    # Remove old rotated file if it exists (keep only 1 rotated file)
    if [ -f "${AUDIT_LOG_PATH}.1.gz" ]; then
        rm -f "${AUDIT_LOG_PATH}.1.gz"
        log_message "Removed old rotated file: ${AUDIT_LOG_PATH}.1.gz"
    fi
    
    # Copy current log to .1 (Vault keeps writing to the original file)
    if cp "$AUDIT_LOG_PATH" "${AUDIT_LOG_PATH}.1"; then
        log_message "Copied current log to ${AUDIT_LOG_PATH}.1"
        
        # Truncate the original file (Vault continues writing from position 0)
        if > "$AUDIT_LOG_PATH"; then
            log_message "Truncated original log file"
            
            # Compress the rotated file in background
            (gzip "${AUDIT_LOG_PATH}.1" && log_message "Compressed rotated file") &
            
            # Restart audit exporter if it exists (to reset metrics)
            if kubectl get namespace audit-monitoring > /dev/null 2>&1; then
                if kubectl get pods -n audit-monitoring -l app=vault-audit-exporter > /dev/null 2>&1; then
                    log_message "Restarting audit exporter pod..."
                    kubectl delete pod -n audit-monitoring -l app=vault-audit-exporter >> "$LOG_FILE" 2>&1 || true
                fi
            fi
            
            log_message "SUCCESS: Audit log rotated successfully"
            log_message "New log size: 0MB, Rotated file: ${AUDIT_LOG_PATH}.1.gz"
        else
            log_message "ERROR: Failed to truncate original log file"
            exit 1
        fi
    else
        log_message "ERROR: Failed to copy log file"
        exit 1
    fi
else
    log_message "Audit log size is OK (${CURRENT_SIZE_MB}MB). No rotation needed."
fi

log_message "=== Audit Log Rotation Check Completed ==="

# Made with Bob