VAULT_LICENSE?="bob"
KBCTL_BIN?=$(shell which kubectl)
KBCTL_EXEC_VAULT?=$(KBCTL_BIN) exec -it vault-0 -n vault -- 
VAULT_NAMESPACE := us-west-org
ENT_ARGS :=--namespace $(VAULT_NAMESPACE)

all-ent: start-minikube install-vault-ent-cluster config-vault install-vault-secrets-operator deploy-and-sync-a-secret rotate-the-secret install-postgresql-pod setup-postgresql transit-encryption setup-dynamic-secrets create-the-application

all-local: start-minikube setup-local-vault install-vso-local install-postgresql-pod setup-postgresql-local deploy-db-ui setup-pki-vault deploy-pki-secrets setup-gitlab-demo setup-audit-monitoring enable-audit-log-rotation port-forward-all
# svc-health config-vault vso-install deploy-static-secret dynamic-secrets
define header
	$(info Running >>> $(1)$(END))
endef

## list all targets
.PHONY: no_targets__ list
no_targets__:
list:
	sh -c "$(MAKE) -p no_targets__ | awk -F':' '/^[a-zA-Z0-9][^\$$#\/\\t=]*:([^=]|$$)/ {split(\$$1,A,/ /);for(i in A)print A[i]}' | grep -v '__\$$' | sort"

.PHONY: test
test: 
	$(call header,$@)
	@echo $(VAULT_LICENSE)
	@echo $(KBCTL_EXEC_VAULT)
	kubectl get pods -n vault
	kubectl get secrets -n app
	echo "username: $$(kubectl get secrets -n app secretkv -o jsonpath="{.data.username}" | base64 -d), pass: $$(kubectl get secrets -n app secretkv -o jsonpath="{.data.password}" | base64 -d)"
	@$(KBCTL_EXEC_VAULT) vault write $(ENT_ARGS) demo-db/config/demo-db \
		plugin_name=postgresql-database-plugin \
  		allowed_roles="dev-postgres" \
  		connection_url="postgresql://{{username}}:{{password}}@postgres-postgresql.postgres.svc.cluster.local:5432/postgres?sslmode=disable" \
  		username="postgres" \
  		password="secret-pass"
	@echo "dynamic username: $$(kubectl get secrets -n demo-ns -o jsonpath="{.items[1].data.username}" | base64 -d), pass: $$(kubectl get secrets -n demo-ns -o jsonpath="{.items[1].data.password}" | base64 -d)"

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


.PHONY: destroy clean-up
destroy:
clean-up:
	$(call header,$@)
	@minikube delete
	@sleep 30


.PHONY: kill-ns
kill-ns:
	$(call header,$@)
	@kubectl delete ns vault app vault-secrets-operator-system demo-ns postgres
	sleep 5

# .PHONY: 
# vault-prereqs:
# 	$(call header,$@)
# 	@kubectl create ns vault
#	@kubectl create secret generic vault-license --from-literal license=$(VAULT_LICENSE) -n vault
#	@kubectl create secret generic vault-license --from-file license=vault-ent/vault-license.lic -n vault

.PHONY: prep-cluster-install
prep-cluster-install:
	$(call header,$@)
	helm repo add hashicorp https://helm.releases.hashicorp.com
	helm repo update
	helm search repo hashicorp/vault


.PHONY: install-vault-cluster
install-vault-cluster: prep-cluster-install
	$(call header,$@)
	helm install vault hashicorp/vault -n vault --create-namespace --values vault/vault-values.yaml
	kubectl get pods -n vault


.PHONY: install-vault-ent-cluster
install-vault-ent-cluster: prep-cluster-install
	$(call header,$@)
	kubectl create ns vault
	sleep 10
	kubectl create secret generic vault-license --from-literal license=$(VAULT_LICENSE) -n vault
	helm install vault hashicorp/vault -n vault --values vault-ent/vault-values.yaml
	kubectl wait --for=jsonpath='{.status.phase}'=Running pod --all --namespace vault --timeout=1m
	kubectl get pods -n vault


# .PHONY: vault-upgrade
# vault-upgrade:
# 	$(call header,$@)
# 	@helm upgrade vault hashicorp/vault -n vault --values vault/my-values.yaml
# 	@sleep 10
# 	@kubectl wait --for=jsonpath='{.status.phase}'=Running pod --all --namespace vault --timeout=1m
# 	@kubectl get all -n vault

.PHONY: uninstall-vault
uninstall-vault:
	$(call header,$@)
	@helm uninstall vault -n vault
	$(KBCTL_BIN) delete ns vault
	@sleep 10

.PHONY: reinstall-vault
reinstall-vault: uninstall-vault install-vault

.PHONY: status
status:
	$(call header,$@)
	@kubectl exec -n vault -ti vault-0 -- vault status

.PHONY: logs
logs:
	$(call header,$@)
	@kubectl logs -n vault sts/vault -f

.PHONY: events
events:
	$(call header,$@)
	@kubectl get events --all-namespaces --sort-by='.metadata.creationTimestamp' -w

# need set up - kb proxy
.PHONY: svc-health
svc-health:
	$(call header,$@)
	@curl -s http://localhost:8200/v1/sys/health | jq

.PHONY: health
health:
	$(call header,$@)
	@kubectl exec -n vault -ti vault-0 -- wget -qO - http://localhost:8200/v1/sys/health

.PHONY: vars
vars:
	@echo "export VAULT_ADDR=http://127.0.0.1:8200"
	@echo "export VAULT_TOKEN=root"

.PHONY: install-vault-secrets-operator
install-vault-secrets-operator:
	$(call header,$@)
	@helm install vault-secrets-operator hashicorp/vault-secrets-operator \
		-n vault-secrets-operator-system \
		--create-namespace \
		--values vault-ent/vault-operator-values.yaml \
		--version 0.8.0
	@sleep 10
	@kubectl wait --for=jsonpath='{.status.phase}'=Running pod \
		--all --namespace vault-secrets-operator-system --timeout=1m
	@kubectl wait --for=jsonpath='{.status.phase}'=Running pod --all --namespace vault-secrets-operator-system --timeout=1m
	@sleep 10

.PHONY: uninstall-vso
uninstall-vso:
	$(call header,$@)
	@helm uninstall vault-secrets-operator -n vault-secrets-operator-system

.PHONY: vso-logs
vso-logs:
	$(call header,$@)
	@kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator -f

# .PHONY: static-secrets
# static-secrets:
.PHONY: config-vault
config-vault:
	$(call header,$@)
	$(KBCTL_EXEC_VAULT) vault namespace create us-west-org
	$(KBCTL_EXEC_VAULT) vault auth enable $(ENT_ARGS) -path demo-auth-mount kubernetes
		$(KBCTL_EXEC_VAULT) vault write $(ENT_ARGS) auth/demo-auth-mount/config \
			kubernetes_host=https://$$(kubectl exec vault-0 -n vault --  printenv KUBERNETES_PORT_443_TCP_ADDR):443
	$(KBCTL_EXEC_VAULT) vault secrets enable  $(ENT_ARGS) -path=kvv2 kv-v2
	$(KBCTL_BIN) cp -n vault support/webapp.hcl vault-0:/tmp/webapp.hcl 
	$(KBCTL_EXEC_VAULT) vault policy write  $(ENT_ARGS) webapp /tmp/webapp.hcl
	$(KBCTL_EXEC_VAULT) vault write  $(ENT_ARGS) auth/demo-auth-mount/role/role1 \
   		bound_service_account_names=demo-static-app \
   		bound_service_account_namespaces=app \
   		policies=webapp \
   		audience=vault \
   		token_period=2m
	$(KBCTL_EXEC_VAULT) vault kv put $(ENT_ARGS) kvv2/webapp/config username="static-user" password="static-password"
	
# @kubectl cp -n vault ./static-secrets.sh vault-0:/tmp/static-secrets.sh
# @kubectl exec -n vault -ti vault-0 -- /bin/sh -c '/tmp/static-secrets.sh'

.PHONY: deploy-and-sync-a-secret
deploy-and-sync-a-secret:
	$(call header,$@)
	@kubectl create ns app
	@sleep 5
	@kubectl apply -f vault-ent/vault-auth-static.yaml
	@kubectl apply -f vault-ent/static-secret.yaml
	@sleep 3
	@echo "username: $$(kubectl get secrets -n app secretkv -o jsonpath="{.data.username}" | base64 -d), pass: $$(kubectl get secrets -n app secretkv -o jsonpath="{.data.password}" | base64 -d)"

.PHONY: rotate-the-secret
rotate-the-secret:
	$(call header,$@)
		@echo "username: $$(kubectl get secrets -n app secretkv -o jsonpath="{.data.username}" | base64 -d), pass: $$(kubectl get secrets -n app secretkv -o jsonpath="{.data.password}" | base64 -d)"
		$(KBCTL_EXEC_VAULT) vault kv put $(ENT_ARGS) kvv2/webapp/config username="static-user2" password="static-password2"
				@echo "username: $$(kubectl get secrets -n app secretkv -o jsonpath="{.data.username}" | base64 -d), pass: $$(kubectl get secrets -n app secretkv -o jsonpath="{.data.password}" | base64 -d)"

.PHONY: uninstall-secret
uninstall-secret:
	$(call header,$@)
	kubectl delete ns app

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

.PHONY: uninstall-postgresql-pod
uninstall-postgresql-pod:
	$(call header,$@)
	@kubectl delete ns postgres
	@$(KBCTL_EXEC_VAULT) vault secrets disable $(ENT_ARGS) demo-db
	sleep 10

.PHONY: setup-postgresql
setup-postgresql:
	$(call header,$@)
	$(KBCTL_EXEC_VAULT) vault secrets enable $(ENT_ARGS) -path=demo-db database
	sleep 10
	$(KBCTL_EXEC_VAULT) vault write $(ENT_ARGS) demo-db/config/demo-db \
		plugin_name=postgresql-database-plugin \
  		allowed_roles="dev-postgres" \
  		connection_url="postgresql://{{username}}:{{password}}@postgres-postgresql.postgres.svc.cluster.local:5432/postgres?sslmode=disable" \
  		username="postgres" \
  		password="secret-pass"
	$(KBCTL_EXEC_VAULT) vault write $(ENT_ARGS) demo-db/roles/dev-postgres db_name=demo-db \
		creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
      	GRANT ALL PRIVILEGES ON DATABASE postgres TO \"{{name}}\";" \
   		revocation_statements="REVOKE ALL ON DATABASE postgres FROM  \"{{name}}\";" \
   		backend=demo-db \
   		name=dev-postgres \
   		default_ttl="1m" \
   		max_ttl="1m"
	$(KBCTL_BIN) cp -n vault support/postgresql.hcl vault-0:/tmp/postgresql.hcl
	$(KBCTL_EXEC_VAULT) vault policy write $(ENT_ARGS) demo-auth-policy-db /tmp/postgresql.hcl

.PHONY: transit-encryption
transit-encryption:
	$(call header,$@)
	$(KBCTL_EXEC_VAULT) vault secrets enable $(ENT_ARGS) -path=demo-transit transit
	$(KBCTL_EXEC_VAULT) vault write  $(ENT_ARGS) -force demo-transit/keys/vso-client-cache
	$(KBCTL_BIN) cp -n vault support/demo-auth-policy-operator.hcl vault-0:/tmp/demo-auth-policy-operator.hcl
	$(KBCTL_EXEC_VAULT) vault policy write $(ENT_ARGS) demo-auth-policy-operator /tmp/demo-auth-policy-operator.hcl
	$(KBCTL_EXEC_VAULT) vault write $(ENT_ARGS) auth/demo-auth-mount/role/auth-role-operator \
		bound_service_account_names=vault-secrets-operator-controller-manager \
		bound_service_account_namespaces=vault-secrets-operator-system \
		token_ttl=0 \
		token_period=120 \
		token_policies=demo-auth-policy-operator \
		audience=vault

.PHONY: setup-dynamic-secrets
setup-dynamic-secrets:
	$(call header,$@)
	$(KBCTL_EXEC_VAULT) vault write $(ENT_ARGS) auth/demo-auth-mount/role/auth-role \
   		bound_service_account_names=demo-dynamic-app \
   		bound_service_account_namespaces=demo-ns \
   		token_ttl=0 \
   		token_period=120 \
   		token_policies=demo-auth-policy-db \
		audience=vault

.PHONY: create-the-application
create-the-application:
	$(call header,$@)
	@kubectl create ns demo-ns
	@sleep 10
	@kubectl apply -f vault-ent/dynamic-secrets/.
	@sleep 10
	echo "dynamic username: $(kubectl get secrets -n demo-ns -o jsonpath="{.items[1].data.username}" | base64 -d), pass: $(kubectl get secrets -n demo-ns -o jsonpath="{.items[1].data.password}" | base64 -d)"

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
	@kubectl apply -f dynamic-secrets/
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
	@kubectl delete ns static-demo db-demo pki-demo postgres gitlab-demo vault-secrets-operator-system || true
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
	@chmod +x scripts/setup/recover-pki-rotation.sh
	@./scripts/setup/recover-pki-rotation.sh

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
	@echo "Access at: https://localhost:8443 (HTTPS) or http://localhost:9090 (HTTP)"
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n pki-demo svc/pki-demo-app 8443:443 9090:80

.PHONY: postgres-port-forward
postgres-port-forward:
	$(call header,$@)
	@echo "Port-forwarding PostgreSQL..."
	@echo "PostgreSQL accessible at: localhost:5432"
	@echo "This is required for dynamic secrets demo"
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n postgres svc/postgres-postgresql 5432:5432

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
clean-pki-vault: clean-all-local

.PHONY: clean-pki-all
clean-pki-all: clean-all-local

.PHONY: clean-vault-all
clean-vault-all: clean-all-local

.PHONY: clean-all-local
clean-all-local:
	$(call header,$@)
	@chmod +x scripts/cleanup/cleanup-all.sh
	@./scripts/cleanup/cleanup-all.sh

.PHONY: db-ui-port-forward
db-ui-port-forward:
	$(call header,$@)
	@echo "Port-forwarding Dynamic DB UI..."
	@echo "Access at: http://localhost:8090"
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n db-demo svc/vso-db-demo-ui 8090:8080

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
	@echo "DB UI demo cleaned up (keeping VaultAuth and VaultDynamicSecret)"

.PHONY: port-forward-all
port-forward-all:
	$(call header,$@)
	@echo "Starting all port-forwards in background..."
	@echo ""
	@# Kill any existing port-forwards
	@pkill -f "kubectl port-forward.*db-demo.*8090" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*pki-demo.*8443" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*postgres.*5432" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*gitlab-demo.*8080" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*audit-monitoring.*3000" 2>/dev/null || true
	@pkill -f "kubectl port-forward.*audit-monitoring.*9090" 2>/dev/null || true
	@sleep 2
	@# Start port-forwards in background
	@echo "Starting Dynamic DB UI port-forward (http://localhost:8090)..."
	@kubectl port-forward -n db-demo svc/vso-db-demo-ui 8090:8080 > /dev/null 2>&1 &
	@sleep 1
	@echo "Starting PKI Demo port-forward (https://localhost:8443 or http://localhost:9090)..."
	@kubectl port-forward -n pki-demo svc/pki-demo-app 8443:443 9090:80 > /dev/null 2>&1 &
	@sleep 1
	@echo "Starting PostgreSQL port-forward (localhost:5432)..."
	@kubectl port-forward -n postgres svc/postgres-postgresql 5432:5432 > /dev/null 2>&1 &
	@sleep 1
	@# Check if GitLab is deployed and start port-forward if it exists
	@if kubectl get namespace gitlab-demo > /dev/null 2>&1; then \
		echo "Starting GitLab UI port-forward (http://localhost:8080)..."; \
		(kubectl port-forward -n gitlab-demo svc/gitlab 8080:80 > /dev/null 2>&1) & \
		sleep 1; \
	fi
	@# Check if audit-monitoring is deployed and start port-forwards if it exists
	@if kubectl get namespace audit-monitoring > /dev/null 2>&1; then \
		echo "Starting Grafana port-forward (http://localhost:3000)..."; \
		(kubectl port-forward -n audit-monitoring svc/grafana 3000:3000 > /dev/null 2>&1) & \
		sleep 1; \
		echo "Starting Prometheus port-forward (http://localhost:9091)..."; \
		(kubectl port-forward -n audit-monitoring svc/prometheus 9091:9090 > /dev/null 2>&1) & \
		sleep 1; \
	fi
	@echo ""
	@echo "=== All Port-Forwards Active ==="
	@echo ""
	@echo "📊 Dynamic DB UI:    http://localhost:8090"
	@echo "🔐 PKI Demo (HTTPS): https://localhost:8443"
	@echo "🔐 PKI Demo (HTTP):  http://localhost:9090"
	@echo "🐘 PostgreSQL:       localhost:5432"
	@if kubectl get namespace gitlab-demo > /dev/null 2>&1; then \
		echo "🦊 GitLab CE:        http://localhost:8080"; \
		echo "   Username:         root"; \
		echo "   Password:         VaultDemoStr0ng!2026"; \
	fi
	@if kubectl get namespace audit-monitoring > /dev/null 2>&1; then \
		echo "📈 Grafana:          http://localhost:3000"; \
		echo "   Username:         admin"; \
		echo "   Password:         admin"; \
		echo "📊 Prometheus:       http://localhost:9091"; \
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
	@echo "URL: http://localhost:8080"
	@echo "Username: root"
	@echo "Password: VaultDemoStr0ng!2026"
	@echo ""
	@echo "Port-forwarding GitLab UI..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n gitlab-demo svc/gitlab 8080:80

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
clean-gitlab: clean-all-local

.PHONY: clean-gitlab-vault
clean-gitlab-vault: clean-all-local

.PHONY: clean-gitlab-all
clean-gitlab-all: clean-all-local

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
	@./scripts/setup/setup-audit-monitoring.sh
.PHONY: enable-audit-log-rotation
enable-audit-log-rotation:
	$(call header,$@)
	@chmod +x scripts/setup/enable-audit-log-rotation.sh
	@./scripts/setup/enable-audit-log-rotation.sh


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
	@kubectl port-forward -n audit-monitoring svc/grafana 3000:3000

.PHONY: prometheus-port-forward
prometheus-port-forward:
	$(call header,$@)
	@echo "=== Prometheus Access Information ==="
	@echo ""
	@echo "URL: http://localhost:9090"
	@echo ""
	@echo "Port-forwarding Prometheus..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	@kubectl port-forward -n audit-monitoring svc/prometheus 9090:9090

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
