# Main target for complete master-demo setup
master-demo: start-minikube setup-local-vault install-vso-local install-postgresql-pod setup-postgresql-local deploy-db-ui setup-pki-vault deploy-pki-secrets setup-encryption-vault deploy-encryption-demo setup-gitlab-demo setup-audit-monitoring enable-audit-log-rotation rotate-audit-log-if-needed setup-auto-audit-rotation port-forward-all

# Legacy alias for backward compatibility
.PHONY: all-local
all-local: master-demo
define header
	$(info Running >>> $(1)$(END))
endef

## list all targets
.PHONY: no_targets__ list
no_targets__:
list:
	sh -c "$(MAKE) -p no_targets__ | awk -F':' '/^[a-zA-Z0-9][^\$$#\/\\t=]*:([^=]|$$)/ {split(\$$1,A,/ /);for(i in A)print A[i]}' | grep -v '__\$$' | sort"


.PHONY: start-minikube
start-minikube:
	$(call header,$@)
	@if minikube status | grep -q "host: Running"; then \
		echo "Minikube is already running"; \
	else \
		echo "Starting minikube..."; \
		minikube start; \
		sleep 5; \
	fi


.PHONY: events
events:
	$(call header,$@)
	@kubectl get events --all-namespaces --sort-by='.metadata.creationTimestamp' -w

.PHONY: vso-logs
vso-logs:
	$(call header,$@)
	@kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator -f

.PHONY: install-postgresql-pod
install-postgresql-pod:
	$(call header,$@)
	@kubectl create ns postgres 2>/dev/null || echo "Namespace postgres already exists"
	@sleep 2
	@helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || echo "Bitnami repo already added"
	@helm upgrade --install postgres bitnami/postgresql --namespace postgres --set auth.audit.logConnections=true --set auth.postgresPassword=secret-pass
	@kubectl wait --for=jsonpath='{.status.phase}'=Running pod --all --namespace postgres --timeout=2m
## need a pause to let connection be available - is there a way to test it?
	@sleep 5


## Local Vault Setup Targets

.PHONY: setup-local-vault
setup-local-vault:
	$(call header,$@)
	@chmod +x scripts/setup/setup-local-vault.sh
	@./scripts/setup/setup-local-vault.sh

.PHONY: install-vso-local
install-vso-local:
	$(call header,$@)
	@helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
	@helm repo update
	@if helm list -n vault-secrets-operator-system | grep -q vault-secrets-operator; then \
		echo "VSO already installed, upgrading..."; \
		helm upgrade vault-secrets-operator hashicorp/vault-secrets-operator \
			-n vault-secrets-operator-system \
			--values scripts/setup/vault-operator-values.yaml; \
	else \
		echo "Installing VSO (latest version)..."; \
		helm install vault-secrets-operator hashicorp/vault-secrets-operator \
			-n vault-secrets-operator-system \
			--create-namespace \
			--values scripts/setup/vault-operator-values.yaml; \
	fi
	@echo "Waiting for VSO pods to be created..."
	@sleep 15
	@echo "Checking pod status..."
	@kubectl get pods -n vault-secrets-operator-system
	@echo "Waiting for pods to be ready (timeout: 5 minutes)..."
	@kubectl wait --for=condition=ready pod \
		--all --namespace vault-secrets-operator-system --timeout=5m || \
		(echo "Pod failed to start. Checking logs..." && \
		kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator --tail=50 && \
		kubectl describe pod -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator && \
		exit 1)

# Note: Static secrets demo has been replaced with GitLab CI/CD demo
# Use 'make all-gitlab' to deploy GitLab with Vault integration

.PHONY: setup-postgresql-local
setup-postgresql-local:
	$(call header,$@)
	@chmod +x scripts/setup/setup-postgresql-vault.sh
	@./scripts/setup/setup-postgresql-vault.sh

.PHONY: deploy-db-ui
deploy-db-ui:
	$(call header,$@)
	@kubectl create ns db-demo || true
	@sleep 5
	@kubectl apply -f dynamic-secrets/ -n db-demo
	@sleep 10
	@echo "Dynamic secrets - username: $$(kubectl get secrets -n db-demo vso-db-demo -o jsonpath="{.data.username}" | base64 -d), password: $$(kubectl get secrets -n db-demo vso-db-demo -o jsonpath="{.data.password}" | base64 -d)"

.PHONY: test-local
test-local:
	$(call header,$@)
	@echo "=== Testing Local Vault Setup ==="
	@echo "Vault Status:"
	@vault status || echo "Cannot connect to Vault"
	@echo ""
	@echo "Static Secrets:"
	@kubectl get secrets -n static-demo secretkv -o jsonpath="{.data.username}" | base64 -d && echo ""
	@kubectl get secrets -n static-demo secretkv -o jsonpath="{.data.password}" | base64 -d && echo ""
	@echo ""
	@echo "Dynamic Secrets:"
	@kubectl get secrets -n db-demo vso-db-demo -o jsonpath="{.data.username}" | base64 -d && echo ""
	@kubectl get secrets -n db-demo vso-db-demo -o jsonpath="{.data.password}" | base64 -d && echo ""

.PHONY: db-logs
db-logs:
	$(call header,$@)
	@echo "Streaming logs from dynamic database demo app..."
	@echo "You'll see the app connecting to PostgreSQL with rotating credentials"
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl logs -n db-demo -l app=vso-db-demo -f --tail=50

.PHONY: clean-local
clean-local:
	$(call header,$@)
	@kubectl delete ns static-demo db-demo pki-demo encryption-demo postgres gitlab-demo vault-secrets-operator-system || true
	@helm uninstall vault-secrets-operator -n vault-secrets-operator-system || true
	@helm uninstall gitlab -n gitlab-demo || true

## PKI Certificate Auto-Renewal Targets

.PHONY: setup-pki-vault
setup-pki-vault:
	$(call header,$@)
	@chmod +x scripts/setup/setup-pki-vault.sh
	@./scripts/setup/setup-pki-vault.sh

.PHONY: deploy-pki-secrets
deploy-pki-secrets:
	$(call header,$@)
	@kubectl create ns pki-demo || true
	@sleep 5
	@kubectl apply -f pki-secrets/
	@sleep 10
	@echo "PKI Demo - Certificate info:"
	@kubectl get secret -n pki-demo pki-demo-tls -o jsonpath="{.data.certificate}" 2>/dev/null | base64 -d | openssl x509 -noout -subject -dates 2>/dev/null || echo "Certificate not yet provisioned"

.PHONY: watch-pki-certs
watch-pki-certs:
	$(call header,$@)
	@echo "Watching certificate expiration (Ctrl+C to stop)..."
	@echo "Certificate renews every ~25 seconds (30s TTL with 5s offset)"
	@echo ""
	@watch -n 2 'kubectl get secret -n pki-demo pki-demo-tls -o jsonpath="{.data.certificate}" 2>/dev/null | base64 -d | openssl x509 -noout -enddate 2>/dev/null || echo "Certificate not yet provisioned"'

.PHONY: pki-logs
pki-logs:
	$(call header,$@)
	@kubectl logs -n pki-demo -l app=pki-demo -f

.PHONY: all-recover
all-recover:
	$(call header,$@)
	@chmod +x scripts/setup/recover-after-reboot.sh
	@./scripts/setup/recover-after-reboot.sh

.PHONY: recover-after-reboot
recover-after-reboot: all-recover

# Legacy alias
.PHONY: recover-pki-rotation
recover-pki-rotation: all-recover


.PHONY: pki-status
pki-status:
	$(call header,$@)
	@echo "=== PKI Demo Status ==="
	@echo ""
	@echo "VaultAuth:"
	@kubectl get vaultauth -n pki-demo
	@echo ""
	@echo "VaultPKISecret:"
	@kubectl get vaultpkisecret -n pki-demo
	@echo ""
	@echo "Pods:"
	@kubectl get pods -n pki-demo
	@echo ""
	@echo "Secret:"
	@kubectl get secret pki-demo-tls -n pki-demo

.PHONY: pki-port-forward
pki-port-forward:
	$(call header,$@)
	@echo "Port-forwarding PKI demo app..."
	@echo "Access at: http://localhost:10003"
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n pki-demo svc/pki-demo-app 10003:80

.PHONY: postgres-port-forward
postgres-port-forward:
	$(call header,$@)
	@echo "Port-forwarding PostgreSQL..."
	@echo "PostgreSQL accessible at: localhost:9998"
	@echo "This is required for dynamic secrets demo"
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n postgres svc/postgres-postgresql 9998:5432

.PHONY: clean-pki
clean-pki:
	$(call header,$@)
	@kubectl delete ns pki-demo || true
	@echo "PKI demo cleaned up"

.PHONY: all-pki
all-pki: setup-pki-vault deploy-pki-secrets
	$(call header,$@)
	@echo ""
	@echo "=== PKI Certificate Auto-Renewal Demo Deployed! ==="
	@echo ""
	@echo "Next steps:"
	@echo "  1. Check status: make pki-status"
	@echo "  2. Watch certificates: make watch-pki-certs"
	@echo "  3. Access demo: make pki-port-forward"
	@echo "  4. View logs: make pki-logs"
	@echo ""
	@echo "The certificate will auto-renew every ~25 seconds!"
.PHONY: clean-pki-vault
clean-pki-vault: clean-master-demo

.PHONY: clean-pki-all
clean-pki-all: clean-master-demo

.PHONY: clean-vault-all
clean-vault-all: clean-master-demo

.PHONY: clean-master-demo
clean-master-demo:
	$(call header,$@)
	@chmod +x scripts/cleanup/cleanup-all.sh
	@./scripts/cleanup/cleanup-all.sh

# Legacy alias for backward compatibility
.PHONY: clean-all-local
clean-all-local: clean-master-demo

.PHONY: db-ui-port-forward
db-ui-port-forward:
	$(call header,$@)
	@echo "Port-forwarding Dynamic DB UI..."
	@echo "Access at: http://localhost:10002"
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n db-demo svc/vso-db-demo-ui 10002:8080

.PHONY: db-ui-logs
db-ui-logs:
	$(call header,$@)
	@echo "Streaming logs from Dynamic DB UI demo..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl logs -n db-demo -l app=vso-db-demo-ui -f --tail=50

.PHONY: db-ui-status
db-ui-status:
	$(call header,$@)
	@echo "=== Dynamic DB UI Demo Status ==="
	@echo ""
	@echo "VaultAuth:"
	@kubectl get vaultauth -n db-demo
	@echo ""
	@echo "VaultDynamicSecret:"
	@kubectl get vaultdynamicsecret -n db-demo
	@echo ""
	@echo "Pods:"
	@kubectl get pods -n db-demo
	@echo ""
	@echo "Secret:"
	@kubectl get secret vso-db-demo -n db-demo
	@echo ""
	@echo "Current Credentials:"
	@echo "  Username: $$(kubectl get secrets -n db-demo vso-db-demo -o jsonpath="{.data.username}" 2>/dev/null | base64 -d || echo 'N/A')"
	@echo "  Password: $$(kubectl get secrets -n db-demo vso-db-demo -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo 'N/A')"

.PHONY: clean-db-ui
clean-db-ui:
	$(call header,$@)
	@kubectl delete -f dynamic-secrets/app-deployment-ui.yaml || true
	@kubectl delete -f dynamic-secrets/service.yaml || true
## Encryption Demo Targets

.PHONY: setup-encryption-vault
setup-encryption-vault:
	$(call header,$@)
	@chmod +x scripts/setup/setup-encryption-vault.sh
	@./scripts/setup/setup-encryption-vault.sh

.PHONY: deploy-encryption-demo
deploy-encryption-demo:
	$(call header,$@)
	@kubectl create ns encryption-demo || true
	@sleep 5
	@echo "Creating ConfigMap from app-simple.py..."
	@kubectl create configmap encryption-app --from-file=app.py=encryption-secrets/app-simple.py -n encryption-demo --dry-run=client -o yaml | kubectl apply -f -
	@echo "Applying other encryption demo resources..."
	@kubectl apply -f encryption-secrets/service.yaml -n encryption-demo
	@kubectl apply -f encryption-secrets/vault-auth-encryption.yaml -n encryption-demo
	@kubectl apply -f encryption-secrets/vault-static-secret.yaml -n encryption-demo
	@kubectl apply -f encryption-secrets/app-deployment.yaml -n encryption-demo
	@sleep 10
	@echo "Encryption Demo deployed!"

.PHONY: encryption-port-forward
encryption-port-forward:
	$(call header,$@)
	@echo "Port-forwarding Encryption Demo UI..."
	@echo "Access at: http://localhost:10004"
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n encryption-demo svc/encryption-demo-ui 10004:8080

.PHONY: encryption-logs
encryption-logs:
	$(call header,$@)
	@echo "Streaming logs from Encryption Demo..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl logs -n encryption-demo -l app=encryption-demo-ui -f --tail=50

.PHONY: encryption-status
encryption-status:
	$(call header,$@)
	@echo "=== Encryption Demo Status ==="
	@echo ""
	@echo "VaultAuth:"
	@kubectl get vaultauth -n encryption-demo
	@echo ""
	@echo "VaultStaticSecret:"
	@kubectl get vaultstaticsecret -n encryption-demo
	@echo ""
	@echo "Pods:"
	@kubectl get pods -n encryption-demo
	@echo ""
	@echo "Service:"
	@kubectl get svc -n encryption-demo

.PHONY: clean-encryption
clean-encryption:
	$(call header,$@)
	@kubectl delete ns encryption-demo || true
	@echo "Encryption demo cleaned up"

	@echo "DB UI demo cleaned up (keeping VaultAuth and VaultDynamicSecret)"

.PHONY: port-forward-all
port-forward-all:
	$(call header,$@)
	@echo "Starting all port-forwards in background..."
	@echo ""
	@# Kill any existing port-forwards
	@pkill -f "kubectl port-forward.*db-demo.*10002" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*pki-demo.*10003" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*postgres.*9998" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*gitlab-demo.*10001" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*encryption-demo.*10004" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*audit-monitoring.*10000" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*audit-monitoring.*9999" 2>/dev/null || true
	@sleep 2
	@# Start port-forwards in background
	@echo "Starting Dynamic DB UI port-forward (http://localhost:10002)..."
	@kubectl port-forward -n db-demo svc/vso-db-demo-ui 10002:8080 > /dev/null 2>&1 &
	@sleep 1
	@echo "Starting PKI Demo port-forward (http://localhost:10003)..."
	@kubectl port-forward -n pki-demo svc/pki-demo-app 10003:80 > /dev/null 2>&1 &
	@sleep 1
	@echo "Starting Encryption Demo port-forward (http://localhost:10004)..."
	@kubectl port-forward -n encryption-demo svc/encryption-demo-ui 10004:8080 > /dev/null 2>&1 &
	@sleep 1
	@echo "Starting PostgreSQL port-forward (localhost:9998)..."
	@kubectl port-forward -n postgres svc/postgres-postgresql 9998:5432 > /dev/null 2>&1 &
	@sleep 1
	@# Check if GitLab is deployed and start port-forward if it exists
	@if kubectl get namespace gitlab-demo > /dev/null 2>&1; then \
		echo "Starting GitLab UI port-forward (http://localhost:10001)..."; \
		(kubectl port-forward -n gitlab-demo svc/gitlab 10001:80 > /dev/null 2>&1) & \
		sleep 1; \
	fi
	@# Check if audit-monitoring is deployed and start port-forwards if it exists
	@if kubectl get namespace audit-monitoring > /dev/null 2>&1; then \
		echo "Waiting for Grafana to be ready..."; \
		kubectl wait --for=condition=ready pod -l app=grafana -n audit-monitoring --timeout=60s > /dev/null 2>&1 || echo "Grafana not ready yet"; \
		echo "Starting Grafana port-forward (http://localhost:10000)..."; \
		(kubectl port-forward -n audit-monitoring svc/grafana 10000:3000 > /dev/null 2>&1) & \
		sleep 1; \
		echo "Waiting for Prometheus to be ready..."; \
		kubectl wait --for=condition=ready pod -l app=prometheus -n audit-monitoring --timeout=60s > /dev/null 2>&1 || echo "Prometheus not ready yet"; \
		echo "Starting Prometheus port-forward (http://localhost:9999)..."; \
		(kubectl port-forward -n audit-monitoring svc/prometheus 9999:9090 > /dev/null 2>&1) & \
		sleep 1; \
	fi
	@echo ""
	@echo "=== All Port-Forwards Active ==="
	@echo ""
	@echo "🔐 Vault UI:         https://127.0.0.1:8200/ui/"
	@echo "   Method:           Username"
	@echo "   Username:         demo"
	@echo "   Password:         demo123"
	@echo "   Namespace:        master-demo"
	@echo ""
	@echo "🦊 GitLab CE:        http://localhost:10001"
	@echo "📊 Dynamic DB UI:    http://localhost:10002"
	@echo "🔐 PKI Demo:         http://localhost:10003"
	@echo "🔒 Encryption Demo:  http://localhost:10004"
	@echo "🐘 PostgreSQL:       localhost:9998"
	@if kubectl get namespace gitlab-demo > /dev/null 2>&1; then \
		echo ""; \
		echo "GitLab Credentials:"; \
		echo "   Username:         root"; \
		echo "   Password:         VaultDemoStr0ng!2026"; \
	fi
	@if kubectl get namespace audit-monitoring > /dev/null 2>&1; then \
		echo "📈 Grafana:          http://localhost:10000"; \
		echo "   Username:         admin"; \
		echo "   Password:         admin"; \
		echo "📊 Prometheus:       http://localhost:9999"; \
	fi
	@echo ""
	@echo "To stop all port-forwards: make stop-port-forwards"
	@echo "To view running port-forwards: ps aux | grep 'kubectl port-forward'"

.PHONY: stop-port-forwards
stop-port-forwards:
	$(call header,$@)
	@echo "Stopping all port-forwards..."
	@pkill -f "kubectl port-forward.*db-demo" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*pki-demo" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*encryption-demo" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*postgres" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*gitlab-demo" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*audit-monitoring" 2>/dev/null || true
	@echo "All port-forwards stopped"

.PHONY: status-port-forwards
status-port-forwards:
	$(call header,$@)
	@echo "=== Active Port-Forwards ==="
	@ps aux | grep -E "kubectl port-forward.*(db-demo|pki-demo|postgres)" | grep -v grep || echo "No port-forwards running"


## GitLab CI/CD Demo Targets

.PHONY: setup-gitlab-vault
setup-gitlab-vault:
	$(call header,$@)
	@chmod +x scripts/setup/setup-gitlab-demo.sh
	@./scripts/setup/setup-gitlab-demo.sh

.PHONY: install-gitlab
install-gitlab:
	$(call header,$@)
	@chmod +x scripts/setup/setup-gitlab-demo.sh
	@./scripts/setup/setup-gitlab-demo.sh

.PHONY: deploy-gitlab-demo
deploy-gitlab-demo:
	$(call header,$@)
	@chmod +x scripts/setup/setup-gitlab-demo.sh
	@./scripts/setup/setup-gitlab-demo.sh

.PHONY: deploy-gitlab-simple
deploy-gitlab-simple: setup-gitlab-demo

.PHONY: register-gitlab-runner
register-gitlab-runner:
	$(call header,$@)
	@chmod +x scripts/setup/setup-gitlab-demo.sh
	@./scripts/setup/setup-gitlab-demo.sh

.PHONY: setup-gitlab-project
setup-gitlab-project:
	$(call header,$@)
	@chmod +x scripts/setup/setup-gitlab-demo.sh
	@./scripts/setup/setup-gitlab-demo.sh

.PHONY: setup-gitlab-demo
setup-gitlab-demo:
	$(call header,$@)
	@chmod +x scripts/setup/setup-gitlab-demo.sh
	@./scripts/setup/setup-gitlab-demo.sh

.PHONY: gitlab-port-forward
gitlab-port-forward:
	$(call header,$@)
	@echo "=== GitLab Access Information ==="
	@echo ""
	@echo "URL: http://localhost:10001"
	@echo "Username: root"
	@echo "Password: VaultDemoStr0ng!2026"
	@echo ""
	@echo "Port-forwarding GitLab UI..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n gitlab-demo svc/gitlab 10001:80

.PHONY: gitlab-logs
gitlab-logs:
	$(call header,$@)
	@echo "Streaming logs from GitLab..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl logs -n gitlab-demo -l app=gitlab -f --tail=50

.PHONY: gitlab-runner-logs
gitlab-runner-logs:
	$(call header,$@)
	@echo "Streaming logs from GitLab Runner..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl logs -n gitlab-demo -l app=gitlab-runner -f --tail=50

.PHONY: gitlab-status
gitlab-status:
	$(call header,$@)
	@echo "=== GitLab Demo Status ==="
	@echo ""
	@echo "VaultAuth:"
	@kubectl get vaultauth -n gitlab-demo
	@echo ""
	@echo "VaultStaticSecret:"
	@kubectl get vaultstaticsecret -n gitlab-demo
	@echo ""
	@echo "Pods:"
	@kubectl get pods -n gitlab-demo
	@echo ""
	@echo "Secret:"
	@kubectl get secret secretkv -n gitlab-demo 2>/dev/null || echo "Secret not yet created"
	@echo ""
	@echo "Current Credentials:"
	@echo "  Username: $$(kubectl get secrets -n gitlab-demo secretkv -o jsonpath="{.data.username}" 2>/dev/null | base64 -d || echo 'N/A')"
	@echo "  Password: $$(kubectl get secrets -n gitlab-demo secretkv -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo 'N/A')"

.PHONY: gitlab-get-password
gitlab-get-password:
	$(call header,$@)
	@echo "GitLab root password:"
	@echo "VaultDemoStr0ng!2026"
	@echo ""

.PHONY: test-gitlab-vault
test-gitlab-vault:
	$(call header,$@)
	@chmod +x scripts/test/test-gitlab-vault.sh
	@./scripts/test/test-gitlab-vault.sh

.PHONY: clean-gitlab
clean-gitlab: clean-master-demo

.PHONY: clean-gitlab-vault
clean-gitlab-vault: clean-master-demo

.PHONY: clean-gitlab-all
clean-gitlab-all: clean-master-demo

.PHONY: all-gitlab
all-gitlab: setup-gitlab-demo
	$(call header,$@)
	@echo ""
	@echo "=== GitLab CI/CD Demo Fully Deployed! ==="
	@echo ""
	@echo "✅ Everything is ready to use:"
	@echo "  - Lightweight GitLab CE deployed"
	@echo "  - Separate Kubernetes runner registered"
	@echo "  - Vault secrets synced to Kubernetes"
	@echo "  - Demo project 'vault-demo' created with pipeline"
	@echo ""
	@echo "🌐 Access Information:"
	@echo "  URL: http://localhost:8080/demo/vault-demo"
	@echo "  Username: root"
	@echo "  Password: VaultDemoStr0ng!2026"
	@echo ""
	@echo "🎯 Next Steps:"
	@echo "  1. Open http://localhost:8080/demo/vault-demo/-/pipelines"
	@echo "  2. Run the pipeline manually"
	@echo "  3. Update secrets: make update-gitlab-secret"
	@echo "  4. Re-run pipeline to see updated values"
	@echo ""
	@echo "📊 Useful Commands:"
	@echo "  - View pipeline logs: make gitlab-logs"
	@echo "  - Test secret rotation: make test-gitlab-vault"
	@echo "  - Stop port-forwards: make stop-port-forwards"


## Audit Monitoring Targets

.PHONY: setup-audit-monitoring
setup-audit-monitoring:
	$(call header,$@)
	@chmod +x scripts/setup/setup-audit-monitoring.sh
	@if [ -z "$$VAULT_TOKEN" ] && [ -z "$(VAULT_TOKEN)" ]; then \
		echo "WARNING: VAULT_TOKEN not set. Telemetry monitoring will be disabled."; \
		echo "To enable telemetry, run: export VAULT_TOKEN"; \
	fi
	@./scripts/setup/setup-audit-monitoring.sh
.PHONY: enable-audit-log-rotation
enable-audit-log-rotation:
	$(call header,$@)
	@chmod +x scripts/setup/enable-audit-log-rotation.sh
	@./scripts/setup/enable-audit-log-rotation.sh

.PHONY: force-audit-rotation
force-audit-rotation:
	$(call header,$@)
	@chmod +x scripts/setup/force-audit-log-rotation.sh
	@./scripts/setup/force-audit-log-rotation.sh

.PHONY: check-audit-log-size
check-audit-log-size:
	$(call header,$@)
	@echo "Checking audit log size..."
	@ls -lh ~/audit.log* 2>/dev/null || echo "No audit log files found"
	@echo ""
	@AUDIT_SIZE=$$(stat -f%z ~/audit.log 2>/dev/null || stat -c%s ~/audit.log 2>/dev/null || echo "0"); \
	if [ "$$AUDIT_SIZE" -gt 104857600 ]; then \
		echo "⚠️  WARNING: Audit log is larger than 100MB ($$(($$AUDIT_SIZE / 1024 / 1024))MB)"; \
		echo "Run 'make force-audit-rotation' to manually rotate the log"; \
	else \
		echo "✓ Audit log size is OK ($$(($$AUDIT_SIZE / 1024 / 1024))MB)"; \
	fi

.PHONY: rotate-audit-log-if-needed
rotate-audit-log-if-needed:
	$(call header,$@)
	@echo "Checking if audit log rotation is needed..."
	@chmod +x scripts/setup/auto-rotate-audit-log.sh
	@./scripts/setup/auto-rotate-audit-log.sh || true

.PHONY: setup-auto-audit-rotation
setup-auto-audit-rotation:
	$(call header,$@)
	@chmod +x scripts/setup/setup-audit-log-rotation-cron.sh
	@./scripts/setup/setup-audit-log-rotation-cron.sh

.PHONY: update-prometheus-policy
update-prometheus-policy:
	$(call header,$@)
	@echo "Updating Prometheus policy with master-demo namespace access..."
	@chmod +x scripts/setup/update-prometheus-policy.sh
	@./scripts/setup/update-prometheus-policy.sh


.PHONY: audit-monitoring-status
audit-monitoring-status:
	$(call header,$@)
	@echo "=== Audit Monitoring Status ==="
	@echo ""
	@echo "Pods:"
	@kubectl get pods -n audit-monitoring
	@echo ""
	@echo "Services:"
	@kubectl get svc -n audit-monitoring
	@echo ""
	@echo "PVCs:"
	@kubectl get pvc -n audit-monitoring

.PHONY: grafana-port-forward
grafana-port-forward:
	$(call header,$@)
	@echo "=== Grafana Access Information ==="
	@echo ""
	@echo "URL: http://localhost:3000"
	@echo "Username: admin"
	@echo "Password: admin"
	@echo ""
	@echo "Port-forwarding Grafana..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n audit-monitoring svc/grafana 10000:3000

.PHONY: prometheus-port-forward
prometheus-port-forward:
	$(call header,$@)
	@echo "=== Prometheus Access Information ==="
	@echo ""
	@echo "URL: http://localhost:9999"
	@echo ""
	@echo "Port-forwarding Prometheus..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n audit-monitoring svc/prometheus 9999:9090

.PHONY: check-vault-telemetry
check-vault-telemetry:
	$(call header,$@)
	@echo "Checking Vault telemetry availability..."
	@echo ""
	@if [ -z "$$VAULT_TOKEN" ]; then \
		echo "ERROR: VAULT_TOKEN not set"; \
		exit 1; \
	fi
	@curl -sk -H "X-Vault-Token: $$VAULT_TOKEN" \
		"$$VAULT_ADDR/v1/sys/metrics?format=prometheus" | head -20
	@echo ""
	@echo "If you see vault_core_* metrics above, telemetry is enabled."
	@echo "If not, add this to your Vault config:"
	@echo "  telemetry {"
	@echo "    prometheus_retention_time = \"5m\""
	@echo "  }"

.PHONY: audit-exporter-logs
audit-exporter-logs:
	$(call header,$@)
	@echo "Streaming logs from Vault audit exporter..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl logs -n audit-monitoring -l app=vault-audit-exporter -f --tail=100

.PHONY: audit-exporter-metrics
audit-exporter-metrics:
	$(call header,$@)
	@echo "Fetching current metrics from exporter..."
	@echo ""
	@kubectl port-forward -n audit-monitoring svc/vault-audit-exporter 9091:9091 > /dev/null 2>&1 &
	@sleep 2
	@curl -s http://localhost:9091/metrics | grep -E "^vault_audit_" | head -20
	@pkill -f "kubectl port-forward.*vault-audit-exporter" 2>/dev/null || true

.PHONY: test-audit-traffic
test-audit-traffic:
	$(call header,$@)
	@chmod +x scripts/test/test-audit-traffic.sh
	@./scripts/test/test-audit-traffic.sh

.PHONY: clean-audit-monitoring
clean-audit-monitoring:
	$(call header,$@)
	@echo "Cleaning up audit monitoring..."
	@kubectl delete namespace audit-monitoring --ignore-not-found=true || true
	@echo "Disabling Vault audit device..."
	@vault audit disable file 2>/dev/null || true
	@echo "Audit monitoring cleaned up"

.PHONY: all-audit-monitoring
all-audit-monitoring: setup-audit-monitoring
	$(call header,$@)
	@echo ""
	@echo "=== Vault Audit Monitoring Deployed! ==="
	@echo ""
	@echo "Next steps:"
	@echo "  1. Check status: make audit-monitoring-status"
	@echo "  2. Access Grafana: make grafana-port-forward"
	@echo "  3. Access Prometheus: make prometheus-port-forward"
	@echo "  4. View exporter logs: make audit-exporter-logs"
	@echo "  5. Generate test traffic: make test-audit-traffic"
	@echo ""
	@echo "Grafana dashboard will be available at http://localhost:3000"
	@echo "Default credentials: admin/admin"
