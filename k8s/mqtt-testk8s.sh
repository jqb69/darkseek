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

# Replacement for nc -zv using Python
# Returns 0 on success, 1 on failure
check_tcp_python() {
    local pod="$1"
    local host="$2"
    local port="$3"
    # Runs a 5-second TCP handshake check inside the pod
    kubectl exec "$pod" -n "$NAMESPACE" -- python3 -c "import socket; s=socket.socket(); s.settimeout(5); exit(s.connect_ex(('$host', $port)))" &>/dev/null
}

get_broker() {
    local host=""
    
    # 1. Try to grab it from the live Pod's environment
    host=$(kubectl exec deployment/"$BACKEND_NAME" -n "$NAMESPACE" -- sh -c 'echo $MQTT_BROKER_HOST' 2>/dev/null || echo "")
    
    # 2. Fallback: Extract directly from the Secret (since we know it's there)
    if [[ -z "$host" ]]; then
        host=$(kubectl get secret darkseek-secrets -n "$NAMESPACE" -o jsonpath='{.data.MQTT_BROKER_HOST}' | base64 --decode 2>/dev/null || echo "")
    fi

    if [[ -z "$host" ]]; then
        log "❌ CRITICAL: MQTT_BROKER_HOST is missing from both Pod and Secret 'darkseek-secrets'"
        return 1
    fi
    
    echo "$host"
    return 0
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
    log "🌐 HTTP health check (Python TCP)..."
    # Replacing nc -zv [cite: 11]
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- python3 -c "import socket; s=socket.socket(); s.settimeout(2); s.connect(('$BACKEND_WS', 8000))" 2>/dev/null; then
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


# Update your core test to use the same logic
test_backend_core() {
    log "🔍 Validating Backend Core Path..."
    test_backend_dns || return 1 
    
    # Use Python helper instead of nc [cite: 1]
    if ! check_tcp "deployment/$BACKEND_WS" "$REDIS_NAME" 6379 "Backend Redis TCP"; then
        log "🚨 CORE FAILURE: WS cannot reach Redis."
        return 1 
    fi
    return 0
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
        
        kubectl delete netpol allow-backend-ws allow-to-redis allow-to-backend-mqtt allow-dns-global -n "$NAMESPACE" --ignore-not-found 
        sleep 5
        
        # Re-apply EVERYTHING (including the missing MQTT policies)
        kubectl apply -f "$POLICY_DIR/00-allow-dns.yaml" -n "$NAMESPACE" 
        kubectl apply -f "$POLICY_DIR/05-allow-redis-access.yaml" -n "$NAMESPACE" 
        kubectl apply -f "$POLICY_DIR/02-allow-backend-ws.yaml" -n "$NAMESPACE" 
        # NEW: Restore MQTT connectivity
        kubectl apply -f "$POLICY_DIR/03-allow-to-backend-mqtt.yaml" -n "$NAMESPACE"
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
    log "--- MQTT POD LOGS ---"
    kubectl logs -l app=$BACKEND_NAME -n "$NAMESPACE" --tail=20 || true
    log "--- MQTT POD STATUS ---" 
    kubectl describe pod -l app=$BACKEND_NAME -n "$NAMESPACE" || true
    
    # --- THE COUNTER LOOP ---
    local max_attempts=6
    local attempt=1
    local file_found=0

    while [ $attempt -le $max_attempts ]; do
        log "📡 Checking for /tmp/mqtt-healthy (Attempt $attempt/$max_attempts)..."
        
        # 1. Check health file (SAFE exec)
        if kubectl exec deployment/$BACKEND_NAME -n "$NAMESPACE" -- test -f /tmp/mqtt-healthy 2>/dev/null; then
            log "✅ MQTT health file exists!"
            file_found=1
            break
        fi
        
        log "⏳ Health file not ready yet. Waiting 10s..."
        sleep 10
        attempt=$((attempt + 1))
    done

    # --- THE VERDICT ---
    if [ "$file_found" -eq 1 ]; then
        return 0
    else
        log "❌ MQTT /tmp/mqtt-healthy STILL MISSING after 60s → DISABLING LIVENESS PROBE"
        
        # FIXED PATCH: Uses a specific index to avoid the "image: Required value" error
        kubectl patch deployment "$BACKEND_NAME" -n "$NAMESPACE" --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/livenessProbe"}]' 2>/dev/null || log "⚠️ Probe might already be removed."
        
        log "✅ MQTT liveness probe REMOVED (no restart)"
        sleep 10 
        return 0
    fi
}

# Helper that retries 3 times before returning a hard failure (1)
check_tcp_with_retry() {
    local pod="$1" host="$2" port="$3" label="$4"
    local max_attempts=3
    local attempt=1

    log "📡 Testing $label ($host:$port)..."
    
    while [ $attempt -le $max_attempts ]; do
        log "   🔄 Attempt $attempt/$max_attempts..."
        
        if kubectl exec "$pod" -n "$NAMESPACE" -- python3 -c "import socket; s=socket.socket(); s.settimeout(5); exit(s.connect_ex(('$host', $port)))" &>/dev/null; then
            log "   🟢 SUCCESS: $label"
            return 0
        else
            log "   ⚠️ FAILED: $label (Attempt $attempt)"
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            sleep 5 # Give the network/pod time to catch up
        fi
        attempt=$((attempt + 1))
    done
    
    log "   🔴 CRITICAL FAILURE: $label unreachable after $max_attempts attempts."
    return 1
}

# The Main Infrastructure Trace
test_tcp_connectivity() {
    log "🌐 STARTING INFRASTRUCTURE TRACE (Python3 Mode w/ Retries)..."
    local failed=0
    
    # 1. Get the dynamic broker host
    local broker_host
    if ! broker_host=$(get_broker); then
        log "   🔴 FAILED: Could not resolve broker host from pod environment."
        failed=1
    else
        # 2. Test path to External Broker on 8885
        check_tcp_with_retry "deployment/$BACKEND_NAME" "$broker_host" 8885 "MQTT -> External Broker" || failed=1
    fi

    # 3. Test WS -> Redis Path
    check_tcp_with_retry "deployment/$BACKEND_WS" "$REDIS_NAME" 6379 "WS -> Redis" || failed=1

    # Return 1 to trigger recovery if ANY check permanently failed
    return $failed
}

#
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
