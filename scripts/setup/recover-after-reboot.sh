#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}=== Vault Secrets Operator Recovery ===${NC}"
echo -e "${GREEN}=== After Minikube Reboot/Sleep      ===${NC}"
echo -e "${GREEN}========================================${NC}"

# Function to print section headers
print_section() {
    echo -e "\n${BLUE}>>> $1${NC}"
}

# Function to print success messages
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Function to print warning messages
print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Function to print error messages
print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Check prerequisites
print_section "Checking Prerequisites"

# Check if VAULT_TOKEN is set
if [ -z "$VAULT_TOKEN" ]; then
    print_error "VAULT_TOKEN is not set"
    echo "Please set your Vault token:"
    echo "  export VAULT_TOKEN=your-token-here"
    exit 1
fi
print_success "VAULT_TOKEN is set"

# Check if VAULT_ADDR is set
if [ -z "$VAULT_ADDR" ]; then
    print_warning "VAULT_ADDR not set, using default: https://127.0.0.1:8200"
    export VAULT_ADDR=https://127.0.0.1:8200
fi
print_success "VAULT_ADDR: $VAULT_ADDR"

# Set namespace
export VAULT_NAMESPACE=master-demo
print_success "VAULT_NAMESPACE: $VAULT_NAMESPACE"

# Check Vault connectivity
print_section "Verifying Vault Connectivity"
if ! vault status > /dev/null 2>&1; then
    print_error "Cannot connect to Vault at $VAULT_ADDR"
    echo "Please ensure:"
    echo "  1. Vault is running"
    echo "  2. Vault is unsealed"
    echo "  3. VAULT_TOKEN is valid"
    exit 1
fi
print_success "Vault is accessible and unsealed"

# Check minikube status
print_section "Checking Minikube Status"
if ! minikube status | grep -q "host: Running"; then
    print_error "Minikube is not running"
    echo "Please start minikube first:"
    echo "  minikube start"
    exit 1
fi
print_success "Minikube is running"

# Step 1: Reconfigure Vault Kubernetes Auth (ROOT CAUSE FIX)
print_section "Step 1: Reconfiguring Vault Kubernetes Auth"
echo "This fixes the root cause: stale Kubernetes credentials in Vault after reboot"

# Get fresh Kubernetes configuration
print_warning "Extracting fresh Kubernetes configuration..."
KUBE_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.server}')
KUBE_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

echo "  Kubernetes API: $KUBE_HOST"

# Ensure service account exists
kubectl create namespace vault-secrets-operator-system 2>/dev/null || true

# Check if service account exists, create if not
if ! kubectl get serviceaccount vault-auth-reviewer -n vault-secrets-operator-system > /dev/null 2>&1; then
    print_warning "Creating vault-auth-reviewer service account..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth-reviewer
  namespace: vault-secrets-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-auth-reviewer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-auth-reviewer
  namespace: vault-secrets-operator-system
EOF
    sleep 3
fi

# Generate new service account token (10-year duration)
print_warning "Generating fresh service account token..."
TOKEN_REVIEWER_JWT=$(kubectl create token vault-auth-reviewer -n vault-secrets-operator-system --duration=87600h)

# Reconfigure Vault Kubernetes auth with fresh credentials
print_warning "Updating Vault Kubernetes auth configuration..."
vault write auth/master-demo-auth/config \
    kubernetes_host="$KUBE_HOST" \
    kubernetes_ca_cert="$KUBE_CA_CERT" \
    token_reviewer_jwt="$TOKEN_REVIEWER_JWT"

print_success "Vault Kubernetes auth reconfigured with fresh credentials"

# Verify the configuration was applied
print_warning "Verifying Kubernetes auth configuration..."
if vault read auth/master-demo-auth/config > /dev/null 2>&1; then
    print_success "Kubernetes auth configuration verified"
else
    print_error "Failed to verify Kubernetes auth configuration"
    exit 1
fi

# Step 2: Restart VSO Controller
print_section "Step 2: Restarting Vault Secrets Operator"
kubectl rollout restart deployment/vault-secrets-operator-controller-manager -n vault-secrets-operator-system

print_warning "Waiting for VSO rollout to complete (timeout: 5 minutes)..."
if kubectl rollout status deployment/vault-secrets-operator-controller-manager -n vault-secrets-operator-system --timeout=5m; then
    print_success "VSO controller restarted successfully"
else
    print_error "VSO controller restart failed or timed out"
    echo "Check logs with: kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator"
    exit 1
fi

# Step 3: Verify Minikube Mount for Audit Monitoring
print_section "Step 3: Verifying Minikube Mount for Audit Monitoring"

# Check if audit-monitoring namespace exists
if kubectl get namespace audit-monitoring > /dev/null 2>&1; then
    # With the Podman driver, the mount is established at minikube start time via --mount flag.
    # No background process is needed — just verify it is present.
    if minikube ssh "test -d /host-home" 2>/dev/null; then
        print_success "Home directory available at /host-home in minikube"

        # Restart audit exporter to ensure it picks up the mount after reboot
        print_warning "Restarting audit exporter pod..."
        kubectl delete pod -n audit-monitoring -l app=vault-audit-exporter 2>/dev/null || true
        sleep 3
        print_success "Audit exporter restarted"
    else
        print_warning "WARNING: /host-home is not mounted in minikube."
        print_warning "The mount is configured at minikube start time (--mount flag)."
        print_warning "If audit monitoring is not working, run: minikube delete && make start-minikube"
    fi
else
    print_warning "Audit monitoring namespace not found, skipping mount check"
fi

# Step 4: Restart Demo Deployments
print_section "Step 4: Restarting Demo Deployments"

# Restart GitLab demo if it exists
if kubectl get namespace gitlab-demo > /dev/null 2>&1; then
    print_warning "Restarting GitLab demo..."
    if kubectl get deployment gitlab -n gitlab-demo > /dev/null 2>&1; then
        kubectl rollout restart deployment/gitlab -n gitlab-demo 2>/dev/null || true
    fi
    if kubectl get deployment gitlab-runner -n gitlab-demo > /dev/null 2>&1; then
        kubectl rollout restart deployment/gitlab-runner -n gitlab-demo 2>/dev/null || true
    fi
    print_success "GitLab demo restarted"
else
    print_warning "GitLab demo not deployed, skipping"
fi

# Restart Dynamic Secrets demo if it exists
if kubectl get namespace db-demo > /dev/null 2>&1; then
    print_warning "Restarting Dynamic Secrets demo..."
    if kubectl get deployment vso-db-demo -n db-demo > /dev/null 2>&1; then
        kubectl rollout restart deployment/vso-db-demo -n db-demo 2>/dev/null || true
    fi
    if kubectl get deployment vso-db-demo-ui -n db-demo > /dev/null 2>&1; then
        kubectl rollout restart deployment/vso-db-demo-ui -n db-demo 2>/dev/null || true
    fi
    print_success "Dynamic Secrets demo restarted"
else
    print_warning "Dynamic Secrets demo not deployed, skipping"
fi

# Restart PKI demo if it exists
if kubectl get namespace pki-demo > /dev/null 2>&1; then
    print_warning "Restarting PKI demo..."
    if kubectl get deployment pki-demo-app -n pki-demo > /dev/null 2>&1; then
        kubectl rollout restart deployment/pki-demo-app -n pki-demo 2>/dev/null || true
    fi
    print_success "PKI demo restarted"
else
    print_warning "PKI demo not deployed, skipping"
fi

# Step 5: Wait for reconciliation
print_section "Step 5: Waiting for VaultAuth Reconciliation"
print_warning "Waiting 15 seconds for VSO to reconcile VaultAuth resources..."
sleep 15

# Step 6: Verify VaultAuth Resources
print_section "Step 6: Verifying VaultAuth Resources"

echo ""
echo "VaultAuth Status:"
kubectl get vaultauth -A 2>/dev/null || echo "No VaultAuth resources found"

echo ""
print_warning "Checking individual VaultAuth resources..."

# Check each VaultAuth resource
VAULTAUTH_READY=true

# Check gitlab-auth
if kubectl get vaultauth gitlab-auth -n gitlab-demo > /dev/null 2>&1; then
    GITLAB_READY=$(kubectl get vaultauth gitlab-auth -n gitlab-demo -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$GITLAB_READY" = "True" ]; then
        print_success "gitlab-auth: Ready"
    else
        print_error "gitlab-auth: Not Ready (Status: $GITLAB_READY)"
        VAULTAUTH_READY=false
    fi
fi

# Check dynamic-auth
if kubectl get vaultauth dynamic-auth -n db-demo > /dev/null 2>&1; then
    DYNAMIC_READY=$(kubectl get vaultauth dynamic-auth -n db-demo -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$DYNAMIC_READY" = "True" ]; then
        print_success "dynamic-auth: Ready"
    else
        print_error "dynamic-auth: Not Ready (Status: $DYNAMIC_READY)"
        VAULTAUTH_READY=false
    fi
fi

# Check pki-auth
if kubectl get vaultauth pki-auth -n pki-demo > /dev/null 2>&1; then
    PKI_READY=$(kubectl get vaultauth pki-auth -n pki-demo -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$PKI_READY" = "True" ]; then
        print_success "pki-auth: Ready"
    else
        print_error "pki-auth: Not Ready (Status: $PKI_READY)"
        VAULTAUTH_READY=false
    fi
fi

if [ "$VAULTAUTH_READY" = "false" ]; then
    echo ""
    print_warning "Some VaultAuth resources are not ready yet"
    print_warning "Waiting another 15 seconds and checking again..."
    sleep 15
    
    echo ""
    echo "VaultAuth Status (after waiting):"
    kubectl get vaultauth -A 2>/dev/null || echo "No VaultAuth resources found"
    
    echo ""
    print_warning "If resources are still not ready, check VSO logs:"
    echo "  kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator --tail=50"
fi

# Step 7: Display PKI Certificate Status (if PKI demo exists)
if kubectl get namespace pki-demo > /dev/null 2>&1; then
    print_section "Step 7: Verifying PKI Certificate Status"
    
    if kubectl get secret pki-demo-tls -n pki-demo > /dev/null 2>&1; then
        echo "Current PKI certificate:"
        kubectl get secret -n pki-demo pki-demo-tls -o jsonpath='{.data.certificate}' 2>/dev/null | base64 -d | openssl x509 -noout -serial -dates 2>/dev/null || echo "Certificate not yet available"
    else
        print_warning "PKI certificate secret not yet created"
    fi
fi

# Step 8: Wait for Deployments to be Ready
print_section "Step 8: Waiting for Deployments to be Ready"

# Wait for GitLab demo deployments
if kubectl get namespace gitlab-demo > /dev/null 2>&1; then
    if kubectl get deployment gitlab -n gitlab-demo > /dev/null 2>&1; then
        print_warning "Waiting for GitLab deployment to be ready..."
        kubectl wait --for=condition=available deployment/gitlab -n gitlab-demo --timeout=120s > /dev/null 2>&1 || print_warning "GitLab deployment not ready yet"
    fi
    if kubectl get deployment gitlab-runner -n gitlab-demo > /dev/null 2>&1; then
        print_warning "Waiting for GitLab Runner deployment to be ready..."
        kubectl wait --for=condition=available deployment/gitlab-runner -n gitlab-demo --timeout=120s > /dev/null 2>&1 || print_warning "GitLab Runner deployment not ready yet"
    fi
fi

# Wait for Dynamic Secrets demo deployments
if kubectl get namespace db-demo > /dev/null 2>&1; then
    if kubectl get deployment vso-db-demo -n db-demo > /dev/null 2>&1; then
        print_warning "Waiting for Dynamic Secrets demo to be ready..."
        kubectl wait --for=condition=available deployment/vso-db-demo -n db-demo --timeout=120s > /dev/null 2>&1 || print_warning "Dynamic Secrets demo not ready yet"
    fi
    if kubectl get deployment vso-db-demo-ui -n db-demo > /dev/null 2>&1; then
        print_warning "Waiting for Dynamic Secrets UI to be ready..."
        kubectl wait --for=condition=available deployment/vso-db-demo-ui -n db-demo --timeout=120s > /dev/null 2>&1 || print_warning "Dynamic Secrets UI not ready yet"
    fi
fi

# Wait for PKI demo deployment
if kubectl get namespace pki-demo > /dev/null 2>&1; then
    if kubectl get deployment pki-demo-app -n pki-demo > /dev/null 2>&1; then
        print_warning "Waiting for PKI demo to be ready..."
        kubectl wait --for=condition=available deployment/pki-demo-app -n pki-demo --timeout=120s > /dev/null 2>&1 || print_warning "PKI demo not ready yet"
    fi
fi

print_success "Deployments are ready (or timed out)"

# Step 9: Start Port-Forwards
print_section "Step 9: Starting Port-Forwards"

# Kill any existing port-forwards
print_warning "Stopping any existing port-forwards..."
pkill -f "kubectl port-forward.*db-demo.*8090" 2>/dev/null || true
pkill -f "kubectl port-forward.*pki-demo.*8443" 2>/dev/null || true
pkill -f "kubectl port-forward.*postgres.*9998" 2>/dev/null || true
pkill -f "kubectl port-forward.*gitlab-demo.*8080" 2>/dev/null || true
pkill -f "kubectl port-forward.*audit-monitoring.*3000" 2>/dev/null || true
pkill -f "kubectl port-forward.*audit-monitoring.*9090" 2>/dev/null || true
sleep 2

# Start port-forwards in background
if kubectl get namespace db-demo > /dev/null 2>&1 && kubectl get svc vso-db-demo-ui -n db-demo > /dev/null 2>&1; then
    print_warning "Starting Dynamic DB UI port-forward (http://localhost:8090)..."
    kubectl port-forward -n db-demo svc/vso-db-demo-ui 8090:8080 > /dev/null 2>&1 &
    sleep 1
fi

if kubectl get namespace pki-demo > /dev/null 2>&1 && kubectl get svc pki-demo-app -n pki-demo > /dev/null 2>&1; then
    print_warning "Starting PKI Demo port-forward (https://localhost:8443 or http://localhost:9090)..."
    kubectl port-forward -n pki-demo svc/pki-demo-app 8443:443 9090:80 > /dev/null 2>&1 &
    sleep 1
fi

if kubectl get namespace postgres > /dev/null 2>&1 && kubectl get svc postgres-postgresql -n postgres > /dev/null 2>&1; then
    print_warning "Starting PostgreSQL port-forward (localhost:9998)..."
    kubectl port-forward -n postgres svc/postgres-postgresql 9998:5432 > /dev/null 2>&1 &
    sleep 1
fi

if kubectl get namespace gitlab-demo > /dev/null 2>&1 && kubectl get svc gitlab -n gitlab-demo > /dev/null 2>&1; then
    print_warning "Starting GitLab UI port-forward (http://localhost:8080)..."
    kubectl port-forward -n gitlab-demo svc/gitlab 8080:80 > /dev/null 2>&1 &
    sleep 1
fi

if kubectl get namespace audit-monitoring > /dev/null 2>&1; then
    if kubectl get svc grafana -n audit-monitoring > /dev/null 2>&1; then
        print_warning "Waiting for Grafana to be ready..."
        kubectl wait --for=condition=ready pod -l app=grafana -n audit-monitoring --timeout=60s > /dev/null 2>&1 || true
        print_warning "Starting Grafana port-forward (http://localhost:3000)..."
        kubectl port-forward -n audit-monitoring svc/grafana 3000:3000 > /dev/null 2>&1 &
        sleep 1
    fi
    
    if kubectl get svc prometheus -n audit-monitoring > /dev/null 2>&1; then
        print_warning "Waiting for Prometheus to be ready..."
        kubectl wait --for=condition=ready pod -l app=prometheus -n audit-monitoring --timeout=60s > /dev/null 2>&1 || true
        print_warning "Starting Prometheus port-forward (http://localhost:9091)..."
        kubectl port-forward -n audit-monitoring svc/prometheus 9091:9090 > /dev/null 2>&1 &
        sleep 1
    fi
fi

# Final Summary
print_section "Recovery Complete!"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}=== Access Information               ===${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}🔐 Vault UI:${NC}         https://127.0.0.1:8200/ui/"
echo "   Method:           Username"
echo "   Username:         demo"
echo "   Password:         demo123"
echo "   Namespace:        master-demo"
echo ""

if kubectl get namespace db-demo > /dev/null 2>&1; then
    echo -e "${BLUE}📊 Dynamic DB UI:${NC}    http://localhost:8090"
fi

if kubectl get namespace pki-demo > /dev/null 2>&1; then
    echo -e "${BLUE}🔐 PKI Demo (HTTPS):${NC} https://localhost:8443"
    echo -e "${BLUE}🔐 PKI Demo (HTTP):${NC}  http://localhost:9090"
fi

if kubectl get namespace postgres > /dev/null 2>&1; then
    echo -e "${BLUE}🐘 PostgreSQL:${NC}       localhost:9998"
fi

if kubectl get namespace gitlab-demo > /dev/null 2>&1; then
    echo -e "${BLUE}🦊 GitLab CE:${NC}        http://localhost:8080"
    echo "   Username:         root"
    echo "   Password:         VaultDemoStr0ng!2026"
fi

if kubectl get namespace audit-monitoring > /dev/null 2>&1; then
    echo -e "${BLUE}📈 Grafana:${NC}          http://localhost:3000"
    echo "   Username:         admin"
    echo "   Password:         admin"
    echo -e "${BLUE}📊 Prometheus:${NC}       http://localhost:9091"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo ""
print_success "All recovery steps completed!"
echo ""
echo "Useful commands:"
echo "  - Check VaultAuth status:  kubectl get vaultauth -A"
echo "  - Check VSO logs:          kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator"
echo "  - Stop port-forwards:      make stop-port-forwards"
echo ""

# Made with Bob