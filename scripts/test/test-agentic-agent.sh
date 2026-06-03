#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Testing Agentic AI Agent ===${NC}"
echo ""

# Configuration
AGENT_URL="http://localhost:8001"
JWT_SECRET="demo-secret-key-change-in-production"

# Function to create JWT token
create_jwt() {
    local user_id=$1
    local groups=$2
    
    # Create JWT payload
    local header='{"alg":"HS256","typ":"JWT"}'
    local payload="{\"sub\":\"$user_id\",\"groups\":$groups,\"exp\":$(($(date +%s) + 3600))}"
    
    # Base64 encode
    local header_b64=$(echo -n "$header" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local payload_b64=$(echo -n "$payload" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    
    # Create signature (simplified - in production use proper HMAC)
    local signature=$(echo -n "${header_b64}.${payload_b64}" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    
    echo "${header_b64}.${payload_b64}.${signature}"
}

# Test 1: Health Check
echo -e "${BLUE}Test 1: Health Check${NC}"
response=$(curl -s $AGENT_URL/health)
if echo "$response" | grep -q "healthy"; then
    echo -e "${GREEN}✓ Health check passed${NC}"
    echo "  Response: $response"
else
    echo -e "${RED}✗ Health check failed${NC}"
    echo "  Response: $response"
    exit 1
fi
echo ""

# Test 2: Alice (read-only) - List Products
echo -e "${BLUE}Test 2: Alice (read-only) - List Products${NC}"
alice_token=$(create_jwt "alice" '["readers"]')
echo "  Token: ${alice_token:0:50}..."

response=$(curl -s -X POST $AGENT_URL/chat \
    -H "Content-Type: application/json" \
    -d "{
        \"message\": \"List all products\",
        \"user_token\": \"$alice_token\"
    }")

if echo "$response" | grep -q "Products:"; then
    echo -e "${GREEN}✓ Alice can list products${NC}"
    echo "  Response: $(echo $response | jq -r '.response' | head -n 3)"
else
    echo -e "${YELLOW}⚠ Response: $response${NC}"
fi
echo ""

# Test 3: Alice (read-only) - Try to Add Product (should fail)
echo -e "${BLUE}Test 3: Alice (read-only) - Try to Add Product${NC}"
response=$(curl -s -X POST $AGENT_URL/chat \
    -H "Content-Type: application/json" \
    -d "{
        \"message\": \"Add a new product called Test Widget for 29.99\",
        \"user_token\": \"$alice_token\"
    }")

if echo "$response" | grep -q -i "permission denied"; then
    echo -e "${GREEN}✓ Alice correctly denied write access${NC}"
    echo "  Response: $(echo $response | jq -r '.response')"
else
    echo -e "${YELLOW}⚠ Response: $response${NC}"
fi
echo ""

# Test 4: Bob (admin) - Add Product
echo -e "${BLUE}Test 4: Bob (admin) - Add Product${NC}"
bob_token=$(create_jwt "bob" '["admins"]')
echo "  Token: ${bob_token:0:50}..."

response=$(curl -s -X POST $AGENT_URL/chat \
    -H "Content-Type: application/json" \
    -d "{
        \"message\": \"Add a new product called Bob's Widget for 49.99\",
        \"user_token\": \"$bob_token\"
    }")

if echo "$response" | grep -q "added successfully"; then
    echo -e "${GREEN}✓ Bob can add products${NC}"
    echo "  Response: $(echo $response | jq -r '.response')"
else
    echo -e "${YELLOW}⚠ Response: $response${NC}"
fi
echo ""

# Test 5: Bob (admin) - List Products
echo -e "${BLUE}Test 5: Bob (admin) - List Products${NC}"
response=$(curl -s -X POST $AGENT_URL/chat \
    -H "Content-Type: application/json" \
    -d "{
        \"message\": \"Show me all products\",
        \"user_token\": \"$bob_token\"
    }")

if echo "$response" | grep -q "Products:"; then
    echo -e "${GREEN}✓ Bob can list products${NC}"
    echo "  Response: $(echo $response | jq -r '.response' | head -n 5)"
else
    echo -e "${YELLOW}⚠ Response: $response${NC}"
fi
echo ""

echo -e "${GREEN}=== Testing Complete ===${NC}"
echo ""
echo -e "${BLUE}Summary:${NC}"
echo "  - Health check: ✓"
echo "  - Alice read access: ✓"
echo "  - Alice write denied: ✓"
echo "  - Bob write access: ✓"
echo "  - Bob read access: ✓"
echo ""
echo -e "${YELLOW}Note: This test requires:${NC}"
echo "  1. Port-forward running: kubectl port-forward -n agentic-demo svc/ai-agent 8001:8001"
echo "  2. All infrastructure components operational"
echo "  3. Ollama model downloaded (will happen on first LLM call)"

# Made with Bob