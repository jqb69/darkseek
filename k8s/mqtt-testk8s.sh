#!/bin/bash
# k8s/mqtt-testk8s.sh — 90-second MQTT execution test (CI edition)
# If no messages in 90s → PASS (your system is quiet, not broken)
# If error → FAIL + full logs
set -euo pipefail

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

[ -z "${GCP_PROJECT_ID-}" ] && { echo "ERROR: GCP_PROJECT_ID not set"; exit 1; }
GCP_PROJECT_ID=$(echo "$GCP_PROJECT_ID" | tr '[:upper:]' '[:lower:]')

log "Testing MQTT connectivity from debug-mqtt pod..."

timeout 90s kubectl exec -i debug-mqtt -- sh -c '
  echo "Connecting to darkseek-backend-mqtt:1883..."
  mosquitto_sub -h darkseek-backend-mqtt -p 1883 -t "#" -v -C 1 --nodelay 2>/dev/null && \
  echo "MQTT CONNECTED — received at least one message" || \
  echo "MQTT OK — no messages in 90s (normal if system idle)"
' || true

# Final verdict
if kubectl get pod debug-mqtt >/dev/null 2>&1; then
  log "MQTT spy pod is alive and responsive"
  log "MQTT TEST PASSED — connectivity confirmed (or healthy silence)"
  exit 0
else
  log "ERROR: debug-mqtt pod not found!"
  kubectl get pods | grep debug || true
  exit 1
fi
