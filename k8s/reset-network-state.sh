#!/bin/bash
# k8s/reset-network-state.sh — Flushes CNI cache and reloads policies
# FIXED: Corrected paths for 07-allow-debug-to-backend.yaml and 02-allow-backend-ws.yaml

set -e

log() { echo "[$(date +'%H:%M:%S')] $*"; }

log "☢️ STARTING NUCLEAR RESET OF NETWORK STATE..."

# 1. DELETE ALL RELATED POLICIES
log "🗑️ Deleting NetworkPolicies..."
# Delete by label (bulk)
kubectl delete networkpolicy -l app=darkseek-policy --ignore-not-found=true
# Delete specific names to be sure
kubectl delete networkpolicy allow-backend-ws allow-to-redis allow-debug-to-backend --ignore-not-found=true

# 2. RE-APPLY POLICIES (FIXED PATHS)
log "♻️ Re-applying fresh policies..."

# Re-apply the specific backend-ws policy
if [ -f "k8s/policies/02-allow-backend-ws.yaml" ]; then
    kubectl apply -f k8s/policies/02-allow-backend-ws.yaml
else
    log "⚠️ WARNING: k8s/policies/02-allow-backend-ws.yaml not found!"
fi

# Re-apply Redis policy
if [ -f "k8s/policies/05-allow-redis-access.yaml" ]; then
    kubectl apply -f k8s/policies/05-allow-redis-access.yaml
else
    log "⚠️ WARNING: k8s/policies/05-allow-redis-access.yaml not found!"
fi

# Re-apply Debug policy (FIXED PATH to k8s/policies/)
if [ -f "k8s/policies/07-allow-debug-to-backend.yaml" ]; then
    log "Applying Debug Policy: k8s/policies/07-allow-debug-to-backend.yaml"
    kubectl apply -f k8s/policies/07-allow-debug-to-backend.yaml
else
    log "❌ ERROR: k8s/policies/07-allow-debug-to-backend.yaml not found! Debug pod will be isolated."
fi

# 3. FORCE RESTART PODS (Clears stale conntrack entries)
log "🔌 Killing pods to force fresh veth pairs..."

kubectl delete pod -l app=darkseek-redis --force --grace-period=0 || true
kubectl rollout restart deployment darkseek-backend-ws

log "⏳ Waiting for pods to stabilize..."
sleep 20
kubectl get pods -o wide

log "✅ Reset complete. Run ./k8s/mqtt-testk8s.sh to verify."
