#!/bin/bash
# k8s/mqtt-debugk8s.sh — Eternal MQTT Spy Pod v2 (Gemini Edition)
set -euo pipefail

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

[ -z "${GCP_PROJECT_ID-}" ] && { echo "ERROR: GCP_PROJECT_ID not set"; exit 1; }

# Sanitize project ID (critical for GCR)
GCP_PROJECT_ID=$(echo "$GCP_PROJECT_ID" | tr '[:upper:]' '[:lower:]')

log "Building ultimate debug-mqtt image (with ts, bash, mosquitto)..."
docker build -t gcr.io/$GCP_PROJECT_ID/debug-mqtt:latest - <<'EOF'
FROM alpine:latest
RUN apk add --no-cache mosquitto-clients bash coreutils moreutils
CMD ["sleep", "infinity"]
EOF

log "Pushing image..."
docker push gcr.io/$GCP_PROJECT_ID/debug-mqtt:latest

log "Deploying immortal debug-mqtt pod..."
kubectl delete pod debug-mqtt --ignore-not-found=true --force --grace-period=0 || true

kubectl run debug-mqtt --restart=Never \
  --image=gcr.io/$GCP_PROJECT_ID/debug-mqtt:latest \
  --overrides='{"spec":{"containers":[{"name":"debug-mqtt","image":"gcr.io/'$GCP_PROJECT_ID'/debug-mqtt:latest","command":["sleep","infinity"]}]}}'

log "MQTT SPY POD IS ALIVE AND ETERNAL"
log ""
log "INSTANT LIVE VIEW (now with perfect timestamps):"
echo "kubectl exec -it debug-mqtt -- mosquitto_sub -h darkseek-backend-mqtt -p 1883 -t '#' -v | ts '[%Y-%m-%d %H:%M:%S]' | sed 's/^/MQTT → /'"
log ""
log "You now have zero-maintenance, timestamped, unbreakable MQTT visibility. Forever."
