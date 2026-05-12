#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Recovering after laptop sleep ===${NC}"

# Fix minikube mount for audit monitoring
echo -e "\n${GREEN}Checking minikube mount for audit monitoring...${NC}"
MOUNT_PID=$(pgrep -f "minikube mount.*home.*host-home" || true)
if [ -n "$MOUNT_PID" ]; then
    echo -e "${YELLOW}Killing stale mount process (PID: $MOUNT_PID)...${NC}"
    kill $MOUNT_PID 2>/dev/null || true
    sleep 2
fi

echo -e "${GREEN}Restarting minikube mount...${NC}"
nohup minikube mount $HOME:/host-home --gid=1000 --uid=1000 > /tmp/minikube-mount.log 2>&1 &
MOUNT_PID=$!
sleep 5

if pgrep -f "minikube mount.*home.*host-home" > /dev/null; then
    echo -e "${GREEN}✓ Home directory mounted at /host-home in minikube (PID: $MOUNT_PID)${NC}"
else
    echo -e "${RED}Failed to mount home directory${NC}"
    tail -20 /tmp/minikube-mount.log 2>/dev/null || true
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