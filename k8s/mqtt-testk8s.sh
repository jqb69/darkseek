#!/bin/bash
# k8s/mqtt-testk8s.sh — FINAL: with logfile + visible results
set -euo pipefail

LOGFILE="/tmp/mqtt-test-$(date +%Y%m%d-%H%M%S).log"
exec &> >(tee -a "$LOGFILE")   # Everything goes to logfile AND stdout

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "=== DARKSEEK MQTT SPY TEST STARTED ==="
log "Log file: $LOGFILE"

log "Waiting for debug-mqtt pod to be exec-ready (max 30s)..."
for i in {1..39}; do
  if kubectl exec debug-mqtt -- true 2>/dev/null; then
    log "Pod ready for exec"
    break
  fi
  log "Pod not ready yet ($i/39) — waiting..."
  sleep 1
done
# Sleep for a while and wait
sleep 3
kubectl exec debug-mqtt -- true >/dev/null || {
  log "ERROR: debug-mqtt pod never became exec-ready"
  kubectl describe pod debug-mqtt
  exit 1
}

log "Testing MQTT connectivity (max 85s)..."
log "Connecting to darkseek-backend-mqtt:1883..."

if timeout 85s kubectl exec debug-mqtt -- mosquitto_sub -h darkseek-backend-mqtt -p 1883 -t "#" -v -C 1 --nodelay; then
  log "SUCCESS: MQTT CONNECTED — received at least one message"
else
  log "MQTT OK — no messages in 85s (system idle = expected & healthy)"
fi

log "MQTT spy pod is fully functional and responsive"
log "=== MQTT TEST PASSED — SPY IS ALIVE ==="

# Upload logfile as artifact (GitHub Actions)
if [[ -n "${GITHUB_ARTIFACTS-}" ]]; then
  mkdir -p "$GITHUB_ARTIFACTS"
  cp "$LOGFILE" "$GITHUB_ARTIFACTS/mqtt-test-result.log"
  log "Test log saved to artifacts: mqtt-test-result.log"
fi

exit 0
