#!/bin/bash
# k8s/reset-network-state.sh — Flushes CNI cache and reloads policies
# This version checks for file existence and avoids deleting the debug-mqtt pod.

set -e

log() { echo "[$(date +'%H:%M:%S')] $*"; }

log "☢️ STARTING NUCLEAR RESET OF NETWORK STATE..."

# 1. DELETE ALL RELATED POLICIES
log "🗑️ Deleting NetworkPolicies..."
kubectl delete networkpolicy -l app=darkseek-policy --ignore-not-found=true
kubectl delete networkpolicy allow-backend-ws allow-to-redis allow-debug-to-backend --ignore-not-found=true

# 2. RE-APPLY POLICIES (CRITICAL ORDER)
log "♻️ Re-applying fresh policies..."

apply_if_exists() {
    if [ -f "$1" ]; then
        log "Applying: $1"
        kubectl apply -f "$1"
    else
        log "⚠️ Skipping: $1 (File not found)"
    fi
}

apply_if_exists "k8s/policies/02-allow-backend-ws.yaml"      # DNS + Redis EGRESS
apply_if_exists "k8s/policies/05-allow-redis-access.yaml"    # Redis INGRESS
apply_if_exists "k8s/policies/07-allow-debug-to-backend.yaml" # Debug EGRESS

# 3. FORCE RESTART CRITICAL PODS (Fresh veth + policy attachment)
# Note: debug-mqtt pod deletion removed per user request.
log "🔌 Killing pods to force fresh veth pairs + policy attachment..."

log "Restarting Backend-WS..."
kubectl delete pod -l app=darkseek-backend-ws --force --grace-period=0 || true
kubectl rollout restart deployment darkseek-backend-ws

log "Restarting Redis..."
kubectl delete pod -l app=darkseek-redis --force --grace-period=0 || true
kubectl rollout restart deployment darkseek-redis

log "⏳ Waiting for pods + CNI to stabilize..."
sleep 25
kubectl get pods -l 'app in (darkseek-backend-ws, debug-mqtt, darkseek-redis)' -o wide

log "✅ Reset complete. Run ./k8s/run-mqtt-tests-with-fix.sh to verify."
