#!/bin/bash
# k8s/frontend-testk8s.sh — FINAL: Streamlit Diagnostic Executioner (Autopilot-Proof)
set -euo pipefail

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "=== DARKSEEK FRONTEND DIAGNOSTIC EXECUTIONER ACTIVATED ==="

# STAGE 1: Find a Running pod
# We specifically select a pod in the "Running" phase to ensure we target a stable instance.
POD=$(kubectl get pods -l app=darkseek-frontend -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$POD" ]]; then
    log "ERROR: No Running frontend pod found"
    kubectl get pods -l app=darkseek-frontend
    exit 1
fi

log "TARGET ACQUIRED: $POD"

# STAGE 2: Wait up to 12 MINUTES for exec readiness (matches 10-min startupProbe + margin)
# This addresses the previous FATAL timeout issue.
log "STAGE 2: Waiting for pod to accept exec (max 720s — matches 10-min startupProbe)..."
for i in {1..720}; do
    if kubectl exec "$POD" -- true 2>/dev/null; then
        log "Pod accepts exec — READY"
        break
    fi
    # Log status every 30 seconds for visibility
    [[ $((i % 30)) -eq 0 ]] && log "Still waiting... ($i/720)"
    sleep 1
done

if ! kubectl exec "$POD" -- true 2>/dev/null; then
    log "FATAL: Pod never became exec-ready after 12 minutes"
    # Execute vital debugging commands on failure
    log "--- KUBECTL DESCRIBE (for events) ---"
    kubectl describe pod "$POD"
    log "--- KUBECTL LOGS (for application output) ---"
    kubectl logs "$POD" --tail=100
    exit 1
fi

# STAGE 3: Full diagnostic blitz - Check essential services and resources
log "STAGE 3: EXECUTING DIAGNOSTIC BLITZ (Netstat, Health, Processes, Resources)..."
log "--- NETSTAT (Checking Streamlit Port 8501) ---"
kubectl exec "$POD" -- netstat -tlnp | grep 8501 || true

log "--- HEALTH CHECK (Streamlit /_stcore/healthz) ---"
kubectl exec "$POD" -- curl -f http://localhost:8501/_stcore/healthz && log "HEALTHZ OK" || log "HEALTHZ FAILED"

log "--- PROCESS LIST (ps aux) ---"
kubectl exec "$POD" -- ps aux

log "--- FILESYSTEM USAGE (df -h) ---"
kubectl exec "$POD" -- df -h

log "--- MEMORY USAGE (free -m) ---"
kubectl exec "$POD" -- free -m

log "=== FRONTEND DIAGNOSTIC COMPLETE ==="
log "Frontend pod $POD is alive and exec-ready"
# Retrieve LoadBalancer IP and construct the full URL
FRONTEND_IP=$(kubectl get svc darkseek-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log "URL: http://$FRONTEND_IP:8501"

exit 0
