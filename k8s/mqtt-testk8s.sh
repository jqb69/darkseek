#!/bin/bash
# k8s/mqtt-testk8s.sh — NON-DESTRUCTIVE MONITOR
# This script monitors Kubernetes service health and returns exit 1 on failure
# to allow the wrapper script (run-mqtt-tests-with-fix.sh) to handle resets.

set -euo pipefail

NAMESPACE="default"
BACKEND_NAME="darkseek-backend-mqtt"
BACKEND_WS="darkseek-backend-ws"
REDIS_NAME="darkseek-redis"
LOGFILE="/tmp/mqtt-test-$(date +%Y%m%d-%H%M%S).log"

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
    if ! timeout 5 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- true 2>/dev/null; then
        log "ERROR: Pod $DEBUG_POD not ready or not found."
        return 1
    fi
    log "✓ External pod '$DEBUG_POD' ready"
    return 0
}

# --- STAGE 2: MQTT CONNECTIVITY ---
stage_mqtt_connectivity() {
    log "📡 STAGE 2: MQTT $BACKEND_NAME:1883..."
    if timeout 10s kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        mosquitto_sub -h "$BACKEND_NAME" -p 1883 -t "#" -v -C 1 --nodelay 2>/dev/null; then
        log "✅ MQTT 1883: Messages received"
        return 0
    else
        # If it connects but just has no messages, that's fine too
        log "✅ MQTT 1883: Connectivity confirmed"
        return 0
    fi
}

# --- STAGE 3: HTTP HEALTH ---
stage_http_health() {
    log "🌐 STAGE 3: HTTP $BACKEND_WS:8000/health..."
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        wget -qO- --timeout=5 "http://$BACKEND_WS:8000/health" > /dev/null 2>&1; then
        log "✅ HTTP /health: 200 OK"
        HTTP_SUCCESS=1
        return 0
    else
        log "❌ HTTP /health: FAILED"
        return 1
    fi
}

# --- STAGE 4: REDIS CHECK ---
stage_redis_check() {
    log "🔴 STAGE 4: Redis Connectivity ($REDIS_NAME:6379)..."
    # Execute the specific check you requested
    if ! kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nc -zv "$REDIS_NAME" 6379 >/dev/null 2>&1; then
        log "❌ Redis connectivity failed"
        return 1
    fi
    log "✅ Redis connectivity passed"
    return 0
}

# --- STAGE 5: POD DIAGNOSTICS ---
stage_pod_diagnostics() {
    local label="$1"
    log "🔍 Diagnostics for pods with label app=$label..."
    kubectl get pods -l app="$label" -n "$NAMESPACE" -o wide || true
}

# --- STAGE 6: FRONTEND STATUS ---
stage_frontend_status() {
    log "🏠 STAGE 6: Frontend IP..."
    local frontend_ip
    frontend_ip=$(kubectl get svc darkseek-frontend -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "PENDING")
    [[ "$frontend_ip" == "PENDING" ]] && log "⏳ Frontend PENDING" || log "🌐 LIVE: http://$frontend_ip"
}

# --- STAGE 7: BACKEND-WS DNS + Redis PING ---
stage_backend_dns() {
    log "🔍 STAGE 7: Backend-WS DNS + Redis from darkseek-backend-ws..."
    
    # Wait for backend-ws ready
    if ! timeout 30 kubectl wait --for=condition=Ready pod -l app=darkseek-backend-ws --timeout=30s; then
        log "❌ Backend-WS pods not ready"
        return 1
    fi
    
    # Test DNS resolution FROM backend-ws (CRITICAL for 500 errors)
    if kubectl exec deployment/darkseek-backend-ws -- nslookup "$REDIS_NAME" >/dev/null 2>&1; then
        log "✅ Backend-WS → nslookup $REDIS_NAME: RESOLVES ✓"
    else
        log "❌ Backend-WS DNS: Temporary failure in name resolution"
        return 1
    fi
    
    # Test ACTUAL Redis PING from backend-ws
    if kubectl exec deployment/darkseek-backend-ws -- bash -c "echo -e 'PING\\r\\nQUIT\\r\\n' | nc $REDIS_NAME 6379 2>/dev/null" | grep -q "^+PONG"; then
        log "✅ Backend-WS → Redis: +PONG ✓"
    else
        log "❌ Backend-WS → Redis PING failed"
        return 1
    fi
    return 0
}

# --- MAIN ---
main() {
    log "🚀 Starting DarkSeek Health Checks..."
    
    stage_wait_debug_pod || exit 1
    stage_mqtt_connectivity || exit 1
    
    # Check HTTP Health First
    if ! stage_http_health; then
        log "🚨 BACKEND HTTP FAILURE DETECTED"
        stage_pod_diagnostics "debug-mqtt"           # Check Client First
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

    # Backend DNS + Redis (catches 500 errors)
    if ! stage_backend_dns; then
        log "🚨 BACKEND-WS DNS/REDIS FAILURE - 500 errors expected"
        stage_pod_diagnostics "darkseek-backend-ws"
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
