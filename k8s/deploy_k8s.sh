#!/bin/bash

# --- Deploy DarkSeek to GKE ---

# Exit on any error
set -e

# --- Check for kubectl ---
if ! command -v kubectl &> /dev/null; then
  echo "Error: 'kubectl' is not installed. Please install it (e.g., via gcloud SDK)." >&2
  exit 1
fi

# --- Define Kubernetes Manifest Directory ---
K8S_DIR="/opt/darkseek/k8s"
if [ ! -d "$K8S_DIR" ]; then
  echo "Error: Kubernetes manifest directory '$K8S_DIR' not found. Please ensure manifests are in place." >&2
  exit 1
fi

# --- Change to Directory ---
cd "$K8S_DIR"

# --- Deploy All Manifests ---
echo "Deploying DarkSeek to GKE..."

kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
kubectl apply -f backend-ws-deployment.yaml
kubectl apply -f backend-ws-service.yaml
kubectl apply -f backend-mqtt-deployment.yaml
kubectl apply -f backend-mqtt-service.yaml
kubectl apply -f frontend-deployment.yaml
kubectl apply -f frontend-service.yaml
kubectl apply -f db-deployment.yaml
kubectl apply -f db-pvc.yaml
kubectl apply -f db-service.yaml
kubectl apply -f redis-deployment.yaml
kubectl apply -f redis-service.yaml

# --- Wait for Deployments to Be Ready ---
echo "Waiting for deployments to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/darkseek-backend-ws
kubectl wait --for=condition=available --timeout=300s deployment/darkseek-backend-mqtt
kubectl wait --for=condition=available --timeout=300s deployment/darkseek-frontend
kubectl wait --for=condition=available --timeout=300s deployment/darkseek-db
kubectl wait --for=condition=available --timeout=300s deployment/darkseek-redis

# --- Display Service External IPs ---
echo "Deployment completed. Fetching external IPs..."
kubectl get services

# --- Success Message ---
echo "\nDarkSeek deployed successfully to GKE!"
echo "Access services at the external IPs shown above:"
echo "  - WebSocket: ws://<backend-ws-ip>:8000/ws/{session_id}"
echo "  - MQTT: http://<backend-mqtt-ip>:8001/process_query/ (subscribe to chat/{session_id}/response)"
echo "  - Frontend: http://<frontend-ip>:8501"
