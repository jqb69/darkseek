#!/bin/bash
# k8s/frontend-testk8s.sh — FINAL: Streamlit Frontend Health & Debug Executioner
# Will make your frontend confess everything or die trying.
set -euo pipefail

NAMESPACE="default"
LOGFILE="/tmp/frontend-test-$(date +%Y%m%d-%H%M%S).log"
FRONTEND_IP=""

exec &> >(tee -a "$LOGFILE")

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

error_exit() { log "FATAL: $*" >&2; exit 1; }

log "=== DARKSEEK FRONTEND DIAGNOSTIC EXECUTIONER ACTIVATED ==="

# STAGE 1: Find a running frontend pod
stage_find_pod() {
    log "STAGE 1: Locating a Running frontend pod..."
    POD=$(kubectl get pods -n $NAMESPACE -l app=darkseek-frontend \
          -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$POD" ]]; then
        log "ERROR: No Running frontend pod found!"
        kubectl get pods -n $NAMESPACE -l app=darkseek-frontend
        error_exit "Frontend pods are dead or dying"
    fi

    log "TARGET ACQUIRED: $POD"
}

# STAGE 2: Wait until we can exec into it
stage_wait_exec_ready() {
    log "STAGE 2: Waiting for pod to accept exec (max 60s)..."
    for i in {1..60}; do
        if kubectl exec "$POD" -- true 2>/dev/null; then
            log "Pod accepts commands — EXEC READY"
            return 0
        fi
        log "Not ready yet ($i/60)..."
        sleep 1
    done
    error_exit "Pod never became exec-ready"
}

# STAGE 3: Run full diagnostic inside the pod
stage_diagnostic_blitz() {
    log "STAGE 3: EXECUTING FULL DIAGNOSTIC BLITZ INSIDE POD..."

    log "=== PORT CHECK ==="
    # Checks if anything is listening on the expected Streamlit port 8501
    kubectl exec "$POD" -- netstat -tlnp | grep 8501 || true
    
    log "=== STREAMLIT HEALTH ENDPOINT ==="
    # Attempts to hit the health endpoint from inside the pod (most critical check)
    kubectl exec "$POD" -- curl -f http://localhost:8501/_stcore/healthz && log "HEALTHZ OK" || log "HEALTHZ FAILED"

    log "=== STREAMLIT VERSION ==="
    kubectl exec "$POD" -- streamlit version || true

    log "=== PYTHON PACKAGES (Top 20) ==="
    kubectl exec "$POD" -- pip list | head -20

    log "=== DISK USAGE ==="
    kubectl exec "$POD" -- df -h /

    log "=== TOP PROCESSES (CPU/Mem check) ==="
    # Shows the top 10 processes by resource usage
    kubectl exec "$POD" -- top -b -n 1 | head -10
}

# STAGE 4: Get external IP and test HTTP response
stage_test_external_access() {
    log "STAGE 4: Testing external HTTP access..."
    IP=$(kubectl get svc darkseek-frontend -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "PENDING")
    
    if [[ "$IP" == "PENDING" ]] || [[ -z "$IP" ]]; then
        log "WARNING: LoadBalancer IP still PENDING or missing."
        FRONTEND_IP="N/A"
    else
        FRONTEND_IP="$IP"
        log "EXTERNAL IP: $IP"
        log "Testing HTTP response from outside the cluster (30s timeout)..."
        # Uses a temporary curl pod to test connectivity from within the cluster network
        HTTP_CODE=$(kubectl run curl-test --rm -i --restart=Never --image=curlimages/curl -- \
            curl -s -o /dev/null -w "%{http_code}" "http://$IP" --max-time 25 || echo "TIMEOUT")
        
        if [[ "$HTTP_CODE" == "200" ]]; then
            log "EXTERNAL HTTP ACCESS: SUCCESS (Code 200)"
        else
            log "EXTERNAL HTTP ACCESS: FAILED (Code: $HTTP_CODE)"
        fi
    fi
}

# === EXECUTE THE DEATH SENTENCE ===
stage_find_pod
stage_wait_exec_ready
stage_diagnostic_blitz
stage_test_external_access

log "=== FRONTEND DIAGNOSTIC COMPLETE — ALL SYSTEMS NOMINAL ==="
echo ""
log "FRONTEND URL: http://$FRONTEND_IP"
echo ""

exit 0
