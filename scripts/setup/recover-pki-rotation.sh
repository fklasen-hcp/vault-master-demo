#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Recovering after laptop sleep ===${NC}"

# Verify minikube mount for audit monitoring
# With the Podman driver, the mount is established at minikube start time via --mount flag.
# No background process is needed — just verify it is present.
echo -e "\n${GREEN}Checking /host-home mount for audit monitoring...${NC}"
if minikube ssh "test -d /host-home" 2>/dev/null; then
    echo -e "${GREEN}✓ Home directory available at /host-home in minikube${NC}"
else
    echo -e "${YELLOW}WARNING: /host-home is not mounted in minikube.${NC}"
    echo -e "${YELLOW}The mount is configured at minikube start time (--mount flag).${NC}"
    echo -e "${YELLOW}If audit monitoring is not working, run: minikube delete && make start-minikube${NC}"
fi

# Restart audit exporter to pick up the mount
echo -e "\n${GREEN}Restarting audit exporter...${NC}"
kubectl delete pod -n audit-monitoring -l app=vault-audit-exporter
sleep 5

echo -e "\n${GREEN}Restarting vault-secrets-operator-controller-manager...${NC}"
kubectl rollout restart deployment/vault-secrets-operator-controller-manager -n vault-secrets-operator-system

echo -e "\n${GREEN}Waiting for rollout to complete...${NC}"
kubectl rollout status deployment/vault-secrets-operator-controller-manager -n vault-secrets-operator-system --timeout=5m

echo -e "\n${GREEN}Waiting briefly for PKI reconciliation...${NC}"
sleep 15

echo -e "\n${GREEN}Current PKI secret certificate:${NC}"
kubectl get secret -n pki-demo pki-demo-tls -o jsonpath='{.data.certificate}' | base64 -d | openssl x509 -noout -serial -dates

echo -e "\n${GREEN}Current VaultPKISecret status:${NC}"
kubectl describe vaultpkisecret -n pki-demo pki-demo-cert | sed -n '/Status:/,/Events:/p'

echo -e "\n${GREEN}Recovery command completed.${NC}"
echo -e "${YELLOW}If the certificate still looks stale, wait ~30 seconds and run this script again.${NC}"

# Made with Bob