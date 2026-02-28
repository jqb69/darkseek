#!/bin/bash
# k8s/run-mqtt-tests-with-fix.sh — RECOVERY WRAPPER
set -u

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $1"; }

# --- RESILIENT VARIABLE HANDLER ---
# 1. Take from ENV (CronJob)
# 2. Else: Fetch from K8s Secret
# 3. Else: Fallback to Mosquitto Test Broker
MQTT_BROKER_HOST=${MQTT_BROKER_HOST:-$(kubectl get secret darkseek-secrets -o jsonpath='{.data.MQTT_BROKER_HOST}' | base64 --decode 2>/dev/null)}
export MQTT_BROKER_HOST=${MQTT_BROKER_HOST:-"test.mosquitto.org"}

log "📡 Monitoring target: $MQTT_BROKER_HOST"

wait_for_debug_pod() {
    log "⏳ Waiting for debug-mqtt pod..."
    timeout 30 kubectl wait --for=condition=Ready pod/debug-mqtt --timeout=30s 2>/dev/null || true
}

# Ensure scripts are executable
chmod +x ./k8s/mqtt-testk8s.sh ./k8s/reset-network-state.sh 2>/dev/null || true

log "🐛 Priming debug environment..."
./k8s/mqtt-debugk8s.sh || true
wait_for_debug_pod

for attempt in 1 2; do
    log "🚀 Connectivity Check: Attempt $attempt/2"
    
    # Run the test script (inherits MQTT_BROKER_HOST via export)
    if ./k8s/mqtt-testk8s.sh; then
        log "✅ HEALTH CHECK PASS (attempt $attempt)"
        exit 0
    fi

    if [ "$attempt" -eq 1 ]; then
        log "⚠️ Attempt 1 failed. Triggering Network State Reset..."
        if [ -f "./k8s/reset-network-state.sh" ]; then
            ./k8s/reset-network-state.sh
            log "⏳ Waiting 15s for convergence..."
            sleep 15
            wait_for_debug_pod
        fi
    fi
done

log "💥 FINAL FAILURE: Connectivity could not be restored."
exit 1
