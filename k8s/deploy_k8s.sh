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
  troubleshoot_k8s || true
  return $exit_code
}
trap 'on_error' ERR

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

check_env_vars() {
  log "Validating required environment variables..."
  required_vars=("GOOGLE_API_KEY" "GOOGLE_CSE_ID" "HUGGINGFACEHUB_API_TOKEN" "DATABASE_URL" "REDIS_URL" "MQTT_BROKER_HOST" "MQTT_BROKER_PORT" "MQTT_TLS" "MQTT_USERNAME" "MQTT_PASSWORD" "POSTGRES_USER" "POSTGRES_PASSWORD" "POSTGRES_DB")
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

check_pod_statuses() {
  log "Checking pod health..."
  local all_healthy=true
  for dep in "darkseek-backend-ws" "darkseek-backend-mqtt" "darkseek-frontend" "darkseek-db" "darkseek-redis"; do
    log "Checking $dep..."
    while IFS= read -r line; do
      pod=$(echo "$line" | cut -d: -f1)
      phase=$(echo "$line" | cut -d: -f2)
      ready=$(echo "$line" | cut -d: -f3)
      if [ "$phase" != "Running" ] || [ "$ready" != "true" ]; then
        echo "Warning: $pod unhealthy ($phase, $ready)" >&2
        kubectl describe pod "$pod" -n "$NAMESPACE" || true
        kubectl logs "$pod" -n "$NAMESPACE" --all-containers=true || true
        all_healthy=false
      else
        log "Pod $pod healthy."
      fi
    done < <(kubectl get pods -n "$NAMESPACE" -l app="$dep" -o jsonpath='{range .items[*]}{.metadata.name}:{.status.phase}:{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null || echo "")
    [ -z "$(kubectl get pods -n "$NAMESPACE" -l app="$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)" ] && all_healthy=false
  done
  $all_healthy || fatal "Unhealthy pods detected."
  log "All pods healthy."
}

# --- MAIN ---
log "Starting deployment..."
check_kubectl
[ ! -d "$K8S_DIR" ] && fatal "Missing $K8S_DIR"
check_env_vars
check_manifest_files
cd "$K8S_DIR"

kubectl apply -f configmap.yaml

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
  --dry-run=client -o yaml | kubectl apply -f -

dryrun_server

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

pvc_name="postgres-pvc"
deployment_name="darkseek-db"
dep_claim=$(kubectl get deployment $deployment_name -o jsonpath='{.spec.template.spec.volumes[?(@.name=="postgres-data")].persistentVolumeClaim.claimName}')
[ "$dep_claim" != "$pvc_name" ] && fatal "PVC mismatch."

pvc_status=$(kubectl get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
[ "$pvc_status" != "Bound" ] && { log "PVC not Bound."; troubleshoot_pvc_and_nodes "$pvc_name" "darkseek-db"; fatal "PVC not Bound."; }

ensure_db_exists
check_db_initialization "$pvc_name" "app=darkseek-db"

log "Waiting for deployments..."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-backend-ws || fatal "WS failed."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-backend-mqtt || fatal "MQTT failed."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-frontend || fatal "Frontend failed."
kubectl wait --for=condition=available --timeout=900s deployment/darkseek-db || fatal "DB failed."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-redis || fatal "Redis failed."

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
