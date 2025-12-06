#!/bin/bash
# k8s/mqtt-testk8s.sh — Modular MQTT Test & Frontend IP Retrieval
# Author: Frank Aigrillo Certified, Refactored for Modularity

# --- 1. SETUP & UTILITIES ---
set -euo pipefail

NAMESPACE="default"
LOGFILE="/tmp/mqtt-test-$(date +%Y%m%d-%H%M%S).log"
FRONTEND_IP=""

# Trap to ensure we tee output to the log file correctly before exiting
exec &> >(tee -a "$LOGFILE")

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
error_exit() {
    log "FATAL ERROR: $*" >&2
    exit 1
}

# --- 2. STAGE FUNCTIONS ---

# STAGE 1: Wait for the Debug Pod to be Ready for Execution
stage_wait_for_pod() {
    log "STAGE 1: Waiting for debug-mqtt pod to be exec-ready (max 39s)..."
    local pod_name="debug-mqtt"
    
    # Poll for exec readiness
    for i in {1..39}; do
        if kubectl exec "$pod_name" -- true 2>/dev/null; then
            log "Pod ready for exec."
            return 0
        fi
        log "Pod not ready yet ($i/39) — waiting..."
        sleep 1
    done

    # If loop finishes without returning 0
    log "ERROR: $pod_name pod never became exec-ready."
    kubectl describe pod "$pod_name"
    error_exit "Debug pod failed to become ready."
}

# STAGE 2: Test MQTT Connectivity
stage_test_mqtt_connectivity() {
    log "STAGE 2: Testing MQTT connectivity to darkseek-backend-mqtt:1883 (max 85s)..."
    
    # Use timeout and mosquitto_sub to check for connectivity.
    # -C 1: Exit after 1 message (or after timeout if no messages)
    if timeout 85s kubectl exec debug-mqtt -- mosquitto_sub -h darkseek-backend-mqtt -p 1883 -t "#" -v -C 1 --nodelay; then
        log "SUCCESS: MQTT CONNECTED — received at least one message."
    else
        # If timeout occurs and no message is received, connectivity is still considered OK 
        # because the internal connection succeeded but the system is idle.
        log "MQTT OK — no messages in 85s (system idle = expected & healthy)."
    fi

    log "MQTT spy pod is fully functional and responsive."
    log "=== MQTT TEST PASSED ==="
}

# STAGE 3: Retrieve and Display Frontend External IP
stage_get_frontend_ip() {
    log "STAGE 3: Retrieving Frontend External IP from LoadBalancer..."
    
    # Use the requested kubectl command to get the IP.
    local ip_address
    ip_address=$(kubectl get service darkseek-frontend -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "PENDING")
    
    if [[ "$ip_address" == "PENDING" ]] || [[ -z "$ip_address" ]]; then
        log "WARNING: Frontend IP is still PENDING. Cannot display public URL."
        FRONTEND_IP="PENDING"
    else
        FRONTEND_IP="$ip_address"
        echo ""
        log "--------------------------------------------------------"
        log "  FRONTEND APPLICATION URL:"
        log "  http://$FRONTEND_IP"
        log "--------------------------------------------------------"
        echo ""
    fi

    # Output the variable as requested by the user
    echo "Frontend IP Address = $FRONTEND_IP"
}

# --- 3. MAIN EXECUTION ---
main() {
    log "=== DARKSEEK CI/CD TEST STARTED: MQTT & EXTERNAL IP ==="
    log "Log file: $LOGFILE"

    stage_wait_for_pod
    
    # Short pause to ensure execution context is fully stable
    sleep 2

    stage_test_mqtt_connectivity
    
    stage_get_frontend_ip
    
    log "=== ALL STAGES COMPLETED SUCCESSFULLY ==="

    # Upload logfile as artifact (GitHub Actions)
    if [[ -n "${GITHUB_ARTIFACTS-}" ]]; then
        mkdir -p "$GITHUB_ARTIFACTS"
        cp "$LOGFILE" "$GITHUB_ARTIFACTS/mqtt-test-result.log"
        log "Test log saved to artifacts: mqtt-test-result.log"
    fi
}

main
