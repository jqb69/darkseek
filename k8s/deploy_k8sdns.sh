#!/bin/bash

# --- Deploy DarkSeek to GKE (With DNS) ---

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

# --- Define DNS Name (replace with your actual domain) ---
DNS_NAME="darkseek.yourdomain.com"

# --- Change to Directory ---
cd "$K8S_DIR"

# --- Install Cert-Manager ---
echo "Installing Cert-Manager for TLS certificate management..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml

# --- Wait for Cert-Manager to be ready ---
echo "Waiting for Cert-Manager to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager

# --- Deploy All Manifests with DNS-specific Services ---
echo "Deploying DarkSeek to GKE with DNS ($DNS_NAME)..."

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

# Deployment files (shared across DNS and no-DNS)
kubectl apply -f backend-ws-deployment.yaml
kubectl apply -f backend-mqtt-deployment.yaml
kubectl apply -f frontend-deployment.yaml
kubectl apply -f db-deployment.yaml
kubectl apply -f redis-deployment.yaml

# DNS-specific service files (ClusterIP)
kubectl apply -f backend-ws-service-dns.yml
kubectl apply -f backend-mqtt-service-dns.yml
kubectl apply -f frontend-service-dns.yml

# Internal services (shared, already ClusterIP)
kubectl apply -f db-service.yml
kubectl apply -f redis-service.yml

# Persistent volume claim for DB (shared)
kubectl apply -f db-pvc.yaml

# Let's Encrypt Certificate setup
kubectl apply -f letsencrypt-clusterissuer.yaml
kubectl apply -f darkseek-certificate.yaml

# Ingress for DNS
kubectl apply -f ingress.yaml

# --- Wait for Deployments to Be Ready ---
echo "Waiting for DarkSeek deployments to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/darkseek-backend-ws
kubectl wait --for=condition=available --timeout=300s deployment/darkseek-backend-mqtt
kubectl wait --for=condition=available --timeout=300s deployment/darkseek-frontend
kubectl wait --for=condition=available --timeout=300s deployment/darkseek-db
kubectl wait --for=condition=available --timeout=300s deployment/darkseek-redis

# --- Patch ConfigMap with DNS ---
echo "Updating ConfigMap with DNS ($DNS_NAME)..."
kubectl patch configmap darkseek-config -p "{\"data\":{\"WEBSOCKET_URI\":\"wss://$DNS_NAME/ws/\",\"MQTT_URI\":\"https://$DNS_NAME\"}}"

# --- Display Ingress External IP ---
echo "Deployment completed. Fetching Ingress IP..."
kubectl get ingress

# --- Success Message ---
echo "\nDarkSeek deployed successfully to GKE with DNS!"
echo "Access services at:"
echo "  - WebSocket: wss://$DNS_NAME/ws/{session_id}"
echo "  - MQTT: https://$DNS_NAME/process_query/"
echo "  - Frontend: https://$DNS_NAME"
