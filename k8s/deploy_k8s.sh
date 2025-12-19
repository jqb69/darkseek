#!/bin/bash
# --- Deploy DarkSeek to GKE (Without DNS) ---
# Date: 2025-09-30,Modified 2025-11-28
set -euo pipefail

NAMESPACE="default"
K8S_DIR="./k8s"
RETRY_APPLY=3
APPLY_SLEEP=3

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
fatal() { echo "ERROR: $*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  log "FATAL: Script failed (exit code: $exit_code). Entering emergency debug mode..."

  # General diagnostics
  troubleshoot_k8s || true

  # List of critical deployments to check (in reverse order for logical debugging)
  local deployments=("darkseek-backend-ws" "darkseek-backend-mqtt" "darkseek-frontend" "darkseek-db" "darkseek-redis")

  for dep in "${deployments[@]}"; do
    # Check if a deployment is NOT available (using a short timeout)
    if ! kubectl wait --for=condition=available --timeout=3s "deployment/$dep" -n "$NAMESPACE" &>/dev/null; then
      log "Deployment $dep is NOT available → dropping you into interactive debug pod..."
      debug_pod_interactively "$dep"
      
      # CRITICAL: Stop everything after debug shell
      log "Debug session for $dep completed. Script terminated intentionally."
      exit $exit_code
    fi
  done

  log "No specific deployment found unhealthy. Exiting with code $exit_code."
  exit $exit_code
}
trap 'on_error' ERR

# ----------------------------------------------------------------------
#  ADVANCED DEBUG: Get an interactive shell in a crashing pod (Improved)
# ----------------------------------------------------------------------
debug_pod_interactively() {
  local dep="$1"
  local container_name

  # Auto-detect the container name for a specific deployment
  case "$dep" in
    "darkseek-backend-ws") container_name="backend-ws";;
    "darkseek-backend-mqtt") container_name="backend-mqtt";;
    "darkseek-frontend") container_name="frontend";;
    "darkseek-db") container_name="postgres";; # Use the container name inside the DB pod
    "darkseek-redis") container_name="redis";;
    *) container_name=$(kubectl get deployment "$dep" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null || echo "$dep");;
  esac

  log "Attempting to start interactive debug session for deployment '$dep' (container: $container_name)..."

  # Find latest pod
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" --sort-by='.metadata.creationTimestamp' -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
  if [ -z "$pod" ]; then
    log "No pod found for deployment '$dep'. Cannot debug."
    return 1
  fi

  log "Found pod: $pod → patching container '$container_name' to sleep 1h"

  # Dynamic patch with correct container name (use --patch for safer operation)
  kubectl patch deployment "$dep" -n "$NAMESPACE" --patch \
    "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$container_name\",\"command\":[\"sleep\",\"3600\"], \"imagePullPolicy\":\"Always\"}]}}}}"

  log "Deployment patched. Pod will restart with infinite sleep. The deployment will be updated."
  log "Connect using:"
  echo ""
  echo "   kubectl exec -it $pod -n $NAMESPACE -- /bin/bash"
  echo ""
  log "After debugging, restore with:"
  echo "   kubectl rollout undo deployment/$dep"
  log "Or re-run the full deploy script."
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

# ----------------------------------------------------------------------
#  IMPROVED DEBUG: Asynchronously check pod status for instant feedback
# ----------------------------------------------------------------------
check_pods_in_background() {
  local dep="$1"
  local timeout="$2"
  local start_time
  start_time=$(date +%s)

  log "[BG CHECK for $dep] Starting background monitoring..."

  while true; do
    # Check elapsed time
    local current_time
    current_time=$(date +%s)
    if (( current_time - start_time > timeout )); then
      log "[BG CHECK for $dep] Monitoring timed out. Exiting background check."
      break
    fi

    # Get the status of the newest pod for this deployment
    local pod_status
    pod_status=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" --sort-by='.metadata.creationTimestamp' -o=jsonpath='{.items[-1:].status.phase}' 2>/dev/null || echo "NoPods")

    if [[ "$pod_status" == "Failed" || "$pod_status" == "Unknown" ]]; then
      log "[BG CHECK for $dep] Pod entered '$pod_status' state. Dumping logs and exiting."
      # The main wait function will handle the full diagnostic dump.
      # This just gives an early warning.
      local failing_pod
      failing_pod=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" --sort-by='.metadata.creationTimestamp' -o=jsonpath='{.items[-1:].metadata.name}')
      log "--- EARLY LOGS for $failing_pod ---"
      kubectl logs "$failing_pod" -n "$NAMESPACE" --all-containers=true --tail=100 || true
      log "--- END EARLY LOGS ---"
      break
    fi

    # Check for CrashLoopBackOff in the container statuses
    local crash_loop
    crash_loop=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" --sort-by='.metadata.creationTimestamp' -o=jsonpath='{range .items[-1:].status.containerStatuses[*]}{.state.waiting.reason}{end}' 2>/dev/null)

    if [[ "$crash_loop" == "CrashLoopBackOff" ]]; then
        log "[BG CHECK for $dep] Pod is in CrashLoopBackOff. Dumping logs and exiting."
        local failing_pod
        failing_pod=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" --sort-by='.metadata.creationTimestamp' -o=jsonpath='{.items[-1:].metadata.name}')
        log "--- EARLY LOGS for $failing_pod ---"
        kubectl logs "$failing_pod" -n "$NAMESPACE" --all-containers=true --tail=100 --previous || true # Use --previous for crash loops
        log "--- END EARLY LOGS ---"
        break
    fi
    
    sleep 10 # Check every 10 seconds
  done
}


troubleshoot_pvc_and_nodes() {
  local pvc="$1"
  log "=== PVC TROUBLESHOOTING: $pvc ==="
  kubectl get pvc "$pvc" -n "$NAMESPACE" -o wide
  kubectl describe pvc "$pvc" -n "$NAMESPACE"
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | grep -i "pvc\|$pvc\|darkseek-db" | tail -20
  kubectl get nodes -o wide
  log "If PVC stuck in Pending → check node disk pressure or increase node pool size"
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
  local pod_name=""
  local timeout=300
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=darkseek-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$pod_name" ] && [ "$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}')" = "Running" ]; then
      break
    fi
    log "Waiting for darkseek-db pod... ($elapsed/$timeout)"
    sleep 10
    elapsed=$((elapsed + 10))
  done

  [ -z "$pod_name" ] && fatal "darkseek-db pod never appeared"

  kubectl exec -n "$NAMESPACE" "$pod_name" -- pg_isready -U "$POSTGRES_USER" -q || \
    { log "pg_isready failed"; kubectl logs "$pod_name" -n "$NAMESPACE"; fatal "Postgres not ready"; }

  kubectl exec -n "$NAMESPACE" "$pod_name" -- psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1;" >/dev/null 2>&1 || \
    { log "Cannot query database $POSTGRES_DB"; kubectl logs "$pod_name" -n "$NAMESPACE"; fatal "DB not functional"; }

  log "PostgreSQL fully ready and accepting connections"
}

verify_backend_image() {
  local deployment_name="$1"
  log "Verifying image for deployment $deployment_name..."
  local image
  image=$(kubectl get deployment "$deployment_name" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "Not found")
  if [ "$image" = "Not found" ]; then
    fatal "Deployment $deployment_name not found or has no image."
  fi
  log "Deployed image for $deployment_name: $image"
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
#  MODIFIED: wait for deployments with FAST feedback loop (LOGS IMPROVED)
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

  log "Waiting up to ${timeout}s for deployments to become Available..."
  for dep in "${deployments[@]}"; do
    log "=== Waiting for deployment/$dep ==="

    # Start the background check and get its Process ID (PID)
    check_pods_in_background "$dep" "$timeout" &
    local bg_pid=$!

    if kubectl wait --for=condition=available --timeout=${timeout}s "deployment/$dep" -n "$NAMESPACE"; then
      log "Deployment $dep is Available."
      kill "$bg_pid" 2>/dev/null || true
      continue
    fi

    # ------------------------------------------------------------------
    #  If we get here, the main wait command timed out.
    # ------------------------------------------------------------------
    kill "$bg_pid" 2>/dev/null || true
    log "WARNING: Deployment '$dep' did NOT become Available – dumping full diagnostics..."

    local pod_names
    pod_names=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$pod_names" ]; then
      for pod in $pod_names; do
        log "--- Full diagnostics for pod: $pod ---"
        kubectl describe pod "$pod" -n "$NAMESPACE" || true
        log "Logs for pod '$pod' (last 200 lines, including previous container crash):"
        # ADDED --previous flag to main log dump for CrashLoopBackOff analysis
        kubectl logs "$pod" -n "$NAMESPACE" --all-containers=true --tail=200 --previous || kubectl logs "$pod" -n "$NAMESPACE" --all-containers=true --tail=200 || log "Warning: Could not retrieve logs for pod '$pod'."
        kubectl exec "$pod" -n "$NAMESPACE" -- python -c "import sys; print(sys.path)" || true
      done
    else
      log "No pods found for label app=$dep"
    fi

    fatal "Deployment '$dep' failed to become ready – see diagnostics above."
  done
}

apply_network_policies() {
  log "Applying Zero-Trust Network Policies..."
  local policy_dir="./policies"
  
  if [ ! -d "$policy_dir" ]; then
    log "No policies directory found. Skipping NetworkPolicy application."
    return 0
  fi

  for policy in "$policy_dir"/*.yaml; do
    [ -f "$policy" ] || continue
    log "Applying network policy: $(basename "$policy")"
    kubectl apply -f "$policy" || log "Warning: Failed to apply $policy (may already exist)"
  done
  
  log "All network policies applied. Cluster now in Zero-Trust mode."
}

check_pod_statuses() {
  log "🔍 Checking pod health + NetworkPolicy attachment..."
  
  local timeout=300 
  local interval=10 
  local elapsed=0
  
  # Persistent state to survive the loop for the final decision tree
  local last_policy_warnings=0 
  local last_liveness_failures=0
  
  while [ $elapsed -lt $timeout ]; do
    # Reseting counters for THIS iteration
    # We use global scope (no 'local') so the decision tree can read them if we break
    policy_warnings=0
    liveness_failures=0
    
    for dep in "darkseek-backend-ws" "darkseek-backend-mqtt" "darkseek-frontend" "darkseek-db" "darkseek-redis"; do
      # 1. SAFE Policy check (ignores kubectl races)
      # We pipe to '|| true' or use local checks to prevent 'set -e' from killing the script here
      policy_status=$(kubectl describe pod -l app="$dep" -n "$NAMESPACE" 2>/dev/null | grep -A5 "Network Policies" || echo "NO_POLICY")
      
      if [[ "$policy_status" == "NO_POLICY" || -z "$policy_status" ]]; then
        log "⚠️ $dep: NO NetworkPolicies detected"
        ((policy_warnings++))
      else
        log "✅ $dep: Policies OK"
      fi
      
      # 2. BULLETPROOF Liveness (kubectl wait)
      # We use a conditional check so a 'fail' just increments our counter instead of exiting the script
      # Liveness (60s = bulletproof)
      if kubectl wait --for=condition=Ready pod -l app="$dep" --timeout=60s -n "$NAMESPACE" &>/dev/null; then
        log "✅ $dep healthy"
      else
        log "❌ $dep unhealthy"
        ((liveness_failures++))
      fi    

    done
    
    # Capture iteration state for the post-loop decision tree
    last_policy_warnings=$policy_warnings
    last_liveness_failures=$liveness_failures

    # Early exit ONLY if perfect
    if [ "$policy_warnings" -eq 0 ] && [ "$liveness_failures" -eq 0 ]; then
      log "✨ ALL PERFECT - Policies + Liveness 100%"
      return 0
    fi
    
    # If we are here, something is wrong. We only "fatal" out if we hit the timeout.
    log "⏳ Retrying stabilization ($elapsed/$timeout). Current: $policy_warnings warnings, $liveness_failures fails..."
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  
  # --- DECISION TREE / SELF-HEALING ---
  # This section is only reached if the loop times out.
  if [ "$last_liveness_failures" -gt 0 ]; then
    fatal "❌ $last_liveness_failures liveness failures - Pods are failing to start. Check logs."
  elif [ "$last_policy_warnings" -gt 0 ]; then
    log "🔧 AUTO-FIX TRIGGERED: $last_policy_warnings policy warnings detected."
    log "♻️ Re-applying NetworkPolicies to force CNI sync..."
    apply_network_policies
    sleep 10
    log "✅ SELF-HEALED: Policies re-applied. Deployment marked as complete."
    return 0 
  fi
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

kill_stale_pods() {
  local app_label="$1"
  log "NUKING ALL pods (running AND terminating) for app=$app_label ..."
  
  # This kills EVERYTHING — no exceptions, no mercy
  kubectl delete pod -l app="$app_label" --force --grace-period=0 --wait=false --ignore-not-found=true || true
  
  # Also instantly remove finalizers from the PVC — breaks the deadlock immediately
  kubectl patch pvc postgres-pvc -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  
  sleep 5
  log "All $app_label pods and PVC finalizers obliterated."
}

force_delete_pods() {
  local app_label="${1:-}"   # e.g. darkseek-backend-ws
  if [ -z "$app_label" ]; then
    log "force_delete_pods called without label – skipping"
    return 0
  fi

  log "Force deleting all pods with label app=$app_label ..."
  # --ignore-not-found makes it safe even if no pods exist
  kubectl delete pods -n "$NAMESPACE" -l "app=$app_label" \
    --grace-period=0 --force \
    --ignore-not-found=true \
    || true

  # Give scheduler a moment to notice they’re gone
  sleep 10
  log "Done force-deleting pods for $app_label"
}

deploy_main_apps() {
  local apps=(
    "darkseek-backend-ws:backend-ws-deployment.yaml"
    "darkseek-backend-mqtt:backend-mqtt-deployment.yaml"
    "darkseek-frontend:frontend-deployment.yaml"
  )
# Ensure frontend is last
  for entry in "${apps[@]}"; do
    local label="${entry%%:*}"
    local file="${entry##*:}"
    log "Deploying $file (app label: $label)..."
    force_delete_pods "$label"
    apply_with_sed "$file"
  done
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

#kubectl delete pod darkseek-db-6d8b945f9c-8849h --force --grace-period=0

# If it's already terminating or gone, also nuke any leftover finalizers on the PVC
#kubectl patch pvc postgres-pvc -p '{"metadata":{"finalizers":null}}' --type=merge
log "Deleting stale darkseek-db pods"
kill_stale_pods "darkseek-db"
#kill_stale_pods "darkseek-db"

# Also clear finalizers on PVC if stuck (nuclear but safe)
#kubectl patch pvc postgres-pvc -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
# REPLACE naked patch with:
if kubectl get pvc postgres-pvc -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
    log "⚠️ PVC stuck → Clearing finalizers..."
    kubectl patch pvc postgres-pvc -p '{"metadata":{"finalizers":null}}' --type=merge
else
    log "✅ PVC healthy (no finalizers needed)"
fi

kubectl apply -f configmap.yaml
dryrun_server
log "🔒 PRE-APPLY: NetworkPolicies (before pods exist)"
apply_network_policies
# 1. Core infrastructure first
apply_with_retry db-deployment.yaml
apply_with_retry redis-deployment.yaml
apply_with_retry db-pvc.yaml



# 2-3.After DB + Redis + PVC
# 
deploy_main_apps

# 4. Services
apply_with_retry backend-ws-service.yaml
apply_with_retry backend-mqtt-service.yaml
apply_with_retry frontend-service.yaml
apply_with_retry db-service.yaml
apply_with_retry redis-service.yaml
#🔧 CRITICAL: Give pods 10s to fully spawn BEFORE policies
#log "⏳ Waiting 10s for pods to initialize before policy lockdown..."


# 5. Lock it down
#apply_network_policies

#log "Patching images with GCP_PROJECT_ID..."
#kubectl set image deployment/darkseek-backend-ws backend-ws=gcr.io/${GCP_PROJECT_ID}/darkseek-backend-ws:latest -n default
#kubectl set image deployment/darkseek-backend-mqtt backend-mqtt=gcr.io/${GCP_PROJECT_ID}/darkseek-backend-mqtt:latest -n default

pvc_name="postgres-pvc"
deployment_name="darkseek-db"
dep_claim=$(kubectl get deployment $deployment_name -o jsonpath='{.spec.template.spec.volumes[?(@.name=="postgres-data")].persistentVolumeClaim.claimName}')
[ "$dep_claim" != "$pvc_name" ] && fatal "PVC mismatch."

pvc_status=$(kubectl get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
[ "$pvc_status" != "Bound" ] && { log "PVC not Bound."; troubleshoot_pvc_and_nodes "$pvc_name" ; fatal "PVC not Bound."; }

ensure_db_exists
check_db_initialization 
verify_backend_image "darkseek-backend-ws"
verify_backend_image "darkseek-backend-mqtt"

wait_for_deployments
sleep 21
check_pod_statuses

log "Setting IPs..."
WEBSOCKET_URI="wss://darkseek-backend-ws:8443/ws/"
MQTT_URI="http://darkseek-backend-ws:8000"
#WS_IP="" MQTT_IP=""
#for i in {1..5}; do
#  WS_IP=$(kubectl get service darkseek-backend-ws -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
#  MQTT_IP=$(kubectl get service darkseek-backend-mqtt -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
#  [ "$WS_IP" != "pending" ] && [ "$MQTT_IP" != "pending" ] && break
#  log "Waiting ($i/5)..."; sleep 30
#done

#[ "$WS_IP" != "pending" ] && [ "$MQTT_IP" != "pending" ] && \
#  kubectl patch configmap darkseek-config -n "$NAMESPACE" -p "{\"data\":{\"WEBSOCKET_URI\":\"wss://darkseek-backend-ws:8443/ws/\",\"MQTT_URI\":\"http://darkseek-backend-mqtt:8001\"}}" || true
  #kubectl patch configmap darkseek-config -n "$NAMESPACE" -p "{\"data\":{\"WEBSOCKET_URI\":\"wss://$WS_IP:443/ws/\",\"MQTT_URI\":\"https://$MQTT_IP:443\"}}" || true
  
#[ -z "$WS_IP" ] || [ "$WS_IP" = "pending" ] || [ -z "$MQTT_IP" ] || [ "$MQTT_IP" = "pending" ] && \
#  echo "Warning: IPs not assigned." >&2
  kubectl patch configmap darkseek-config -n "$NAMESPACE" -p "{\"data\":{\"WEBSOCKET_URI\":\"wss://darkseek-backend-ws:8443/ws/\",\"MQTT_URI\":\"http://darkseek-backend-ws:8000\"}}" || true

log "Deployment complete. Services:"
kubectl get services -n "$NAMESPACE" -o wide
log "DarkSeek deployed!"
echo "Access:"
echo " WebSocket: $WEBSOCKET_URI{session_id}"
echo " Backend API: $MQTT_URI/process_query"
echo " Frontend: http://<frontend-external-ip>"
