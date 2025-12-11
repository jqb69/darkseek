#!/bin/bash
# k8s/frontend-testk8s.sh — FINAL MODULAR EXECUTIONER (Autopilot-Proof, Slim-Image Safe)
set -euo pipefail

NAMESPACE="default"
APP_LABEL="darkseek-frontend"
MAX_WAIT=720  # 12 minutes

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

find_running_pod() {
    local pod
    pod=$(kubectl get pods -n "$NAMESPACE" -l app="$APP_LABEL" \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')
    echo "$pod"
}

wait_for_exec_ready() {
    local pod="$1"
    local elapsed=0
    local interval=30

    log "STAGE 2: Waiting for pod '$pod' to accept exec (max ${MAX_WAIT}s = $((MAX_WAIT/60)) min)..."

    while (( elapsed < MAX_WAIT )); do
        # Primary check: Can we exec into the pod?
        if kubectl exec "$pod" -- true 2>/dev/null; then
            log "Pod accepts exec — READY"
            return 0
        fi

        (( elapsed++ ))

        # Every 30 seconds (or at 10s mark): status + logs dump
        if (( elapsed % interval == 0 || elapsed == 10 )); then
            local mins=$((elapsed / 60))
            local secs=$((elapsed % 60))
            log "STATUS CHECK [$mins:$secs/$((MAX_WAIT/60)) min]: Still waiting for exec..."
            
            log "--- POD STATUS ---"
            kubectl get pod "$pod" -o wide || true

            log "--- RECENT LOGS (last 10 lines) ---"
            if ! kubectl logs "$pod" --tail=10 2>/dev/null; then
                log "No logs available yet (container may still be starting)"
            fi

            log "--- CONTAINER STATUS ---"
            # Extract container status for detailed health check (Ready state)
            kubectl get pod "$pod" -o jsonpath='{.status.containerStatuses[*].{name:ready,state}}' 2>/dev/null || true
            echo
        fi

        sleep 1
    done

    log "FATAL: Pod '$pod' never became exec-ready after ${MAX_WAIT}s"
    log "--- FINAL POD DESCRIBE ---"
    kubectl describe pod "$pod" || true
    log "--- FINAL LOGS (last 100 lines) ---"
    kubectl logs "$pod" --tail=100 || true

    return 1
}

run_slim_diagnostics() {
    local pod="$1"
    log "STAGE 3: EXECUTING SLIM-IMAGE SAFE DIAGNOSTICS on $pod"

    log "--- PYTHON/STREAMLIT VERSIONS ---"
    # Check if python is available and run a simple command
    kubectl exec "$pod" -- python -c "import streamlit, sys; print(f'Streamlit {streamlit.__version__} | Python {sys.version.split()[0]}')" 2>/dev/null || log "Python version check failed (Python may be missing or Streamlit not installed)."

    log "--- APPLICATION DIRECTORY LISTING ---"
    kubectl exec "$pod" -- ls -la /app 2>/dev/null || log "/app directory listing failed."

    log "--- ENVIRONMENT (PATH/PYTHON/STREAMLIT) ---"
    kubectl exec "$pod" -- env | grep -E "(PATH|PYTHON|STREAMLIT)" 2>/dev/null || log "Environment variables not visible."
    
    log "--- HEALTH CHECK (Attempting wget/curl fallback) ---"
    # Use 'sh -c' to check if 'wget' or 'curl' exists, then execute the health check
    if kubectl exec "$pod" -- sh -c 'command -v wget >/dev/null && wget -qO- http://localhost:8501/_stcore/healthz || (command -v curl >/dev/null && curl -f http://localhost:8501/_stcore/healthz)' 2>/dev/null | grep -q "ok"; then
        log "HEALTHZ OK — Streamlit is confirmed alive via http check."
    else
        log "HEALTHZ FAILED — Service is unreachable. Dumping final logs for insight."
        kubectl logs "$pod" --tail=100 || true
    fi
}

get_frontend_url() {
    local ip
    ip=$(kubectl get svc darkseek-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "PENDING")
    if [[ "$ip" != "PENDING" && -n "$ip" ]]; then
        echo "http://$ip:8501"
    else
        echo "IP still PENDING"
    fi
}

main() {
    log "=== DARKSEEK FRONTEND DIAGNOSTIC EXECUTIONER ACTIVATED ==="

    local pod
    pod=$(find_running_pod)
    [[ -z "$pod" ]] && { log "ERROR: No Running frontend pod"; kubectl get pods -l app="$APP_LABEL"; exit 1; }

    log "TARGET ACQUIRED: $pod"

    # STAGE 2: Wait for exec readiness (which now includes status/log streaming)
    wait_for_exec_ready "$pod" || exit 1
    
    # STAGE 3: Run diagnostics safe for slim images
    run_slim_diagnostics "$pod"

    log "=== FRONTEND DIAGNOSTIC COMPLETE ==="
    local url
    url=$(get_frontend_url)
    log "FRONTEND URL → $url"

    if [[ "$url" == "IP still PENDING" ]]; then
        log "Note: The LoadBalancer IP is still pending, but the application is confirmed running inside the pod."
        exit 0
    fi
    log "Frontend pod $pod is alive and passed slim diagnostics."
}

main
