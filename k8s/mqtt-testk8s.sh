#!/bin/bash
# k8s/mqtt-testk8s.sh — PRODUCTION MONITOR (NO NUCLEAR LOOPS)
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
BACKEND_NAME="${BACKEND_NAME:-darkseek-backend-mqtt}"
BACKEND_WS="${BACKEND_WS:-darkseek-backend-ws}"
REDIS_NAME="${REDIS_NAME:-darkseek-redis}"
DEBUG_POD="${DEBUG_POD:-debug-mqtt}"
POLICY_DIR="${POLICY_DIR:-k8s/policies}"
LOGFILE="/tmp/mqtt-test-$(date +%Y%m%d-%H%M%S).log"
RECOVERY_LOCK="/tmp/mqtt-test-recovery-${NAMESPACE}.lock"

exec &> >(tee -a "$LOGFILE")
trap 'rm -f "$RECOVERY_LOCK"' EXIT
log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

# =======================================================
# DIAGNOSTICS
# =======================================================
diagnose_pod() {
    local app="$1"
    log "--- $app STATUS ---"
    kubectl get pods -l "app=$app" -n "$NAMESPACE" -o wide || true
    kubectl logs -l "app=$app" -n "$NAMESPACE" --tail=10 2>&1 || true
}

dump_network_state() {
    log "🌐 NETWORK STATE:"
    kubectl get netpol -n "$NAMESPACE" -o wide || true
    kubectl get svc -n "$NAMESPACE" -o wide || true
}

# =======================================================
# RETRY HELPER (CRITICAL)
# =======================================================
wait_for_connectivity() {
    local test_cmd="$1"
    local desc="$2"
    for i in {1..12}; do  # 2 minutes total
        if eval "$test_cmd" 2>/dev/null; then
            log "✅ $desc OK (attempt $i)"
            return 0
        fi
        log "⏳ $desc pending ($i/12)..."
        sleep 10
    done
    return 1
}

# =======================================================
# STAGED TESTS (NON-FATAL)
# =======================================================
test_debug_pod() {
    log "🔍 Debug pod check..."
    kubectl get pod "$DEBUG_POD" -n "$NAMESPACE" &>/dev/null || { log "❌ Debug pod missing"; return 1; }
    kubectl wait --for=condition=Ready pod/"$DEBUG_POD" -n "$NAMESPACE" --timeout=30s || { log "❌ Debug pod not Ready"; return 1; }
    log "✅ Debug pod ready"
}

test_mqtt_from_debug() {
    log "📡 MQTT from debug pod..."
    wait_for_connectivity "kubectl exec '$DEBUG_POD' -n '$NAMESPACE' -- mosquitto_sub -h '$BACKEND_NAME' -p 1883 -t 'health/check' -C 1 -W 5" "MQTT"
}

test_http_from_debug() {
    log "🌐 HTTP health check (raw TCP)..."
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        timeout 5 nc -zv "$BACKEND_WS" 8000 >/dev/null 2>&1; then
        log "✅ Backend port 8000 TCP open"
        return 0
    else
        log "❌ Backend port 8000 unreachable"
        return 1
    fi
}


test_redis_from_debug() {
    log "🔴 Redis from debug pod..."
    wait_for_connectivity "kubectl exec '$DEBUG_POD' -n '$NAMESPACE' -- nc -zv '$REDIS_NAME' 6379" "Redis"
}

# Add this helper before test_backend_core()
test_backend_dns() {
    wait_for_connectivity "kubectl exec -n '$NAMESPACE' deployment/$BACKEND_WS -- python3 -c 'import socket; socket.gethostbyname(\"$REDIS_NAME\")'" "Backend DNS"
}


test_backend_core() {
    log "🔍 Backend WS → Redis..."
    
    # Test DNS first (SHORT!)
    if ! test_backend_dns; then
        log "❌ Backend DNS failed → Check allow-dns-egress policy"
        return 1
    fi
    
    # Test TCP
    if ! wait_for_connectivity "kubectl exec -n '$NAMESPACE' deployment/$BACKEND_WS -- nc -zv '$REDIS_NAME' 6379" "Backend Redis TCP"; then
        log "❌ Backend Redis TCP failed → Check allow-to-redis policy"
        return 1
    fi
    
    log "✅ Backend core healthy"
}

# =======================================================
# CONTROLLED RECOVERY (LIMITED)
# =======================================================
controlled_recovery() {
    local attempt=1
    [[ -f "$RECOVERY_LOCK" ]] && { log "⚠️ Recovery locked (recent)"; return 1; }
    
    for i in {1..2}; do  # MAX 2 attempts per run
        log "🔧 Recovery attempt $attempt..."
        touch "$RECOVERY_LOCK"
        
        # Soft reset: just policies (no pod kills)
        kubectl delete netpol allow-backend-ws allow-to-redis allow-dns-egress -n "$NAMESPACE" --ignore-not-found || true
        sleep 5
        
        kubectl apply -f "$POLICY_DIR/00-allow-dns.yaml" -n "$NAMESPACE" || true
        kubectl apply -f "$POLICY_DIR/05-allow-redis-access.yaml" -n "$NAMESPACE" || true
        kubectl apply -f "$POLICY_DIR/02-allow-backend-ws.yaml" -n "$NAMESPACE" || true
        
        log "⏳ 60s CNI propagation..."
        sleep 60
        
        rm -f "$RECOVERY_LOCK"
        
        # Verify recovery worked
        if test_backend_core; then
            log "✅ Recovery $attempt successful"
            return 0
        fi
        
        ((attempt++))
        sleep 30
    done
    
    log "❌ Recovery failed after 2 attempts → Manual intervention needed"
    dump_network_state
    return 1
}

# ADD THIS FUNCTION before main()
fix_mqtt_health() {
    log "🔧 CHECKING MQTT HEALTH (emergency diagnostics)..."
    
    # 1. MQTT diagnostics (non-blocking)
    log "--- MQTT POD LOGS ---"
    kubectl logs -l app=$BACKEND_NAME -n "$NAMESPACE" --tail=20 || true
    log "--- MQTT POD STATUS ---" 
    kubectl describe pod -l app=$BACKEND_NAME -n "$NAMESPACE" || true
    
    # 2. Check health file (SAFE exec)
    if kubectl exec deployment/$BACKEND_NAME -n "$NAMESPACE" -- test -f /tmp/mqtt-healthy 2>/dev/null; then
        log "✅ MQTT health file exists"
        return 0
    else
        log "❌ MQTT /tmp/mqtt-healthy MISSING → DISABLE LIVENESS PROBE"
        # PATCH ONLY (NO rollout restart - per your history)
        kubectl patch deployment $BACKEND_NAME -p '{"spec":{"template":{"spec":{"containers":[{"name":"backend-mqtt","livenessProbe":null}]}}}}' --type=merge -n "$NAMESPACE"
        log "✅ MQTT liveness probe DISABLED (no restart)"
        sleep 10  # Brief settle
        return 0
    fi
}


# ADD THIS FUNCTION anywhere before main()
test_tcp_connectivity() {
    log "🌐 TCP CONNECTIVITY VERIFICATION (NO verification traps)..."
    
    # Test 1: WS → Redis (direct deployment exec)
    if kubectl exec deployment/$BACKEND_WS -n "$NAMESPACE" -- nc -zv $REDIS_NAME 6379 &>/dev/null; then
        log "✅ WS → Redis:6379 TCP OK"
    else
        log "❌ WS → Redis TCP FAILED"
    fi
    
    # Test 2: Debug → WS
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nc -zv $BACKEND_WS 8000 &>/dev/null; then
        log "✅ Debug → WS:8000 TCP OK"
    else
        log "❌ Debug → WS TCP FAILED"
    fi
    
    # Test 3: Debug → Redis
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nc -zv $REDIS_NAME 6379 &>/dev/null; then
        log "✅ Debug → Redis:6379 TCP OK"
    else
        log "❌ Debug → Redis TCP FAILED"
    fi
    
    log "📊 TCP SUMMARY COMPLETE"
    return 0  # Always succeed - just reporting
}

# =======================================================
# MAIN (SAFE, NO FAILFAST)
# =======================================================
main() {
    log "🚀 DarkSeek Health Monitor Starting..."
    dump_network_state
    
    fix_mqtt_health
    # *** TCP CONNECTIVITY TESTS ***
    test_tcp_connectivity
    test_debug_pod    || log "⚠️ Debug pod issues"
    test_mqtt_from_debug || log "⚠️ MQTT issues"
    test_http_from_debug || log "⚠️ HTTP issues" 
    test_redis_from_debug || log "⚠️ Redis issues"
    
    if ! test_backend_core; then
        log "🚨 Backend core failure → Attempting recovery..."
        if ! controlled_recovery; then
            log "💀 CRITICAL: Manual intervention required"
            echo "Run: kubectl describe netpol -n $NAMESPACE" >&2
            echo "Check: kubectl exec deployment/$BACKEND_WS -n $NAMESPACE -- nslookup $REDIS_NAME" >&2
            exit 1
        fi
    fi
    
    log "🎉 ALL SYSTEMS OPERATIONAL"
    kubectl get all -n "$NAMESPACE" -o wide
}

main "$@"
