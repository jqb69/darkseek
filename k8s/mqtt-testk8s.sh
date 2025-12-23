#!/bin/bash
# k8s/mqtt-testk8s.sh — STABLE MONITOR
# RESTORED WITH ENHANCED DIAGNOSTICS AND ROBUST STAGE 7 DNS/REDIS LOGIC

set -euo pipefail

NAMESPACE="default"
BACKEND_NAME="darkseek-backend-mqtt"
BACKEND_WS="darkseek-backend-ws"
REDIS_NAME="darkseek-redis"
DEBUG_POD="debug-mqtt"
LOGFILE="/tmp/mqtt-test-$(date +%Y%m%d-%H%M%S).log"

exec &> >(tee -a "$LOGFILE")

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

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
    local POD=$(kubectl get pods -l app="$PODNAME" -n "$NAMESPACE" -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2>/dev/null | head -n 1 || echo "")
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

dump_network_diagnostics() {
    log "🚨 STAGE 7 FAILURE - DUMPING NETWORK STATE..."
    
    echo "=== ALL NETWORKPOLICIES YAML DUMP ==="
    kubectl get netpol -n "$NAMESPACE" -o yaml
    
    echo "=== WS POD LABELS ==="
    kubectl get pod -l app=darkseek-backend-ws -n "$NAMESPACE" -o yaml | grep -A10 "labels:"
    
    echo "=== POLICY SELECTORS ==="
    kubectl get netpol -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podSelector}{"\n"}{end}'
    
    echo "=== WS POD ATTACHED POLICIES ==="
    kubectl get netpol allow-backend-ws -n "$NAMESPACE" -o yaml | grep -A15 podSelector -B5
}


nuclear_network_reset() {
    log "☢️ STAGE 7 FAILURE DETECTED: Triggering Recovery..."
    
    dump_network_diagnostics
    
    log "🗑️ Purging ALL NetPols..."
    kubectl delete netpol --all -n "$NAMESPACE" --timeout=30s || true
    
    log "🔄 ROLLING RESTART WS (clears CNI cache)..."
    kubectl rollout restart deployment/$BACKEND_WS -n "$NAMESPACE"
    kubectl rollout status deployment/$BACKEND_WS -n "$NAMESPACE" --timeout=90s || true
    
    sleep 15  # WS pods READY
    
    log "♻️ CRITICAL ORDER - NO DENY-ALL UNTIL LAST..."
    
    # 1. DNS FIRST (WS needs this IMMEDIATELY)
    kubectl apply -f k8s/policies/00-allow-dns.yaml -n "$NAMESPACE" && sleep 5
    
    # 2. WS EGRESS SECOND (before any deny)
    kubectl apply -f k8s/policies/02-allow-backend-ws.yaml -n "$NAMESPACE" && sleep 5
    
    # 3. DB/Redis (WS dependencies)
    kubectl apply -f k8s/policies/04-allow-db-access.yaml -n "$NAMESPACE" && sleep 2
    kubectl apply -f k8s/policies/05-allow-redis-access.yaml -n "$NAMESPACE" && sleep 2
    
    # 4. DENY-ALL LAST (after WS is protected)
    kubectl apply -f k8s/policies/01-deny-all.yaml -n "$NAMESPACE" && sleep 3
    
    # 5. Rest safe
    kubectl apply -f k8s/policies/ -n "$NAMESPACE"
    
    log "✅ WS-PROTECTED RECOVERY COMPLETE"
}


# --- STAGE 1: WAIT FOR POD READY ---
stage_wait_debug_pod() {
    log "⏳ STAGE 1: Checking debug pod '$DEBUG_POD'..."
    if ! timeout 5 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- true 2>/dev/null; then
        log "ERROR: Pod $DEBUG_POD not responding."
        return 1
    fi
    log "✓ Debug pod ready"
    return 0
}

# --- STAGE 2: MQTT CONNECTIVITY ---
stage_mqtt_connectivity() {
    log "📡 STAGE 2: MQTT $BACKEND_NAME:1883..."
    if timeout 10s kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        mosquitto_sub -h "$BACKEND_NAME" -p 1883 -t "health/check" -C 1 -W 3 >/dev/null 2>&1 || true; then
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
        return 0
    else
        log "❌ HTTP /health: FAILED"
        return 1
    fi
}

# --- STAGE 4: REDIS CHECK (DEBUG POD) ---
stage_redis_check() {
    log "🔴 STAGE 4: Redis Connectivity ($REDIS_NAME:6379) from Debug Pod..."
    if ! kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        /bin/sh -c "nc -zv $REDIS_NAME 6379" >/dev/null 2>&1; then
        log "❌ Redis connectivity failed from debug-mqtt"
        return 1
    fi
    
    log "✅ Redis connectivity passed from debug-mqtt"
    return 0
}

# --- STAGE 7: BACKEND DNS + REDIS (UPDATED ROBUST LOGIC) ---
stage_backend_dns() {
    log "🔍 STAGE 7: Backend-WS DNS + Redis from darkseek-backend-ws..."
    
    # Check if ANY pod is READY (handles 0/1 case)
    local READY_PODS=$(kubectl get pods -l app=darkseek-backend-ws --no-headers 2>/dev/null | grep "1/1" | wc -l)
    if [ "$READY_PODS" -eq 0 ]; then
        log "❌ No READY backend-ws pods (0/1 state detected)"
        kubectl get pods -l app=darkseek-backend-ws
        return 1
    fi
    
    log "✅ $READY_PODS READY backend-ws pods found"
    
    # Now test DNS from deployment (picks healthy pod)
    kubectl exec deployment/$BACKEND_WS -- nslookup darkseek-redis >/dev/null 2>&1 && \
        log "✅ Backend-WS → nslookup: RESOLVES ✓" || { log "❌ DNS fail"; return 1; }
    
    # Redis PING
    kubectl exec deployment/$BACKEND_WS -- bash -c "echo -e 'PING\r\nQUIT\r\n' | nc darkseek-redis 6379 2>/dev/null" | grep -q "^+PONG" && \
        log "✅ Backend-WS → Redis: +PONG ✓" || { log "❌ Redis PING fail"; return 1; }
}

stage_7check(){
    
    # STAGE 7: Backend-WS DNS + Redis
    if ! kubectl exec deployment/$BACKEND_WS -- nslookup darkseek-redis &>/dev/null; then
      log "❌ DNS fail"
      
      # GEMINI'S SMOKING GUN
      dump_network_diagnostics
      
      # GEMINI'S NUCLEAR RECOVERY
      nuclear_network_reset
      
      # RETEST
      if kubectl exec deployment/$BACKEND_WS -- nslookup darkseek-redis &>/dev/null; then
        log "✅ NUCLEAR RESET SUCCESS - DNS RESTORED"
      else
        log "💀 PERMANENT FAILURE - Manual intervention required"
        exit 0
      fi
    fi

}

stage_frontend_status() {
    log "🏠 STAGE 5: Frontend Check..."
    kubectl get svc darkseek-frontend -o wide || true
}

# --- MAIN (UPDATED EXECUTION FLOW) ---
main() {
    log "🚀 Starting DarkSeek Health Checks..."
    
    stage_wait_debug_pod || exit 1
    stage_mqtt_connectivity || exit 1
    
    # Check HTTP Health First
    if ! stage_http_health; then
        log "🚨 BACKEND HTTP FAILURE DETECTED"
        stage_pod_diagnostics "$DEBUG_POD"           # Check Client First
        stage_pod_diagnostics "$BACKEND_WS" # Check Server Second
        exit 0
    fi

    # Then Check Redis Connectivity
    if ! stage_redis_check; then
        log "🚨 REDIS FAILURE DETECTED"
        stage_pod_diagnostics "$DEBUG_POD"
        stage_pod_diagnostics "$REDIS_NAME"
        exit 0
    fi

    if ! stage_7check; then
        log "🚨 BACKEND-WS DNS/REDIS NC LOOKUP FAILURE"
        stage_pod_diagnostics "$BACKEND_WS"
        stage_pod_diagnostics "$REDIS_NAME"
        exit 0
    fi
    # Backend DNS + Redis (catches 500 errors)
    if ! stage_backend_dns; then
        log "🚨 BACKEND-WS DNS/REDIS FAILURE - 500 errors expected"
        stage_pod_diagnostics "$BACKEND_WS"
        stage_pod_diagnostics "$REDIS_NAME"
        exit 1
    fi

    # Summary diagnostics on success
    stage_pod_diagnostics "$DEBUG_POD"
    stage_pod_diagnostics "$BACKEND_WS"
    stage_pod_diagnostics "$BACKEND_NAME"
    stage_frontend_status

    log "✅ All tests passed"
    exit 0
}

main "$@"
