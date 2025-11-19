#!/bin/bash
# --- Deploy DarkSeek to GKE (Without DNS) ---
# Date: 2025-09-30
set -euo pipefail

NAMESPACE="default"
K8S_DIR="./k8s"
RETRY_APPLY=3
APPLY_SLEEP=3

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
fatal() { echo "ERROR: $*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  log "Script failed (exit code: $exit_code). Running troubleshooting..."

  # First, run the general troubleshooting for PVCs, events, etc.
  troubleshoot_k8s || true
  # THEN, check if the backend-ws deployment was the cause of the failure.
  # If so, trigger the interactive debug mode specifically for it.
  if ! kubectl wait --for=condition=available --timeout=1s "deployment/darkseek-backend-ws" -n "$NAMESPACE" &>/dev/null; then
    debug_pod_interactively "darkseek-backend-ws"
  fi

  return $exit_code
}
trap 'on_error' ERR

# ----------------------------------------------------------------------
#  ADVANCED DEBUG: Get an interactive shell in a crashing pod
# ----------------------------------------------------------------------
debug_pod_interactively() {
  local dep="$1"
  log "Attempting to start interactive debug session for deployment '$dep'..."

  # Find a failing pod for the deployment
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" --sort-by='.metadata.creationTimestamp' -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")

  if [ -z "$pod" ]; then
    log "Could not find a pod for deployment '$dep' to debug."
    return
  fi

  log "Found pod '$pod'. Patching deployment '$dep' to prevent crash."

  # Override the container's command to keep it alive
  kubectl patch deployment "$dep" -n "$NAMESPACE" -p \
    '{"spec":{"template":{"spec":{"containers":[{"name":"backend-ws","command":["sleep","3600"]}]}}}}'

  log "Deployment patched. Please wait a moment for the pod to restart with the new command."
  log "The pod will now run for 1 hour without crashing."
  log "To get a shell inside the pod, run this command from your local machine:"
  echo ""
  echo "  kubectl exec -it $pod -n $NAMESPACE -- /bin/bash"
  echo ""
  log "Inside the shell, you can debug interactively:"
  log "  - Check environment variables with 'env'"
  log "  - Check files with 'ls -la /app'"
  log "  - Try to run the application manually to see the error: 'python /app/main.py'"
  log "When you are finished, you must un-patch the deployment by re-running the pipeline or using 'kubectl rollout undo deployment/$dep'."
}

check_kubectl() {
  if ! command -v kubectl &> /dev/null; then
    log "'kubectl' not found — installing..."
    curl -fsSL -o /tmp/kubectl "https://storage.googleapis.com/kubernetes-release/release/$(curl -fsSL https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
    command -v kubectl &> /dev/null || fatal "Failed to install kubectl."
    log "'kubectl' installed."
  else
    log "'kubectl' available."
  fi
}

check_envsubst() {
  command -v envsubst >/dev/null 2>&1 || { 
    log "envsubst not found — installing gettext..."
    sudo apt-get update -qq
    sudo apt-get install -y gettext
    command -v envsubst >/dev/null 2>&1 || fatal "Failed to install envsubst"
    log "envsubst installed."
  }
}

check_env_vars() {
  log "Validating required environment variables..."
  required_vars=( "GCP_PROJECT_ID" "GOOGLE_API_KEY" "GOOGLE_CSE_ID" "HUGGINGFACEHUB_API_TOKEN" "DATABASE_URL" "REDIS_URL" "MQTT_BROKER_HOST" "MQTT_BROKER_PORT" "MQTT_TLS" "MQTT_USERNAME" "MQTT_PASSWORD" "POSTGRES_USER" "POSTGRES_PASSWORD" "POSTGRES_DB")
  for var in "${required_vars[@]}"; do
    [ -z "${!var-}" ] && fatal "Environment variable '$var' is not set."
  done
  log "All required environment variables are set."
}

check_manifest_files() {
  log "Validating manifest files in '$K8S_DIR'..."
  required_files=("configmap.yaml" "backend-ws-deployment.yaml" "backend-mqtt-deployment.yaml" "frontend-deployment.yaml" "db-deployment.yaml" "redis-deployment.yaml" "backend-ws-service.yaml" "backend-mqtt-service.yaml" "frontend-service.yaml" "db-service.yaml" "redis-service.yaml" "db-pvc.yaml")
  for file in "${required_files[@]}"; do
    [ ! -f "$K8S_DIR/$file" ] && fatal "Missing file: $file"
  done
  log "All manifest files present."
}

dryrun_server() {
  log "Running server-side dry-run validation..."
  if ! kubectl apply -f "./" --dry-run=server --validate=true; then
    fatal "Server-side validation failed. Fix YAML (e.g., value + valueFrom conflict)."
  fi
  log "Server-side dry-run passed."
}

apply_with_retry() {
  local file="$1" i=0
  until [ $i -ge $RETRY_APPLY ]; do
    if kubectl apply -f "$file"; then return 0; fi
    i=$((i + 1))
    log "Retrying $file ($i/$RETRY_APPLY)..."
    sleep $APPLY_SLEEP
  done
  fatal "Failed to apply $file after $RETRY_APPLY attempts."
}

troubleshoot_k8s() {
  log "=== TROUBLESHOOTING ==="
  kubectl get pvc -n "$NAMESPACE" || true
  kubectl describe pvc db-pvc -n "$NAMESPACE" || true
  kubectl get pv || true
  kubectl get pods -n "$NAMESPACE" -l app=darkseek-db -o wide || true
  POD=$(kubectl get pods -n "$NAMESPACE" -l app=darkseek-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [ -n "$POD" ] && { kubectl describe pod "$POD" -n "$NAMESPACE"; kubectl logs "$POD" -n "$NAMESPACE" --all-containers=true; } || log "No DB pod."
  kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -n 30 || true
  kubectl get nodes -o wide || true
  log "=== END TROUBLESHOOTING ==="
}

ensure_db_exists() {
  log "Ensuring DB '$POSTGRES_DB' exists..."
  if ! kubectl exec -n "$NAMESPACE" deployment/darkseek-db -- psql -U "$POSTGRES_USER" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$POSTGRES_DB'" | grep -q 1; then
    log "Creating database '$POSTGRES_DB'..."
    kubectl exec -n "$NAMESPACE" deployment/darkseek-db -- psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE \"$POSTGRES_DB\";"
  else
    log "Database '$POSTGRES_DB' already exists."
  fi
}

check_db_initialization() {
  log "Checking PostgreSQL initialization..."
  local pod_label="app=darkseek-db" timeout=300 interval=10 elapsed=0 pod_name=""
  while [ $elapsed -lt $timeout ]; do
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l "$pod_label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [ -n "$pod_name" ] && [ "$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}')" = "Running" ] && break
    log "Waiting for pod ($elapsed/$timeout)..."
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  [ -z "$pod_name" ] && fatal "No pod found for $pod_label."
  kubectl exec -n "$NAMESPACE" "$pod_name" -- pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1 || \
    { log "pg_isready failed."; kubectl describe pod "$pod_name"; kubectl logs "$pod_name"; fatal "Postgres not ready."; }
  log "PostgreSQL accepting connections."
  local user="$POSTGRES_USER" db="$POSTGRES_DB"
  [ -z "$db" ] && fatal "POSTGRES_DB not set."
  kubectl exec -n "$NAMESPACE" "$pod_name" -- psql -U "$user" -d "$db" -c "SELECT 1;" >/dev/null 2>&1 && \
    log "Database '$db' functional." || \
    { log "Query failed."; kubectl describe pod "$pod_name"; kubectl logs "$pod_name"; fatal "Cannot query '$db'."; }
}

verify_backend_ws_image() {
  log "Verifying backend-ws image..."
  local image
  image=$(kubectl get deployment darkseek-backend-ws -n default \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "Not found")
  if [ "$image" = "Not found" ]; then
    fatal "Deployment darkseek-backend-ws not found or has no image."
  fi
  log "Deployed image: $image"
}

debug_python_startup() {
  local dep="$1"
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$pod" ]; then
    log "=== PYTHON DEBUG: $dep ($pod) ==="
    kubectl logs "$pod" -n "$NAMESPACE" --tail=50 | grep -i "import\|error\|exception\|traceback" || true
    kubectl exec "$pod" -n "$NAMESPACE" -- python -c "import sys; print('Python path:', sys.path)" || true
    kubectl exec "$pod" -n "$NAMESPACE" -- ls -la /app/ || true
    kubectl exec "$pod" -n "$NAMESPACE" -- find /app -name "*.py" | head -20 || true
  fi
}

# -----------------------------------------------------------------------
#  IMPROVED DEBUG: wait for all deployments with detailed pod diagnostics
# -----------------------------------------------------------------------
wait_for_deployments() {
  local deployments=(
    "darkseek-backend-ws"
    "darkseek-backend-mqtt"
    "darkseek-frontend"
    "darkseek-db"
    "darkseek-redis"
  )
  local timeout=900
  local interval=15

  log "Waiting up to ${timeout}s for deployments to become Available..."
  for dep in "${deployments[@]}"; do
    log "=== Waiting for deployment/$dep ==="
    if kubectl wait --for=condition=available --timeout=${timeout}s "deployment/$dep" -n "$NAMESPACE"; then
      log "Deployment $dep is Available."
      continue
    fi

    # ------------------------------------------------------------------
    #  If the wait timed out, dump diagnostics for ALL related pods.
    # ------------------------------------------------------------------
    log "WARNING: Deployment '$dep' did NOT become Available – dumping diagnostics..."

    # 1. List all pods for this deployment
    log "Pods for '$dep':"
    kubectl get pods -n "$NAMESPACE" -l "app=$dep" -o wide || true

    # 2. Get the names of all pods for this deployment
    local pod_names
    pod_names=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$pod_names" ]; then
      # 3. Loop through each pod and dump its individual diagnostics
      for pod in $pod_names; do
        log "--------------------------------------------------"
        log "--- Diagnostics for pod: $pod ---"
        log "--------------------------------------------------"

        # 3a. Describe the pod
        log "Describing pod '$pod':"
        kubectl describe pod "$pod" -n "$NAMESPACE" || true

        # 3b. Get the logs for the pod
        log "Logs for pod '$pod' (last 200 lines):"
        # Always print the full logs to ensure we don't miss anything.
        kubectl logs "$pod" -n "$NAMESPACE" --all-containers=true --tail=200 || log "Warning: Could not retrieve logs for pod '$pod'. It may have crashed before producing any output.
      done
    else
      log "No pods found for label app=$dep"
    fi

    # 4. Get recent events related to this deployment
    log "Recent events for '$dep':"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | grep -i "$dep" | tail -n 20 || true
    debug_python_startup "$dep"

    fatal "Deployment '$dep' failed to become ready – see diagnostics above."
  done
}

check_pod_statuses() {
  log "Checking pod health..."
  local timeout=300 interval=10 elapsed=0 all_healthy=true
  while [ $elapsed -lt $timeout ]; do
    all_healthy=true
    for dep in "darkseek-backend-ws" "darkseek-backend-mqtt" "darkseek-frontend" "darkseek-db" "darkseek-redis"; do
      pod_status=$(kubectl get pods -n "$NAMESPACE" -l app="$dep" -o jsonpath='{range .items[*]}{.metadata.name}:{.status.phase}:{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null || echo "")
      if [ -z "$pod_status" ]; then
        log "No pods for $dep (elapsed: $elapsed/$timeout)."
        all_healthy=false
        continue
      fi
      while IFS= read -r line; do
        pod_name=$(echo "$line" | cut -d: -f1)
        phase=$(echo "$line" | cut -d: -f2)
        ready=$(echo "$line" | cut -d: -f3)
        if [ "$phase" != "Running" ] || [ "$ready" != "true" ]; then
          log "Pod $pod_name for $dep unhealthy (Phase: $phase, Ready: $ready) (elapsed: $elapsed/$timeout)."
          kubectl describe pod "$pod_name" -n "$NAMESPACE" || true
          kubectl logs "$pod_name" -n "$NAMESPACE" --all-containers=true || true
          all_healthy=false
        else
          log "Pod $pod_name healthy."
        fi
      done <<< "$pod_status"
    done
    [ "$all_healthy" = true ] && break
    log "Retrying in $interval seconds (elapsed: $elapsed/$timeout)..."
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  $all_healthy || fatal "Unhealthy pods after $timeout seconds."
  log "All pods healthy."
}

apply_with_envsubst() {
  local file="$1"
  #export GCP_PROJECT_ID
  log "Apply with envsubst to ${file}: GCP_PROJECT_ID=${GCP_PROJECT_ID}"
  local i=0
  while [ "$i" -lt "$RETRY_APPLY" ]; do
    # Pipe envsubst output to kubectl; check success
    envsubst < "$file" > "${file}.subst"
    # Now attempt to apply the temp file
    if kubectl apply -f "${file}.subst" --v=8; then
      log "Substituted content:"
      cat "${file}.subst"
      return 0
    fi
    i=$((i + 1))
    log "Retrying ${file} (${i}/${RETRY_APPLY})..."
    sleep "$APPLY_SLEEP"
  done

  fatal "Failed to apply ${file} after ${RETRY_APPLY} attempts."
 
}

apply_with_sed() {
  local file="$1"
  log "Applying with substitution to ${file}: GCP_PROJECT_ID=${GCP_PROJECT_ID}"

  # Use sed for a more reliable substitution.
  # It replaces the literal string "${GCP_PROJECT_ID}" with the variable's value.
  sed "s|\${GCP_PROJECT_ID}|${GCP_PROJECT_ID}|g" "$file" > "${file}.subst"

  log "Substituted content:"
  cat "${file}.subst"

  # Apply the temporary file with retries
  local i=0
  until [ $i -ge $RETRY_APPLY ]; do
    if kubectl apply -f "${file}.subst"; then return 0; fi
    i=$((i + 1))
    log "Retrying ${file} ($i/$RETRY_APPLY)..."
    sleep $APPLY_SLEEP
  done
  fatal "Failed to apply ${file} after ${RETRY_APPLY} attempts."
}

# --- MAIN ---
log "Starting deployment..."
check_kubectl
check_envsubst
[ ! -d "$K8S_DIR" ] && fatal "Missing $K8S_DIR"
check_env_vars
check_manifest_files
cd "$K8S_DIR"

# FIX: Convert GCP_PROJECT_ID to lowercase to ensure a valid GCR path.
export GCP_PROJECT_ID=$(echo "$GCP_PROJECT_ID" | tr '[:upper:]' '[:lower:]')

log "Updating darkseek-secrets..."
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
  --from-literal=GCP_PROJECT_ID="${GCP_PROJECT_ID}" \
  --dry-run=client -o yaml | kubectl apply -f -


kubectl apply -f configmap.yaml
dryrun_server


#apply_with_retry backend-ws-deployment.yaml
apply_with_sed backend-ws-deployment.yaml
apply_with_sed backend-mqtt-deployment.yaml

log "Waiting for deployments..."
apply_with_retry frontend-deployment.yaml
apply_with_retry db-deployment.yaml
log "Applying other resources..."
apply_with_retry redis-deployment.yaml
apply_with_retry backend-ws-service.yaml
apply_with_retry backend-mqtt-service.yaml
apply_with_retry frontend-service.yaml
apply_with_retry db-service.yaml
apply_with_retry redis-service.yaml
apply_with_retry db-pvc.yaml

#log "Patching images with GCP_PROJECT_ID..."
#kubectl set image deployment/darkseek-backend-ws backend-ws=gcr.io/${GCP_PROJECT_ID}/darkseek-backend-ws:latest -n default
#kubectl set image deployment/darkseek-backend-mqtt backend-mqtt=gcr.io/${GCP_PROJECT_ID}/darkseek-backend-mqtt:latest -n default

pvc_name="postgres-pvc"
deployment_name="darkseek-db"
dep_claim=$(kubectl get deployment $deployment_name -o jsonpath='{.spec.template.spec.volumes[?(@.name=="postgres-data")].persistentVolumeClaim.claimName}')
[ "$dep_claim" != "$pvc_name" ] && fatal "PVC mismatch."

pvc_status=$(kubectl get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
[ "$pvc_status" != "Bound" ] && { log "PVC not Bound."; troubleshoot_pvc_and_nodes "$pvc_name" "darkseek-db"; fatal "PVC not Bound."; }

ensure_db_exists
check_db_initialization "$pvc_name" "app=darkseek-db"
verify_backend_ws_image
wait_for_deployments

check_pod_statuses

log "Fetching IPs..."
WS_IP="" MQTT_IP=""
for i in {1..5}; do
  WS_IP=$(kubectl get service darkseek-backend-ws -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
  MQTT_IP=$(kubectl get service darkseek-backend-mqtt -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
  [ "$WS_IP" != "pending" ] && [ "$MQTT_IP" != "pending" ] && break
  log "Waiting ($i/5)..."; sleep 30
done

[ "$WS_IP" != "pending" ] && [ "$MQTT_IP" != "pending" ] && \
  kubectl patch configmap darkseek-config -n "$NAMESPACE" -p "{\"data\":{\"WEBSOCKET_URI\":\"wss://$WS_IP:443/ws/\",\"MQTT_URI\":\"https://$MQTT_IP:443\"}}" || true

[ -z "$WS_IP" ] || [ "$WS_IP" = "pending" ] || [ -z "$MQTT_IP" ] || [ "$MQTT_IP" = "pending" ] && \
  echo "Warning: IPs not assigned." >&2

log "Deployment complete. Services:"
kubectl get services -n "$NAMESPACE" -o wide
log "DarkSeek deployed!"
echo "Access:"
echo "  WS: wss://$WS_IP:443/ws/{session_id}"
echo "  MQTT: https://$MQTT_IP:443/process_query/"
echo "  Frontend: http://<frontend-ip>:8501"
