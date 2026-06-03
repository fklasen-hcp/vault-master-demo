#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check what we're checking for
CHECK_TYPE=${1:-"agentic"}

echo -e "${BLUE}=== Checking Kubernetes Resources ===${NC}"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}ERROR: kubectl not found${NC}"
    exit 1
fi

# Check if cluster is accessible
if ! kubectl cluster-info > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot access Kubernetes cluster${NC}"
    exit 1
fi

# Get node capacity
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
TOTAL_MEMORY=$(kubectl get node $NODE_NAME -o jsonpath='{.status.capacity.memory}' | sed 's/Ki$//')
TOTAL_CPU=$(kubectl get node $NODE_NAME -o jsonpath='{.status.capacity.cpu}')

# Convert memory to Mi
TOTAL_MEMORY_MI=$((TOTAL_MEMORY / 1024))

echo -e "${GREEN}Node: $NODE_NAME${NC}"
echo -e "${GREEN}Total Capacity: ${TOTAL_MEMORY_MI}Mi RAM, ${TOTAL_CPU} CPUs${NC}"

# Get current resource requests and limits
CURRENT_REQUESTS=$(kubectl describe nodes | grep -A 5 "Allocated resources:" | grep -E "memory|cpu")

# Extract current memory and CPU usage
CURRENT_MEMORY_REQUESTS=$(echo "$CURRENT_REQUESTS" | grep memory | awk '{print $2}' | sed 's/Mi//' | sed 's/(.*//')
CURRENT_CPU_REQUESTS=$(echo "$CURRENT_REQUESTS" | grep cpu | awk '{print $2}' | sed 's/m//' | sed 's/(.*//')

# Calculate available resources
AVAILABLE_MEMORY=$((TOTAL_MEMORY_MI - CURRENT_MEMORY_REQUESTS))
AVAILABLE_CPU=$((TOTAL_CPU * 1000 - CURRENT_CPU_REQUESTS))

echo -e "${BLUE}Current Usage:${NC}"
echo -e "  Memory Requests: ${CURRENT_MEMORY_REQUESTS}Mi"
echo -e "  CPU Requests: ${CURRENT_CPU_REQUESTS}m"
echo -e ""
echo -e "${BLUE}Available:${NC}"
echo -e "  Memory: ${AVAILABLE_MEMORY}Mi"
echo -e "  CPU: ${AVAILABLE_CPU}m"

# Define requirements based on check type
if [ "$CHECK_TYPE" = "agentic" ]; then
    REQUIRED_MEMORY=6000  # 6GB for Agentic AI demo
    REQUIRED_CPU=3000     # 3 CPU cores
    DEMO_NAME="Agentic AI"
else
    echo -e "${RED}Unknown check type: $CHECK_TYPE${NC}"
    exit 1
fi

echo -e ""
echo -e "${BLUE}${DEMO_NAME} Demo Requirements:${NC}"
echo -e "  Memory: ${REQUIRED_MEMORY}Mi"
echo -e "  CPU: ${REQUIRED_CPU}m"
echo -e ""

# Check if resources are sufficient
if [ $AVAILABLE_MEMORY -lt $REQUIRED_MEMORY ]; then
    echo -e "${RED}✗ Insufficient memory available${NC}"
    echo -e "${YELLOW}  Available: ${AVAILABLE_MEMORY}Mi${NC}"
    echo -e "${YELLOW}  Required:  ${REQUIRED_MEMORY}Mi${NC}"
    echo -e "${YELLOW}  Shortfall: $((REQUIRED_MEMORY - AVAILABLE_MEMORY))Mi${NC}"
    MEMORY_OK=false
else
    echo -e "${GREEN}✓ Sufficient memory available${NC}"
    MEMORY_OK=true
fi

if [ $AVAILABLE_CPU -lt $REQUIRED_CPU ]; then
    echo -e "${RED}✗ Insufficient CPU available${NC}"
    echo -e "${YELLOW}  Available: ${AVAILABLE_CPU}m${NC}"
    echo -e "${YELLOW}  Required:  ${REQUIRED_CPU}m${NC}"
    echo -e "${YELLOW}  Shortfall: $((REQUIRED_CPU - AVAILABLE_CPU))m${NC}"
    CPU_OK=false
else
    echo -e "${GREEN}✓ Sufficient CPU available${NC}"
    CPU_OK=true
fi

echo -e ""

# Final decision
if [ "$MEMORY_OK" = true ] && [ "$CPU_OK" = true ]; then
    echo -e "${GREEN}=== Resources Check: PASSED ===${NC}"
    echo -e "${GREEN}Sufficient resources available for ${DEMO_NAME} demo${NC}"
    exit 0
else
    echo -e "${RED}=== Resources Check: FAILED ===${NC}"
    echo -e "${YELLOW}Insufficient resources for ${DEMO_NAME} demo${NC}"
    echo -e ""
    echo -e "${BLUE}Options:${NC}"
    echo -e "  ${YELLOW}1. Increase Minikube resources:${NC}"
    echo -e "     minikube stop"
    echo -e "     minikube delete"
    echo -e "     minikube start --cpus=8 --memory=16384 --disk-size=50g"
    echo -e ""
    echo -e "  ${YELLOW}2. Deploy only ${DEMO_NAME} demo (skips other demos):${NC}"
    echo -e "     make agentic-demo-only"
    echo -e ""
    echo -e "  ${YELLOW}3. Clean up unused demos to free resources:${NC}"
    echo -e "     kubectl delete namespace <unused-namespace>"
    exit 1
fi

# Made with Bob
