# ./k8s/deploy_k8s.sh
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

# --- Check for kubectl and install if not present ---
check_kubectl() {
  if ! command -v kubectl &> /dev/null; then
    log "'kubectl' not found — attempting to install..."
    curl -fsSL -o /tmp/kubectl "https://storage.googleapis.com/kubernetes-release/release/$(curl -fsSL https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
    command -v kubectl &> /dev/null || fatal "Failed to install kubectl. Install manually."
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

# --- Troubleshooting helper ---
troubleshoot_pvc_and_nodes() {
  # Usage: troubleshoot_pvc_and_nodes <pvc-name> <deployment-name-or-label>
  local pvc_name="${1:-postgres-pvc}"
  local deployment="${2:-darkseek-db}"

  log "Running troubleshooting for PVC '$pvc_name' and deployment '$deployment'..."

  log "1) PVC status:"
  kubectl get pvc "$pvc_name" -n "$NAMESPACE" -o wide || echo "  -> PVC not found."

  log "2) Describe PVC (events):"
  kubectl describe pvc "$pvc_name" -n "$NAMESPACE" || true

  log "3) List PVs to find matching volume:"
  kubectl get pv -o=custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name,SC:.spec.storageClassName,CAP:.spec.capacity.storage,AM:.spec.accessModes || true

  log "4) Describe cluster events for the deployment's pods (scheduling errors):"
  kubectl describe deployment "$deployment" -n "$NAMESPACE" || true
  kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -n 20 || true

  log "5) Node status and taints:"
  kubectl get nodes -o wide || true
  kubectl describe nodes | grep -E 'Name:|Taints:|Unschedulable|Allocatable' -A3 -B1 || true

  log "6) Check if any pod is holding the PVC (ReadWriteOnce conflicts):"
  kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}' | grep -E "\b$pvc_name\b" || echo "  -> No pod currently listing the PVC."

  log "7) Optional: scale deployment to 0 then back to 1 to force reschedule (commented by default)."
  echo "To perform scale restart run: troubleshoot_pvc_and_nodes_scale_restart \"$deployment\""
}

troubleshoot_pvc_and_nodes_scale_restart() {
  local deployment="${1:-darkseek-db}"
  log "Scaling '$deployment' to 0 then back to 1..."
  kubectl scale deployment "$deployment" -n "$NAMESPACE" --replicas=0
  sleep 3
  kubectl scale deployment "$deployment" -n "$NAMESPACE" --replicas=1
  log "Scale restart requested for '$deployment'."
}

# --- Check Database Initialization (improved) ---
check_db_initialization() {
  log "Checking PostgreSQL initialization for PVC '$1' (label $2)..."
  local pod_label="${2:-app=darkseek-db}"
  local timeout=300
  local interval=10
  local elapsed=0
  local pod_name=""

  while [ $elapsed -lt $timeout ]; do
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l "$pod_label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$pod_name" ]; then
      pod_phase=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      if [ "$pod_phase" = "Running" ]; then
        log "Pod '$pod_name' is Running."
        break
      fi
    fi
    log "Waiting for pod ($elapsed/$timeout)..."
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  if [ -z "$pod_name" ]; then
    fatal "No pod found for label '$pod_label' in namespace '$NAMESPACE'. Run troubleshoot_pvc_and_nodes to inspect PVC/PV and events."
  fi

  if ! kubectl exec -n "$NAMESPACE" "$pod_name" -- pg_isready -U "${POSTGRES_USER:-admin}" >/dev/null 2>&1; then
    log "pg_isready failed — dumping diagnostics..."
    kubectl describe pod "$pod_name" -n "$NAMESPACE" || true
    kubectl logs "$pod_name" -n "$NAMESPACE" --all-containers=true || true
    fatal "Postgres is not accepting connections. Run troubleshoot_pvc_and_nodes postgres-pvc $pod_label"
  fi
  log "PostgreSQL is accepting connections."

  local user="${POSTGRES_USER:-admin}"
  local db="${POSTGRES_DB:-darkseekdb}"
  if kubectl exec -n "$NAMESPACE" "$pod_name" -- psql -U "$user" -d "$db" -c "SELECT 1;" >/dev/null 2>&1; then
    log "Database '$db' is initialized and functional."
  else
    log "Simple query failed — dumping diagnostics..."
    kubectl describe pod "$pod_name" -n "$NAMESPACE" || true
    kubectl logs "$pod_name" -n "$NAMESPACE" --all-containers=true || true
    fatal "Failed to query database '$db'. Check POSTGRES_USER/POSTGRES_PASSWORD/POSTGRES_DB and PVC contents."
  fi
}

# --- Check Pod Statuses After Deployment ---
check_pod_statuses() {
  log "Checking pod statuses for deployments..."
  deployments=(
    "darkseek-backend-ws"
    "darkseek-backend-mqtt"
    "darkseek-frontend"
    "darkseek-db"
    "darkseek-redis"
  )
  local all_healthy=true
  for deployment in "${deployments[@]}"; do
    log "Checking pods for deployment '$deployment'..."
    pod_status=$(kubectl get pods -n "$NAMESPACE" -l app="$deployment" -o jsonpath='{range .items[*]}{.metadata.name}:{.status.phase}:{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null || echo "")
    if [ -z "$pod_status" ]; then
      echo "  -> No pods found for '$deployment'." >&2
      all_healthy=false
      continue
    fi
    while IFS= read -r line; do
      pod_name=$(echo "$line" | cut -d':' -f1)
      phase=$(echo "$line" | cut -d':' -f2)
      ready=$(echo "$line" | cut -d':' -f3)
      if [ "$phase" != "Running" ] || [ "$ready" != "true" ]; then
        echo "Warning: Pod '$pod_name' not healthy (Phase: $phase, Ready: $ready)." >&2
        kubectl describe pod "$pod_name" -n "$NAMESPACE" || true
        kubectl logs "$pod_name" -n "$NAMESPACE" --all-containers=true || true
        all_healthy=false
      else
        log "Pod '$pod_name' is healthy."
      fi
    done <<< "$pod_status"
  done

  $all_healthy || fatal "Some pods are not healthy. See above diagnostics."
  log "All pods are healthy."
}

# --- Start script execution ---
log "Checking for kubectl..."
check_kubectl

if [ ! -d "$K8S_DIR" ]; then
  fatal "Kubernetes manifest directory '$K8S_DIR' not found."
fi

check_env_vars
check_manifest_files

cd "$K8S_DIR"

log "Deploying DarkSeek to GKE without DNS..."

kubectl apply -f configmap.yaml

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

# Apply manifests with a small retry loop
apply_with_retry() {
  local file="$1"
  local i=0
  until [ $i -ge $RETRY_APPLY ]; do
    if kubectl apply -f "$file"; then
      return 0
    fi
    i=$((i + 1))
    sleep $APPLY_SLEEP
  done
  fatal "Failed to apply $file after $RETRY_APPLY attempts."
}

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

# --- Troubleshoot PVC/PV binding if PVC not Bound ---
pvc_name="postgres-pvc"
pvc_status=$(kubectl get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [ "$pvc_status" != "Bound" ]; then
  log "PVC '$pvc_name' status: $pvc_status"
  log "Running automated troubleshooting checks..."
  troubleshoot_pvc_and_nodes "$pvc_name" "darkseek-db"
  fatal "PVC '$pvc_name' is not Bound. Resolve PV/PVC issues and re-run the script."
fi

# --- Check Database Initialization ---
check_db_initialization "$pvc_name" "app=darkseek-db"

# --- Wait for Deployments to Be Ready ---
log "Waiting for deployments to become available..."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-backend-ws || fatal "darkseek-backend-ws failed to become ready."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-backend-mqtt || fatal "darkseek-backend-mqtt failed to become ready."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-frontend || fatal "darkseek-frontend failed to become ready."
kubectl wait --for=condition=available --timeout=900s deployment/darkseek-db || fatal "darkseek-db failed to become ready."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-redis || fatal "darkseek-redis failed to become ready."

check_pod_statuses

# --- Patch ConfigMap with External IPs ---
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
echo "  - WebSocket: wss://$WS_IP:443/ws/{session_id}"
echo "  - MQTT: https://$MQTT_IP:443/process_query/"
echo "  - Frontend: http://<frontend-ip>:8501"
