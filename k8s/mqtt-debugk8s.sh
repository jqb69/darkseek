#!/bin/bash
# k8s/mqtt-debugk8s.sh — ETERNAL FINAL v13 — WHITESPACE CLEANED
set -euo pipefail

DEBUG_MODE=false
while getopts "d" opt; do
    case "$opt" in
        d) DEBUG_MODE=true ;;
        *) echo "Usage: $0 [-d]"; exit 1 ;;
    esac
done

error_exit() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ❌ FATAL: $*" >&2
    exit 1
}

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
debug() { $DEBUG_MODE && log "DEBUG: $*"; }

$DEBUG_MODE && set -x

log "=== DARKSEEK MQTT SPY DEPLOYMENT STARTED ==="
$DEBUG_MODE && log "DEBUG MODE ENABLED"

check_command() { command -v "$1" &>/dev/null || error_exit "Required command '$1' not found"; }
check_command docker
check_command kubectl
check_command xargs

[ -z "${GCP_PROJECT_ID-}" ] && error_exit "GCP_PROJECT_ID not set"
GCP_PROJECT_ID=$(echo "$GCP_PROJECT_ID" | tr '[:upper:]' '[:lower:]')
readonly GCP_PROJECT_ID
readonly IMAGE="us-central1-docker.pkg.dev/${GCP_PROJECT_ID}/darkseek/debug-mqtt:latest"

build_image() {
    log "Building $IMAGE"
    docker build -t "$IMAGE" - <<EOF
FROM alpine:latest
RUN apk add --no-cache mosquitto-clients bash coreutils wget
CMD ["sleep", "infinity"]
EOF
}

push_image() {
    log "Pushing $IMAGE"
    docker push "$IMAGE" || error_exit "Docker push failed"
}

check_existing_pod() {
    kubectl get pod debug-mqtt >/dev/null 2>&1
}

nuke_and_deploy() {
    if $DEBUG_MODE; then
        check_existing_pod && { log "Existing debug-mqtt pod — leaving untouched"; return 0; }
        log "DEBUG MODE: deploying fresh pod"
    else
        log "PRODUCTION MODE: replacing pod"
        kubectl delete pod debug-mqtt --force --grace-period=0 --wait=false || true
        sleep 8
    fi

    check_existing_pod && return 0

    log "Deploying immortal spy pod..."
    kubectl replace --force -f - <<EOF || error_exit "Kubectl deployment failed"
apiVersion: v1
kind: Pod
metadata:
  name: debug-mqtt
  labels:
    app: debug-mqtt
    networking/allow: backend
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
        [[ "$phase" == "Running" ]] && { log "POD IS RUNNING — SPY IS ALIVE"; return 0; }
        log "Pod phase: $phase — waiting... ($i/39)"
        sleep 2
    done
    log "❌ Pod failed to reach Running state"
    kubectl describe pod debug-mqtt
    log "⚠️ Spy left running for debugging"
    exit 1
}

build_image
push_image
nuke_and_deploy
verify_pod

log "MQTT SPY POD IS ALIVE AND ETERNAL"
echo "kubectl exec -it debug-mqtt -- mosquitto_sub -h darkseek-backend-mqtt -p 1883 -t '#' -v"
log "You now have unbreakable MQTT surveillance. Forever."
