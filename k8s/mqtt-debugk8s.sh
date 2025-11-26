#!/bin/bash
# k8s/mqtt-debugk8s.sh — One-click MQTT live debugger pod
set -euo pipefail

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

[ -z "${GCP_PROJECT_ID-}" ] && { echo "ERROR: GCP_PROJECT_ID not set"; exit 1; }

log "Building debug-mqtt image..."
docker build -t gcr.io/$GCP_PROJECT_ID/debug-mqtt:latest - <<'EOF'
FROM alpine:latest
RUN apk add --no-cache mosquitto-clients bash coreutils
CMD ["sleep", "infinity"]
EOF

log "Pushing image..."
docker push gcr.io/$GCP_PROJECT_ID/debug-mqtt:latest

log "Deploying permanent debug-mqtt pod..."
kubectl delete pod debug-mqtt --ignore-not-found=true --force --grace-period=0 || true
kubectl run debug-mqtt --restart=Never --image=gcr.io/$GCP_PROJECT_ID/debug-mqtt:latest --overrides='
{
  "spec": {
    "containers": [{
      "name": "debug-mqtt",
      "image": "gcr.io/'$GCP_PROJECT_ID'/debug-mqtt:latest",
      "command": ["sleep", "infinity"]
    }]
  }
}' > /dev/null

log "MQTT debugger pod created!"
log ""
log "USAGE (instant live view):"
echo "   kubectl exec -it debug-mqtt -- mosquitto_sub -h darkseek-backend-mqtt -p 1883 -t '#' -v"
echo ""
echo "   Pretty with timestamps:"
echo "   kubectl exec -it debug-mqtt -- mosquitto_sub -h darkseek-backend-mqtt -p 1883 -t '#' -v | ts '[%Y-%m-%d %H:%M:%S]' | sed 's/^/MQTT → /'"
echo ""
log "You now have permanent, zero-maintenance MQTT spying. Forever."
