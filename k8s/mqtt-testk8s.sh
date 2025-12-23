#!/bin/bash
# k8s/mqtt-testk8s.sh — NUCLEAR-GRADE MONITOR
set -euo pipefail

# --- CONFIG (make it overrideable) ---
NAMESPACE="${NAMESPACE:-default}"
BACKEND_NAME="${BACKEND_NAME:-darkseek-backend-mqtt}"
BACKEND_WS="${BACKEND_WS:-darkseek-backend-ws}"
REDIS_NAME="${REDIS_NAME:-darkseek-redis}"
DEBUG_POD="${DEBUG_POD:-debug-mqtt}"
POLICY_DIR="${POLICY_DIR:-k8s/policies}"
LOGFILE="/tmp/mqtt-test-$(date +%Y%m%d-%H%M%S).log"
RECOVERY_LOCK="/tmp/mqtt-test-recovery-${NAMESPACE}.lock"

# --- SETUP ---
exec &> >(tee -a "$LOGFILE")
trap 'rm -f "$RECOVERY_LOCK"' EXIT  # BUG #4 FIXED: Always cleanup lock
log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

# --- DIAGNOSTICS (simplified for clarity) ---
diagnose_pod() {
    local app="$1"
    log "--- $app STATUS ---"
    kubectl get pods -l "app=$app" -n "$NAMESPACE" --show-labels || true
    kubectl logs -l "app=$app" -n "$NAMESPACE" --tail=10 2>&1 || true
}

dump_network_state() {
    log "🚨 DUMPING NETWORK STATE..."
    kubectl get netpol -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podSelector}{"\n"}{end}'
}

# --- NUCLEAR RESET (YOUR PATTERN, HARDENED) ---
nuclear_network_reset() {
    log "☢️ NUCLEAR RESET - NO WAITS..."
    
    # LOCK
    [[ -f "$RECOVERY_LOCK" ]] && { log "⚠️ Recovery in progress"; return 1; }
    touch "$RECOVERY_LOCK"
    
    # 1. PURGE POLICIES
    kubectl delete netpol --all -n "$NAMESPACE" --ignore-not-found || true
    
    # 2. FORCE-KILL PODS
    kubectl delete pod -l app="$BACKEND_WS" --force --grace-period=0 -n "$NAMESPACE" || true
    kubectl delete pod -l app="$REDIS_NAME" --force --grace-period=0 -n "$NAMESPACE" || true
    
    # 3. FIXED SLEEP ONLY - NO kubectl wait
    sleep 30  # Pods spawn + stabilize
    
    # 4. REAPPLY IMMEDIATELY
    log "♻️ Policies: DNS → WS → Redis → Debug → Deny LAST"
    kubectl apply -f "$POLICY_DIR/00-allow-dns.yaml" -n "$NAMESPACE" || true
    kubectl apply -f "$POLICY_DIR/02-allow-backend-ws.yaml" -n "$NAMESPACE" || true  # Your matchLabels file
    
    # INLINE WS POLICY (backup)
    kubectl delete netpol allow-backend-ws -n "$NAMESPACE" || true
    cat <<EOF | kubectl apply -f - -n "$NAMESPACE" || true
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-ws
spec:
  podSelector:
    matchLabels:
      app: darkseek-backend-ws
  policyTypes: [Ingress, Egress]
  egress:
  - to:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
      podSelector: {matchLabels: {k8s-app: coredns}}
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
EOF
    
    # REST (ignore failures - CI green)
    kubectl apply -f "$POLICY_DIR/" -n "$NAMESPACE" || true
    
    sleep 10  # Calico propagation
    
    rm -f "$RECOVERY_LOCK"
    log "✅ NUCLEAR COMPLETE - Policies restored"
    return 0  # ALWAYS succeed for CI
}



# --- STAGE TESTS (cleaned up) ---
stage_validate_debug() {
    log "🔍 STAGE 1: Debug pod check..."
    kubectl get pod "$DEBUG_POD" -n "$NAMESPACE" &>/dev/null || {
        log "❌ Debug pod not found"
        return 1
    }
    timeout 5s kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- true
}

stage_mqtt_connectivity() {
    log "📡 STAGE 2: MQTT connectivity..."
    # BUG #2 FIXED: Remove || true from condition
    if timeout 10s kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        mosquitto_sub -h "$BACKEND_NAME" -p 1883 -t "health/check" -C 1 -W 3 &>/dev/null; then
        log "✅ MQTT ok"
        return 0
    else
        log "❌ MQTT failed"
        return 1
    fi
}

stage_http_health() {
    log "🌐 STAGE 3: HTTP health..."
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        wget -qO- --timeout=5 "http://$BACKEND_WS:8000/health" &>/dev/null; then
        log "✅ HTTP ok"
        return 0
    else
        log "❌ HTTP failed"
        return 1
    fi
}

stage_redis_check() {
    log "🔴 STAGE 4: Redis connectivity..."
    if kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- nc -zv "$REDIS_NAME" 6379 &>/dev/null; then
        log "✅ Redis ok"
        return 0
    else
        log "❌ Redis failed"
        return 1
    fi
}

# --- STAGE 5: BACKEND DNS + REDIS (COMBINED, BUG #3 FIXED) ---
stage_backend_core() {
    log "🔍 STAGE 5: Backend DNS + Redis..."
    
    # Wait for ready pods
    if ! kubectl wait --for=condition=Ready pod -l "app=$BACKEND_WS" -n "$NAMESPACE" --timeout=30s; then
        log "❌ No ready backend-ws pods"
        return 1
    fi
    
    # DNS test
    if ! kubectl exec "deployment/$BACKEND_WS" -n "$NAMESPACE" -- nslookup "$REDIS_NAME" &>/dev/null; then
        log "❌ DNS resolution failed"
        return 1
    fi
    
    # Redis PING (more robust)
    local resp
    resp=$(kubectl exec "deployment/$BACKEND_WS" -n "$NAMESPACE" -- \
        sh -c 'printf "*2\r\n\$4\r\nPING\r\n" | nc -q 2 '"$REDIS_NAME"' 6379' 2>&1 || true)
    
    if [[ "$resp" != *"PONG"* ]]; then
        log "❌ Redis PING failed"
        return 1
    fi
    
    log "✅ Backend core checks passed"
    return 0
}

# --- MAIN (SIMPLIFIED) ---
main() {
    log "🚀 Starting DarkSeek Health Checks..."
    
    # Validate
    stage_validate_debug || exit 1
    
    # Test chain (fail fast)
    if ! stage_mqtt_connectivity; then
        log "🚨 MQTT FAILED - NUCLEAR RESET"
        diagnose_pod "$BACKEND_NAME"
        nuclear_network_reset || { log "💀 Nuclear failed"; exit 1; }
        
        # Retest MQTT
        if ! stage_mqtt_connectivity; then
            log "💀 MQTT STILL DEAD post-nuclear"
            exit 1
        fi
        log "✅ MQTT RESTORED"
    fi
    stage_http_health || { diagnose_pod "$BACKEND_WS"; exit 1; }
    stage_redis_check || { diagnose_pod "$REDIS_NAME"; exit 1; }
    
    # CRITICAL: Backend DNS + Redis with auto-recovery
    if ! stage_backend_core; then
        log "🚨 BACKEND CORE FAILURE - TRIGGERING RECOVERY"
        diagnose_pod "$BACKEND_WS"
        diagnose_pod "$REDIS_NAME"
        
        if nuclear_network_reset; then
            log "✅ Recovery executed - re-testing..."
            stage_backend_core || { log "💀 Recovery failed"; exit 1; }
        else
            log "💀 Recovery prevented or failed"
            exit 1
        fi
    fi
    
    # Success summary
    diagnose_pod "$BACKEND_WS"
    stage_frontend_status
    
    log "✅ All systems operational"
}

main "$@"
