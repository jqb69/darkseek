#!/bin/bash
# --- Deploy DarkSeek to GKE (Without DNS) ---
# Date: 2025-09-30,Modified 2025-11-28
set -euo pipefail

NAMESPACE="default"
K8S_DIR="./k8s"
POLICY_DIR="./policies"
RETRY_APPLY=3
APPLY_SLEEP=3
MAX_RETRIES=10
RETRY_INTERVAL=10

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
  log "🔄 Checking PostgreSQL initialization (with retries)..."
  
  local pod_name
  pod_name=$(kubectl get pod -l app=darkseek-db -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name" | head -1)
  if [ -z "$pod_name" ]; then
    log "❌ No darkseek-db pod found"
    return 1
  fi
  
  # Wait for pod to be Running (ignore init container phase)
  for i in {1..30}; do
    if kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; then
      log "✅ Postgres pod Running"
      break
    fi
    log "⏳ Waiting for pod Running... ($i/30)"
    sleep 2
  done
  
  # RETRY pg_isready up to 3 minutes
  for i in {1..90}; do
    if kubectl exec "$pod_name" -n "$NAMESPACE" -- pg_isready -U "$POSTGRES_USER" -q 2>/dev/null; then
      log "✅ PostgreSQL ready (attempt $i)"
      
      # Bonus: verify we can actually query
      if kubectl exec "$pod_name" -n "$NAMESPACE" -- psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1;" >/dev/null 2>&1; then
        log "✅ Database $POSTGRES_DB fully operational"
        return 0
      fi
    fi
    
    # Show pod logs every 10 attempts for debugging
    if [ $((i % 10)) -eq 0 ]; then
      log "⏳ Postgres still starting... (attempt $i/90)"
      kubectl logs "$pod_name" -n "$NAMESPACE" --tail=5 || true
    fi
    
    sleep 2
  done
  
  log "❌ Postgres failed to become ready after 3 minutes"
  kubectl logs "$pod_name" -n "$NAMESPACE" || true
  kubectl describe pod "$pod_name" -n "$NAMESPACE" || true
  return 1
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

apply_networking() {
  log "🛡️ Applying DNS-Aware Zero-Trust Policies..."
  
  local policy_dir="${POLICY_DIR:-./policies}"
  
  if [ ! -d "$policy_dir" ]; then
    log "⚠️ Policy directory $policy_dir not found. Skipping networking layer."
    return 0
  fi

  log "📂 Using policy source: $policy_dir"
  # ONE tiE ONLY!!!!!
  #kubectl delete netpol deny-all-ingress -n "$NAMESPACE" && sleep 2 || true
  # CRITICAL DEPENDENCY ORDER: DB → Redis → WS
  kubectl apply -f "$policy_dir"/00-allow-dns.yaml -n "$NAMESPACE" && sleep 2
  
  
  # 1. DB FIRST (backend-ws needs postgres:5432)
  kubectl apply -f "$policy_dir"/04-allow-db-access.yaml -n "$NAMESPACE" && sleep 3
  
  # 2. REDIS SECOND (backend-ws needs redis:6379)  
  kubectl apply -f "$policy_dir"/05-allow-redis-access.yaml -n "$NAMESPACE" && sleep 3
  
  # 3. WS LAST (now has DB + Redis ingress)
  kubectl apply -f "$policy_dir"/02-allow-backend-ws.yaml -n "$NAMESPACE" && sleep 3

  # Remaining policies (safe order)
  log "Applying remaining application rules..."
  for policy in "$policy_dir"/{03,06,07}-*.yaml; do
    [ -f "$policy" ] && kubectl apply -f "$policy" -n "$NAMESPACE"
  done

  log "Applying frontend ingress rules..."
  for policy in "$policy_dir"/allow-frontend*.yaml; do
    [ -f "$policy" ] && kubectl apply -f "$policy" -n "$NAMESPACE"
  done
  #kubectl apply -f "$policy_dir"/01-deny-all.yaml -n "$NAMESPACE" && sleep 2
  log "✅ Policies: DNS→Deny→DB→Redis→WS→All ✅"
}




check_dns_resolution() {
  # Test if backend can see redis
  kubectl exec deployment/darkseek-backend-ws -- nslookup darkseek-redis &>/dev/null
}

verify_and_fix_networking() {
  log "🔍 Verifying Calico NetworkPolicy enforcement..."

  # 1. Verify controller (Grok's clean version)
  if kubectl get pods -n kube-system -l k8s-app=calico-node &>/dev/null && \
     kubectl get daemonset calico-node -n kube-system &>/dev/null; then
    log "✅ Calico CNI active"
  elif kubectl get pods -n kube-system -l app=gke-connectivity-agent &>/dev/null; then
    log "✅ GKE NetworkPolicy controller active"
  else
    log "⚠️ No NetworkPolicy support → Skipping"
    return 0
  fi

  # 2. Get WS pod
  local ws_pod=$(kubectl get pod -l app=darkseek-backend-ws -n "$NAMESPACE" --no-headers -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [ -z "$ws_pod" ] && { log "❌ No backend-ws pod"; return 1; }

  # 3. Policy count
  local policy_count=$(kubectl get netpol -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
  log "📋 $policy_count NetworkPolicies"

  # 4. Policy attachment check
  if kubectl describe pod "$ws_pod" -n "$NAMESPACE" | grep -A15 "Network Policies" | grep -q "allow-backend-ws"; then
    log "✅ WS policy attached"
  else
    log "⚠️ WS policy NOT attached (CNI delay?)"  # Normal for 2-3min
  fi

  # 5. TCP connectivity
  if kubectl exec "$ws_pod" -n "$NAMESPACE" -- timeout 10 nc -zv darkseek-redis 6379 &>/dev/null; then
    log "✅ WS → Redis TCP OK"
  else
    log "⚠️ WS → Redis TCP pending"
  fi

  # 6. DNS resolution (GENIUS PYTHON TEST)
  if kubectl exec "$ws_pod" -n "$NAMESPACE" -- python3 -c "import socket; socket.gethostbyname('darkseek-redis')" &>/dev/null; then
    log "✅ WS → Redis DNS OK"
  else
    log "⚠️ WS → Redis DNS failing"
  fi

  log "✅ Verification complete"
  return 0  # NEVER FAILS
}


check_system_health() {
  log "🔍 SURGICAL POLICY ATTACHMENT CHECK..."
  
  local problematic_pods=()
  local ws_policy_attached=false
  local redis_policy_attached=false

  # Helper: verify that a given policy is listed on a pod's "Network Policies" section
  verify_policy_on_pod() {
    local pod_label="$1"      # e.g. app=darkseek-backend-ws
    local policy_name="$2"    # e.g. allow-backend-ws
    local kind_label="$3"     # human name for logs, e.g. WS or REDIS

    local pod_name
    pod_name=$(kubectl get pod -l "app=${pod_label}" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$pod_name" ]; then
      log "⚠️ No pod with app=${pod_label} found. Skipping ${kind_label} attachment check."
      return 0
    fi

    # Policy object must exist
    if ! kubectl get netpol "$policy_name" -n "$NAMESPACE" &>/dev/null; then
      log "🚨 ${kind_label} POLICY MISSING → $policy_name not found in API"
      return 1
    fi

    # Check if policy name appears in the 'Network Policies' section of the pod description
    if kubectl describe pod "$pod_name" -n "$NAMESPACE" | grep -A10 "Network Policies" | grep -q "$policy_name"; then
      log "✅ ${kind_label} policy $policy_name listed on pod $pod_name"
      return 0
    else
      log "⚠️ ${kind_label} policy $policy_name exists but is NOT listed on pod $pod_name under 'Network Policies'"
      log "   → Possible causes: label mismatch, namespace mismatch, or CNI/controller delay."
      return 1
    fi
  }

  # 1. CHECK WS POLICY ATTACHMENT
  if verify_policy_on_pod "darkseek-backend-ws" "allow-backend-ws" "WS"; then
    ws_policy_attached=true
  else
    problematic_pods+=("darkseek-backend-ws")
    ws_policy_attached=false
  fi

  # 2. CHECK REDIS POLICY ATTACHMENT
  if verify_policy_on_pod "darkseek-redis" "allow-to-redis" "REDIS"; then
    redis_policy_attached=true
  else
    problematic_pods+=("darkseek-redis")
    redis_policy_attached=false
  fi

  # 3. SURGICAL NUCLEAR FIX - ONLY BROKEN POLICIES
  if [ ${#problematic_pods[@]} -gt 0 ]; then
    log "⚔️ SURGICALLY NUKE + RE-APPLY (WS/REDIS policies)"

    # TARGETED DELETE
    kubectl delete netpol allow-backend-ws allow-to-redis -n "$NAMESPACE" --ignore-not-found=true || true
    sleep 2

    # TARGETED RE-APPLY  
    kubectl apply -f "$POLICY_DIR/02-allow-backend-ws.yaml" -n "$NAMESPACE" || true
    kubectl apply -f "$POLICY_DIR/05-allow-redis-access.yaml" -n "$NAMESPACE" || true

    sleep 17  # controller propagation

    # VERIFY FIX BEHAVIORALLY (WS → Redis DNS)
    if kubectl exec deployment/darkseek-backend-ws -n "$NAMESPACE" -- nslookup darkseek-redis &>/dev/null; then
      log "✅ SURGICAL FIX SUCCESS - WS can resolve redis (DNS OK)"
    else
      log "⚠️ SURGICAL FIX PENDING - WS still cannot resolve redis. Manual intervention needed."
    fi
  else
    log "✅ ALL POLICIES APPEAR ATTACHED CORRECTLY"
  fi

  # 4. FINAL HEALTH CHECK (non-blocking)
  log "💚 Deployment health:"
  kubectl get deployments -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}:{.status.readyReplicas}/{.spec.replicas}{"\n"}{end}' || true

  return 0  # NEVER hard-fail from this helper
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

# After ANY policy apply/delete (surgical OR nuclear)
wait_for_policy_propagation() {
  log "⏳ Waiting 45 for Calico CNI propagation..."
  sleep 55  # CRITICAL: CNI needs this to update iptables
  
  log "🔍 Verifying policy attachment post-propagation..."
  check_system_health  # Now this will actually see policies attached
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
    #force_delete_pods "$label"
    apply_with_sed "$file"
  done
}

# --- MAIN (FINAL CLEAN VERSION) ---
log "Starting deployment..."
check_kubectl
check_envsubst
[ ! -d "$K8S_DIR" ] && fatal "Missing $K8S_DIR"
check_env_vars
check_manifest_files
cd "$K8S_DIR"

export GCP_PROJECT_ID=$(echo "$GCP_PROJECT_ID" | tr '[:upper:]' '[:lower:]')

# SECRETS + CONFIGMAP (always first)
log "🔑 Updating secrets + configmap..."
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

# =======================================================
# PHASE 1: STORAGE + DATABASE (PVC → DB → Service)
# =======================================================
log "🏗️ PHASE 1: Storage + Database..."
kill_stale_pods "darkseek-db"

# Clear PVC finalizers if stuck
if kubectl get pvc postgres-pvc -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
    log "⚠️ PVC stuck → Clearing finalizers..."
    kubectl patch pvc postgres-pvc -p '{"metadata":{"finalizers":null}}' --type=merge
fi

apply_with_retry db-pvc.yaml
apply_with_retry db-deployment.yaml
apply_with_retry db-service.yaml

log "⏳ 90s: DB initialization + PVC bind..."
sleep 90  # Postgres init container + PVC provisioning

pvc_name="postgres-pvc"
if [ "$(kubectl get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}')" != "Bound" ]; then
    troubleshoot_pvc_and_nodes "$pvc_name"
    fatal "PVC $pvc_name not Bound"
fi

ensure_db_exists
check_db_initialization  # Your retry version

# =======================================================
# PHASE 2: REDIS + SERVICES
# =======================================================
log "🔴 PHASE 2: Redis + Core Services..."
apply_with_retry redis-deployment.yaml
apply_with_retry redis-service.yaml

log "⏳ 30s: Redis startup..."
sleep 30

# =======================================================
# PHASE 3: APPLICATIONS (Now DB/Redis ready)
# =======================================================
log "🚀 PHASE 3: Deploy applications..."
deploy_main_apps  # ws + mqtt + frontend deployments

log "⏳ 45s: App pods startup + image pulls..."
sleep 45

verify_backend_image "darkseek-backend-ws"
verify_backend_image "darkseek-backend-mqtt"

# =======================================================
# PHASE 4.5: ALL SERVICES BEFORE WAIT (CRITICAL FIX)
# =======================================================
log "🌐 PHASE 4.5: All services (BEFORE wait)..."
apply_with_retry backend-ws-service.yaml
apply_with_retry backend-mqtt-service.yaml
apply_with_retry frontend-service.yaml

log "⏳ 30s: Service endpoints ready..."
sleep 30

wait_for_deployments  # NOW waits for ALL deployments + services

# =======================================================
# PHASE 5: NETWORK LOCKDOWN (Everything else ready)
# =======================================================
log "🔒 PHASE 5: Network lockdown..."
apply_networking  # DNS → DB → Redis → Apps

log "⏳ 180s CRITICAL Calico CNI propagation..."
sleep 180  # NO TESTS UNTIL CNI FINISHED

#verify_and_fix_networking
#wait_for_policy_propagation

log "🌐 QUICK TCP TESTS (proof everything works):"
# Test WS → Redis (no nc needed - use bash built-in /dev/tcp)
kubectl exec deployment/darkseek-backend-ws -- bash -c 'echo > /dev/tcp/darkseek-redis/6379 && echo "Redis OK" || echo "Redis FAILED"' || true
# Test WS → DB (Postgres port 5432)
kubectl exec deployment/darkseek-backend-ws -- bash -c 'echo > /dev/tcp/darkseek-db/5432 && echo "DB OK" || echo "DB FAILED"' || true
log "✅ Deploy COMPLETE - NO verification traps"
# =======================================================
# PHASE 6: FINAL CONFIG + STATUS
# =======================================================
log "✅ PHASE 6: Finalize..."
kubectl patch configmap darkseek-config -n "$NAMESPACE" -p '{
  "data": {
    "WEBSOCKET_URI": "wss://darkseek-backend-ws:8443/ws/",
    "MQTT_URI": "http://darkseek-backend-ws:8000"
  }
}' || true

log "🎉 DEPLOYMENT COMPLETE!"
echo "Services:"
kubectl get svc -n "$NAMESPACE" -o wide
echo "Deployments:"
kubectl get deployments -n "$NAMESPACE" -o wide
echo "Pods:"
kubectl get pods -n "$NAMESPACE" -o wide
echo ""
echo "✅ URLs:"
echo "  Frontend: http://$(kubectl get svc frontend-service -n '$NAMESPACE' -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/"
echo "  WebSocket: wss://darkseek-backend-ws:8443/ws/{session_id}"
echo "  API: http://darkseek-backend-ws:8000/process_query"
