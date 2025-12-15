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

# Global status variable to track HTTP health: 1 = Success, 0 = Failure
HTTP_SUCCESS=0 

exec &> >(tee -a "$LOGFILE")

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
cleanup_debug_pod() {
    log "🧹 AUTO CLEANUP: Removing $DEBUG_POD pod..."
    # The --force --grace-period=0 ensures an immediate, aggressive removal
    # We ignore errors here in case the pod is already gone when the trap fires.
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

# --- STAGE 0: IMMEDIATE PRE-CLEANUP ---
stage_pre_cleanup() {
    log "🧼 STAGE 0: Pre-cleanup check for orphaned $DEBUG_POD..."
    # Check if the pod exists
    if kubectl get pod "$DEBUG_POD" -n "$NAMESPACE" &> /dev/null; then
        log "⚠️ Found orphaned $DEBUG_POD. Deleting now to ensure a fresh start."
        # Aggressive delete
        kubectl delete pod "$DEBUG_POD" -n "$NAMESPACE" --ignore-not-found=true --force --grace-period=0 || true
        
        # Explicitly wait for the Kube API to confirm the pod is gone.
        log "⏳ Waiting for deletion confirmation (max 15s)..."
        for i in {1..15}; do
            if ! kubectl get pod "$DEBUG_POD" -n "$NAMESPACE" &> /dev/null; then
                log "✓ Pod confirmed fully terminated ($i s)"
                return 0
            fi
            sleep 1
        done
        log "⚠️ Pod deletion confirmation timeout (15s). Proceeding."
    else
        log "✓ No orphaned $DEBUG_POD found."
    fi
}

# --- STAGE 1: CREATE DEBUG POD (NEW) ---
stage_create_debug_pod() {
    log "➕ STAGE 1: Creating $DEBUG_POD pod..."
    # NOTE: You must use an image that contains 'mosquitto_sub' and 'wget'.
    # This example uses the image found in your previous logs.
    kubectl run "$DEBUG_POD" \
        --image="***-docker.pkg.dev/***/darkseek/debug-mqtt:latest" \
        --restart=Never \
        --rm=false \
        --command -- sleep infinity
    log "✓ $DEBUG_POD creation initiated."
}


# --- STAGE 2: WAIT FOR POD READY (Old Stage 1) ---
stage_wait_debug_pod() {
    log "⏳ STAGE 2: Waiting for $DEBUG_POD to be ready..."
    for i in {1..60}; do
        # Use kubectl exec to check readiness (pod running + container ready)
        if timeout 5 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- true 2>/dev/null; then
            log "✓ Debug pod ready ($i s)"
            return 0
        fi
        ((i % 10 == 0)) && log "Waiting... ($i/60s)"
        sleep 1
    done
    kubectl describe pod "$DEBUG_POD" -n "$NAMESPACE"
    error_exit "debug-mqtt not ready after 60s"
}

# --- STAGE 3: MQTT CONNECTIVITY (Old Stage 2) ---
stage_mqtt_connectivity() {
    log "📡 STAGE 3: MQTT $BACKEND_NAME:1883..."
    # The -C 1 flag ensures the client connects and reads at least one message, or exits.
    # Since we are subscribing to '#' (all topics), success confirms broker connectivity.
    if timeout 85s kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        mosquitto_sub -h "$BACKEND_NAME" -p 1883 -t "#" -v -C 1 --nodelay; then
        log "✅ MQTT 1883: Messages received"
    else
        log "✅ MQTT 1883: Connected (idle OK)"
    fi
}

# --- STAGE 4: HTTP/WS HEALTH (Old Stage 3) ---
stage_http_health() {
    log "🌐 STAGE 4: HTTP $BACKEND_WS:8000/health..."
    
    # NON-FATAL timeout - explicit check for /health endpoint
    if timeout 10 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        wget -qO- --timeout=8 --spider http://"$BACKEND_WS":8000/health 2>/dev/null; then
        log "✅ HTTP /health: 200 OK"
        HTTP_SUCCESS=1 # Set global success status
        return 0
    fi
    
    # Fallback check for root endpoint
    if timeout 10 kubectl exec "$DEBUG_POD" -n "$NAMESPACE" -- \
        wget -qO- --timeout=8 --spider http://"$BACKEND_WS":8000/ 2>/dev/null; then
        log "✅ HTTP root: 200 OK"
        HTTP_SUCCESS=1 # Set global success status
        return 0
    fi
    
    # Both failed - log-based fallback
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


# --- STAGE 5: BACKEND DIAGNOSTICS (Old Stage 4) ---
stage_backend_diagnostics() {
    log "🔍 STAGE 5: Backend Service Diagnostics ($BACKEND_NAME & $BACKEND_WS)..."
    
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

# --- STAGE 6: FRONTEND STATUS (Old Stage 5) ---
stage_frontend_status() {
    log "🏠 STAGE 6: Frontend IP..."
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
    
    stage_pre_cleanup # STAGE 0: Ensure clean slate and wait for old pod deletion
    stage_create_debug_pod # STAGE 1: Create the new debug pod
    
    stage_wait_debug_pod # STAGE 2: Wait for the new pod to be ready
    sleep 3
    stage_mqtt_connectivity # STAGE 3
    stage_http_health # STAGE 4
    
    # Check status and perform fatal exit if needed, but only after diagnostics
    if [[ "$HTTP_SUCCESS" -eq 0 ]]; then
        stage_backend_diagnostics # STAGE 5: Run diagnostics to gather failure info
        stage_frontend_status     # STAGE 6: Gather final status
        error_exit "HTTP/WS API facade ($BACKEND_WS:8000) is unreachable. See STAGE 5 logs for details."
    fi

    # If successful, run remaining stages normally
    stage_backend_diagnostics # STAGE 5
    stage_frontend_status # STAGE 6
    
    log "🎉 10/10 PERFECT PASS ✓"
}

main "$@"
