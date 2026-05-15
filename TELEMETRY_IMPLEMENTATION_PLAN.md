# Vault Telemetry Monitoring Implementation Plan

## Overview
Add Vault telemetry monitoring to the existing audit monitoring stack, creating a separate Grafana dashboard for Vault performance and health metrics. The implementation will be conditional - only deploying telemetry monitoring if Vault has telemetry enabled.

## Current State Analysis

### Existing Infrastructure
- **Vault Configuration**: Telemetry enabled with `prometheus_retention_time = "5m"` at `/v1/sys/metrics`
- **Audit Monitoring Stack**: Already deployed in `audit-monitoring` namespace
  - Prometheus (scraping audit exporter on port 9091)
  - Grafana (with audit dashboard)
  - Vault Audit Exporter (custom Python exporter)
- **Architecture**: Vault runs locally at `127.0.0.1:8200`, accessed from Minikube via `host.minikube.internal`

### Key Constraints
1. Vault telemetry endpoint requires authentication (VAULT_TOKEN)
2. Telemetry must be enabled in Vault config (prerequisite check needed)
3. **CRITICAL**: Must not break existing audit monitoring if telemetry unavailable - setup continues with audit-only monitoring
4. Must use existing Prometheus/Grafana instances (no new deployments)
5. The `make all-local` workflow must complete successfully whether telemetry is available or not

## Implementation Plan

### Phase 1: Prerequisites and Validation

#### 1.1 Update README Prerequisites Section
**File**: `README.md`
**Changes**:
- Add telemetry configuration requirement to Vault prerequisites
- Document the required telemetry stanza:
  ```hcl
  telemetry {
    prometheus_retention_time = "5m"
    disable_hostname = false
  }
  ```
- Note that telemetry monitoring is optional but recommended
- Add verification command: `curl -H "X-Vault-Token: $VAULT_TOKEN" https://127.0.0.1:8200/v1/sys/metrics`

#### 1.2 Create Telemetry Verification Function
**File**: `scripts/setup/setup-audit-monitoring.sh`
**Location**: After Vault status check (around line 42)
**Function**:
```bash
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
        return 1
    fi
}
```

### Phase 2: Prometheus Configuration

#### 2.1 Update Prometheus ConfigMap
**File**: `audit-monitoring/kubernetes/02-prometheus-config.yaml`
**Changes**: Add new scrape job for Vault telemetry

```yaml
      # Vault Telemetry Scraper (requires telemetry enabled in Vault)
      - job_name: 'vault-telemetry'
        metrics_path: '/v1/sys/metrics'
        params:
          format: ['prometheus']
        scheme: https
        tls_config:
          insecure_skip_verify: true
        
        # Use Vault token for authentication
        authorization:
          type: Bearer
          credentials_file: /vault/token
        
        static_configs:
          - targets: ['host.minikube.internal:8200']
            labels:
              service: 'vault'
              environment: 'local'
        
        # Scrape every 15 seconds (telemetry retention is 5m)
        scrape_interval: 15s
        scrape_timeout: 10s
        
        relabel_configs:
          - source_labels: [__address__]
            target_label: instance
            replacement: 'vault-local'
```

#### 2.2 Authentication Options Analysis

**Option A: Direct Token (Simpler, Recommended)**
- **Pros**:
  - Simple implementation (just mount existing VAULT_TOKEN)
  - No additional Vault configuration needed
  - Prometheus already in `audit-monitoring` namespace
  - Matches existing audit monitoring pattern
  - Works immediately with current setup
- **Cons**:
  - Token needs manual rotation if it expires
  - Less "cloud-native" approach

**Option B: VSO with Kubernetes Auth (More Complex)**
- **Pros**:
  - More "proper" Kubernetes-native approach
  - Automatic token renewal via VSO
  - Demonstrates VSO capabilities
- **Cons**:
  - Requires additional Vault configuration:
    - New Kubernetes auth role for Prometheus
    - New policy for telemetry endpoint access
    - VaultAuth resource in audit-monitoring namespace
    - VaultStaticSecret to sync token
  - More moving parts = more potential failure points
  - Adds complexity to troubleshooting
  - VSO dependency for monitoring stack (circular dependency risk)

**Recommendation: Option A (Direct Token)**

For a monitoring/observability stack, **simplicity and reliability are paramount**. The direct token approach:
1. Keeps monitoring independent of the system being monitored (VSO)
2. Reduces failure modes (no VSO dependency)
3. Matches the existing audit exporter pattern (uses VAULT_TOKEN)
4. Is easier to troubleshoot when issues arise
5. Works with your existing token that's already configured

**Implementation: Direct Token Approach**

**File**: `audit-monitoring/kubernetes/03-prometheus-deployment.yaml`
**Changes**: Mount Vault token secret into Prometheus

```yaml
# Add to volumes section:
      - name: vault-token
        secret:
          secretName: vault-token
          items:
          - key: token
            path: token

# Add to volumeMounts section:
        - name: vault-token
          mountPath: /vault
          readOnly: true
```

**Note**: If you prefer the VSO approach for learning/demonstration purposes, I can provide an alternative implementation plan. However, for production-like monitoring, the direct token approach is more robust.

### Phase 3: Grafana Dashboard

#### 3.1 Create Telemetry Dashboard
**File**: `audit-monitoring/grafana/vault-telemetry-dashboard.json`
**Structure**: 7 panel groups covering the requested metrics

**Dashboard Layout**:
```
Row 1: Core Health Overview (4 panels)
- Total API Requests (stat)
- Average Request Latency (stat)
- Seal Status (stat with color coding)
- Leader Elections (stat)

Row 2: Request Performance (2 panels)
- Request Rate Over Time (timeseries by operation)
- Request Latency Distribution (heatmap)

Row 3: Authentication & Authorization (2 panels)
- Login Attempts by Auth Method (timeseries)
- Policy Evaluations (timeseries)

Row 4: Secrets Engine Activity (2 panels)
- Reads/Writes by Engine (stacked timeseries)
- Errors by Engine (timeseries)

Row 5: Audit Compliance (2 panels)
- Audit Log Entries (stat + timeseries)
- Audit Log Errors (stat + timeseries)

Row 6: System Health (2 panels)
- Unsealed Status Timeline (state timeline)
- Core Metrics Summary (table)
```

**Key Metrics Mapping**:
1. **Core Health**:
   - `vault_core_handle_request{quantile="0.99"}` - Request latency
   - `rate(vault_core_handle_request_count[5m])` - Request rate
   - `vault_core_unsealed` - Seal status (1=unsealed, 0=sealed)
   - `increase(vault_core_leadership_setup_failed[1h])` - Leader elections

2. **Authentication**:
   - `rate(vault_token_create_count[5m])` - Token creation rate
   - `rate(vault_token_lookup_count[5m])` - Token lookups
   - `rate(vault_policy_get_policy[5m])` - Policy evaluations

3. **Secrets Engines**:
   - `rate(vault_secret_kv_count[5m])` - KV operations
   - `rate(vault_database_*[5m])` - Database operations
   - `rate(vault_pki_*[5m])` - PKI operations

4. **Audit**:
   - `vault_audit_log_request` - Audit log entries
   - `vault_audit_log_request_failure` - Audit failures

#### 3.2 Update Grafana ConfigMap
**File**: `audit-monitoring/kubernetes/04-grafana-config.yaml`
**Changes**: Add second dashboard ConfigMap

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-vault-telemetry
  namespace: audit-monitoring
data:
  vault-telemetry-dashboard.json: |
    {
      "title": "Vault Telemetry & Performance",
      "tags": ["vault", "telemetry", "performance", "health"],
      ...
    }
```

#### 3.3 Update Grafana Deployment
**File**: `audit-monitoring/kubernetes/05-grafana-deployment.yaml`
**Changes**: Mount both dashboards

```yaml
# Add to volumeMounts:
        - name: dashboard-telemetry
          mountPath: /var/lib/grafana/dashboards/telemetry

# Add to volumes:
      - name: dashboard-telemetry
        configMap:
          name: grafana-dashboard-vault-telemetry
```

### Phase 4: Setup Script Modifications

#### 4.1 Conditional Deployment Logic
**File**: `scripts/setup/setup-audit-monitoring.sh`
**Location**: After audit device setup, before Kubernetes deployment

```bash
# Check telemetry availability
TELEMETRY_ENABLED=false
if check_vault_telemetry; then
    TELEMETRY_ENABLED=true
    
    # Create Kubernetes secret with Vault token
    echo -e "\n${GREEN}Creating Vault token secret for Prometheus...${NC}"
    kubectl create secret generic vault-token \
        --from-literal=token="$VAULT_TOKEN" \
        -n audit-monitoring \
        --dry-run=client -o yaml | kubectl apply -f -
    
    echo -e "${GREEN}✓ Telemetry monitoring will be enabled${NC}"
else
    echo -e "${YELLOW}⚠ Telemetry monitoring will be skipped${NC}"
fi

# Deploy Kubernetes resources
echo -e "\n${GREEN}Deploying Kubernetes resources...${NC}"

# ... existing deployment code ...

# Conditional telemetry dashboard deployment
if [ "$TELEMETRY_ENABLED" = true ]; then
    echo -e "${BLUE}Deploying telemetry dashboard...${NC}"
    kubectl apply -f audit-monitoring/kubernetes/06-grafana-telemetry-dashboard.yaml
fi
```

#### 4.2 Update Status Display
**Location**: End of script (around line 170)

```bash
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
```

### Phase 5: Documentation Updates

#### 5.1 Update README Architecture Diagram
**File**: `README.md`
**Changes**: Add telemetry flow to architecture diagram

```
Audit Monitoring Stack:
  - Vault Audit Exporter → Prometheus (audit logs)
  - Vault Telemetry → Prometheus (performance metrics)
  - Prometheus → Grafana (2 dashboards)
```

#### 5.2 Update Demo Section
**File**: `README.md`
**Section**: "4. Audit Monitoring Demo"
**Changes**:
- Mention two dashboards available
- List key metrics visible in telemetry dashboard
- Note that telemetry is optional

```markdown
#### Available Dashboards

1. **Vault Audit Monitoring** - Security and compliance metrics
   - Request patterns and volumes
   - Authentication activity
   - Error tracking
   
2. **Vault Telemetry & Performance** (if telemetry enabled)
   - Core health metrics (request rate, latency)
   - Seal/unseal status
   - Authentication and authorization activity
   - Secrets engine usage
   - Audit log metrics
```

#### 5.3 Add Troubleshooting Section
**File**: `README.md`
**New Section**: Under Troubleshooting

```markdown
### Telemetry Not Available

If telemetry monitoring is not deployed:

1. Verify telemetry is enabled in Vault config:
   ```bash
   curl -H "X-Vault-Token: $VAULT_TOKEN" \
     https://127.0.0.1:8200/v1/sys/metrics?format=prometheus
   ```

2. Add telemetry stanza to vault-server.hcl:
   ```hcl
   telemetry {
     prometheus_retention_time = "5m"
     disable_hostname = false
   }
   ```

3. Restart Vault and re-run setup:
   ```bash
   make setup-audit-monitoring
   ```
```

### Phase 6: Makefile Updates

#### 6.1 Add Telemetry-Specific Targets
**File**: `Makefile`
**New Targets**:

```makefile
.PHONY: check-vault-telemetry
check-vault-telemetry:
	@echo "Checking Vault telemetry..."
	@curl -sk -H "X-Vault-Token: $$VAULT_TOKEN" \
		"$$VAULT_ADDR/v1/sys/metrics?format=prometheus" | head -20

.PHONY: telemetry-dashboard
telemetry-dashboard: grafana-port-forward
	@echo "Opening Vault Telemetry dashboard..."
	@echo "Navigate to: http://localhost:3000/d/vault-telemetry"
```

## Implementation Order

1. ✅ **Phase 1**: Prerequisites and validation (README + verification function)
2. ✅ **Phase 2**: Prometheus configuration (scrape config + token mount)
3. ✅ **Phase 3**: Grafana dashboard (create dashboard JSON + ConfigMap)
4. ✅ **Phase 4**: Setup script modifications (conditional logic)
5. ✅ **Phase 5**: Documentation updates (README sections)
6. ✅ **Phase 6**: Makefile updates (new targets)

## Testing Plan

### Test Scenarios

1. **Telemetry Enabled** (Happy Path)
   - Run `make setup-audit-monitoring`
   - Verify telemetry check passes
   - Verify Prometheus scrapes Vault metrics
   - Verify both dashboards appear in Grafana
   - Verify metrics populate in telemetry dashboard

2. **Telemetry Disabled** (Graceful Degradation)
   - Disable telemetry in Vault config
   - Run `make setup-audit-monitoring`
   - Verify warning message appears
   - Verify audit monitoring still works
   - Verify only audit dashboard appears

3. **Token Issues**
   - Test with invalid VAULT_TOKEN
   - Verify appropriate error messages
   - Verify setup doesn't proceed

### Validation Commands

```bash
# Check telemetry endpoint
curl -sk -H "X-Vault-Token: $VAULT_TOKEN" \
  https://127.0.0.1:8200/v1/sys/metrics?format=prometheus | grep vault_core_

# Check Prometheus targets
kubectl port-forward -n audit-monitoring svc/prometheus 9090:9090
# Visit: http://localhost:9090/targets

# Check Prometheus metrics
curl -s http://localhost:9090/api/v1/query?query=vault_core_unsealed

# Check Grafana dashboards
kubectl port-forward -n audit-monitoring svc/grafana 3000:3000
# Visit: http://localhost:3000
```

## Metrics Reference

### Core Health Metrics
- `vault_core_handle_request_count` - Total requests
- `vault_core_handle_request_sum` / `vault_core_handle_request_count` - Avg latency
- `vault_core_leadership_setup_failed` - Leader elections
- `vault_core_unsealed` - Seal status (1=unsealed)

### Authentication Metrics
- `vault_token_create_count` - Token creations
- `vault_token_lookup_count` - Token lookups
- `vault_policy_get_policy` - Policy evaluations

### Secrets Engine Metrics
- `vault_secret_kv_count` - KV operations
- `vault_database_*` - Database operations
- `vault_pki_*` - PKI operations

### Audit Metrics
- `vault_audit_log_request` - Audit entries
- `vault_audit_log_request_failure` - Audit failures

## File Changes Summary

### New Files
1. `audit-monitoring/grafana/vault-telemetry-dashboard.json` - Telemetry dashboard
2. `TELEMETRY_IMPLEMENTATION_PLAN.md` - This document

### Modified Files
1. `README.md` - Prerequisites, architecture, demo section, troubleshooting
2. `scripts/setup/setup-audit-monitoring.sh` - Telemetry check, conditional deployment
3. `audit-monitoring/kubernetes/02-prometheus-config.yaml` - Add Vault scrape job
4. `audit-monitoring/kubernetes/03-prometheus-deployment.yaml` - Mount Vault token
5. `audit-monitoring/kubernetes/04-grafana-config.yaml` - Add telemetry dashboard ConfigMap
6. `audit-monitoring/kubernetes/05-grafana-deployment.yaml` - Mount telemetry dashboard
7. `Makefile` - Add telemetry check targets

## Security Considerations

1. **Token Storage**: Vault token stored as Kubernetes secret (base64 encoded)
2. **TLS**: Using `insecure_skip_verify` for local development (acceptable for demo)
3. **Token Rotation**: If Vault token changes, secret must be updated
4. **Namespace Isolation**: All resources in `audit-monitoring` namespace

## Future Enhancements

1. **Token Rotation**: Automate Vault token renewal
2. **Alerting**: Add Prometheus alerting rules for critical metrics
3. **Multi-Vault**: Support multiple Vault instances
4. **Enterprise Metrics**: Add replication metrics for Vault Enterprise
5. **Resource Metrics**: Integrate node_exporter for system metrics

## Success Criteria

- ✅ Telemetry check function works correctly (returns 0 or 1, never fails)
- ✅ Prometheus successfully scrapes Vault metrics when enabled
- ✅ Grafana displays both dashboards when telemetry enabled
- ✅ **CRITICAL**: Setup gracefully skips telemetry when disabled and continues
- ✅ **CRITICAL**: `make all-local` completes successfully whether telemetry is available or not
- ✅ Documentation clearly explains prerequisites and optional nature
- ✅ All existing audit monitoring functionality preserved
- ✅ No breaking changes to existing workflows
- ✅ Exit codes remain 0 (success) even when telemetry unavailable

---

**Implementation Status**: Ready for execution
**Estimated Time**: 3-4 hours
**Risk Level**: Low (conditional deployment prevents breaking changes)