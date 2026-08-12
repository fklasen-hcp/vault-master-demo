#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Setting up complete GitLab + Vault demo ===${NC}"

if ! minikube status | grep -q "host: Running"; then
    echo -e "${RED}ERROR: Minikube is not running${NC}"
    echo "Please start minikube first: minikube start"
    exit 1
fi

if [ -z "$VAULT_ADDR" ]; then
    echo -e "${YELLOW}VAULT_ADDR not set. Using default: https://127.0.0.1:8200${NC}"
    export VAULT_ADDR=https://127.0.0.1:8200
fi

if [ -z "$VAULT_TOKEN" ]; then
    echo -e "${RED}ERROR: VAULT_TOKEN is not set${NC}"
    echo "Example: export VAULT_TOKEN=your-token-here"
    exit 1
fi

echo -e "${GREEN}Using Vault at: $VAULT_ADDR${NC}"

if ! vault status > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to Vault at $VAULT_ADDR${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Vault is accessible and unsealed${NC}"

# Use master-demo namespace
export VAULT_NAMESPACE=master-demo

echo -e "\n${GREEN}Checking prerequisite Vault resources...${NC}"
if ! vault secrets list | grep -q "master-demo-kv"; then
    echo -e "${RED}ERROR: KV engine 'master-demo-kv' not found. Run local Vault setup first.${NC}"
    exit 1
fi

if ! vault auth list | grep -q "master-demo-auth"; then
    echo -e "${RED}ERROR: Kubernetes auth 'master-demo-auth' not found. Run local Vault setup first.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Base Vault configuration exists${NC}"

echo -e "\n${GREEN}Creating/updating GitLab Vault policy...${NC}"
vault policy write master-demo-gitlab-policy - <<EOF
path "master-demo-kv/data/webapp/config" {
   capabilities = ["read", "list", "subscribe"]
   subscribe_event_types = ["kv*"]
}

path "sys/events/subscribe/kv*" {
   capabilities = ["read"]
}
EOF

echo -e "${GREEN}Creating/updating GitLab Kubernetes auth role...${NC}"
vault write auth/master-demo-auth/role/master-demo-gitlab-role \
   bound_service_account_names=gitlab-runner \
   bound_service_account_namespaces=gitlab-demo \
   policies=master-demo-gitlab-policy \
   audience=vault \
   token_period=2m

echo -e "\n${GREEN}Ensuring demo secret exists in Vault...${NC}"
if vault kv get master-demo-kv/webapp/config > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Secret 'master-demo-kv/webapp/config' already exists${NC}"
else
    vault kv put master-demo-kv/webapp/config username="static-user" password="static-password"
    echo -e "${GREEN}✓ Default demo secret created${NC}"
fi

echo -e "\n${GREEN}Creating gitlab-demo namespace...${NC}"
kubectl create namespace gitlab-demo 2>/dev/null || echo "Namespace already exists"

echo -e "\n${GREEN}Deploying lightweight GitLab manifest...${NC}"
kubectl apply -f static-secrets-gitlab-ci/manifests/gitlab-simple.yaml

echo -e "\n${GREEN}Waiting for GitLab pod to be created...${NC}"
for i in $(seq 1 90); do
    if kubectl get pods -n gitlab-demo -l app=gitlab --no-headers 2>/dev/null | grep -q .; then
        break
    fi
    sleep 2
done

if ! kubectl get pods -n gitlab-demo -l app=gitlab --no-headers 2>/dev/null | grep -q .; then
    echo -e "${RED}ERROR: GitLab pod was not created${NC}"
    kubectl get all -n gitlab-demo || true
    exit 1
fi

GITLAB_POD=$(kubectl get pods -n gitlab-demo -l app=gitlab --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
kubectl wait --for=condition=ready pod/$GITLAB_POD -n gitlab-demo --timeout=15m

echo -e "\n${GREEN}Deploying GitLab VSO resources...${NC}"
kubectl apply -f static-secrets-gitlab-ci/
sleep 10
kubectl get secret secretkv -n gitlab-demo 2>/dev/null || echo "Secret not yet synced"

echo -e "\n${GREEN}Waiting for GitLab internal services to finish initialization...${NC}"
SERVICES_READY=false
for i in $(seq 1 90); do
    GITLAB_POD=$(kubectl get pods -n gitlab-demo -l app=gitlab --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)

    if [ -z "$GITLAB_POD" ]; then
        sleep 10
        continue
    fi

    set +e
    STATUS_OUTPUT=$(kubectl exec -n gitlab-demo $GITLAB_POD -- /bin/bash -lc 'gitlab-ctl status || true' 2>&1)
    STATUS_RC=$?
    set -e

    if echo "$STATUS_OUTPUT" | grep -q "run: .*postgresql" && echo "$STATUS_OUTPUT" | grep -q "run: .*puma" && echo "$STATUS_OUTPUT" | grep -q "run: .*sidekiq"; then
        SERVICES_READY=true
        break
    fi

    sleep 10
done

if [ "$SERVICES_READY" != "true" ]; then
    echo -e "${RED}ERROR: GitLab services did not finish initializing${NC}"
    echo "$STATUS_OUTPUT"
    exit 1
fi

# Allow GitLab services to fully stabilise before running memory-intensive rails commands
echo -e "\n${YELLOW}Waiting 60 seconds for GitLab to fully stabilise...${NC}"
sleep 60

echo -e "\n${GREEN}Creating GitLab admin API token...${NC}"
set +e
TOKEN_OUTPUT=$(kubectl exec -n gitlab-demo $GITLAB_POD -- gitlab-rails runner "
begin
  require 'securerandom'

  user = User.find_by(id: 1) || User.find_by(username: 'root') || User.find_by(email: 'admin@example.com')
  raise 'root user not available yet' if user.nil?

  token_name = 'automation-token'
  user.personal_access_tokens.where(name: token_name).destroy_all

  raw_token = SecureRandom.hex(20)
  pat = user.personal_access_tokens.create!(
    name: token_name,
    scopes: [:api, :read_repository, :write_repository],
    expires_at: 30.days.from_now
  )

  pat.set_token(raw_token) if pat.respond_to?(:set_token)
  pat.save!

  puts raw_token
rescue => e
  warn 'PAT_ERROR: ' + e.class.to_s + ': ' + e.message
  e.backtrace.first(20).each { |line| warn line }
  exit 1
end
" 2>&1)
TOKEN_RC=$?
set -e

TOKEN=$(echo "$TOKEN_OUTPUT" | grep -v "^$" | tail -1)

if [ $TOKEN_RC -ne 0 ] || [ -z "$TOKEN" ] || [[ "$TOKEN" == PAT_ERROR:* ]] || [[ "$TOKEN" == ERROR* ]]; then
    echo -e "${RED}ERROR: Failed to create admin access token${NC}"
    echo "$TOKEN_OUTPUT"
    exit 1
fi

echo -e "${GREEN}✓ Admin token created${NC}"

echo -e "\n${GREEN}Ensuring GitLab is reachable on localhost:8080...${NC}"
PF_PID=""
cleanup() {
    if [ -n "$PF_PID" ] && kill -0 "$PF_PID" >/dev/null 2>&1; then
        kill "$PF_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if ! curl -s http://localhost:8080/users/sign_in > /dev/null 2>&1; then
    kubectl port-forward -n gitlab-demo svc/gitlab 8080:80 > /tmp/gitlab-port-forward.log 2>&1 &
    PF_PID=$!

    for i in $(seq 1 60); do
        if curl -s http://localhost:8080/users/sign_in > /dev/null 2>&1; then
            break
        fi
        sleep 2
    done
fi

if ! curl -s http://localhost:8080/users/sign_in > /dev/null 2>&1; then
    echo -e "${RED}ERROR: GitLab API endpoint on localhost:8080 is unreachable${NC}"
    cat /tmp/gitlab-port-forward.log 2>/dev/null || true
    exit 1
fi

echo -e "\n${GREEN}Waiting for GitLab API to be fully ready...${NC}"
for i in $(seq 1 30); do
    if curl -s "http://localhost:8080/api/v4/version" -H "PRIVATE-TOKEN: $TOKEN" | grep -q "version"; then
        echo -e "${GREEN}✓ GitLab API is responding${NC}"
        break
    fi
    sleep 2
done

echo -e "\n${GREEN}Ensuring GitLab group 'demo' exists...${NC}"
GROUP_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" "http://localhost:8080/api/v4/groups/demo" \
  -H "PRIVATE-TOKEN: $TOKEN")
GROUP_BODY=$(echo "$GROUP_RESPONSE" | sed '/^HTTP_STATUS:/d')
GROUP_STATUS=$(echo "$GROUP_RESPONSE" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)
GROUP_ID=$(echo "$GROUP_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

if [ "$GROUP_STATUS" = "404" ] || [ -z "$GROUP_ID" ]; then
    CREATE_GROUP_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "http://localhost:8080/api/v4/groups" \
      -H "PRIVATE-TOKEN: $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "Demo",
        "path": "demo",
        "visibility": "public"
      }')
    GROUP_BODY=$(echo "$CREATE_GROUP_RESPONSE" | sed '/^HTTP_STATUS:/d')
    GROUP_STATUS=$(echo "$CREATE_GROUP_RESPONSE" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)
    GROUP_ID=$(echo "$GROUP_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

    if [ "$GROUP_STATUS" != "201" ] || [ -z "$GROUP_ID" ]; then
        echo -e "${RED}ERROR: Failed to create group 'demo'${NC}"
        echo "$GROUP_BODY"
        exit 1
    fi
fi

echo -e "${GREEN}✓ Group ready with ID: $GROUP_ID${NC}"

echo -e "\n${GREEN}Recreating project demo/vault-demo...${NC}"
EXISTING_PROJECT=$(curl --fail -s "http://localhost:8080/api/v4/projects/demo%2Fvault-demo" \
  -H "PRIVATE-TOKEN: $TOKEN" || true)
PROJECT_ID=$(echo "$EXISTING_PROJECT" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

if [ -n "$PROJECT_ID" ]; then
    curl --fail -s -X DELETE "http://localhost:8080/api/v4/projects/$PROJECT_ID" \
      -H "PRIVATE-TOKEN: $TOKEN" > /dev/null
    sleep 5
fi

PROJECT_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "http://localhost:8080/api/v4/projects" \
  -H "PRIVATE-TOKEN: $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"vault-demo\",
    \"path\": \"vault-demo\",
    \"namespace_id\": $GROUP_ID,
    \"description\": \"Vault Secrets Integration Demo\",
    \"visibility\": \"public\",
    \"initialize_with_readme\": false,
    \"default_branch\": \"main\"
  }")

PROJECT_BODY=$(echo "$PROJECT_RESPONSE" | sed '/^HTTP_STATUS:/d')
PROJECT_STATUS=$(echo "$PROJECT_RESPONSE" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)
PROJECT_ID=$(echo "$PROJECT_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

if [ "$PROJECT_STATUS" != "201" ] || [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}ERROR: Failed to create project${NC}"
    echo "$PROJECT_BODY"
    exit 1
fi

echo -e "${GREEN}✓ Project created with ID: $PROJECT_ID${NC}"

CI_CONTENT=$(base64 < static-secrets-gitlab-ci/sample-project/.gitlab-ci.yml | tr -d '\n')
README_CONTENT=$(base64 < static-secrets-gitlab-ci/sample-project/README.md | tr -d '\n')

echo -e "\n${GREEN}Creating initial commit...${NC}"
COMMIT_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "http://localhost:8080/api/v4/projects/$PROJECT_ID/repository/commits" \
  -H "PRIVATE-TOKEN: $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"branch\": \"main\",
    \"commit_message\": \"Initial Vault demo project\",
    \"actions\": [
      {
        \"action\": \"create\",
        \"file_path\": \".gitlab-ci.yml\",
        \"content\": \"$CI_CONTENT\",
        \"encoding\": \"base64\"
      },
      {
        \"action\": \"create\",
        \"file_path\": \"README.md\",
        \"content\": \"$README_CONTENT\",
        \"encoding\": \"base64\"
      }
    ]
  }")

COMMIT_BODY=$(echo "$COMMIT_RESPONSE" | sed '/^HTTP_STATUS:/d')
COMMIT_STATUS=$(echo "$COMMIT_RESPONSE" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)

if [ "$COMMIT_STATUS" != "201" ]; then
    echo -e "${RED}ERROR: Failed to create initial commit${NC}"
    echo "$COMMIT_BODY"
    exit 1
fi

echo -e "${GREEN}✓ Initial commit created${NC}"

echo -e "\n${GREEN}Creating runner authentication token...${NC}"
RUNNER_TOKEN=$(kubectl exec -n gitlab-demo $GITLAB_POD -- gitlab-rails runner "
token = Ci::Runner.create!(
  runner_type: 'instance_type',
  description: 'Kubernetes Runner',
  tag_list: ['kubernetes'],
  run_untagged: true,
  locked: false
).token
puts token
" 2>/dev/null | tail -1)

if [ -z "$RUNNER_TOKEN" ]; then
    REGISTRATION_TOKEN=$(kubectl exec -n gitlab-demo $GITLAB_POD -- gitlab-rails runner "puts Gitlab::CurrentSettings.current_application_settings.runners_registration_token" 2>/dev/null | tail -1)

    if [ -z "$REGISTRATION_TOKEN" ]; then
        echo -e "${RED}ERROR: Failed to get runner token${NC}"
        exit 1
    fi

    TOKEN_TYPE="registration-token"
    RUNNER_AUTH_TOKEN="$REGISTRATION_TOKEN"
else
    TOKEN_TYPE="token"
    RUNNER_AUTH_TOKEN="$RUNNER_TOKEN"
fi

RUNNER_POD=$(kubectl get pods -n gitlab-demo -l app=gitlab-runner -o name | head -1 | cut -d'/' -f2)

if [ -z "$RUNNER_POD" ]; then
    echo -e "${RED}ERROR: GitLab runner pod not found${NC}"
    exit 1
fi

echo -e "\n${GREEN}Registering GitLab runner...${NC}"
kubectl exec -n gitlab-demo $RUNNER_POD -- sh -c 'mkdir -p /etc/gitlab-runner && rm -f /etc/gitlab-runner/config.toml && touch /etc/gitlab-runner/config.toml'

kubectl exec -n gitlab-demo $RUNNER_POD -- gitlab-runner register \
  --non-interactive \
  --config /etc/gitlab-runner/config.toml \
  --url "http://gitlab.gitlab-demo.svc.cluster.local" \
  --${TOKEN_TYPE} "${RUNNER_AUTH_TOKEN}" \
  --executor "kubernetes" \
  --kubernetes-namespace "gitlab-demo" \
  --kubernetes-image "alpine:latest" \
  --kubernetes-helper-image "gitlab/gitlab-runner-helper:arm64-v16.11.1" \
  --kubernetes-service-account "gitlab-runner" \
  --tag-list "kubernetes" \
  --run-untagged="true" \
  --locked="false"

kubectl exec -n gitlab-demo $RUNNER_POD -- sh -c 'cat >> /etc/gitlab-runner/config.toml << EOF

[[runners.kubernetes.volumes.secret]]
  name = "secretkv"
  mount_path = "/vault/secrets"
  read_only = true
EOF'

echo -e "\n${GREEN}Triggering initial pipeline...${NC}"
PIPELINE_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "http://localhost:8080/api/v4/projects/$PROJECT_ID/pipeline?ref=main" \
  -H "PRIVATE-TOKEN: $TOKEN")
PIPELINE_BODY=$(echo "$PIPELINE_RESPONSE" | sed '/^HTTP_STATUS:/d')
PIPELINE_STATUS=$(echo "$PIPELINE_RESPONSE" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1)
PIPELINE_ID=$(echo "$PIPELINE_BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

echo ""
echo -e "${GREEN}=== GitLab + Vault demo setup complete ===${NC}"
echo "Project URL: http://localhost:8080/demo/vault-demo"
echo "Pipeline URL: http://localhost:8080/demo/vault-demo/-/pipelines"
echo "Username: root"
echo "Password: VaultDemoStr0ng!2026"
if [ "$PIPELINE_STATUS" = "201" ] && [ -n "$PIPELINE_ID" ]; then
    echo "Initial pipeline created with ID: $PIPELINE_ID"
else
    echo "Initial pipeline was not created automatically; run it manually from the UI"
fi
echo "Re-run the pipeline after updating Vault secret master-demo-kv/webapp/config to show fresh values."

# Made with Bob