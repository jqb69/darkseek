#!/bin/bash
# k8s/reset-network-state.sh — FIXED VERSION
set -euo pipefail

log() { echo "[$(date +'%H:%M:%S')] $*"; }

log "☢️ NUCLEAR NETWORK RESET STARTING..."

# 1. DELETE ALL NETWORKPOLICIES (nuclear)
log "🗑️ Deleting ALL NetworkPolicies..."
kubectl delete networkpolicy --all --ignore-not-found=true || true

# 2. RE-APPLY CRITICAL POLICIES (DNS FIRST if exists)
log "♻️ Re-applying policies (DNS → WS → Redis → Debug)..."

apply_if_exists() {
    if [ -f "$1" ]; then
        log "Applying: $1"
        kubectl apply -f "$1"
    else
        log "⚠️ Skipping: $1 (missing)"
    fi
}

# CRITICAL ORDER:
apply_if_exists "k8s/policies/00-allow-dns.yaml"           # DNS FIRST
apply_if_exists "k8s/policies/02-allow-backend-ws.yaml"    # WS
apply_if_exists "k8s/policies/05-allow-redis-access.yaml"  # Redis
apply_if_exists "k8s/policies/07-allow-debug-to-backend.yaml"

# 3. FORCE KILL PODS (fresh veth pairs)
log "🔌 Force killing pods..."
kubectl delete pod -l app=darkseek-backend-ws --force --grace-period=0 || true
kubectl delete pod -l app=darkseek-redis --force --grace-period=0 || true

# 4. WAIT FOR STABILIZATION (NO DOUBLE RESTART)
log "⏳ Waiting for fresh pods (handles 90s startup)..."
kubectl rollout status deployment/darkseek-backend-ws --timeout=180s
kubectl rollout status deployment/darkseek-redis --timeout=60s

log "✅ Pods stable. CNI attaching..."
sleep 25  # CNI propagation

log "📊 Pod status:"
kubectl get pods -l 'app in (darkseek-backend-ws,darkseek-redis,debug-mqtt)' -o wide

log "✅ RESET COMPLETE. Test: ./k8s/run-mqtt-tests-with-fix.sh"
