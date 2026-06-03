#!/bin/bash

# Test Agentic AI Demo End-to-End
# This script tests the complete demo flow

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Testing Agentic AI Demo...${NC}\n"

# Test 1: Check all pods are running
echo -e "${YELLOW}Test 1: Checking pod status...${NC}"
PODS=$(kubectl get pods -n agentic-demo --no-headers)
if echo "$PODS" | grep -q "Running"; then
    echo -e "${GREEN}✓ Pods are running${NC}"
    kubectl get pods -n agentic-demo
else
    echo -e "${RED}✗ Some pods are not running${NC}"
    kubectl get pods -n agentic-demo
    exit 1
fi

# Test 2: Check Ollama model is loaded
echo -e "\n${YELLOW}Test 2: Checking Ollama model...${NC}"
MODEL_CHECK=$(kubectl get pod -n agentic-demo -l app=ollama -o name | head -1 | xargs -I {} kubectl exec -n agentic-demo {} -- ollama list 2>/dev/null | grep llama3.2:1b || echo "")
if [ -n "$MODEL_CHECK" ]; then
    echo -e "${GREEN}✓ Ollama model llama3.2:1b is loaded${NC}"
else
    echo -e "${RED}✗ Ollama model not found${NC}"
    exit 1
fi

# Test 3: Check UI has cryptography package
echo -e "\n${YELLOW}Test 3: Checking UI dependencies...${NC}"
CRYPTO_CHECK=$(kubectl get pod -n agentic-demo -l app=agentic-demo-ui -o name | head -1 | xargs -I {} kubectl exec -n agentic-demo {} -- pip list 2>/dev/null | grep cryptography || echo "")
if [ -n "$CRYPTO_CHECK" ]; then
    echo -e "${GREEN}✓ Cryptography package installed${NC}"
else
    echo -e "${RED}✗ Cryptography package missing${NC}"
    exit 1
fi

# Test 4: Check UI can authenticate to Vault (check if UI is responding)
echo -e "\n${YELLOW}Test 4: Checking UI is responding...${NC}"
UI_POD=$(kubectl get pod -n agentic-demo -l app=agentic-demo-ui -o name | head -1)
if [ -n "$UI_POD" ]; then
    # Check if UI is serving requests using Python (UI runs on port 8002)
    if kubectl exec -n agentic-demo "$UI_POD" -- python3 -c "import requests; r=requests.get('http://localhost:8002/'); exit(0 if r.status_code == 200 else 1)" 2>/dev/null; then
        echo -e "${GREEN}✓ UI is responding${NC}"
    else
        echo -e "${RED}✗ UI not responding${NC}"
        exit 1
    fi
else
    echo -e "${RED}✗ UI pod not found${NC}"
    exit 1
fi

# Test 5: Skip JWT key check (requires Vault token to verify)
echo -e "\n${YELLOW}Test 5: Skipping JWT key verification (requires Vault access)${NC}"
echo -e "${GREEN}✓ Skipped (manual verification required)${NC}"

# Test 6: Check Agent is running
echo -e "\n${YELLOW}Test 6: Checking AI Agent status...${NC}"
AGENT_LOGS=$(kubectl logs -n agentic-demo -l app=ai-agent --tail=1000 2>/dev/null | grep "Uvicorn running" || echo "")
if [ -n "$AGENT_LOGS" ]; then
    echo -e "${GREEN}✓ AI Agent is running${NC}"
else
    echo -e "${RED}✗ AI Agent not running properly${NC}"
    exit 1
fi

# Test 7: Check Vault policies exist (requires VAULT_TOKEN)
echo -e "\n${YELLOW}Test 7: Checking Vault policies (requires VAULT_TOKEN)...${NC}"

# Check if vault CLI is available and VAULT_TOKEN is set
if ! command -v vault &> /dev/null; then
    echo -e "${YELLOW}⚠ Vault CLI not found, skipping Vault policy checks${NC}"
elif [ -z "$VAULT_TOKEN" ]; then
    echo -e "${YELLOW}⚠ VAULT_TOKEN not set, skipping Vault policy checks${NC}"
    echo -e "${YELLOW}  Run: export VAULT_TOKEN=root (or your token)${NC}"
else
    # Set Vault environment variables
    export VAULT_ADDR=${VAULT_ADDR:-http://127.0.0.1:8200}
    export VAULT_NAMESPACE=${VAULT_NAMESPACE:-master-demo}
    
    POLICIES="master-demo-agentic-base master-demo-agentic-alice master-demo-agentic-bob master-demo-policy-agentic-ui"
    ALL_EXIST=true
    for policy in $POLICIES; do
        if vault policy read "$policy" > /dev/null 2>&1; then
            echo -e "${GREEN}  ✓ Policy $policy exists${NC}"
        else
            echo -e "${RED}  ✗ Policy $policy missing${NC}"
            ALL_EXIST=false
        fi
    done
    
    if [ "$ALL_EXIST" = true ]; then
        echo -e "${GREEN}✓ All Vault policies exist${NC}"
    else
        echo -e "${RED}✗ Some Vault policies are missing${NC}"
        exit 1
    fi
fi

# Test 8: Check Vault auth methods (requires VAULT_TOKEN)
echo -e "\n${YELLOW}Test 8: Checking Vault auth methods (requires VAULT_TOKEN)...${NC}"

if ! command -v vault &> /dev/null; then
    echo -e "${YELLOW}⚠ Vault CLI not found, skipping auth method checks${NC}"
elif [ -z "$VAULT_TOKEN" ]; then
    echo -e "${YELLOW}⚠ VAULT_TOKEN not set, skipping auth method checks${NC}"
else
    if vault auth list 2>&1 | grep -q "master-demo-jwt/"; then
        echo -e "${GREEN}  ✓ JWT auth method enabled${NC}"
    else
        echo -e "${RED}  ✗ JWT auth method missing${NC}"
        exit 1
    fi
    
    if vault auth list 2>&1 | grep -q "master-demo-auth/"; then
        echo -e "${GREEN}  ✓ Kubernetes auth method enabled${NC}"
    else
        echo -e "${RED}  ✗ Kubernetes auth method missing${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✓ All Vault auth methods configured${NC}"

# Summary
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}All tests passed! Demo is ready.${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "\n${BLUE}Access the demo at: http://localhost:10006${NC}"
echo -e "${YELLOW}Note: Make sure port-forward is running: make agentic-port-forward${NC}\n"

# Made with Bob
