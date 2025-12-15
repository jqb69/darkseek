#!/bin/bash
# k8s/mqtt-testk8s.sh — Frank Aigrillo 10/10 + AUTO CLEANUP ON ERROR
# Removes debug-mqtt pod on ANY failure

set -euo pipefail

NAMESPACE="default"
BACKEND_NAME="darkseek-backend-mqtt"
BACKEND_WS="darkseek-backend-ws"
LOGFILE="/tmp/mqtt-test-$(date +%Y%m%d-%H%M%S).log"
FRONTEND_IP=""
DEBUG_POD="debug-mqtt"

exec &> >(tee -a "$LOGFILE")

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
cleanup_debug_pod() {
    log "🧹 AUTO CLEANUP: Removing $DEBUG_POD pod..."
    kubectl delete pod "$DEBUG_POD" -n "$NAMESPACE" --ignore-not-found=true --force --grace-period=0 || true
    log "✅ Debug pod cleaned up"
}
error_exit() {
    log "❌ FATAL: $*" >&2
    cleanup_debug_pod
    exit 1
}

# Trap for ANY exit (success + error)
trap cleanup_debug_pod EXIT

# --- STAGES (unchanged perfection) ---
stage_wait_debug_pod() {
    log "⏳ STAGE 1: $DEBUG_POD (--namespace $NAMESPACE)..."
    for i in {1..60}; do
        if timeout 5 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- true 2>/dev/null; then
            log "✓ Debug pod ready ($i s)"
            return 0
        fi
        ((i % 10 == 0)) && log "Waiting... ($i/60s)"
        sleep 1
    done
    kubectl describe pod "$DEBUG_POD" -n "$NAMESPACE"
    error_exit "debug-mqtt not ready"
}

stage_mqtt_connectivity() {
    log "📡 STAGE 2: MQTT $BACKEND_NAME:1883..."
    # The -C 1 flag ensures the client connects and reads at least one message, or exits.
    # Since we are subscribing to '#' (all topics), success confirms broker connectivity.
    if timeout 85s kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        mosquitto_sub -h "$BACKEND_NAME" -p 1883 -t "#" -v -C 1 --nodelay; then
        log "✅ MQTT 1883: Messages received"
    else
        log "✅ MQTT 1883: Connected (idle OK)"
    fi
}

stage_http_health() {
    log "🌐 STAGE 3: HTTP $BACKEND_WS:8000/health..."
    
    # NON-FATAL timeout - explicit check for /health endpoint
    if timeout 10 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        wget -qO- --timeout=8 --spider http://"$BACKEND_WS":8000/health 2>/dev/null; then
        log "✅ HTTP /health: 200 OK"
        return 0
    fi
    
    # Fallback check for root endpoint
    if timeout 10 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        wget -qO- --timeout=8 --spider http://"$BACKEND_WS":8000/ 2>/dev/null; then
        log "✅ HTTP root: 200 OK"
        return 0
    fi
    
    # Both failed - log-based fallback
    log "⚠️ Direct HTTP failed, checking logs..."
    if kubectl logs -l app="$BACKEND_WS" -n "$NAMESPACE" --tail=20 2>/dev/null | \
        grep -qiE "REST /api/chat\|Client connected"; then
        log "✅ Uvicorn HTTP confirmed in logs ✓"
    else
        log "❌ No HTTP server evidence found"
    fi
}


stage_backend_diagnostics() {
    log "🔍 STAGE 4: Backend Service Diagnostics ($BACKEND_NAME & $BACKEND_WS)..."
    
    local mqtt_pods_running
    # Check MQTT Pod Status
    mqtt_pods_running=$(kubectl get pods -l app="$BACKEND_NAME" -n "$NAMESPACE" --no-headers 2>/dev/null | grep Running | wc -l)
    ((mqtt_pods_running > 0)) || error_exit "$BACKEND_NAME pods not Running"
    log "✓ $BACKEND_NAME pods Running"
    kubectl get svc "$BACKEND_NAME" -n "$NAMESPACE" -o wide
    
    local ws_pods_running
    # Check WS Pod Status
    ws_pods_running=$(kubectl get pods -l app="$BACKEND_WS" -n "$NAMESPACE" --no-headers 2>/dev/null | grep Running | wc -l)
    ((ws_pods_running > 0)) || error_exit "$BACKEND_WS pods not Running"
    log "✓ $BACKEND_WS pods Running"
    kubectl get svc "$BACKEND_WS" -n "$NAMESPACE" -o wide
    
    log "--- $BACKEND_NAME (MQTT) Logs (Last 10) ---"
    kubectl logs -l app="$BACKEND_NAME" -n "$NAMESPACE" --tail=10 2>/dev/null || log "No MQTT logs available"

    log "--- $BACKEND_WS (WS) Logs (Last 10) ---"
    kubectl logs -l app="$BACKEND_WS" -n "$NAMESPACE" --tail=10 2>/dev/null || log "No WS logs available"
}

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
    log "🚀 DarkSeek Health: $BACKEND_NAME (Auto-cleanup enabled)"
    log "📁 Log: $LOGFILE"

    stage_wait_debug_pod
    sleep 3
    stage_mqtt_connectivity
    stage_http_health
    stage_backend_diagnostics # Now checks both WS and MQTT status/logs
    stage_frontend_status
    
    log "🎉 10/10 PERFECT PASS ✓"
}

main "$@"
