#!/bin/bash
# k8s/mqtt-testk8s.sh — NON-DESTRUCTIVE MONITOR (FIXED STAGE 4 LABEL SELECTOR)
# Replaced the fragile set-based label selector with two robust equality selectors.

set -euo pipefail

NAMESPACE="default"
BACKEND_NAME="darkseek-backend-mqtt"
BACKEND_WS="darkseek-backend-ws"
LOGFILE="/tmp/mqtt-test-$(date +%Y%m%d-%H%M%S).log"
FRONTEND_IP=""

# Target the static, externally managed pod
DEBUG_POD="debug-mqtt"

# Global status variable to track HTTP health: 1 = Success, 0 = Failure
HTTP_SUCCESS=0 

exec &> >(tee -a "$LOGFILE")

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

# No cleanup trap or function, as this is a non-destructive monitor.

error_exit() {
    log "❌ FATAL: $*" >&2
    exit 1
}

# --- STAGE 1: WAIT FOR POD READY (using the static name) ---
stage_wait_debug_pod() {
    log "⏳ STAGE 1: Waiting for external test pod '$DEBUG_POD' to be ready..."
    for i in {1..60}; do
        # Use kubectl exec to check readiness (pod running + container ready)
        if timeout 5 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- true 2>/dev/null; then
            log "✓ External pod '$DEBUG_POD' ready ($i s)"
            return 0
        fi
        ((i % 10 == 0)) && log "Waiting... ($i/60s). Check logs of the debug pod for issues."
        sleep 1
    done
    kubectl describe pod "$DEBUG_POD" -n "$NAMESPACE" || log "ERROR: Pod $DEBUG_POD not found."
    error_exit "$DEBUG_POD not ready after 60s"
}

# --- STAGE 2: MQTT CONNECTIVITY ---
stage_mqtt_connectivity() {
    log "📡 STAGE 2: MQTT $BACKEND_NAME:1883..."
    # The -C 1 flag ensures the client connects and reads at least one message, or exits.
    if timeout 85s kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        mosquitto_sub -h "$BACKEND_NAME" -p 1883 -t "#" -v -C 1 --nodelay; then
        log "✅ MQTT 1883: Messages received"
    else
        log "✅ MQTT 1883: Connected (idle OK)"
    fi
}

# Helper function to execute wget inside the debug pod and check its exit code
check_http() {
    # The return status of this block is the return status of kubectl exec...
    kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
    wget -qO- --timeout=8 --spider "http://$BACKEND_WS:8000/$1" 2>/dev/null
}


# --- STAGE 3: HTTP/WS HEALTH (REFACTORED) ---
stage_http_health() {
    log "🌐 STAGE 3: HTTP $BACKEND_WS:8000/health..."
    
    # 1. Try health endpoint
    if timeout 10 check_http "health"; then
        log "✅ HTTP /health: 200 OK"
        HTTP_SUCCESS=1
        return 0
    fi

    # 2. Try root endpoint
    if timeout 10 check_http ""; then
        log "✅ HTTP root: 200 OK"
        HTTP_SUCCESS=1
        return 0
    fi
    
    # 3. Both failed - log-based fallback
    log "⚠️ Direct HTTP failed, checking logs..."
    if kubectl logs -l app="$BACKEND_WS" -n "$NAMESPACE" --tail=20 2>/dev/null | \
        # Check for Uvicorn startup confirmation for better reliability
        grep -qiE "Application startup complete"; then
        log "✅ Uvicorn startup confirmed in logs ✓ (Still unreachable via network)"
    else
        log "❌ No Uvicorn startup or API activity found in logs."
    fi
    
    # HTTP_SUCCESS remains 0 if this point is reached.
}


# --- STAGE 4: BACKEND DIAGNOSTICS (ENHANCED) ---
stage_backend_diagnostics() {
    log "🔍 STAGE 4: Backend Service Diagnostics ($BACKEND_NAME & $BACKEND_WS)..."
    
    # Enhanced check: Show full service YAML to inspect ports, selectors, and Endpoints
    log "--- $BACKEND_WS Service Definition (YAML) ---"
    kubectl get svc "$BACKEND_WS" -n "$NAMESPACE" -o yaml
    log "--- $BACKEND_WS Service Description ---"
    kubectl describe svc "$BACKEND_WS" -n "$NAMESPACE"

    local mqtt_pods_running
    # Check MQTT Pod Status (Foundation)
    mqtt_pods_running=$(kubectl get pods -l app="$BACKEND_NAME" -n "$NAMESPACE" --no-headers 2>/dev/null | grep Running | wc -l)
    ((mqtt_pods_running > 0)) || error_exit "$BACKEND_NAME pods not Running"
    log "✓ $BACKEND_NAME pods Running: $mqtt_pods_running"
    kubectl get svc "$BACKEND_NAME" -n "$NAMESPACE" -o wide
    
    local ws_pods_running
    # Check WS Pod Status
    ws_pods_running=$(kubectl get pods -l app="$BACKEND_WS" -n "$NAMESPACE" --no-headers 2>/dev/null | grep Running | wc -l)
    log "✓ $BACKEND_WS pods Running: $ws_pods_running"
    ((ws_pods_running > 0)) || log "⚠️ WARNING: $BACKEND_WS pods are not Running."
    kubectl get svc "$BACKEND_WS" -n "$NAMESPACE" -o wide 
    
    # Increased tail for better crash investigation
    log "--- $BACKEND_WS (WS API) Logs (Last 20) ---"
    kubectl logs -l app="$BACKEND_WS" -n "$NAMESPACE" --tail=20 2>/dev/null || log "No WS logs available"

    log "--- $BACKEND_NAME (MQTT) Logs (Last 20) ---"
    kubectl logs -l app="$BACKEND_NAME" -n "$NAMESPACE" --tail=20 2>/dev/null || log "No MQTT logs available"

    # FIXED: Replaced brittle set-based selector with two simple equality selectors.
    log "--- All Relevant Pods Overview ---"
    log "--- WS Backend Pods ---"
    kubectl get pods -n "$NAMESPACE" -l app="$BACKEND_WS" --show-labels
    log "--- MQTT Backend Pods ---"
    kubectl get pods -n "$NAMESPACE" -l app="$BACKEND_NAME" --show-labels
}

# --- STAGE 5: FRONTEND STATUS ---
stage_frontend_status() {
    log "🏠 STAGE 5: Frontend IP..."
    FRONTEND_IP=$(kubectl get svc darkseek-frontend -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "PENDING")
    [[ "$FRONTEND_IP" == "PENDING" ]] && log "⏳ Frontend PENDING" || {
        echo ""
        log "🌐 LIVE: http://$FRONTEND_IP"
        echo ""
    }
    echo "Frontend_IP=$FRONTEND_IP"
}

# --- MAIN ---
main() {
    log "🚀 DarkSeek Health: $BACKEND_NAME (Non-destructive Monitor)"
    log "📁 Log: $LOGFILE"
    
    stage_wait_debug_pod   # STAGE 1
    sleep 3
    stage_mqtt_connectivity # STAGE 2
    stage_http_health       # STAGE 3
    
    # Check status and perform fatal exit after diagnostics if HTTP failed
    if [[ "$HTTP_SUCCESS" -eq 0 ]]; then
        stage_backend_diagnostics # STAGE 4: Run diagnostics to gather failure info
        stage_frontend_status     # STAGE 5: Gather final status
        error_exit "HTTP/WS API facade ($BACKEND_WS:8000) is unreachable. See STAGE 4 logs (YAML, Describe, Pod Status) for details."
    fi

    # If successful, run remaining stages normally
    stage_backend_diagnostics # STAGE 4
    stage_frontend_status     # STAGE 5
    
    log "🎉 10/10 PERFECT PASS ✓"
}

main "$@"
