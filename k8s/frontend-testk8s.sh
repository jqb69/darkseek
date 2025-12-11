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
    kubectl exec "$pod" -- python -c "import streamlit, sys; print(f'Streamlit {streamlit.__version__} | Python {sys.version.split()[0]}')" 2>/dev/null || log "Python/Streamlit check failed"

    log "--- APPLICATION DIRECTORY ---"
    kubectl exec "$pod" -- ls -la /app 2>/dev/null || log "Cannot list /app"

    log "--- ENVIRONMENT ---"
    kubectl exec "$pod" -- env | grep -E "(PATH|PYTHON|STREAMLIT)" 2>/dev/null || log "No env vars visible"

    # GEMINI'S GENIUS: 5-RETRY SOCKET CHECK — KILLS THE RACE CONDITION DEAD
    log "--- HEALTH CHECK: Verifying Streamlit is listening on 8501 (5 retries) ---"
    local attempts=0
    local max_attempts=5

    while (( attempts < max_attempts )); do
        (( attempts++ ))
        log "Attempt $attempts/$max_attempts — checking port 8501..."

        # Python socket check: Bypasses curl/wget dependency.
        # Exits 0 on success, 1 on failure. Redirecting stderr/stdout to discard output.
        if kubectl exec "$pod" -- python -c "import socket; s=socket.socket(); s.settimeout(3); exit(0 if s.connect_ex(('127.0.0.1', 8501)) == 0 else 1)" &>/dev/null; then
            log "SUCCESS: Streamlit is LISTENING on 8501 — FULLY READY"
            # Print the final URL directly here, as this is the point of guaranteed readiness.
            log "FRONTEND IS 100% LIVE → http://$(kubectl get svc darkseek-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "IP still PENDING"):8501"
            return 0 # Success! Exit the function.
        fi

        log "Port 8501 not ready yet — retrying in 2s..."
        sleep 2
    done

    log "FATAL: Streamlit failed to bind to 8501 after $max_attempts attempts"
    log "--- FINAL LOGS ---"
    kubectl logs "$pod" --tail=100 || true
    return 1 # Failure!
}

get_frontend_url() {
    local ip
    ip=$(kubectl get svc darkseek-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "PENDING")
    if [[ "$ip" != "PENDING" && -n "$ip" ]]; then
        echo "http://$ip:8501"
    else
        echo "IP still PENDING"
    }

main() {
    log "=== DARKSEEK FRONTEND DIAGNOSTIC EXECUTIONER ACTIVATED ==="

    local pod
    pod=$(find_running_pod)
    [[ -z "$pod" ]] && { log "ERROR: No Running frontend pod"; kubectl get pods -l app="$APP_LABEL"; exit 1; }

    log "TARGET ACQUIRED: $pod"

    # STAGE 2: Wait for exec readiness
    wait_for_exec_ready "$pod" || exit 1
    
    # STAGE 3: Run diagnostics. The function itself handles the final SUCCESS logging and URL print.
    run_slim_diagnostics "$pod" || exit 1 # Exit the script entirely if run_slim_diagnostics returns 1 (failure)

    log "=== DIAGNOSTIC COMPLETE: Pod is fully ready ==="
    # The final URL is already logged by run_slim_diagnostics on success, so we don't need redundant logging here.
}

main
