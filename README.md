# Vault Secrets Operator with Local Vault Enterprise

This repository demonstrates how to use HashiCorp's Vault Secrets Operator (VSO) with a local Vault Enterprise server, showcasing static secrets, dynamic database credentials, and PKI certificate auto-renewal in Kubernetes.

## todos
- move to namespaces or at least one new namespace
- add telemetry to grafana

## Overview

This setup uses:
- **Local Vault Enterprise** server (127.0.0.1:8200) - persistent, production-like
- **Minikube** Kubernetes cluster
- **Vault Secrets Operator** - syncs secrets from Vault to Kubernetes
- **PostgreSQL** - for dynamic database credentials demo
- **PKI Engine** - for automatic certificate generation and renewal
- **GitLab CE** - for CI/CD pipeline integration demo

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│   Minikube Cluster                                              │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Vault Secrets Operator                                   │  │
│  │ - Syncs static secrets (KV)                              │  │
│  │ - Manages dynamic credentials (PostgreSQL)               │  │
│  │ - Auto-renews PKI certificates                           │  │
│  └──────────────┬───────────────────────────────────────────┘  │
│                 │                                               │
│  ┌──────────────▼───────────────────────────────────────────┐  │
│  │ Application Pods                                         │  │
│  │ - Static secrets (username/password)                    │  │
│  │ - Dynamic DB credentials (auto-rotated)                 │  │
│  │ - TLS certificates (auto-renewed)                       │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Audit Monitoring Stack (audit-monitoring namespace)     │  │
│  │                                                          │  │
│  │  Vault Audit Exporter → Prometheus → Grafana            │  │
│  │  - Tails ~/audit.log via hostPath (/host-home)         │  │
│  │  - Parses JSON audit entries                           │  │
│  │  - Exposes Prometheus metrics (10s scrape)             │  │
│  │  - Real-time dashboard (15 panels, 5s refresh)         │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────┼───────────────────────────────────────────────┘
                  │
                  │ HTTPS (via host.minikube.internal)
                  │ Audit logs written to ~/audit.log
                  │
         ┌────────▼────────┐
         │ Local Vault     │
         │ 127.0.0.1:8200  │
         │                 │
         │ Engines:        │
         │ - vso-demo-kv   │
         │ - vso-demo-db   │
         │ - vso-demo-pki  │
         │                 │
         │ Audit Device:   │
         │ - File audit    │
         │ - ~/audit.log   │
         │ - Auto-rotation │
         └─────────────────┘
```

### Audit Monitoring Flow

```
Local Vault (~/audit.log)
         │ JSON audit logs
         ▼
Vault Audit Exporter (Python)
  - Tails log file via hostPath
  - Parses JSON entries
  - Calculates latency
  - Exposes metrics on :9091
         │ HTTP scrape (10s)
         ▼
Prometheus
  - 15-day retention
  - Port: 9090
         │ PromQL queries
         ▼
Grafana Dashboard
  - 15 panels
  - 5-second refresh
  - Port: 3000
```

## Prerequisites

- **make** - Command-line build tool (usually pre-installed on macOS/Linux)
- **Vault Enterprise** running at `127.0.0.1:8200`
- Vault must be **unsealed** and accessible
- **Minikube** installed and running
- **kubectl** and **helm** installed
- **Docker** - Required for building the audit exporter image
- **jq** - JSON processor for cleanup scripts (`brew install jq` on macOS)
- **curl**, **base64**, **openssl** - Standard CLI tools (usually pre-installed)
- **VAULT_TOKEN** environment variable set

**Note:** The audit monitoring feature requires a Vault file audit device writing to `~/audit.log`. The setup script (`make all-local`) will automatically:
- Enable the audit device
- Configure automatic log rotation (100MB max, keeps 1 rotated file, 24h rotation)
- No manual configuration needed - Vault Enterprise handles rotation automatically!

Maximum disk usage: ~200MB (current file + 1 rotated backup file).


## Quick Commands Reference

### Deploy Everything from Scratch
```bash
# Set environment variables
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
export VAULT_TOKEN=your-vault-root-token

# Deploy all demos (dynamic, PKI, GitLab CI) est. time 5-10 to deploy
make all-local
```

### Restart After Shutdown
```bash
# 1. Start minikube
minikube start

# 2. Verify Vault is running and unsealed
vault status

# 3. Set environment variables
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
export VAULT_TOKEN=your-vault-root-token

# 4. Update Vault's Kubernetes auth (minikube IP changes)
./scripts/setup/setup-local-vault.sh

# 5. Start all port-forwards (single command!)
make port-forward-all
```

**After laptop sleep / system recovery**

If demos stop working after your laptop sleeps (PKI rotation stops, audit monitoring breaks, etc.), use the recovery helper:

```bash
make all-recover
```

This script:
- Restarts the minikube mount for audit log access
- Restarts the audit exporter pod
- Restarts the VSO controller for PKI rotation
- Verifies PKI certificate status

It usually restores all functionality after a suspend/resume event.

**What persists automatically:**
- ✅ All Vault data (secrets, policies, roles, PKI CAs)
- ✅ All Kubernetes resources (pods, secrets, deployments)
- ✅ Static secrets (work immediately after restart)
- ✅ PKI certificates (continue auto-renewing)
- ✅ Dynamic secrets (work after port-forward is restarted)

### Complete Cleanup
```bash
# Clean all Vault configuration and demo namespaces (preserves Minikube cluster)
make clean-all-local

# To completely remove the Minikube cluster (optional):
minikube delete
```

### Redeploy Individual Demos
```bash
# Redeploy static secrets only
make deploy-static-secrets-local

# Redeploy dynamic secrets only
make setup-postgresql-local
make deploy-dynamic-secrets-local

# Redeploy PKI demo only
make setup-pki-vault
make deploy-pki-secrets
```


## Quick Start (Complete Setup)

### 1. Prerequisites Check

```bash
# Verify Vault is running
vault status

# Verify minikube is available
minikube version

# Verify kubectl and helm
kubectl version --client
helm version
```

### 2. Set Environment Variables

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
export VAULT_TOKEN=your-vault-root-token
```

### 3. Deploy Everything

```bash
make all-local
```

This single command will:
1. ✅ Start minikube (if not running)
2. ✅ Configure Vault with auth methods, policies, and secrets engines
3. ✅ Install Vault Secrets Operator
4. ✅ Deploy static secrets demo
5. ✅ Install PostgreSQL
6. ✅ Configure PostgreSQL in Vault with proper permissions
7. ✅ Deploy dynamic secrets **interactive web UI demo**
8. ✅ Configure PKI engines (root + issuing CA)
9. ✅ Deploy PKI certificate auto-renewal demo

### 4. Verify All Demos

```bash
# Static secrets
kubectl get secret -n static-demo secretkv -o jsonpath="{.data.username}" | base64 -d
kubectl get secret -n static-demo secretkv -o jsonpath="{.data.password}" | base64 -d

# Dynamic secrets
kubectl get secret -n db-demo vso-db-demo -o jsonpath="{.data.username}" | base64 -d
kubectl get secret -n db-demo vso-db-demo -o jsonpath="{.data.password}" | base64 -d

# PKI certificates
kubectl get secret -n pki-demo pki-demo-tls -o jsonpath="{.data.certificate}" | base64 -d | openssl x509 -noout -subject -dates
```

### 5. Access the Interactive Demos

**Option A: Start All Port-Forwards at Once (Recommended)**

```bash
# Start all port-forwards in background (single command!)
make port-forward-all

# Access the demos:
# - Dynamic DB UI:    http://localhost:8090
# - PKI Demo (HTTPS): https://localhost:8443
# - PKI Demo (HTTP):  http://localhost:9090
# - PostgreSQL:       localhost:5432

# Check status
make status-port-forwards

# Stop all port-forwards
make stop-port-forwards
```

**Option B: Individual Port-Forwards**

```bash
# Dynamic DB UI - Interactive web interface
make db-ui-port-forward
# Open: http://localhost:8090

# PKI Demo - Certificate auto-renewal web interface
make pki-port-forward
# Open: https://localhost:8443 or http://localhost:9090

# PostgreSQL (required for dynamic secrets)
make postgres-port-forward
```

## Demos

### 1. Static Secrets Demo

Static secrets are stored in Vault's KV v2 engine (`vso-demo-kv`) and automatically synced to Kubernetes:

```bash
# Update secret in Vault
vault kv put vso-demo-kv/webapp/config username="demo-user" password="demo-pass"

# Wait 30 seconds for sync
sleep 30

# Verify update in Kubernetes
kubectl get secret -n app secretkv -o jsonpath="{.data.password}" | base64 -d
```

**Configuration:**
- Vault engine: `vso-demo-kv` (KV v2)
- Vault path: `webapp/config`
- K8s secret: `secretkv` in namespace `static-demo`
- Refresh interval: 30 seconds

### 2. Dynamic Secrets Demo

Dynamic secrets are generated on-demand by Vault's database engine (`vso-demo-db`) with automatic rotation.

#### Option A: Interactive Web UI Demo (Recommended)

The web UI provides a visual, interactive demonstration of dynamic credentials:

```bash
# Deploy the web UI demo
make deploy-db-ui

# Access the web interface
make db-ui-port-forward
# Then open: http://localhost:8090
```

**Features:**
- 🔄 **Real-time credential display** - Watch username/password update every ~30 seconds
- 💾 **Interactive database operations** - Insert, query, and clear records
- 📊 **Activity log** - See which credentials performed each operation
- 🚫 **No pod restarts** - Credentials update seamlessly via sidecar pattern
- 🎯 **Visual rotation** - Clear indication when credentials change

**How it works:**
1. Credential monitor sidecar reads secrets from Kubernetes API every 3 seconds
2. Web application reads credentials from shared volume (no cache delays)
3. Each database operation shows which credential was used
4. Credentials rotate automatically without disrupting the application

**Web UI Commands:**
```bash
make db-ui-status          # Check deployment status
make db-ui-logs            # View application logs
make db-ui-port-forward    # Access web UI at http://localhost:8090
make clean-db-ui           # Remove web UI (keeps VaultAuth/VaultDynamicSecret)
```

#### Option B: Command-Line Demo

Watch credentials rotate from the command line:

```bash
# Watch credentials rotate every ~20-25 seconds
watch -n 5 'echo "Username:"; kubectl get secret -n db-demo vso-db-demo -o jsonpath="{.data.username}" | base64 -d; echo -e "\nPassword:"; kubectl get secret -n db-demo vso-db-demo -o jsonpath="{.data.password}" | base64 -d'

# View application logs (shows credentials in use)
make db-logs
```

**Configuration:**
- Vault engine: `vso-demo-db` (PostgreSQL)
- Vault role: `dev-postgres`
- K8s secret: `vso-db-demo` in namespace `db-demo`
- TTL: 30 seconds (demo-optimized)
- Auto-rotation: ~25 seconds (5s before expiry)
- **No rolloutRestartTargets** - Applications read credentials from file updated by sidecar

To force immediate rotation:
```bash
kubectl delete secret -n db-demo vso-db-demo
# VSO will recreate it immediately with new credentials
```

### 3. PKI Certificate Auto-Renewal Demo

Certificates are automatically generated and renewed by Vault's PKI engine (`vso-demo-pki-issuing`):

```bash
# Watch certificate expiration in real-time
make watch-pki-certs

# Check PKI demo status
make pki-status

# View application logs
make pki-logs

# Access the demo application
make pki-port-forward
# Then open: https://localhost:8443 or http://localhost:9090
```

**Configuration:**
- Vault engines: `vso-demo-pki-root` (Root CA), `vso-demo-pki-issuing` (Issuing CA)
- Vault role: `vso-demo-cert-issuer`
- K8s secret: `pki-demo-tls` in namespace `pki-demo`
- Certificate TTL: 30 seconds (demo-optimized)
- Auto-renewal: ~25 seconds (5s before expiry)
- Root CA validity: 10 years
- Issuing CA validity: 1 year

**What you'll see:**
- Certificates automatically renew every ~25 seconds
- No pod restarts required
- Web UI shows current certificate details
- Serial number changes with each renewal

**PKI-specific commands:**
```bash
# Deploy PKI demo only
make all-pki

# Clean up PKI demo
make clean-pki

# Clean up PKI Vault configuration
make clean-pki-vault

# Complete PKI cleanup (K8s + Vault)
make clean-pki-all

### 4. GitLab CI/CD Integration Demo

GitLab CE with a lightweight Kubernetes runner demonstrates how CI/CD pipelines can consume secrets from Vault via VSO.

**Layout**
- GitLab manifests: `static-secrets-gitlab-ci/manifests/`
- GitLab VSO resources: `static-secrets-gitlab-ci/`
- Sample project files synced into GitLab: `static-secrets-gitlab-ci/sample-project/`
- GitLab setup scripts: `scripts/setup/`
- GitLab cleanup scripts: `scripts/cleanup/`
- GitLab test scripts: `scripts/test/`

**Deploy**
```bash
# Complete GitLab demo
make all-gitlab

# Included in full environment bootstrap
make all-local
```

**Step-by-step flow**
```bash
make setup-gitlab-vault
make install-gitlab
make deploy-gitlab-demo
make setup-gitlab-project
make register-gitlab-runner
make gitlab-port-forward
```

Login:
- URL: `http://localhost:8080`
- Username: `root`
- Password: `VaultDemoStr0ng!2026`

**Configuration**
- Vault engine: `vso-demo-kv`
- Vault path: `webapp/config`
- Vault role: `vso-demo-gitlab-role`
- Kubernetes namespace: `gitlab-demo`
- Synced secret: `secretkv`
- Refresh interval: `30s`
- Runner model: separate GitLab Runner deployment using Kubernetes executor
- Secret mount in jobs: `/vault/secrets`

**Demo flow**
1. `make all-gitlab` or `make all-local`
2. Open `http://localhost:8080/demo/vault-demo/-/pipelines`
3. Run the pipeline
4. Inspect job output showing:
   - `/vault/secrets/username`
   - `/vault/secrets/password`
5. Update Vault:
   ```bash
   vault kv put vso-demo-kv/webapp/config username="new-user" password="new-pass"
   ```
6. Wait about 30 seconds for VSO sync
7. Re-run the pipeline
8. Show the updated values in the job log

**What this proves**
- GitLab pipeline does not need direct Vault connectivity
- VSO syncs Vault KV data into a Kubernetes secret
- Runner-created job pods mount the synced secret as files
- Re-running the pipeline after a Vault update shows the changed value

**Useful commands**
```bash
make gitlab-status
make gitlab-logs
make gitlab-runner-logs
make test-gitlab-vault
make clean-gitlab
make clean-gitlab-vault
make clean-gitlab-all
```

**Resource requirements**
- Minimum: 4 CPU, 8GB RAM
- Recommended: 6 CPU, 12GB RAM
- GitLab initialization still takes several minutes
### 5. Audit Monitoring Demo

Real-time monitoring and visualization of all Vault operations through Prometheus and Grafana.

#### Quick Start

```bash
# Deploy complete audit monitoring stack (included in make all-local)
make setup-audit-monitoring

# Access Grafana dashboard
make grafana-port-forward
# Open: http://localhost:3000 (admin/admin)

# Access Prometheus
make prometheus-port-forward
# Open: http://localhost:9091

# Generate test traffic
make test-audit-traffic
```

#### Components

**1. Vault Audit Exporter (Python)**
- Tails the Vault audit log file (`~/audit.log`)
- Parses JSON audit entries (both request and response)
- Calculates latency from request/response pairs
- Exposes 9 Prometheus metric families
- Handles log rotation gracefully
- Resource usage: ~50-100MB memory, <5% CPU

**2. Prometheus**
- Scrapes exporter every 10 seconds (near real-time)
- 15-day retention
- Port: 9090
- Resource usage: ~512MB memory, ~200m CPU

**3. Grafana**
- Pre-configured dashboard with 15 panels
- 5-second refresh rate
- Port: 3000
- Default credentials: admin/admin
- Resource usage: ~256MB memory, ~100m CPU

#### Dashboard Panels (15 Total)

1. **Total Requests** - Last 15 minutes
2. **Error Rate** - With warning/critical thresholds
3. **Active Operations** - Requests per minute
4. **Unique Clients** - Distinct client IPs
5. **Requests Over Time** - Stacked area chart
6. **Requests by Mount Type** - Pie chart (KV, DB, PKI, etc.)
7. **Operations by Type** - Bar gauge (read, write, delete, list)
8. **Top 10 Paths** - Most accessed Vault paths
9. **Authentication Activity** - Login attempts and methods
10. **Errors and Warnings** - Error tracking over time
11. **KV Operations** - Static secret access patterns
12. **Database Credentials** - Dynamic secret generation
13. **PKI Certificates** - Certificate issuance and renewal
14. **Request Latency** - p50, p95, p99 percentiles
15. **Exporter Health** - Monitoring system status

#### Metrics Exposed

- `vault_audit_requests_total` - Request counts by operation, path, mount type
- `vault_audit_responses_total` - Response status codes
- `vault_audit_auth_requests_total` - Authentication activity
- `vault_audit_mount_requests_total` - Per-mount activity
- `vault_audit_errors_total` - Error tracking
- `vault_audit_warnings_total` - Warning tracking
- `vault_audit_request_duration_seconds` - Latency histogram
- `vault_audit_lease_operations_total` - Lease operations
- `vault_audit_pki_operations_total` - PKI-specific operations

#### Configuration

**Audit Log:**
- Location: `~/audit.log`
- Mounted in minikube at `/host-home` via hostPath
- Automatic rotation: 100MB files, keeps 1 rotated file (~200MB max)
- Rotation handled by Vault Enterprise (no cron needed)

**Scraping:**
- Interval: 10 seconds (near real-time)
- Dashboard refresh: 5 seconds
- Prometheus retention: 15 days

**Access URLs:**
- Grafana: http://localhost:3000 (admin/admin)
- Prometheus: http://localhost:9091
- Exporter metrics: http://localhost:9091/metrics

#### What You'll See

- 📊 **Real-time request activity** - Every Vault operation visualized instantly
- 🔐 **Authentication patterns** - Track which services access Vault and when
- 📈 **Secret engine activity** - KV reads, database credential generation, PKI issuance
- ⚠️ **Error rates and warnings** - Immediate visibility into issues
- ⏱️ **Request latency** - Performance metrics (p50, p95, p99 percentiles)
- 🎯 **Top paths** - Most frequently accessed Vault paths
- 📉 **Operations breakdown** - Read, write, delete, list operations
- 🔄 **Dynamic secrets rotation** - Watch credentials being generated and revoked
- 🔒 **PKI certificate lifecycle** - Certificate issuance and renewal patterns

#### Useful Commands

```bash
# View current metrics directly
make audit-exporter-metrics

# Generate test traffic for demo
make test-audit-traffic

# Check all component status
make audit-monitoring-status

# View exporter logs
make audit-exporter-logs

# Clean up (removes all monitoring components)
make clean-audit-monitoring
```

#### Troubleshooting

**Dashboard shows old data after clearing audit log:**
```bash
# Restart exporter to reset metrics
kubectl rollout restart deployment/vault-audit-exporter -n audit-monitoring
```

Note: Prometheus counters are monotonic (only increase). Clearing the log file doesn't reset displayed metrics. Restarting the exporter resets its internal counters. For a complete reset including Prometheus data, use `make clean-audit-monitoring && make setup-audit-monitoring`.

**Exporter not starting:**
```bash
# Check logs
make audit-exporter-logs

# Verify audit log exists
ls -la ~/audit.log

# Verify Vault audit device is enabled
vault audit list
```

**No metrics in Prometheus:**
```bash
# Check if Prometheus can reach exporter
kubectl port-forward -n audit-monitoring svc/vault-audit-exporter 9091:9091 &
curl http://localhost:9091/metrics

# Check Prometheus targets
make prometheus-port-forward
# Open: http://localhost:9091/targets
```

**Dashboard shows no data:**
```bash
# Verify Prometheus has data
make prometheus-port-forward
# Open: http://localhost:9091/graph
# Query: vault_audit_requests_total

# Check Grafana datasource configuration
# Grafana → Configuration → Data Sources → Prometheus
# Should point to: http://prometheus:9090
```

#### Performance and Scalability

The exporter processes logs line-by-line with minimal memory footprint and can handle:
- ~1000 requests/second
- Log files up to several GB
- Rotation without data loss
- Continuous operation for extended periods

#### Security Considerations

1. **Audit Log Access**: Exporter has read-only access via hostPath mount
2. **Sensitive Data**: Vault HMAC-hashes sensitive fields in audit logs
3. **Network**: All services run within Kubernetes cluster namespace
4. **Credentials**: Change default Grafana password (admin/admin) in production

#### Files and Structure

```
audit-monitoring/
├── exporter/
│   ├── vault_audit_exporter.py       # Main exporter code
│   ├── requirements.txt               # Python dependencies
│   └── Dockerfile                     # Container image
├── kubernetes/
│   ├── 00-namespace.yaml             # audit-monitoring namespace
│   ├── 01-exporter-deployment.yaml   # Exporter deployment and service
│   ├── 02-prometheus-config.yaml     # Prometheus configuration
│   ├── 03-prometheus-deployment.yaml # Prometheus deployment and service
│   ├── 04-grafana-config.yaml        # Grafana datasources and dashboard
│   └── 05-grafana-deployment.yaml    # Grafana deployment and service
├── grafana/
│   └── vault-audit-dashboard.json    # Dashboard definition (15 panels)
└── logrotate-vault-audit.conf        # Alternative log rotation config
```



## How It Works

### Connection to Local Vault

VSO connects to your local Vault using `host.minikube.internal`, which resolves to your host machine's IP from within minikube pods. This allows the Kubernetes cluster to access your local Vault server without complex networking.

### Kubernetes Authentication

1. Service accounts in Kubernetes have associated service account tokens (JWTs)
2. VSO uses the Kubernetes auth method to authenticate with Vault
3. Vault validates the service account tokens with the Kubernetes API (via `vso-demo-auth` mount)
4. Upon successful validation, Vault issues Vault tokens with appropriate policies

### Static Secrets Flow

1. Secrets stored in Vault's KV v2 engine (`vso-demo-kv/webapp/config`)
2. `VaultStaticSecret` CRD tells VSO what to sync
3. VSO authenticates using `VaultAuth` CRD
4. VSO reads secret from Vault and creates K8s secret `secretkv` in `static-demo` namespace
5. Automatically refreshed every 30 seconds
6. Changes in Vault propagate to Kubernetes

### Dynamic Secrets Flow

1. `VaultDynamicSecret` CRD requests credentials from `vso-demo-db`
2. VSO authenticates and requests credentials from Vault
3. Vault generates new PostgreSQL user with 30s TTL
4. VSO creates K8s secret `vso-db-demo` in `db-demo` namespace with credentials
5. Before expiry (~25s), VSO requests new credentials
6. Old credentials automatically revoked by Vault

### PKI Certificate Flow

1. `VaultPKISecret` CRD requests certificate from `vso-demo-pki-issuing`
2. VSO authenticates and requests certificate from Vault
3. Vault generates certificate signed by Issuing CA (30s TTL)
4. VSO creates K8s secret with certificate, private key, and CA chain
5. Before expiry (~25s), VSO requests new certificate
6. Old certificate automatically revoked by Vault
7. **No pod restart needed** - applications read updated secret

### Transit Encryption

VSO uses Vault's Transit engine (`vso-demo-transit`) to encrypt its client cache:
- Cache encryption key `vso-client-cache` stored in Vault
- Adds security layer for cached secrets
- Even if Kubernetes is compromised, cache is encrypted

## Vault Resources (with vso-demo- prefix)

All Vault resources use the `vso-demo-` prefix for easy identification:

### Auth Methods
- `vso-demo-auth` - Kubernetes authentication mount

### Secrets Engines
- `vso-demo-kv` - KV v2 for static secrets
- `vso-demo-db` - PostgreSQL database for dynamic credentials
- `vso-demo-pki-root` - Root CA (10-year validity)
- `vso-demo-pki-issuing` - Issuing CA (1-year validity)
- `vso-demo-transit` - Transit encryption for VSO cache

### Policies
- `vso-demo-webapp` - Read access to static secrets
- `vso-demo-auth-policy-db` - Read access to dynamic credentials
- `vso-demo-pki-issuer` - Issue/sign/revoke certificates
- `vso-demo-auth-policy-operator` - VSO operator transit encryption

### Roles
- `vso-demo-role1` - Static secrets role
- `vso-demo-auth-role` - Dynamic secrets role
- `vso-demo-pki-cert-issuer` - PKI certificate issuance role
- `vso-demo-auth-role-operator` - VSO operator role

## Configuration Files

### Vault Setup Scripts
- [`scripts/setup/setup-local-vault.sh`](scripts/setup/setup-local-vault.sh) - Configures Vault auth, KV, database, and transit engines
- [`scripts/setup/setup-postgresql-vault.sh`](scripts/setup/setup-postgresql-vault.sh) - Configures the PostgreSQL database secrets engine
- [`scripts/setup/setup-pki-vault.sh`](scripts/setup/setup-pki-vault.sh) - Configures PKI root and issuing CAs
- [`scripts/setup/setup-gitlab-demo.sh`](scripts/setup/setup-gitlab-demo.sh) - End-to-end GitLab demo setup: Vault policy/role, GitLab deployment, VSO resources, project bootstrap, and runner registration
- [`scripts/setup/vault-operator-values.yaml`](scripts/setup/vault-operator-values.yaml) - Helm values for VSO installation

### Cleanup Script
- [`scripts/cleanup/cleanup-all.sh`](scripts/cleanup/cleanup-all.sh) - Removes all demo-related Vault configuration and deletes the Minikube cluster

### VSO Configuration
- VSO install values are stored in [`scripts/setup/vault-operator-values.yaml`](scripts/setup/vault-operator-values.yaml)

### Static Secrets
- [`static-secrets/vault-auth-static.yaml`](static-secrets/vault-auth-static.yaml) - VaultAuth CRD
- [`static-secrets/static-secret.yaml`](static-secrets/static-secret.yaml) - VaultStaticSecret CRD

### Dynamic Secrets
- [`dynamic-secrets/vault-auth-dynamic.yaml`](dynamic-secrets/vault-auth-dynamic.yaml) - VaultAuth CRD
- [`dynamic-secrets/vault-dynamic-secret.yaml`](dynamic-secrets/vault-dynamic-secret.yaml) - VaultDynamicSecret CRD
- [`dynamic-secrets/app-deployment.yaml`](dynamic-secrets/app-deployment.yaml) - Simple CLI application
- [`dynamic-secrets/app-deployment-ui.yaml`](dynamic-secrets/app-deployment-ui.yaml) - Interactive web UI with credential monitor
- [`dynamic-secrets/service.yaml`](dynamic-secrets/service.yaml) - Service for web UI access
- [`dynamic-secrets/app-deployment.yaml`](dynamic-secrets/app-deployment.yaml) - Sample application

### PKI Secrets
- [`pki-secrets/vault-auth-pki.yaml`](pki-secrets/vault-auth-pki.yaml) - VaultAuth CRD
- [`pki-secrets/vault-pki-secret.yaml`](pki-secrets/vault-pki-secret.yaml) - VaultPKISecret CRD
- [`pki-secrets/app-deployment.yaml`](pki-secrets/app-deployment.yaml) - Nginx with cert monitor
- [`pki-secrets/service.yaml`](pki-secrets/service.yaml) - Service for HTTPS/HTTP access

### GitLab CI Demo
- [`static-secrets-gitlab-ci/manifests/gitlab-simple.yaml`](static-secrets-gitlab-ci/manifests/gitlab-simple.yaml) - Lightweight GitLab CE + runner manifest
- [`static-secrets-gitlab-ci/vault-auth-gitlab.yaml`](static-secrets-gitlab-ci/vault-auth-gitlab.yaml) - VaultAuth for GitLab demo
- [`static-secrets-gitlab-ci/gitlab-static-secret.yaml`](static-secrets-gitlab-ci/gitlab-static-secret.yaml) - VaultStaticSecret syncing `secretkv`
- [`static-secrets-gitlab-ci/sample-project/.gitlab-ci.yml`](static-secrets-gitlab-ci/sample-project/.gitlab-ci.yml) - Pipeline that prints the Vault-synced secret
- [`static-secrets-gitlab-ci/sample-project/README.md`](static-secrets-gitlab-ci/sample-project/README.md) - Sample project documentation
- [`scripts/setup/setup-gitlab-demo.sh`](scripts/setup/setup-gitlab-demo.sh) - Complete GitLab demo setup and project bootstrap

## Makefile Targets

### Complete Setup
```bash
make all-local              # Deploy everything (dynamic + PKI + GitLab CI demo)
make all-pki                # Deploy PKI demo only
make all-gitlab             # Deploy GitLab CI demo only
```

### Individual Components
```bash
make start-minikube         # Start minikube cluster
make setup-local-vault      # Configure Vault (auth, KV, DB, transit)
make install-vso-local      # Install Vault Secrets Operator
make install-postgresql-pod # Install PostgreSQL
make setup-postgresql-local # Configure PostgreSQL in Vault
make deploy-db-ui           # Deploy dynamic secrets web UI demo
make setup-pki-vault        # Configure PKI engines in Vault
make deploy-pki-secrets     # Deploy PKI demo application
make setup-gitlab-demo      # Complete GitLab CI demo setup
```

### Port-Forwarding
```bash
make port-forward-all       # Start ALL port-forwards in background (recommended!)
make stop-port-forwards     # Stop all port-forwards
make status-port-forwards   # Check which port-forwards are running
make db-ui-port-forward     # Access DB UI demo only (http://localhost:8090)
make pki-port-forward       # Access PKI demo only (https://localhost:8443)
make postgres-port-forward  # Port-forward PostgreSQL only (localhost:5432)
make gitlab-port-forward    # Port-forward GitLab UI (http://localhost:8080)
```

### Monitoring & Testing
```bash
make test-local             # Test all demos
make pki-status             # Check PKI demo status
make watch-pki-certs        # Watch certificate renewal
make pki-logs               # View PKI demo logs
make all-recover            # Restart VSO, audit monitoring, and verify PKI rotation after sleep/staleness
make db-logs                # View dynamic DB demo logs (CLI version)
make db-ui-status           # Check dynamic DB UI demo status
make db-ui-logs             # View dynamic DB UI demo logs
make vso-logs               # View VSO operator logs
# GitLab validation is done by re-running the demo pipeline after updating Vault
```

### Cleanup
```bash
make clean-all-local        # Remove all demo Vault config and delete the Minikube cluster
```

## Cleanup Options

### Complete Cleanup (Remove Everything)
```bash
# Remove all demo Vault configuration and delete the Minikube cluster
make clean-all-local
```

### Manual Cleanup
```bash
# Delete the Minikube cluster
minikube delete

# Vault configuration (all demos)
vault delete auth/vso-demo-auth/role/vso-demo-gitlab-role
vault delete auth/vso-demo-auth/role/vso-demo-role1
vault delete auth/vso-demo-auth/role/vso-demo-auth-role
vault delete auth/vso-demo-auth/role/vso-demo-auth-role-operator
vault delete auth/vso-demo-auth/role/vso-demo-pki-cert-issuer
vault policy delete vso-demo-gitlab-policy
vault policy delete vso-demo-webapp
vault policy delete vso-demo-auth-policy-db
vault policy delete vso-demo-pki-issuer
vault policy delete vso-demo-auth-policy-operator
vault secrets disable vso-demo-kv
vault secrets disable vso-demo-db
vault secrets disable vso-demo-pki-root
vault secrets disable vso-demo-pki-issuing
vault secrets disable vso-demo-transit
vault auth disable vso-demo-auth
```

## Advantages of Local Vault

✅ **Persistent data** - Survives minikube restarts
✅ **No unsealing** - Your local Vault is already managed
✅ **Production-like** - Closer to real deployment
✅ **Easy debugging** - Direct access to Vault UI and CLI
✅ **Resource efficient** - No Vault pod in cluster

## Troubleshooting

### VSO Cannot Connect to Vault

```bash
# Verify Vault is accessible from host
curl -k https://127.0.0.1:8200/v1/sys/health

# Check from minikube
minikube ssh "curl -k https://host.minikube.internal:8200/v1/sys/health"

# Check VSO logs
make vso-logs
```

### Secrets Not Syncing

```bash
# Check VSO logs
kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator -f

# Check VaultAuth status
kubectl get vaultauth -A

# Check all VSO CRDs
kubectl get vaultstaticsecret -A
kubectl get vaultdynamicsecret -A
kubectl get vaultpkisecret -A

# Describe specific resource for details
kubectl describe vaultstaticsecret vault-kv-app -n static-demo
```

### Dynamic Secrets Not Working

```bash
# Verify port-forward is running
ps aux | grep "port-forward.*postgres"

# Restart port-forward using make command
make postgres-port-forward &

# Or manually
kubectl port-forward -n postgres svc/postgres-postgresql 5432:5432 &

# Test Vault can connect to PostgreSQL
vault read vso-demo-db/creds/dev-postgres

# Check if database engine is configured
vault read vso-demo-db/config/vso-demo-db
```

### PKI Certificates Not Renewing

```bash
# Check PKI demo status
make pki-status

# Check VaultPKISecret status
kubectl describe vaultpkisecret pki-demo-cert -n pki-demo

# Verify PKI engines are configured
vault read vso-demo-pki-issuing/roles/vso-demo-cert-issuer

# Test certificate issuance manually
vault write vso-demo-pki-issuing/issue/vso-demo-cert-issuer common_name="test.local" ttl="30s"

# Check application logs
make pki-logs
```

### Minikube IP Changed After Restart

```bash
# Reconfigure Vault's Kubernetes auth with new minikube IP
./setup-local-vault.sh

# Restart VSO pods to pick up new configuration
kubectl rollout restart deployment -n vault-secrets-operator-system
```

## Learn More

- [Vault Secrets Operator Documentation](https://developer.hashicorp.com/vault/docs/platform/k8s/vso)
- [Vault Kubernetes Authentication](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Vault Database Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/databases)
- [Vault Transit Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/transit)

## License

See [LICENSE](LICENSE) file for details.
