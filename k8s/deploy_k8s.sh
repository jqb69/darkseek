# ./k8s/deploy_k8s.sh
#!/bin/bash

# --- Deploy DarkSeek to GKE (Without DNS) ---

# Exit on any error
set -e

# --- Check for kubectl and install if not present ---
check_kubectl() {
  if ! command -v kubectl &> /dev/null; then
    echo "Error: 'kubectl' is not installed. Attempting to install it..." >&2
    curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/kubectl
    if ! command -v kubectl &> /dev/null; then
      echo "Error: Failed to install 'kubectl'. Please install it manually." >&2
      exit 1
    else
      echo "'kubectl' installed successfully."
    fi
  else
    echo "'kubectl' is already installed."
  fi
}

# --- Validate Required Environment Variables ---
check_env_vars() {
  echo "Validating required environment variables..."
  required_vars=(
    "GOOGLE_API_KEY"
    "GOOGLE_CSE_ID"
    "HUGGINGFACEHUB_API_TOKEN"
    "DATABASE_URL"
    "REDIS_URL"
    "MQTT_BROKER_HOST"
    "MQTT_BROKER_PORT"
    "MQTT_TLS"
    "MQTT_USERNAME"
    "MQTT_PASSWORD"
    "POSTGRES_USER"
    "POSTGRES_PASSWORD"
    "POSTGRES_DB"
  )
  for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
      echo "Error: Environment variable '$var' is not set." >&2
      exit 1
    fi
  done
  echo "All required environment variables are set."
}

# --- Validate Kubernetes Manifest Files ---
check_manifest_files() {
  echo "Validating Kubernetes manifest files..."
  required_files=(
    "configmap.yaml"
    "backend-ws-deployment.yaml"
    "backend-mqtt-deployment.yaml"
    "frontend-deployment.yaml"
    "db-deployment.yaml"
    "redis-deployment.yaml"
    "backend-ws-service.yaml"
    "backend-mqtt-service.yaml"
    "frontend-service.yaml"
    "db-service.yaml"
    "redis-service.yaml"
    "db-pvc.yaml"
  )
  for file in "${required_files[@]}"; do
    if [ ! -f "$K8S_DIR/$file" ]; then
      echo "Error: Required manifest file '$file' not found in '$K8S_DIR'." >&2
      exit 1
    fi
  done
  echo "All required manifest files are present."
}

# --- Check Database Initialization ---
check_db_initialization() {
  echo "Checking PostgreSQL initialization for 'darkseek-db'..."
  local timeout=300
  local interval=10
  local elapsed=0

  # Wait for a darkseek-db pod to be Running
  while [ $elapsed -lt $timeout ]; do
    pod_name=$(kubectl get pods -n default -l app=darkseek-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$pod_name" ]; then
      pod_phase=$(kubectl get pod "$pod_name" -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      if [ "$pod_phase" = "Running" ]; then
        echo "Pod '$pod_name' is Running. Checking database status..."
        break
      fi
    fi
    echo "Waiting for 'darkseek-db' pod to be Running ($elapsed/$timeout seconds)..."
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  if [ $elapsed -ge $timeout ] || [ -z "$pod_name" ]; then
    echo "Error: No 'darkseek-db' pod reached Running state within $timeout seconds." >&2
    echo "Diagnostics:"
    kubectl get pods -n default -l app=darkseek-db
    if [ -n "$pod_name" ]; then
      kubectl describe pod "$pod_name" -n default
      kubectl logs "$pod_name" -n default || echo "No logs available."
    fi
    echo "Likely server-side issue: Check GKE cluster resources, PVC binding, or node availability."
    exit 1
  fi

  # Check if PostgreSQL is accepting connections
  if kubectl exec "$pod_name" -n default -- pg_isready -U admin; then
    echo "PostgreSQL is accepting connections."
  else
    echo "Error: PostgreSQL is not accepting connections." >&2
    echo "Diagnostics:"
    kubectl describe pod "$pod_name" -n default
    kubectl logs "$pod_name" -n default || echo "No logs available."
    echo "Likely client-side issue: Check POSTGRES_USER, POSTGRES_PASSWORD, or database configuration in secrets."
    exit 1
  fi

  # Attempt a simple query to verify database functionality
  if kubectl exec "$pod_name" -n default -- psql -U admin -d darkseekdb -c "SELECT 1;" >/dev/null 2>&1; then
    echo "Database 'darkseekdb' is initialized and functional."
  else
    echo "Error: Failed to query database 'darkseekdb'." >&2
    echo "Diagnostics:"
    kubectl describe pod "$pod_name" -n default
    kubectl logs "$pod_name" -n default || echo "No logs available."
    echo "Likely client-side issue: Check POSTGRES_DB, user permissions, or existing data in PVC."
    exit 1
  fi
}

# --- Check Pod Statuses After Deployment ---
check_pod_statuses() {
  echo "Checking pod statuses for all deployments..."
  deployments=(
    "darkseek-backend-ws"
    "darkseek-backend-mqtt"
    "darkseek-frontend"
    "darkseek-db"
    "darkseek-redis"
  )
  all_healthy=true
  for deployment in "${deployments[@]}"; do
    echo "Checking pods for deployment '$deployment'..."
    pod_status=$(kubectl get pods -n default -l app=$deployment -o jsonpath='{range .items[*]}{.metadata.name}:{.status.phase}:{.status.containerStatuses[*].ready}{"\n"}{end}')
    if [ -z "$pod_status" ]; then
      echo "Error: No pods found for deployment '$deployment'." >&2
      all_healthy=false
      continue
    fi
    while IFS= read -r line; do
      pod_name=$(echo "$line" | cut -d':' -f1)
      phase=$(echo "$line" | cut -d':' -f2)
      ready=$(echo "$line" | cut -d':' -f3)
      if [ "$phase" != "Running" ] || [ "$ready" != "true" ]; then
        echo "Warning: Pod '$pod_name' is not healthy (Phase: $phase, Ready: $ready)." >&2
        echo "Pod details for '$pod_name':"
        kubectl describe pod "$pod_name" -n default
        echo "Logs for '$pod_name':"
        kubectl logs "$pod_name" -n default --all-containers=true || echo "No logs available."
        all_healthy=false
      else
        echo "Pod '$pod_name' is healthy."
      fi
    done <<< "$pod_status"
  done
  if [ "$all_healthy" = false ]; then
    echo "Error: Some pods are not healthy. Check above details for troubleshooting." >&2
    exit 1
  fi
  echo "All pods are healthy."
}

echo "Checking for kubectl..."
check_kubectl

# --- Define Kubernetes Manifest Directory ---
K8S_DIR="./k8s"
if [ ! -d "$K8S_DIR" ]; then
  echo "Error: Kubernetes manifest directory '$K8S_DIR' not found." >&2
  exit 1
fi

# --- Validate Prerequisites ---
check_env_vars
check_manifest_files

# --- Change to Directory ---
cd "$K8S_DIR"

# --- Deploy All Manifests ---
echo "Deploying DarkSeek to GKE without DNS..."

# Shared configuration
kubectl apply -f configmap.yaml

# Create or update secrets from environment variables
echo "Creating or updating darkseek-secrets from environment variables..."
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

# Deployment files
kubectl apply -f backend-ws-deployment.yaml
kubectl apply -f backend-mqtt-deployment.yaml
kubectl apply -f frontend-deployment.yaml
kubectl apply -f db-deployment.yaml
kubectl apply -f redis-deployment.yaml

# Service files (with LoadBalancer)
kubectl apply -f backend-ws-service.yaml
kubectl apply -f backend-mqtt-service.yaml
kubectl apply -f frontend-service.yaml
kubectl apply -f db-service.yaml
kubectl apply -f redis-service.yaml

# Persistent volume claim for DB
kubectl apply -f db-pvc.yaml

# --- Check Database Initialization ---
check_db_initialization

# --- Wait for Deployments to Be Ready ---
echo "Waiting for deployments to be ready..."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-backend-ws || { echo "Error: Deployment 'darkseek-backend-ws' failed to become ready."; exit 1; }
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-backend-mqtt || { echo "Error: Deployment 'darkseek-backend-mqtt' failed to become ready."; exit 1; }
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-frontend || { echo "Error: Deployment 'darkseek-frontend' failed to become ready."; exit 1; }
kubectl wait --for=condition=available --timeout=900s deployment/darkseek-db || { echo "Error: Deployment 'darkseek-db' failed to become ready."; exit 1; }
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-redis || { echo "Error: Deployment 'darkseek-redis' failed to become ready."; exit 1; }

# --- Check Pod Statuses ---
check_pod_statuses

# --- Patch ConfigMap with External IPs ---
echo "Fetching external IPs..."
for i in {1..5}; do
  WS_IP=$(kubectl get service darkseek-backend-ws -o jsonpath='{.status.loadBalancer.ingress[0].ip}' || echo "pending")
  MQTT_IP=$(kubectl get service darkseek-backend-mqtt -o jsonpath='{.status.loadBalancer.ingress[0].ip}' || echo "pending")
  if [ "$WS_IP" != "pending" ] && [ "$MQTT_IP" != "pending" ]; then
    kubectl patch configmap darkseek-config -p "{\"data\":{\"WEBSOCKET_URI\":\"wss://$WS_IP:443/ws/\",\"MQTT_URI\":\"https://$MQTT_IP:443\"}}"
    break
  fi
  echo "Waiting for IPs ($i/5)..."
  sleep 30
done
if [ "$WS_IP" = "pending" ] || [ "$MQTT_IP" = "pending" ]; then
  echo "Warning: External IPs not assigned after retries. ConfigMap not updated." >&2
fi

# --- Display Service External IPs ---
echo "Deployment completed. Fetching external IPs..."
kubectl get services

# --- Success Message ---
echo "\nDarkSeek deployed successfully to GKE (Without DNS)!"
echo "Access services at:"
echo "  - WebSocket: wss://$WS_IP:443/ws/{session_id}"
echo "  - MQTT: https://$MQTT_IP:443/process_query/"
echo "  - Frontend: http://<frontend-ip>:8501"
