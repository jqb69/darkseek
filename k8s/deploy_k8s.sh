#!/bin/bash
# --- Deploy DarkSeek to GKE (Without DNS) ---
# Date: 2025-09-30
set -euo pipefail

NAMESPACE="default"
K8S_DIR="./k8s"
RETRY_APPLY=3
APPLY_SLEEP=3

# --- Utilities ---
log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
fatal() { echo "ERROR: $*" >&2; exit 1; }

# --- Error handler ---
on_error() {
  local exit_code=$?
  log "Script failed (exit code: $exit_code). Running cluster troubleshooting..."
  troubleshoot_k8s || true
  return $exit_code
}
trap 'on_error' ERR

# --- Check for kubectl ---
check_kubectl() {
  if ! command -v kubectl &> /dev/null; then
    log "'kubectl' not found — attempting to install..."
    curl -fsSL -o /tmp/kubectl "https://storage.googleapis.com/kubernetes-release/release/$(curl -fsSL https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
    command -v kubectl &> /dev/null || fatal "Failed to install kubectl."
    log "'kubectl' installed."
  else
    log "'kubectl' available."
  fi
}

# --- Validate Required Environment Variables ---
check_env_vars() {
  log "Validating required environment variables..."
  required_vars=(
    "GOOGLE_API_KEY" "GOOGLE_CSE_ID" "HUGGINGFACEHUB_API_TOKEN"
    "DATABASE_URL" "REDIS_URL"
    "MQTT_BROKER_HOST" "MQTT_BROKER_PORT" "MQTT_TLS" "MQTT_USERNAME" "MQTT_PASSWORD"
    "POSTGRES_USER" "POSTGRES_PASSWORD" "POSTGRES_DB"
  )
  for var in "${required_vars[@]}"; do
    if [ -z "${!var-}" ]; then
      fatal "Environment variable '$var' is not set."
    fi
  done
  log "All required environment variables are set."
}

# --- Validate Kubernetes Manifest Files ---
check_manifest_files() {
  log "Validating Kubernetes manifest files in '$K8S_DIR'..."
  required_files=(
    "configmap.yaml" "backend-ws-deployment.yaml" "backend-mqtt-deployment.yaml"
    "frontend-deployment.yaml" "db-deployment.yaml" "redis-deployment.yaml"
    "backend-ws-service.yaml" "backend-mqtt-service.yaml" "frontend-service.yaml"
    "db-service.yaml" "redis-service.yaml" "db-pvc.yaml"
  )
  for file in "${required_files[@]}"; do
    if [ ! -f "$K8S_DIR/$file" ]; then
      fatal "Required manifest file '$file' not found in '$K8S_DIR'."
    fi
  done
  log "All required manifest files are present."
}

# --- SERVER-SIDE DRY-RUN VALIDATION ---
dryrun_server() {
  log "Running server-side dry-run validation on all manifests..."
  if ! kubectl apply -f "$K8S_DIR/" --dry-run=server --validate=true; then
    fatal "Server-side validation failed. Fix YAML errors (e.g., value + valueFrom conflict)."
  fi
  log "Server-side dry-run passed. All manifests are valid."
}

# --- Apply with retry ---
apply_with_retry() {
  local file="$1"
  local i=0
  until [ $i -ge $RETRY_APPLY ]; do
    if kubectl apply -f "$file"; then
      return 0
    fi
    i=$((i + 1))
    log "Retrying $file ($i/$RETRY_APPLY) in $APPLY_SLEEP seconds..."
    sleep $APPLY_SLEEP
  done
  fatal "Failed to apply $file after $RETRY_APPLY attempts."
}

# --- Troubleshooting (keep your full version below) ---
troubleshoot_k8s() {
  log "=== begin automated troubleshoot_k8s ==="
  log "NAMESPACE=$NAMESPACE"
  log "1) PVC list:"
  kubectl get pvc -n "$NAMESPACE" || true
  log "2) Describe PVC 'db-pvc' (if present):"
  kubectl describe pvc db-pvc -n "$NAMESPACE" || true
  log "3) List PVs:"
  kubectl get pv || true
  log "4) Pods for darkseek-db and describe first pod:"
  kubectl get pods -n "$NAMESPACE" -l app=darkseek-db -o wide || true
  POD=$(kubectl get pods -n "$NAMESPACE" -l app=darkseek-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$POD" ]; then
    log "Describing pod $POD:"
    kubectl describe pod "$POD" -n "$NAMESPACE" || true
    log "Collecting logs from $POD:"
    kubectl logs "$POD" -n "$NAMESPACE" --all-containers=true || true
  else
    log "No darkseek-db pod found to describe/log."
  fi
  log "5) Last 30 cluster events (namespace):"
  kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -n 30 || true
  log "6) Node status and taints:"
  kubectl get nodes -o wide || true
  kubectl describe nodes | grep -E 'Name:|Taints:|Unschedulable|Allocatable' -A3 -B1 || true
  log "=== end automated troubleshoot_k8s ==="
}

# --- (Keep all your other functions: troubleshoot_pvc_and_nodes, check_db_initialization, etc.) ---
# ... [your existing functions go here] ...

# --- MAIN EXECUTION ---
log "Checking for kubectl..."
check_kubectl
[ ! -d "$K8S_DIR" ] && fatal "Kubernetes manifest directory '$K8S_DIR' not found."
check_env_vars
check_manifest_files
cd "$K8S_DIR"

log "Deploying DarkSeek to GKE without DNS..."

# Apply ConfigMap
kubectl apply -f configmap.yaml

# Create/Update Secret
log "Creating or updating darkseek-secrets..."
kubectl create secret generic darkseek-secrets \
  --from-literal=GOOGLE_API_KEY="${GOOGLE_API_KEY}" \
  --from-literal=GOOGLE_CSE_ID="${GOOGLE_CSE_ID}" \
  --from-literal=HUGGINGFACEHUB_API_TOKEN="${HUGGINGFACEHUB_API_TOKEN}" \
  --from-literal=DATABASE_URL="${DATABASE_URL}" \
  --from-literal=REDIS_URL="${REDIS_URL}" \
  --from-literal=MQTT_BROKER_HOST="${MQTT_BROKER_HOST}" \
  --from-literal=MQTT_BROKER_PORT="${MQTT_BROKER_PORT}" \
  --from-literal=MQTT_TLS="${MQTT_TLS}" \
  --from-literal=MQTT_USERNAME="${MQTT_USERNAME}" \
  --from-literal=MQTT_PASSWORD="${MQTT_PASSWORD}" \
  --from-literal=POSTGRES_USER="${POSTGRES_USER}" \
  --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  --from-literal=POSTGRES_DB="${POSTGRES_DB}" \
  --dry-run=client -o yaml | kubectl apply -f -

# === SERVER-SIDE DRY-RUN BEFORE ANY APPLY ===
dryrun_server

# === APPLY ALL MANIFESTS WITH RETRY ===
apply_with_retry backend-ws-deployment.yaml
apply_with_retry backend-mqtt-deployment.yaml
apply_with_retry frontend-deployment.yaml
apply_with_retry db-deployment.yaml
apply_with_retry redis-deployment.yaml
apply_with_retry backend-ws-service.yaml
apply_with_retry backend-mqtt-service.yaml
apply_with_retry frontend-service.yaml
apply_with_retry db-service.yaml
apply_with_retry redis-service.yaml
apply_with_retry db-pvc.yaml

# --- (Rest of your script: PVC check, db init, wait, patch, etc.) ---
pvc_name="postgres-pvc"
deployment_name="darkseek-db"
dep_claim=$(kubectl get deployment $deployment_name -o jsonpath='{.spec.template.spec.volumes[?(@.name=="postgres-data")].persistentVolumeClaim.claimName}')
if [ "$dep_claim" != "$pvc_name" ]; then
  fatal "Deployment $deployment_name is referencing PVC $dep_claim, but PVC is named $pvc_name. Fix db-deployment.yaml."
fi
pvc_status=$(kubectl get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [ "$pvc_status" != "Bound" ]; then
  log "PVC '$pvc_name' status: $pvc_status"
  log "Running automated troubleshooting checks..."
  troubleshoot_pvc_and_nodes "$pvc_name" "darkseek-db"
  fatal "PVC '$pvc_name' is not Bound. Resolve PV/PVC issues and re-run the script."
fi

check_db_initialization "$pvc_name" "app=darkseek-db"

log "Waiting for deployments to become available..."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-backend-ws || fatal "darkseek-backend-ws failed to become ready."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-backend-mqtt || fatal "darkseek-backend-mqtt failed to become ready."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-frontend || fatal "darkseek-frontend failed to become ready."
kubectl wait --for=condition=available --timeout=900s deployment/darkseek-db || fatal "darkseek-db failed to become ready."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-redis || fatal "darkseek-redis failed to become ready."

check_pod_statuses

log "Fetching external IPs..."
WS_IP=""
MQTT_IP=""
for i in {1..5}; do
  WS_IP=$(kubectl get service darkseek-backend-ws -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
  MQTT_IP=$(kubectl get service darkseek-backend-mqtt -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
  if [ "$WS_IP" != "pending" ] && [ "$MQTT_IP" != "pending" ]; then
    kubectl patch configmap darkseek-config -n "$NAMESPACE" -p "{\"data\":{\"WEBSOCKET_URI\":\"wss://$WS_IP:443/ws/\",\"MQTT_URI\":\"https://$MQTT_IP:443\"}}" || true
    break
  fi
  log "Waiting for IPs ($i/5)..."
  sleep 30
done
if [ -z "$WS_IP" ] || [ "$WS_IP" = "pending" ] || [ -z "$MQTT_IP" ] || [ "$MQTT_IP" = "pending" ]; then
  echo "Warning: External IPs not assigned after retries. ConfigMap not updated." >&2
fi

log "Deployment completed. Service list:"
kubectl get services -n "$NAMESPACE" -o wide
log "DarkSeek deployed successfully to GKE (Without DNS)!"
echo
echo "Access services at (replace with assigned IPs):"
echo " - WebSocket: wss://$WS_IP:443/ws/{session_id}"
echo " - MQTT: https://$MQTT_IP:443/process_query/"
echo " - Frontend: http://<frontend-ip>:8501"
