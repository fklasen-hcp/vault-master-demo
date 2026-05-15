#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Setting up Vault Audit Monitoring ===${NC}"

# Note: Audit devices are global in Vault and must be configured in root namespace
# Unset namespace for audit device operations
unset VAULT_NAMESPACE

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

# Enable file audit device
AUDIT_LOG_PATH="$HOME/audit.log"
echo -e "\n${GREEN}Enabling Vault file audit device...${NC}"

# Check if audit device already exists
if vault audit list | grep -q "file/"; then
    echo -e "${YELLOW}File audit device already enabled${NC}"
else
    vault audit enable file file_path="$AUDIT_LOG_PATH" || {
        echo -e "${RED}Failed to enable audit device${NC}"
        exit 1
    }
    echo -e "${GREEN}✓ File audit device enabled at $AUDIT_LOG_PATH${NC}"
fi

# Ensure audit log file exists
if [ ! -f "$AUDIT_LOG_PATH" ]; then
    echo -e "${YELLOW}Creating audit log file...${NC}"
    touch "$AUDIT_LOG_PATH"
    chmod 640 "$AUDIT_LOG_PATH"
fi

# Check Vault telemetry availability (non-blocking)
check_vault_telemetry() {
    echo -e "\n${GREEN}Checking Vault telemetry availability...${NC}"
    
    # Test telemetry endpoint
    TELEMETRY_CHECK=$(curl -sk -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/sys/metrics?format=prometheus" 2>/dev/null)
    
    if echo "$TELEMETRY_CHECK" | grep -q "vault_core_"; then
        echo -e "${GREEN}✓ Vault telemetry is enabled and accessible${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ Vault telemetry is not available${NC}"
        echo -e "${YELLOW}  Telemetry monitoring will be skipped${NC}"
        echo -e "${YELLOW}  To enable, add to your Vault config:${NC}"
        echo -e "${YELLOW}    telemetry {${NC}"
        echo -e "${YELLOW}      prometheus_retention_time = \"5m\"${NC}"
        echo -e "${YELLOW}    }${NC}"
        echo -e "${YELLOW}  Continuing with audit monitoring only...${NC}"
        return 1
    fi
}

# Check telemetry availability (secret will be created after namespace exists)
TELEMETRY_ENABLED=false
if check_vault_telemetry; then
    TELEMETRY_ENABLED=true
    echo -e "${GREEN}✓ Telemetry monitoring will be enabled${NC}"
    echo -e "${YELLOW}Note: Vault token secret will be created after namespace setup${NC}"
fi

echo -e "${GREEN}✓ Audit log file ready: $AUDIT_LOG_PATH${NC}"

# Mount home directory into minikube
echo -e "\n${GREEN}Mounting home directory into minikube...${NC}"

# Check if minikube is running
if ! minikube status | grep -q "host: Running"; then
    echo -e "${RED}ERROR: Minikube is not running${NC}"
    exit 1
fi

# Kill any existing mount processes (they may be stale from previous minikube instance)
EXISTING_MOUNT=$(pgrep -f "minikube mount.*home.*host-home" || true)
if [ -n "$EXISTING_MOUNT" ]; then
    echo -e "${YELLOW}Killing stale mount process (PID: $EXISTING_MOUNT)...${NC}"
    kill $EXISTING_MOUNT 2>/dev/null || true
    sleep 2
fi

# Start fresh mount
echo -e "${BLUE}Starting minikube mount in background...${NC}"
nohup minikube mount $HOME:/host-home --gid=1000 --uid=1000 > /tmp/minikube-mount.log 2>&1 &
MOUNT_PID=$!
echo -e "${YELLOW}Waiting for mount to be ready...${NC}"

# Wait for mount to be ready (check log for success message)
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if grep -q "Successfully mounted" /tmp/minikube-mount.log 2>/dev/null; then
        echo -e "${GREEN}✓ Home directory mounted at /host-home in minikube${NC}"
        echo -e "${YELLOW}Note: The mount process must stay running (PID: $MOUNT_PID)${NC}"
        break
    fi
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ $WAIT_COUNT -eq $MAX_WAIT ]; then
    echo -e "${RED}Mount did not complete within ${MAX_WAIT} seconds${NC}"
    echo -e "${YELLOW}Check /tmp/minikube-mount.log for details:${NC}"
    tail -20 /tmp/minikube-mount.log 2>/dev/null || true
    exit 1
fi

# Build Docker image for exporter
echo -e "\n${GREEN}Building vault-audit-exporter Docker image...${NC}"
cd audit-monitoring/exporter
eval $(minikube docker-env)
docker build -t vault-audit-exporter:latest . || {
    echo -e "${RED}Failed to build Docker image${NC}"
    exit 1
}
cd ../..
echo -e "${GREEN}✓ Docker image built successfully${NC}"

# Deploy Kubernetes resources
echo -e "\n${GREEN}Deploying Kubernetes resources...${NC}"

# Create namespace
echo -e "${BLUE}Creating audit-monitoring namespace...${NC}"
kubectl apply -f audit-monitoring/kubernetes/00-namespace.yaml

# Create Vault token secret if telemetry is enabled
if [ "$TELEMETRY_ENABLED" = true ]; then
    echo -e "\n${GREEN}Creating Vault token secret for Prometheus...${NC}"
    if kubectl create secret generic vault-token \
        --from-literal=token="$VAULT_TOKEN" \
        -n audit-monitoring \
        --dry-run=client -o yaml | kubectl apply -f -; then
        
        # Verify the secret was created and has content
        TOKEN_LENGTH=$(kubectl get secret vault-token -n audit-monitoring -o jsonpath='{.data.token}' 2>/dev/null | base64 -d | wc -c | tr -d ' ')
        if [ "$TOKEN_LENGTH" -gt 0 ]; then
            echo -e "${GREEN}✓ Vault token secret created successfully (${TOKEN_LENGTH} bytes)${NC}"
        else
            echo -e "${RED}ERROR: Vault token secret was created but is empty!${NC}"
            echo -e "${RED}This will prevent telemetry from working.${NC}"
            TELEMETRY_ENABLED=false
        fi
    else
        echo -e "${RED}ERROR: Failed to create vault-token secret${NC}"
        echo -e "${YELLOW}Telemetry monitoring will be disabled${NC}"
        TELEMETRY_ENABLED=false
    fi
fi

# Deploy exporter
echo -e "${BLUE}Deploying Vault audit exporter...${NC}"
kubectl apply -f audit-monitoring/kubernetes/01-exporter-deployment.yaml

# Deploy Prometheus
echo -e "${BLUE}Deploying Prometheus...${NC}"
kubectl apply -f audit-monitoring/kubernetes/02-prometheus-config.yaml
kubectl apply -f audit-monitoring/kubernetes/03-prometheus-deployment.yaml

# Deploy Grafana
echo -e "${BLUE}Deploying Grafana...${NC}"
kubectl apply -f audit-monitoring/kubernetes/04-grafana-config.yaml

# Create dashboard ConfigMap from JSON file
echo -e "${BLUE}Creating Grafana dashboard ConfigMap from file...${NC}"
kubectl create configmap grafana-dashboard-vault-audit \
    --from-file=audit-monitoring/grafana/vault-audit-dashboard.json \
    -n audit-monitoring \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f audit-monitoring/kubernetes/05-grafana-deployment.yaml

echo -e "${GREEN}✓ All Kubernetes resources deployed${NC}"

# Wait for pods to be ready
echo -e "\n${GREEN}Waiting for pods to be ready...${NC}"

echo -e "${BLUE}Waiting for exporter...${NC}"
kubectl wait --for=condition=ready pod -l app=vault-audit-exporter -n audit-monitoring --timeout=120s || {
    echo -e "${YELLOW}Warning: Exporter pod not ready yet. Check logs with: make audit-exporter-logs${NC}"
}

echo -e "${BLUE}Waiting for Prometheus...${NC}"
kubectl wait --for=condition=ready pod -l app=prometheus -n audit-monitoring --timeout=120s || {
    echo -e "${YELLOW}Warning: Prometheus pod not ready yet${NC}"
}

echo -e "${BLUE}Waiting for Grafana...${NC}"
kubectl wait --for=condition=ready pod -l app=grafana -n audit-monitoring --timeout=120s || {
    echo -e "${YELLOW}Warning: Grafana pod not ready yet${NC}"
}

# Display status
echo -e "\n${GREEN}=== Audit Monitoring Status ===${NC}"
kubectl get pods -n audit-monitoring
echo ""
kubectl get svc -n audit-monitoring

# Display access information
echo -e "\n${GREEN}=== Access Information ===${NC}"
echo -e "${BLUE}Grafana Dashboards:${NC}"
echo -e "  URL: ${YELLOW}http://localhost:3000${NC}"
echo -e "  Username: ${YELLOW}admin${NC}"
echo -e "  Password: ${YELLOW}admin${NC}"
echo -e "  Dashboards:"
echo -e "    - ${YELLOW}Vault Audit Monitoring${NC} (audit logs)"
if [ "$TELEMETRY_ENABLED" = true ]; then
    echo -e "    - ${YELLOW}Vault Telemetry & Performance${NC} (metrics)"
fi
echo -e "  Command: ${YELLOW}make grafana-port-forward${NC}"
echo ""
echo -e "${BLUE}Prometheus:${NC}"
echo -e "  URL: ${YELLOW}http://localhost:9090${NC}"
echo -e "  Command: ${YELLOW}make prometheus-port-forward${NC}"
echo ""
echo -e "${BLUE}Exporter Metrics:${NC}"
echo -e "  URL: ${YELLOW}http://localhost:9091/metrics${NC}"
echo -e "  Command: ${YELLOW}kubectl port-forward -n audit-monitoring svc/vault-audit-exporter 9091:9091${NC}"

# Display useful commands
echo -e "\n${GREEN}=== Useful Commands ===${NC}"
echo -e "  View exporter logs:     ${YELLOW}make audit-exporter-logs${NC}"
echo -e "  Check status:           ${YELLOW}make audit-monitoring-status${NC}"
echo -e "  Access Grafana:         ${YELLOW}make grafana-port-forward${NC}"
echo -e "  Access Prometheus:      ${YELLOW}make prometheus-port-forward${NC}"
echo -e "  Generate test traffic:  ${YELLOW}make test-audit-traffic${NC}"
echo -e "  Clean up:               ${YELLOW}make clean-audit-monitoring${NC}"

echo -e "\n${GREEN}=== Setup Complete! ===${NC}"
if [ "$TELEMETRY_ENABLED" = true ]; then
    echo -e "${GREEN}✓ Audit monitoring and telemetry monitoring deployed${NC}"
else
    echo -e "${GREEN}✓ Audit monitoring deployed (telemetry skipped)${NC}"
fi
echo -e "${YELLOW}Note: It may take a few minutes for all services to be fully operational.${NC}"
echo -e "${YELLOW}Use 'make grafana-port-forward' to access the dashboards.${NC}"

# Made with Bob
