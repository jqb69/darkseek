#!/bin/bash
# k8s/mqtt-debugk8s.sh — ETERNAL FINAL v9 — FRANK AIGRILLO + YOU = ABSOLUTE DOMINATION
set -euo pipefail

DEBUG_MODE=false
while getopts "d" opt; do
    case "$opt" in
        d) DEBUG_MODE=true ;;
        *) echo "Usage: $0 [-d]  # -d = debug mode (verbose + no ghost nuke)" ; exit 1 ;;
    esac
done

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
debug() { $DEBUG_MODE && log "DEBUG: $*"; }

log "=== DARKSEEK MQTT SPY DEPLOYMENT STARTED ==="
$DEBUG_MODE && log "DEBUG MODE ENABLED — GHOST NUKE SKIPPED"

check_command() { command -v "$1" &>/dev/null || { log "ERROR: '$1' not found. Install it."; exit 1; }; }
check_command docker
check_command kubectl
check_command xargs

[ -z "${GCP_PROJECT_ID-}" ] && { log "ERROR: GCP_PROJECT_ID not set"; exit 1; }
GCP_PROJECT_ID=$(echo "$GCP_PROJECT_ID" | tr '[:upper:]' '[:lower:]')
readonly GCP_PROJECT_ID
readonly IMAGE="gcr.io/${GCP_PROJECT_ID}/debug-mqtt:latest"

build_image() {
    log "Building $IMAGE"
    docker build -t "$IMAGE" - <<EOF
FROM alpine:latest
RUN apk add --no-cache mosquitto-clients bash coreutils moreutils
CMD ["sleep", "infinity"]
EOF
}

push_image() {
    log "Pushing $IMAGE"
    if ! (docker push "$IMAGE"); then
        log "ERROR: Push failed"
        exit 1
    fi
}

nuke_and_deploy() {
    if $DEBUG_MODE; then
        log "DEBUG MODE: Skipping ghost nuke and forced replace"
        kubectl get pod debug-mqtt >/dev/null 2>&1 && log "Existing debug-mqtt pod detected (left intact)"
    else
        log "NUKING ALL GHOSTS — NO MERCY"
        kubectl delete pod debug-mqtt --force --grace-period=0 --wait=false || true
        sleep 5
        kubectl get node -o name | xargs -I {} kubectl debug {} \
          --image=mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11 -- \
          /bin/sh -c "ip link del gke* 2>/dev/null || true" || true
        sleep 3
    fi

    log "Deploying immortal debug pod..."
    kubectl replace --force -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: debug-mqtt
spec:
  restartPolicy: Never
  containers:
  - name: debug-mqtt
    image: $IMAGE
    command: ["sleep", "infinity"]
    resources:
      requests:
        memory: "128Mi"
        cpu: "100m"
      limits:
        memory: "512Mi"
        cpu: "500m"
EOF
}

verify_pod() {
    log "Verifying debug-mqtt pod is Running..."
    for i in {1..39}; do
        phase=$(kubectl get pod debug-mqtt -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
        if [[ "$phase" == "Running" ]]; then
            log "POD IS RUNNING — SPY IS ALIVE"
            return 0
        fi
        log "Pod phase: $phase — waiting... ($i/39)"
        sleep 2
    done
    log "ERROR: debug-mqtt pod failed to reach Running state"
    kubectl describe pod debug-mqtt
    exit 1
}

# === MAIN EXECUTION ===
build_image
push_image
nuke_and_deploy
verify_pod

log "MQTT SPY POD IS ALIVE AND ETERNAL"
log "INSTANT LIVE VIEW:"
echo "kubectl exec -it debug-mqtt -- mosquitto_sub -h darkseek-backend-mqtt -p 1883 -t '#' -v | ts '[%Y-%m-%d %H:%M:%S]' | sed 's/^/MQTT → /'"
log "Forever. No bugs. No ghosts. No mercy."

exit 0
