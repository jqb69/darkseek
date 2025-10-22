# k8s/rollback_k8s.sh
#!/bin/bash
set -e
echo "Rolling back deployments..."
kubectl rollout undo deployment/darkseek-frontend -n default
kubectl rollout undo deployment/darkseek-backend-ws -n default
kubectl rollout undo deployment/darkseek-backend-mqtt -n default
kubectl rollout undo deployment/darkseek-db -n default
kubectl rollout undo deployment/darkseek-redis -n default
echo "Rollback completed."
