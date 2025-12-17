#!/bin/bash
# k8s/reset-network-state.sh — Flushes CNI cache and reloads policies

log() { echo "[$(date +'%H:%M:%S')] $*"; }

log "☢️ STARTING NUCLEAR RESET OF NETWORK STATE..."

# 1. DELETE ALL RELATED POLICIES
log "🗑️ Deleting NetworkPolicies..."
# Delete by label (bulk)
kubectl delete networkpolicy -l app=darkseek-policy --ignore-not-found=true
# Delete by specific names (targeted)
kubectl delete networkpolicy allow-to-redis allow-debug-to-backend --ignore-not-found=true

# 2. RE-APPLY POLICIES
log "♻️ Re-applying fresh policies..."
kubectl apply -f k8s/policies/03-allow-backend-mqtt.yaml
kubectl apply -f k8s/policies/05-allow-backend-ws-to-mqtt-egress.yaml
kubectl apply -f k8s/policies/05-allow-redis-access.yaml
kubectl apply -f k8s/network-policy.yaml

# 3. FORCE RESTART PODS (Clears stale conntrack entries)
log "🔌 Killing pods to force fresh veth pairs..."
kubectl delete pod -l app=debug-mqtt --force --grace-period=0
kubectl delete pod -l app=darkseek-redis --force --grace-period=0
# Optional: restart backend to clear its DNS cache
kubectl rollout restart deployment darkseek-backend-ws

log "⏳ Waiting for pods to stabilize..."
sleep 10
kubectl get pods -o wide

log "✅ Reset complete. Run ./mqtt-testk8s.sh to verify."
