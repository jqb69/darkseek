#!/bin/bash
# k8s/run-mqtt-tests-with-fix.sh — RECOVERY WRAPPER
set -Eeuo pipefail

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $1"; }

# --- RESILIENT VARIABLE HANDLER ---
# 1. Take from ENV (CronJob)
# 2. Else: Fetch from K8s Secret
# 3. Else: Fallback to Mosquitto Test Broker
MQTT_BROKER_HOST="${MQTT_BROKER_HOST:-$(kubectl get secret darkseek-secrets \
  -o jsonpath='{.data.MQTT_BROKER_HOST}' 2>/dev/null | base64 --decode 2>/dev/null || true)}"
export MQTT_BROKER_HOST="${MQTT_BROKER_HOST:-test.mosquitto.org}"

log "📡 Monitoring target: $MQTT_BROKER_HOST"

wait_for_debug_pod() {
  log "⏳ Waiting for debug-mqtt pod..."
  # single timeout; if it fails we just log and continue
  if ! kubectl wait --for=condition=Ready pod/debug-mqtt --timeout=30s 2>/dev/null; then
    log "⚠️ debug-mqtt pod not Ready within 30s (continuing anyway)"
  fi
}

# Ensure scripts are executable
chmod +x ./k8s/mqtt-testk8s.sh ./k8s/reset-network-state.sh ./k8s/mqtt-debugk8s.sh 2>/dev/null || true

log "🐛 Priming debug environment..."
./k8s/mqtt-debugk8s.sh || log "⚠️ mqtt-debugk8s.sh failed (continuing)"
wait_for_debug_pod

for attempt in 1 2; do
  log "🚀 Connectivity Check: Attempt $attempt/2"

  if ./k8s/mqtt-testk8s.sh; then
    log "✅ HEALTH CHECK PASS (attempt $attempt)"
    exit 0
  fi

  if [ "$attempt" -eq 1 ]; then
    log "⚠️ Attempt 1 failed. Triggering Network State Reset..."
    if [ -f "./k8s/reset-network-state.sh" ]; then
      ./k8s/reset-network-state.sh || log "⚠️ reset-network-state.sh failed"
      log "⏳ Waiting 15s for convergence..."
      sleep 15
      wait_for_debug_pod
    else
      log "⚠️ reset-network-state.sh not found, skipping reset."
    fi
  fi
done

log "💥 FINAL FAILURE: Connectivity could not be restored."
exit 1
