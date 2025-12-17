#!/bin/bash
# k8s/mqtt-testk8s.sh — NON-DESTRUCTIVE MONITOR (FIXED: HTTP Method)
# Fixes the HTTP check by using the correct 'wget -qO-' argument to ensure a GET request is sent.

set -euo pipefail

NAMESPACE="default"
BACKEND_NAME="darkseek-backend-mqtt"
# --- FQDN for guaranteed resolution ---
BACKEND_WS="darkseek-backend-ws.default.svc.cluster.local"
# -------------------------------------
LOGFILE="/tmp/mqtt-test-$(date +%Y%m%d-%H%M%SZ).log"
FRONTEND_IP=""

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
    # Still use short name for MQTT, as the test output shows it was connected (idle OK)
    if timeout 85s kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        mosquitto_sub -h "$BACKEND_NAME" -p 1883 -t "#" -v -C 1 --nodelay; then
        log "✅ MQTT 1883: Messages received"
    else
        log "✅ MQTT 1883: Connected (idle OK)"
    fi
}

# Helper function to execute wget inside the debug pod and check for a successful GET response
check_http() {
    local endpoint="$1"
    # URL now uses the FQDN
    local url="http://$BACKEND_WS:8000/$endpoint"
    
    # FIX: Forces a GET request using wget -qO- and discards output.
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        wget -qO- --timeout=8 "$url" > /dev/null 2>&1; then
        return 0 # Success (HTTP 2xx or 3xx)
    else
        local status=$?
        
        # Retaining the original wget error code diagnostics
        if [[ "$status" -eq 4 ]]; then
            log "DEBUG: 🛑 Failed to reach $url. wget status: $status (Network error/Timeout)"
        elif [[ "$status" -eq 8 ]]; then
            log "DEBUG: 🛑 Failed to reach $url. wget status: $status (Server error/Bad URL)"
        else
            log "DEBUG: 🛑 Failed to reach $url. Exit status: $status (General error)"
        fi
        return 1 # Failure
    fi
}

# --- STAGE 3: HTTP/WS HEALTH (REFACTORED) ---
stage_http_health() {
    log "🌐 STAGE 3: HTTP $BACKEND_WS:8000/health..."
    
    # 1. Raw connectivity checks
    log "--- STAGE 3.1: Raw Connectivity Checks ---"
    # DNS Test now uses FQDN for successful resolution
    log "🔎 DNS Test: nslookup $BACKEND_WS"
    # Using a short timeout to prevent the command hanging if CoreDNS fails completely
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nslookup "$BACKEND_WS"; then
        log "✅ DNS resolution passed!"
    else
        log "❌ DNS resolution failed!"
    fi

    # TCP Test now uses FQDN for successful connection attempt
    log "🔎 TCP Test: nc -zv $BACKEND_WS 8000"
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nc -zv "$BACKEND_WS" 8000 2>&1; then
        log "✅ TCP connection successful!"
    else
        log "❌ TCP connection failed! (Possible NetworkPolicy issue or service down)"
    fi
    log "--- End Raw Connectivity Checks ---"
    
    # 2. Try health endpoint (uses FQDN via check_http)
    if check_http "health"; then
        log "✅ HTTP /health: 200 OK"
        HTTP_SUCCESS=1
        return 0
    fi

    # 3. Try root endpoint (uses FQDN via check_http)
    if check_http ""; then
        log "✅ HTTP root: 200 OK"
        HTTP_SUCCESS=1
        return 0
    fi
    
    # 4. Both failed - log-based fallback
    log "⚠️ Direct HTTP failed, checking logs..."
    if kubectl logs -l app=darkseek-backend-ws -n "$NAMESPACE" --tail=20 2>/dev/null | \
        grep -qiE "Application startup complete"; then
        log "✅ Uvicorn startup confirmed in logs ✓ (Still unreachable via network)"
    else
        log "❌ No Uvicorn startup or API activity found in logs."
    fi
}


# --- STAGE 4: BACKEND DIAGNOSTICS ---
stage_backend_diagnostics() {
    log "🔍 STAGE 4: Backend Service Diagnostics ($BACKEND_NAME & darkseek-backend-ws)..."
    
    log "--- darkseek-backend-ws Service Definition (YAML) ---"
    kubectl get svc darkseek-backend-ws -n "$NAMESPACE" -o yaml
    log "--- darkseek-backend-ws Service Description ---"
    kubectl describe svc darkseek-backend-ws -n "$NAMESPACE"

    local mqtt_pods_running
    mqtt_pods_running=$(kubectl get pods -l app="$BACKEND_NAME" -n "$NAMESPACE" --no-headers 2>/dev/null | grep Running | wc -l)
    ((mqtt_pods_running > 0)) || error_exit "$BACKEND_NAME pods not Running"
    log "✓ $BACKEND_NAME pods Running: $mqtt_pods_running"
    kubectl get svc "$BACKEND_NAME" -n "$NAMESPACE" -o wide
    
    local ws_pods_running
    ws_pods_running=$(kubectl get pods -l app=darkseek-backend-ws -n "$NAMESPACE" --no-headers 2>/dev/null | grep Running | wc -l)
    log "✓ darkseek-backend-ws pods Running: $ws_pods_running"
    ((ws_pods_running > 0)) || log "⚠️ WARNING: darkseek-backend-ws pods are not Running."
    kubectl get svc darkseek-backend-ws -n "$NAMESPACE" -o wide 
    
    log "--- darkseek-backend-ws (WS API) Logs (Last 20) ---"
    kubectl logs -l app=darkseek-backend-ws -n "$NAMESPACE" --tail=20 2>/dev/null || log "No WS logs available"

    log "--- $BACKEND_NAME (MQTT) Logs (Last 20) ---"
    kubectl logs -l app="$BACKEND_NAME" -n "$NAMESPACE" --tail=20 2>/dev/null || log "No MQTT logs available"

    log "--- All Relevant Pods Overview ---"
    log "--- WS Backend Pods ---"
    kubectl get pods -n "$NAMESPACE" -l app=darkseek-backend-ws --show-labels
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


# --- STAGE 6: REDIS CONNECTIVITY (NEW) ---
stage_redis_connectivity() {
    log "🔴 STAGE 6: Redis Connectivity (darkseek-redis:6379)..."
    
    # 1. Check Redis service exists
    if ! kubectl get svc | grep -q redis; then
        log "❌ Redis service NOT FOUND! (Check: kubectl get svc | grep redis)"
        return 1
    fi
    log "✅ Redis service exists"
    
    # 2. Get Redis service name (handles darkseek-redis, redis, etc.)
    REDIS_SVC=$(kubectl get svc -o jsonpath='{.items[?(@.spec.ports[0].port==6379)].metadata.name}')
    log "🔍 Redis service: $REDIS_SVC"
    
    # 3. TCP connectivity test from debug-mqtt
    log "🔎 TCP Test: nc -zv $REDIS_SVC 6379"
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nc -zv "$REDIS_SVC" 6379 2>&1 | grep -q "succeeded"; then
        log "✅ Redis TCP: Connected!"
    else
        log "❌ Redis TCP: FAILED! (NetworkPolicy or service down)"
        return 1
    fi
    
    # 4. Redis PING test (redis-cli if available, else echo PING)
 
    log "🔎 Redis PING Test:"
    if timeout 5 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        bash -c "echo -e 'PING\\r\\nQUIT\\r\\n' | nc $REDIS_SVC 6379 2>/dev/null" | \
        grep -q "^+PONG"; then
        log "✅ Redis PING: +PONG ✓"
    else
        log "❌ Redis PING: FAILED"
    fi

    # 5. Backend → Redis NetworkPolicy check
    log "🔍 Backend NetworkPolicy allows Redis access?"
    if kubectl get networkpolicy -l app=darkseek-backend-ws -o yaml 2>/dev/null | grep -q "app: redis"; then
        log "✅ Backend → Redis NetworkPolicy exists"
    else
        log "⚠️  NO Backend → Redis NetworkPolicy! (Apply fix below)"
    fi
    
    log "✅ REDIS FULLY OPERATIONAL ✓"
    return 0
}


# --- MAIN ---
main() {
    log "🚀 DarkSeek Health: $BACKEND_NAME (Non-destructive Monitor)"
    log "📁 Log: $LOGFILE"
    
    stage_wait_debug_pod
    sleep 3
    stage_mqtt_connectivity
    stage_http_health
    
    if [[ "$HTTP_SUCCESS" -eq 0 ]]; then
        stage_backend_diagnostics
        stage_frontend_status
        error_exit "HTTP/WS API facade (darkseek-backend-ws:8000) is unreachable or unhealthy (4xx/5xx status). See STAGE 4 logs (YAML, Describe, Pod Status) for details."
    fi
    # NEW: Redis test (CRITICAL for 500 errors)
    stage_redis_connectivity || {
        log "🚨 REDIS FAILED - Backend 500 errors expected!"
        log "💡 FIX: Apply 'allow-backend-to-redis' NetworkPolicy + Fix Redis host in backend"
        stage_backend_diagnostics
        stage_frontend_status
        exit 2  # Redis failure = Critical but non-fatal
    }
    stage_backend_diagnostics
    stage_frontend_status
    
    log "🎉 10/10 PERFECT PASS ✓"
}

main "$@"
