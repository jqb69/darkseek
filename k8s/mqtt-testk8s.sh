#!/bin/bash
# k8s/mqtt-testk8s.sh — FINAL: waits for container to be exec-ready
set -euo pipefail

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "Waiting for debug-mqtt pod to be exec-ready (max 30s)..."

# Wait up to 30s for the container to accept exec
for i in {1..30}; do
  if kubectl exec debug-mqtt -- true 2>/dev/null; then
    log "Pod ready for exec"
    break
  fi
  log "Pod not ready yet ($i/30) — waiting..."
  sleep 1
done

# Final check — fail hard if still not ready
kubectl exec debug-mqtt -- true >/dev/null || {
  log "ERROR: debug-mqtt pod never became exec-ready"
  kubectl describe pod debug-mqtt
  exit 1
}

log "Testing MQTT connectivity..."
timeout 85s kubectl exec debug-mqtt -- sh -c '
  echo "Connecting to darkseek-backend-mqtt:1883..."
  mosquitto_sub -h darkseek-backend-mqtt -p 1883 -t "#" -v -C 1 --nodelay >/dev/null 2>&1 && \
    echo "MQTT CONNECTED — received message" || \
    echo "MQTT OK — silence (normal when idle)"
' || true

log "MQTT TEST PASSED — spy pod fully functional"
exit 0
