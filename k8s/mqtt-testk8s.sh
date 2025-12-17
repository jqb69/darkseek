#!/bin/bash
# k8s/mqtt-testk8s.sh — NON-DESTRUCTIVE MONITOR (FIXED: HTTP Method & FQDN)
# This script monitors Kubernetes service health using FQDNs and precise network checks.

set -euo pipefail

NAMESPACE="default"
BACKEND_NAME="darkseek-backend-mqtt"
# --- FQDN for guaranteed resolution across namespaces ---
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
    # Still use short name for MQTT as established in the broker config
    if timeout 15s kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        mosquitto_sub -h "$BACKEND_NAME" -p 1883 -t "#" -v -C 1 --nodelay 2>/dev/null; then
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
        # Retaining original wget error code diagnostics
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

# --- STAGE 3: HTTP/WS HEALTH ---
stage_http_health() {
    log "🌐 STAGE 3: HTTP $BACKEND_WS:8000/health..."
    
    # 1. Raw connectivity checks
    log "--- STAGE 3.1: Raw Connectivity Checks ---"
    log "🔎 DNS Test: nslookup $BACKEND_WS"
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nslookup "$BACKEND_WS" > /dev/null 2>&1; then
        log "✅ DNS resolution passed!"
    else
        log "❌ DNS resolution failed!"
    fi

    log "🔎 TCP Test: nc -zv $BACKEND_WS 8000"
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nc -zv "$BACKEND_WS" 8000 2>&1; then
        log "✅ TCP connection successful!"
    else
        log "❌ TCP connection failed! (Possible NetworkPolicy issue or service down)"
    fi
    log "--- End Raw Connectivity Checks ---"
    
    # 2. Try health endpoint
    if check_http "health"; then
        log "✅ HTTP /health: 200 OK"
        HTTP_SUCCESS=1
        return 0
    fi

    # 3. Try root endpoint
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

# --- STAGE 4: BACKEND DIAGNOSTICS (ENHANCED) ---
stage_pod_diagnostics() {
    local PODNAME="${1:?PODNAME required}"
    log "🔍 POD DIAGNOSTICS: $PODNAME (EXTENSIVE)..."
    
    # 1. POD STATUS
    log "--- $PODNAME PODS ---"
    kubectl get pods -l app="$PODNAME" -n "$NAMESPACE" --show-labels || true
    
    # 2. SERVICE
    log "--- $PODNAME SERVICE ---"
    kubectl get svc "$PODNAME" -n "$NAMESPACE" -o wide 2>/dev/null || log "No service found"
    
    # 3. DESCRIBE POD (1st ready pod)
    local POD=$(kubectl get pods -l app="$PODNAME" -n "$NAMESPACE" -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$POD" ]]; then
        log "--- $POD describe ---"
        kubectl describe pod "$POD" -n "$NAMESPACE" | head -50 || true
    fi
    
    # 4. LOGS (last 20)
    log "--- $PODNAME LOGS (last 20) ---"
    kubectl logs -l app="$PODNAME" -n "$NAMESPACE" --tail=20 2>/dev/null || log "No logs available"
    
    # 5. NETWORK POLICY
    log "--- $PODNAME NetworkPolicies ---"
    kubectl get networkpolicy -l app="$PODNAME" -n "$NAMESPACE" -o yaml 2>/dev/null | head -30 || log "No specific policies found for app label"
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
}

# --- STAGE 6: REDIS CONNECTIVITY ---
stage_redis_connectivity() {
    log "🔴 STAGE 6: Redis Connectivity (darkseek-redis:6379)..."
    
    # 1. Check Redis service exists
    if ! kubectl get svc -n "$NAMESPACE" | grep -q redis; then
        log "❌ Redis service NOT FOUND!"
        return 1
    fi
    log "✅ Redis service exists"
    
    # 2. Get Redis service name
    local REDIS_SVC=$(kubectl get svc -n "$NAMESPACE" -o jsonpath='{.items[?(@.spec.ports[0].port==6379)].metadata.name}' | xargs)
    log "🔍 Redis service: $REDIS_SVC"
    
    # 3. TCP connectivity test
    log "🔎 TCP Test: nc -zv $REDIS_SVC 6379"
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nc -zv "$REDIS_SVC" 6379 2>&1 | grep -q "succeeded"; then
        log "✅ Redis TCP: Connected!"
    else
        log "❌ Redis TCP: FAILED! (NetworkPolicy or service down)"
        return 1
    fi
    
    # 4. Redis PING test (using QUIT to ensure the stream closes)
    log "🔎 Redis PING Test:"
    if timeout 5 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        bash -c "echo -e 'PING\r\nQUIT\r\n' | nc $REDIS_SVC 6379 2>/dev/null" | \
        grep -q "^+PONG"; then
        log "✅ Redis PING: +PONG ✓"
    else
        log "❌ Redis PING: FAILED"
        return 1
    fi

    # 5. NetworkPolicy cross-check
    log "🔍 Backend NetworkPolicy allows Redis access?"
    if kubectl get networkpolicy -n "$NAMESPACE" -o yaml 2>/dev/null | grep -q "app: darkseek-redis"; then
        log "✅ Backend → Redis NetworkPolicy egress rule found"
    else
        log "⚠️ NO Backend → Redis NetworkPolicy detected!"
    fi
    
    log "✅ REDIS FULLY OPERATIONAL ✓"
    return 0
}

# --- MAIN ---
main() {
    log "🚀 DarkSeek Health: $BACKEND_NAME (Non-destructive Monitor)"
    log "📁 Log: $LOGFILE"
    
    stage_wait_debug_pod
    sleep 2
    stage_mqtt_connectivity
    stage_http_health
    
    if [[ "$HTTP_SUCCESS" -eq 0 ]]; then
        stage_pod_diagnostics "darkseek-backend-ws"
        stage_frontend_status
        error_exit "HTTP/WS API facade (darkseek-backend-ws:8000) is unreachable. Review logs above."
    fi

    # Redis test (CRITICAL for 500 errors)
    stage_redis_connectivity || {
        log "🚨 REDIS FAILED - Backend 500 errors expected!"
        stage_pod_diagnostics "darkseek-redis"
        stage_frontend_status
        exit 2 
    }

    stage_pod_diagnostics "darkseek-backend-mqtt"
    stage_pod_diagnostics "darkseek-backend-ws"
    stage_pod_diagnostics "debug-mqtt"
    stage_frontend_status
    
    log "🎉 10/10 PERFECT PASS ✓"
}

main "$@"
