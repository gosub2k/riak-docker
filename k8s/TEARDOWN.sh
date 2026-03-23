#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="riak"
STATEFULSET="riak"

RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║        ⚠️   DESTRUCTIVE OPERATION — DATA LOSS AHEAD   ⚠️       ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  This will delete:                                           ║${NC}"
echo -e "${RED}║    • StatefulSet '${STATEFULSET}' (all pods)                          ║${NC}"
echo -e "${RED}║    • All PersistentVolumeClaims for '${STATEFULSET}'                  ║${NC}"
echo -e "${RED}║    • All data stored in those volumes                        ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  Namespace: ${NAMESPACE}                                          ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Show what currently exists
echo -e "${YELLOW}Current state:${NC}"
echo "--- StatefulSet ---"
kubectl get statefulset -n "$NAMESPACE" 2>/dev/null || echo "  (none found)"
echo ""
echo "--- Pods ---"
kubectl get pods -n "$NAMESPACE" -l app=riak 2>/dev/null || echo "  (none found)"
echo ""
echo "--- PVCs ---"
kubectl get pvc -n "$NAMESPACE" -l app=riak 2>/dev/null || \
  kubectl get pvc -n "$NAMESPACE" 2>/dev/null | grep riak || echo "  (none found)"
echo ""

echo -e "${RED}Type 'YES DELETE EVERYTHING' to confirm:${NC}"
read -r confirm

if [ "$confirm" != "YES DELETE EVERYTHING" ]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "Deleting StatefulSet..."
kubectl delete statefulset "$STATEFULSET" -n "$NAMESPACE" --grace-period=120

echo "Deleting PVCs..."
kubectl delete pvc -n "$NAMESPACE" -l app=riak 2>/dev/null || true
# Also catch PVCs by the volumeClaimTemplate naming convention (riak-data-riak-N)
kubectl get pvc -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | \
  grep "^riak-data-" | \
  xargs -r kubectl delete pvc -n "$NAMESPACE"

echo ""
echo -e "${YELLOW}Done. StatefulSet and volumes deleted.${NC}"
echo ""
echo "Remaining resources in namespace '$NAMESPACE':"
kubectl get all,pvc -n "$NAMESPACE" 2>/dev/null || true
