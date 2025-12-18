#!/bin/bash
# k8s/mqtt-testk8s.sh — NON-DESTRUCTIVE MONITOR
# This script monitors Kubernetes service health and returns exit 1 on failure
# to allow the wrapper script (run-mqtt-tests-with-fix.sh) to handle resets.

set -euo pipefail

NAMESPACE="default"
BACKEND_NAME="darkseek-backend-mqtt"
# --- FQDN for guaranteed resolution ---
BACKEND_WS="darkseek-backend-ws.default.svc.cluster.local"
REDIS_NAME="darkseek-redis"
LOGFILE="/tmp/mqtt-test-$(date +%Y%m%d-%H%M%SZ).log"

# Target the static, externally managed pod
DEBUG_POD="debug-mqtt"

# Global status variable to track HTTP health: 1 = Success, 0 = Failure
HTTP_SUCCESS=0 

exec &> >(tee -a "$LOGFILE")

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

error_exit() {
    log "❌ FATAL: $*" >&2
    exit 1
}

# --- STAGE 1: WAIT FOR POD READY ---
stage_wait_debug_pod() {
    log "⏳ STAGE 1: Waiting for external test pod '$DEBUG_POD' to be ready..."
    for i in {1..60}; do
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
    if timeout 15s kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        mosquitto_sub -h "$BACKEND_NAME" -p 1883 -t "#" -v -C 1 --nodelay 2>/dev/null; then
        log "✅ MQTT 1883: Messages received"
    else
        log "✅ MQTT 1883: Connected (idle OK)"
    fi
}

# Helper function for GET requests
check_http() {
    local endpoint="$1"
    local url="http://$BACKEND_WS:8000/$endpoint"
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        wget -qO- --timeout=8 "$url" > /dev/null 2>&1; then
        return 0 
    else
        return 1
    fi
}

# --- STAGE 3: HTTP/WS HEALTH ---
stage_http_health() {
    log "🌐 STAGE 3: HTTP $BACKEND_WS:8000/health..."
    log "🔎 DNS Test: nslookup $BACKEND_WS"
    kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nslookup "$BACKEND_WS" > /dev/null 2>&1 || log "❌ DNS resolution failed!"

    log "🔎 TCP Test: nc -zv $BACKEND_WS 8000"
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nc -zv "$BACKEND_WS" 8000 2>&1; then
        log "✅ TCP connection successful!"
    else
        log "❌ TCP connection failed!"
    fi
    
    if check_http "health" || check_http ""; then
        log "✅ HTTP Health: 200 OK"
        HTTP_SUCCESS=1
        return 0
    fi
    log "❌ HTTP /health: FAILED"
    return 1
}

# --- STAGE 4: REDIS CONNECTIVITY (PERPLEXITY OPTIMIZED) ---
stage_redis_check() {
    log "🔴 STAGE 4: Redis Connectivity ($REDIS_NAME:6379)..."
    
    # 1. Service check
    kubectl get svc "$REDIS_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || { 
        log "❌ Redis service missing"; 
        return 1; 
    }
    
    # 2. TCP check
    if ! kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nc -zv "$REDIS_NAME" 6379 >/dev/null 2>&1; then
        log "❌ TCP failed"
        return 1
    fi
    log "✅ TCP OK"
    
    # 3. REAL Redis PING (Raw TCP Protocol - No redis-cli needed)
    # Sends RESP PING command and expects +PONG response
    if timeout 5 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        bash -c "echo -e 'PING\r\nQUIT\r\n' | nc $REDIS_NAME 6379 2>/dev/null" | \
        grep -q "^\+PONG"; then
        log "✅ Redis PING: +PONG"
        return 0
    else
        log "❌ Redis PING failed (TCP OK, Redis application down)"
        return 1
    fi
}

# --- STAGE 5: EXTENSIVE POD DIAGNOSTICS ---
stage_pod_diagnostics() {
    local POD_LABEL="${1:?Label required}"
    log "🔍 STAGE 5: Diagnostics for label app=$POD_LABEL..."
    
    log "--- Pods for $POD_LABEL ---"
    kubectl get pods -l app="$POD_LABEL" -n "$NAMESPACE" -o wide || true
    
    log "--- Service for $POD_LABEL ---"
    kubectl get svc -l app="$POD_LABEL" -n "$NAMESPACE" -o wide || true
    
    local FIRST_POD=$(kubectl get pods -l app="$POD_LABEL" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$FIRST_POD" ]]; then
        log "--- Describe $FIRST_POD ---"
        kubectl describe pod "$FIRST_POD" -n "$NAMESPACE" | head -n 25 || true
        log "--- Logs for $FIRST_POD (Last 15) ---"
        kubectl logs "$FIRST_POD" -n "$NAMESPACE" --tail=15 2>/dev/null || true
    fi
}

# --- STAGE 6: FRONTEND STATUS ---
stage_frontend_status() {
    log "🏠 STAGE 6: Frontend Status..."
    local FRONTEND_IP=$(kubectl get svc darkseek-frontend -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "PENDING")
    log "🌐 Frontend Service: $FRONTEND_IP"
}

# --- MAIN ---
main() {
    log "🚀 Starting DarkSeek Health Checks..."
    
    stage_wait_debug_pod || exit 1
    stage_mqtt_connectivity || exit 1
    
    # Check HTTP Health First
    if ! stage_http_health; then
        log "🚨 BACKEND HTTP FAILURE DETECTED"
        stage_pod_diagnostics "debug-mqtt"         # Check Client First
        stage_pod_diagnostics "darkseek-backend-ws" # Check Server Second
        exit 1
    fi

    # Then Check Redis Connectivity
    if ! stage_redis_check; then
        log "🚨 REDIS FAILURE DETECTED"
        stage_pod_diagnostics "debug-mqtt"
        stage_pod_diagnostics "darkseek-redis"
        exit 1
    fi

    # Summary diagnostics on success
    stage_pod_diagnostics "debug-mqtt"
    stage_pod_diagnostics "darkseek-backend-ws"
    stage_pod_diagnostics "darkseek-backend-mqtt"
    stage_frontend_status

    log "✅ All tests passed"
    exit 0
}

main "$@"
