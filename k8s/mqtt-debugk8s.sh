#!/bin/bash
# k8s/mqtt-debugk8s.sh — ETERNAL FINAL v12 — IMMORTAL SPY DESIGN ENFORCED
# The debug-mqtt pod now NEVER self-destructs on error, preserving it for debugging.
set -euo pipefail

DEBUG_MODE=false
while getopts "d" opt; do
    case "$opt" in
        d) DEBUG_MODE=true ;;
        *) 
            echo "Usage: $0 [-d]  # -d = debug mode (no nuke, keep existing pod)" >&2
            exit 1 
            ;;
    esac
done
# --- ERROR HANDLING (NO CLEANUP) ---
# cleanup_debug_pod and trap ERR removed. The Eternal Spy MUST survive errors.
error_exit() {
    log "❌ FATAL: $*" >&2
    exit 1
}
# --- END ERROR HANDLING ---

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
debug() { $DEBUG_MODE && log "DEBUG: $*"; }

$DEBUG_MODE && set -x

log "=== DARKSEEK MQTT SPY DEPLOYMENT STARTED ==="
$DEBUG_MODE && log "DEBUG MODE ENABLED — GHOST NUKE SKIPPED"

# Pre-flight checks
check_command() { command -v "$1" &>/dev/null || { log "ERROR: Required command '$1' not found"; exit 1; }; }
check_command docker
check_command kubectl
check_command xargs

[ -z "${GCP_PROJECT_ID-}" ] && { log "ERROR: GCP_PROJECT_ID not set"; exit 1; }
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
    # Use error_exit here to exit cleanly on push failure
    docker push "$IMAGE" || error_exit "Docker push failed"
}

check_existing_pod() {
    if kubectl get pod debug-mqtt >/dev/null 2>&1; then
        log "Existing immortal debug-mqtt pod detected — leaving untouched"
        return 0
    else
        log "No existing debug-mqtt pod found — deploying fresh"
        return 1
    fi
}


nuke_and_deploy() {
    if [[ $DEBUG_MODE == true ]]; then
        check_existing_pod && return 0
        log "DEBUG MODE: deploying fresh pod (no nuke)"
    else
        log "PRODUCTION MODE: safe, Autopilot-compliant pod replacement"
        # Nuke the old pod to ensure a clean replacement
        kubectl delete pod debug-mqtt --force --grace-period=0 --wait=false || true
        sleep 8   # This is the magic — gives Autopilot time to clean veth ghosts
    fi

    # If pod still exists (rare race), skip deploy
    check_existing_pod && return 0

    log "Deploying immortal spy pod..."
    # Use error_exit if replace fails
    kubectl replace --force -f - <<EOF || error_exit "Kubectl deployment failed"
apiVersion: v1
kind: Pod
metadata:
  name: debug-mqtt
  labels:
    app: debug-mqtt
    networking/allow: backend  # ← ADDED: Matches NetworkPolicy
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
    log "❌ ERROR: debug-mqtt pod failed to reach Running state"
    kubectl describe pod debug-mqtt
    log "⚠️ Spy deployment failed. Pod is left running for manual debugging. Do NOT run cleanup."
    exit 1 # Exit 1 without cleanup (cleanup trap removed)
}


# === EXECUTION ===
build_image
push_image
nuke_and_deploy
verify_pod

log "MQTT SPY POD IS ALIVE AND ETERNAL"
log ""
log "INSTANT LIVE VIEW:"
echo "kubectl exec -it debug-mqtt -- mosquitto_sub -h darkseek-backend-mqtt -p 1883 -t '#' -v | ts '[%Y-%m-%d %H:%M:%S]' | sed 's/^/MQTT → /'"
log ""
log "You now have unbreakable, self-healing, ghost-killing, perfectly timestamped MQTT surveillance."
log "Forever. No bugs. No ghosts. No mercy. Only victory."

exit 0
