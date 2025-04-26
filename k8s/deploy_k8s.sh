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

echo "Checking for kubectl..."
check_kubectl

# --- Define Kubernetes Manifest Directory ---
K8S_DIR="./k8s"
if [ ! -d "$K8S_DIR" ]; then
  echo "Error: Kubernetes manifest directory '$K8S_DIR' not found." >&2
  exit 1
fi

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

# --- Wait for Deployments to Be Ready ---
echo "Waiting for deployments to be ready..."
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-backend-ws
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-backend-mqtt
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-frontend
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-db
kubectl wait --for=condition=available --timeout=600s deployment/darkseek-redis

# --- Patch ConfigMap with External IPs ---
echo "Fetching external IPs..."
WS_IP=$(kubectl get service darkseek-backend-ws -o jsonpath='{.status.loadBalancer.ingress[0].ip}' || echo "pending")
MQTT_IP=$(kubectl get service darkseek-backend-mqtt -o jsonpath='{.status.loadBalancer.ingress[0].ip}' || echo "pending")
if [ "$WS_IP" != "pending" ] && [ "$MQTT_IP" != "pending" ]; then
  kubectl patch configmap darkseek-config -p "{\"data\":{\"WEBSOCKET_URI\":\"wss://$WS_IP:443/ws/\",\"MQTT_URI\":\"https://$MQTT_IP:443\"}}"
else
  echo "Warning: External IPs not yet assigned. ConfigMap not updated."
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
