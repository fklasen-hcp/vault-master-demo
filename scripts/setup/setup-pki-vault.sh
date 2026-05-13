#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Setting up Vault PKI for Certificate Auto-Renewal ===${NC}"

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
    exit 1
fi

echo -e "${GREEN}✓ Vault is accessible and unsealed${NC}"

# Use master-demo namespace
echo -e "\n${GREEN}Using master-demo namespace${NC}"
export VAULT_NAMESPACE=master-demo

# Enable PKI root engine
echo -e "\n${GREEN}Enabling PKI root engine...${NC}"
if vault secrets enable -path=master-demo-pki-root pki 2>/dev/null; then
    echo "✓ PKI root engine enabled"
else
    echo "PKI root engine already enabled or failed"
    if vault secrets list | grep -q "master-demo-pki-root"; then
        echo "✓ PKI root engine exists"
    else
        echo -e "${RED}ERROR: Failed to enable PKI root engine${NC}"
        exit 1
    fi
fi

# Tune PKI root engine for 10 years
echo -e "\n${GREEN}Configuring PKI root engine TTL...${NC}"
vault secrets tune -max-lease-ttl=87600h master-demo-pki-root

# Generate root CA certificate
echo -e "\n${GREEN}Generating root CA certificate...${NC}"
if vault read master-demo-pki-root/issuer/root-2024 > /dev/null 2>&1; then
    echo "✓ Root CA certificate already exists"
else
    vault write -field=certificate master-demo-pki-root/root/generate/internal \
        common_name="Demo Root CA" \
        issuer_name="root-2024" \
        ttl=87600h > /dev/null
    echo "✓ Root CA certificate generated"
fi

# Enable PKI issuing engine
echo -e "\n${GREEN}Enabling PKI issuing engine...${NC}"
if vault secrets enable -path=master-demo-pki-issuing pki 2>/dev/null; then
    echo "✓ PKI issuing engine enabled"
else
    echo "PKI issuing engine already enabled or failed"
    if vault secrets list | grep -q "master-demo-pki-issuing"; then
        echo "✓ PKI issuing engine exists"
    else
        echo -e "${RED}ERROR: Failed to enable PKI issuing engine${NC}"
        exit 1
    fi
fi

# Tune PKI issuing engine for 1 year max, but allow very short TTLs for demo
echo -e "\n${GREEN}Configuring PKI issuing engine TTL...${NC}"
vault secrets tune -max-lease-ttl=8760h -default-lease-ttl=30s master-demo-pki-issuing

# Generate intermediate CA CSR
echo -e "\n${GREEN}Generating intermediate CA CSR...${NC}"
CSR=$(vault write -field=csr master-demo-pki-issuing/intermediate/generate/internal \
    common_name="Demo Issuing CA" \
    issuer_name="issuing-2024")

# Sign intermediate CA with root CA
echo -e "\n${GREEN}Signing intermediate CA with root CA...${NC}"
SIGNED_CERT=$(vault write -field=certificate master-demo-pki-root/root/sign-intermediate \
    issuer_ref="root-2024" \
    csr="$CSR" \
    format=pem_bundle \
    ttl=43800h)

# Import signed certificate
echo -e "\n${GREEN}Importing signed intermediate certificate...${NC}"
vault write master-demo-pki-issuing/intermediate/set-signed \
    certificate="$SIGNED_CERT" > /dev/null

echo "✓ Intermediate CA configured"

# Create PKI role for certificate issuance
echo -e "\n${GREEN}Creating PKI role for certificate issuance...${NC}"
vault write master-demo-pki-issuing/roles/master-demo-cert-issuer \
    allowed_domains="local,minikube.internal" \
    allow_subdomains=true \
    allow_bare_domains=true \
    allow_localhost=true \
    max_ttl="24h" \
    ttl="30s" \
    key_type="rsa" \
    key_bits=2048

echo "✓ PKI role 'master-demo-cert-issuer' created"

# Create policy for PKI certificate issuance
echo -e "\n${GREEN}Creating policy for PKI certificate issuance...${NC}"
vault policy write master-demo-pki-issuer - <<EOF
path "master-demo-pki-issuing/issue/master-demo-cert-issuer" {
   capabilities = ["create", "update"]
}
path "master-demo-pki-issuing/sign/master-demo-cert-issuer" {
   capabilities = ["create", "update"]
}
path "master-demo-pki-issuing/revoke" {
   capabilities = ["create", "update"]
}
EOF

echo "✓ Policy 'master-demo-pki-issuer' created"

# Create Kubernetes role for PKI
echo -e "\n${GREEN}Creating Kubernetes role for PKI certificate issuance...${NC}"
vault write auth/master-demo-auth/role/master-demo-pki-cert-issuer \
   bound_service_account_names=pki-demo-app \
   bound_service_account_namespaces=pki-demo \
   policies=master-demo-pki-issuer \
   audience=vault \
   token_period=2m

echo "✓ Kubernetes role 'master-demo-pki-cert-issuer' created"

# Test certificate issuance
echo -e "\n${GREEN}Testing certificate issuance...${NC}"
if vault write master-demo-pki-issuing/issue/master-demo-cert-issuer \
    common_name="test.local" \
    ttl="30s" > /dev/null 2>&1; then
    echo "✓ Test certificate issued successfully"
else
    echo -e "${YELLOW}Warning: Test certificate issuance failed, but setup may still work${NC}"
fi

echo -e "\n${GREEN}=== Vault PKI Configuration Complete ===${NC}"
echo -e "${GREEN}✓ PKI root engine enabled (master-demo-pki-root)${NC}"
echo -e "${GREEN}✓ PKI issuing engine enabled (master-demo-pki-issuing)${NC}"
echo -e "${GREEN}✓ Root CA generated (10-year validity)${NC}"
echo -e "${GREEN}✓ Intermediate CA generated and signed${NC}"
echo -e "${GREEN}✓ PKI role 'master-demo-cert-issuer' created${NC}"
echo -e "${GREEN}✓ Policy 'master-demo-pki-issuer' created${NC}"
echo -e "${GREEN}✓ Kubernetes role 'master-demo-pki-cert-issuer' created${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Deploy PKI secrets: make deploy-pki-secrets"
echo "  2. Watch certificates: make watch-pki-certs"
echo "  3. Access demo: make pki-port-forward"

# Made with Bob