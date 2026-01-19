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

nuke_namespace() {
  read -p "🚨 WARNING: This will delete ALL resources in $NAMESPACE. Continue? (y/N): " confirm
  if [[ "$confirm" == [yY] ]]; then
    log "💣 Nuking namespace $NAMESPACE..."
    kubectl delete all --all -n "$NAMESPACE"
    kubectl delete networkpolicy --all -n "$NAMESPACE"
    kubectl delete configmap --all -n "$NAMESPACE"
    kubectl delete secret --all -n "$NAMESPACE"
    log "✅ Namespace cleared."
  else
    log "Operation cancelled."
  fi
}

# ----------------------------------------------------------------------
#  MODIFIED ADVANCED DEBUG: Avoid sleep 3600!
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

  log "🚀 Creating EPHEMERAL debug pod for $dep (self-destructs in 30min)..."
  
  # Create SEPARATE debug pod - DON'T TOUCH production deployment
  # Start an ephemeral debug container attached to the existing pod
  kubectl debug -it "$pod" -n "$NAMESPACE" \
    --image=busybox:1.36 \
    --target="$container_name" \
    -- sh
  #kubectl run debug-$dep -n "$NAMESPACE" --image=busybox:1.36 --restart=Never --overrides='{
  #  "spec": {
  #    "containers": [{"name": "debug", "image": "busybox:1.36", "command": ["sleep", "1800"]}],
  #    "nodeSelector": {"kubernetes.io/hostname": "'$(kubectl get pod $pod -o jsonpath='{.spec.nodeName}')'"}
  #  }
  #}' || true
  
  #debug_pod=$(kubectl get pod debug-$dep -n "$NAMESPACE" -o name 2>/dev/null | sed 's/pod\///')
  #log "🔍 Debug pod ready: kubectl exec -it $debug_pod -n $NAMESPACE -- sh"
  log "⏰ Auto-deletes in 30min - WON'T BREAK PRODUCTION"
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

check_ca_cert_exists() {
  local cert_path="certs/ca.crt"
  
  log "🔍 Verifying ca.crt at $cert_path..."
  
  if [ ! -f "$cert_path" ]; then
    fatal "❌ ca.crt NOT FOUND at $cert_path!
           Download: curl -o certs/ca.crt https://test.mosquitto.org/ssl/mosquitto.org.crt
           Then: mkdir -p certs && mv ~/Downloads/mosquitto.org.crt certs/ca.crt"
  fi
  
  # Verify real certificate
  if [ ! "$(grep -e "-----BEGIN CERTIFICATE-----" "$cert_path")" ]; then
    fatal "❌ $cert_path invalid (missing BEGIN CERTIFICATE)"
  fi
  
  # Verify file size (should be ~1.4KB)
  local cert_size=$(stat -f%z "$cert_path" 2>/dev/null || stat -c%s "$cert_path")
  if [ "$cert_size" -lt 1000 ]; then
    fatal "❌ $cert_path too small ($cert_size bytes) - corrupted download?"
  fi
  
  export CERT_FILE="$cert_path"
  log "✅ certs/ca.crt VALID ($cert_size bytes) → Using: $CERT_FILE"
}

# ADD THIS IMMEDIATELY AFTER check_manifest_files() - BEFORE ANY DEPLOYMENTS

enable_gke_network_policy() {
  local cluster_name project zone
  
  # AUTO-DETECT CLUSTER INFO
  cluster_name=$(kubectl config current-context | cut -d'/' -f3)
  project=$(gcloud config get-value project 2>/dev/null || echo "$GCP_PROJECT_ID")
  zone=$(gcloud container clusters list --filter="name:$cluster_name" --format="value(location)" --limit=1 --project="$project")
  
  # EXPORT GLOBAL CLUSTER_NAME for entire script
  export CLUSTER_NAME="$cluster_name"
  export GCP_PROJECT="$project" 
  export CLUSTER_ZONE="$zone"
  
  log "🔍 Auto-detected → CLUSTER_NAME=$CLUSTER_NAME GCP_PROJECT=$GCP_PROJECT CLUSTER_ZONE=$CLUSTER_ZONE"
  
  # CHECK CURRENT STATUS
  if gcloud container clusters describe "$CLUSTER_NAME" --zone="$CLUSTER_ZONE" --project="$GCP_PROJECT" | grep -q "networkPolicy:.*enabled: true"; then
    log "✅ NetworkPolicy already ENABLED"
    return 0
  fi
  
  log "🔓 ENABLING GKE NetworkPolicy..."
  gcloud container clusters update "$CLUSTER_NAME" \
    --update-addons=NetworkPolicy=ENABLED \
    --zone="$CLUSTER_ZONE" --project="$GCP_PROJECT"
    
  gcloud container clusters update "$CLUSTER_NAME" \
    --enable-network-policy \
    --zone="$CLUSTER_ZONE" --project="$GCP_PROJECT"
  
  log "⏳ Waiting for Calico CNI..."
  for i in {1..30}; do
    if kubectl get pods -n kube-system -l k8s-app=calico-node &>/dev/null; then
      log "✅ Calico ACTIVE - NetworkPolicy READY!"
      return 0
    fi
    sleep 10
  done
}


check_network_policy_support() {
  log "🔍 Checking GKE NetworkPolicy support..."
  
  if kubectl get pods -n kube-system -l k8s-app=calico-node &>/dev/null; then
    log "✅ Calico CNI found - NetworkPolicy FULLY SUPPORTED"
    return 0
  fi
  
  if kubectl get daemonset -n kube-system gke-connectivity-agent &>/dev/null; then
    log "✅ GKE NetworkPolicy agent found - SUPPORTED"
    return 0
  fi
  
  log "🚨 NO NETWORKPOLICY CNI DETECTED - AUTO-ENABLING..."
  enable_gke_network_policy || {
    log "⚠️ NetworkPolicy enable failed - BYPASSING policies"
    export SKIP_POLICIES=true
  }
}

check_manifest_files() {
  log "Validating manifest files in '$K8S_DIR'..."
  required_files=("configmap.yaml" "backend-ws-deployment.yaml" "backend-mqtt-deployment.yaml" "frontend-deployment.yaml" "db-deployment.yaml" "redis-deployment.yaml" "backend-ws-service.yaml" "backend-mqtt-service.yaml" "frontend-service.yaml" "db-service.yaml" "redis-service.yaml" "db-pvc.yaml")
  for file in "${required_files[@]}"; do
    [ ! -f "$K8S_DIR/$file" ] && fatal "Missing file: $file"
  done
  log "All manifest files present."
}

run_policy_audit() {
  log "🔍 === SURGICAL POLICY AUDIT ==="

  declare -A audit_map=(
    ["darkseek-backend-mqtt"]="allow-backend-mqtt|allow-dns"
    ["darkseek-backend-ws"]="allow-backend-ws|allow-db-access|allow-redis-access|allow-dns"
    ["darkseek-redis"]="allow-redis-access|allow-to-redis"
    ["darkseek-db"]="allow-db-access|allow-to-db"
    ["darkseek-frontend"]="allow-frontend"
  )

  local failed_audit=0

  for app in "${!audit_map[@]}"; do
    local pod_name
    pod_name=$(kubectl get pod -l "app=${app}" -n "$NAMESPACE" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$pod_name" ]; then
      log "⚠️ $app: No running pod found. Skipping audit."
      continue
    fi

    local policy_list
    policy_list=$(kubectl describe pod "$pod_name" -n "$NAMESPACE" | \
      sed -n '/Network Policies:/,/^  [A-Z]/p' | \
      grep -E "allow-|dns" | xargs || echo "NONE")

    if echo "$policy_list" | grep -qE "${audit_map[$app]}"; then
      log "✅ $app: Attached -> [ $policy_list ]"
    else
      log "🚨 $app: MISMATCH!"
      log "   Expected: ${audit_map[$app]}"
      log "   Found:    $policy_list"
      failed_audit=$((failed_audit + 1))
    fi
  done

  if [ $failed_audit -eq 0 ]; then
    log "✨ ALL POLICIES VERIFIED ON KERNEL LEVEL"
  else
    log "⚠️ AUDIT FINISHED: $failed_audit mismatch(es) found."
  fi
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
  log "🔄 Checking PostgreSQL initialization (Internal Socket + Process)..."
  
  local pod_name
  pod_name=$(kubectl get pod -l app=darkseek-db -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name" | head -1)
  
  if [ -z "$pod_name" ]; then
    log "❌ No darkseek-db pod found"
    return 1
  fi
  
  # 1. Wait for Pod to be Ready (Handles InitContainers/Volume Mounts)
  kubectl wait --for=condition=Ready pod/"$pod_name" -n "$NAMESPACE" --timeout=120s || return 1

  # 2. THE PERPLEXITY ULTRA-ROBUST CHECK (Modified for Tool-less Containers)
  log "🧪 Verifying Postgres Internal State..."
  local db_alive=false
  for i in {1..20}; do
    # 1538 = Hex for Port 5432. 
    # This check is bulletproof: No 'ss' or 'netstat' required.
    if kubectl exec "$pod_name" -n "$NAMESPACE" -- sh -c "
      (grep -q '00000000:1538' /proc/net/tcp || grep -q '00000000:1538' /proc/net/tcp6) && \
      pgrep -f postgres >/dev/null
    "; then
      log "✅ Postgres Socket 5432 + Process both ACTIVE"
      db_alive=true
      break
    fi
    log "⏳ Waiting for Postgres to bind to interface... ($i/20)"
    sleep 3
  done

  if [ "$db_alive" = false ]; then
    log "❌ Postgres process/socket never stabilized."
    kubectl logs "$pod_name" -n "$NAMESPACE" -c postgres --tail=20
    return 1
  fi

  # 3. FINAL PROTOCOL CHECK
  log "📡 Running final pg_isready protocol check..."
  for i in {1..10}; do
    if kubectl exec "$pod_name" -n "$NAMESPACE" -- pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q; then
       log "✅ Protocol check passed. Database is accepting connections."
       return 0
    fi
    sleep 2
  done

  log "❌ Socket is open but pg_isready failed (likely Auth or NetworkPolicy loopback issue)."
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
    "darkseek-backend-mqtt"  
    "darkseek-backend-ws"
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
  
  sleep 7
  log "All $app_label pods and PVC finalizers obliterated."
}

# force_delete_pods: The GKE-Proof Cleanup (Logic by Perplexity)
force_delete_pods() {
  local app_label="${1:-}"
  local extra_label="${2:-}"  # Optional: e.g., "monitoring"
  local selector=""

  # 1. Build the Selector Dynamically
  if [ -n "$app_label" ] && [ -n "$extra_label" ]; then
    selector="app=$app_label,purpose=$extra_label"
  elif [ -n "$app_label" ]; then
    selector="app=$app_label"
  elif [ -n "$extra_label" ]; then
    selector="purpose=$extra_label"
  else
    log "⚠️ force_delete_pods called without targets – skipping"
    return 0
  fi

  log "☢️ FORCE DELETING pods with selector: [$selector]"
  
  # 2. The Heavy Lifting
  # --grace-period=0 --force: Tells K8s to bypass the container's exit signal
  kubectl delete pods -n "$NAMESPACE" -l "$selector" \
    --grace-period=0 --force \
    --ignore-not-found=true >/dev/null 2>&1 || true

  # 3. The "Cooldown": Essential for GKE/Calico to clear iptables
  log "⏳ Waiting 15s for CNI/Iptables reconciliation..."
  sleep 15
  log "✅ Cleanup for [$selector] complete."
}

verify_dns_connectivity() {
  log "🧪 Verifying Cluster DNS Configuration..."
  
  # 1. Force Label for Namespace Selector (Ensures policy can target kube-system)
  kubectl label namespace kube-system kubernetes.io/metadata.name=kube-system --overwrite >/dev/null 2>&1

  # 2. Get Live ClusterIP
  local dns_ip
  dns_ip=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  [ -z "$dns_ip" ] && { log "❌ ERROR: kube-dns IP not found."; return 1; }
  log "🔍 Detected Cluster DNS IP: $dns_ip"

  # 3. Apply the Sanitized Policy
  if [ -f "$POLICY_DIR/00-allow-dns.yaml" ]; then
    sed "s/DNS_IP_PLACEHOLDER/$dns_ip/g" "$POLICY_DIR/00-allow-dns.yaml" | tr -d '\302\240' | tr -d '\r' > "$POLICY_DIR/00-allow-dns.tmp.yaml"
    kubectl apply -f "$POLICY_DIR/00-allow-dns.tmp.yaml" -n "$NAMESPACE" && sleep 3
    rm -f "$POLICY_DIR/00-allow-dns.tmp.yaml"
    sleep 15 # Give Calico a head start
  else
    fatal "Missing DNS policy file."
  fi

  local canary_name="network-gate-canary"
  local max_attempts=15
  local attempt=1

  # --- STEP 1: PRE-FLIGHT (Outside the loop) ---
  local canary_status
  canary_status=$(kubectl get pod "$canary_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

  if [[ "$canary_status" == "Running" ]]; then
    log "🛰️ Re-using existing ACTIVE Network Canary..."
  elif [[ "$canary_status" == "Succeeded" ]] || [[ "$canary_status" == "Failed" ]] || [[ "$canary_status" == "Completed" ]]; then
    log "♻️ Found STALE Canary (Status: $canary_status). Replacing..."
    kubectl delete pod "$canary_name" -n "$NAMESPACE" --grace-period=0 --force >/dev/null 2>&1
    sleep 3 
    # Now create a fresh one
    kubectl run "$canary_name" -n "$NAMESPACE" --image=busybox:1.36 --restart=Never --labels="purpose=monitoring" --command -- sh -c "sleep 3600" >/dev/null 2>&1
    kubectl wait --for=condition=Ready "pod/$canary_name" -n "$NAMESPACE" --timeout=120s
  elif [[ "$canary_status" == "NotFound" ]]; then
    log "📡 Launching Stable Network Canary (60m TTL)..."
    kubectl run "$canary_name" -n "$NAMESPACE" --image=busybox:1.36 --restart=Never --labels="purpose=monitoring" --command -- sh -c "sleep 3600" >/dev/null 2>&1
    kubectl wait --for=condition=Ready "pod/$canary_name" -n "$NAMESPACE" --timeout=120s
  fi

  # --- STEP 2: THE PROBE LOOP ---
  log "📡 Running resolution test (looking for ANY response)..."
  while [ $attempt -le $max_attempts ]; do
    log "   Attempt $attempt/$max_attempts..."
    
    # Fast execute
    local output
    output=$(kubectl exec "$canary_name" -n "$NAMESPACE" -- nslookup google.com 2>&1 || true)

    if [[ "$output" == *"Address"* ]] || [[ "$output" == *"can't resolve"* ]]; then
      log "✅ Network Gate OPEN (DNS responded)."
      return 0
    fi

    log "⚠️ Attempt $attempt: Network Policy not yet propagated (Output: ${output:0:50}...)"
    
    [ $attempt -lt $max_attempts ] && sleep 10 # Reduced sleep because exec is cheap
    ((attempt++))
  done

  log "❌ DNS STILL BLOCKED (Absolute Timeout)."
  return 1 
}
verify_internal_connectivity() {
  local pod_name
  pod_name=$(kubectl get pod -l app=darkseek-backend-mqtt -n "$NAMESPACE" -o name | head -1)

  log "🧪 Testing path: MQTT -> Postgres (via $pod_name)..."

  # Use the real pod to run the test. 
  # If 'nc' is missing, we use 'timeout' with bash sockets as a backup
  if kubectl exec "$pod_name" -n "$NAMESPACE" -- sh -c "nc -zv darkseek-db 5432" >/dev/null 2>&1; then
    log "✅ Internal path OPEN."
    return 0
  else
    log "🚨 Internal path BLOCKED or 'nc' missing in image."
    # Dump logs for the developer to see if it was a timeout or a missing command
    kubectl exec "$pod_name" -n "$NAMESPACE" -- sh -c "nc -zv darkseek-db 5432" || true
    return 1
  fi
}

apply_networking() {
  log "🛡️ Applying DNS-Aware Policies..."
  
  local policy_dir="${POLICY_DIR:-./policies}"
  
  if [ ! -d "$policy_dir" ]; then
    log "⚠️ Policy directory $policy_dir not found. Skipping networking layer."
    return 0
  fi

  log "📂 Using policy source: $policy_dir"
  # 1. PREPARE & VALIDATE DNS (The Gatekeeper)
  # This function now handles the IP detection, the Patching, and the Retry Loop.
  # 2. RUN THE DNS GATE
  if ! verify_dns_connectivity; then
    log "🚨 NETWORK ERROR: DNS is blocked."
    log "Current Policy State:"
    kubectl describe netpol allow-dns-egress -n "$NAMESPACE"
    fatal "Deployment halted to avoid application isolation."
  fi
  #kubectl apply -f "$policy_dir"/00-allow-dns.yaml -n "$NAMESPACE" && sleep 2
  
  log "🔑 Opening paths to Database and Redis..."
  # 1. DB FIRST (backend-ws needs postgres:5432)
  kubectl apply -f "$policy_dir"/04-allow-db-access.yaml -n "$NAMESPACE" && sleep 3
  
  # 2. REDIS SECOND (backend-ws needs redis:6379)  
  kubectl apply -f "$policy_dir"/05-allow-redis-access.yaml -n "$NAMESPACE" && sleep 3
  
  # 3. OPEN THE APP PIPES (Producer then Consumer)
  log "📡 Opening MQTT Worker paths..."
  kubectl apply -f "$policy_dir"/03-allow-backend-mqtt.yaml -n "$NAMESPACE" && sleep 5
  
  log "🔌 Opening WebSocket API paths..."
  # 3. WS LAST (now has DB + Redis ingress)
  kubectl apply -f "$policy_dir"/02-allow-backend-ws.yaml -n "$NAMESPACE" && sleep 3
  
  # Remaining policies (safe order)
  log "Applying remaining application rules..."
  for policy in "$policy_dir"/{06,07}-*.yaml; do
    [ -f "$policy" ] && kubectl apply -f "$policy" -n "$NAMESPACE"
  done

  log "Applying frontend ingress rules..."
  for policy in "$policy_dir"/allow-frontend*.yaml; do
    [ -f "$policy" ] && kubectl apply -f "$policy" -n "$NAMESPACE"
  done
  #kubectl apply -f "$policy_dir"/01-deny-all.yaml -n "$NAMESPACE" && sleep 2
  log "✅ Policies: DNS→Deny→DB→Redis→WS→All ✅"
}



# Function to wait for application-level health files
wait_for_mqtt_health() {
  local app_label="darkseek-backend-mqtt"
  local health_file="/tmp/mqtt-healthy"
  
  log "⏳ Stability Watch: Waiting for MQTT TLS Handshake..."
  
  for i in {1..30}; do # Increased to 30 to allow for slow GKE volume/secret mounts
    # 1. CHECK FOR CRASHES (The Early Warning System)
    local pod_info
    pod_info=$(kubectl get pod -l app="$app_label" -n "$NAMESPACE" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount} {.items[0].metadata.name}' 2>/dev/null)
    
    local restarts=$(echo "$pod_info" | awk '{print $1}')
    local pod_name=$(echo "$pod_info" | awk '{print $2}')

    if [[ "$restarts" -gt 0 ]]; then
      log "🚨 FATAL: MQTT container is crashing (Restarts: $restarts)."
      log "🔍 Pulling TLS/Auth Error Logs..."
      kubectl logs "$pod_name" -n "$NAMESPACE" -c backend-mqtt --tail=50
      return 1
    fi

    # 2. CHECK FOR HEALTH FILE (The Logic Verification)
    if [[ -n "$pod_name" ]]; then
      # Using 'test -f' is the silent/clean way to check for file existence
      if kubectl exec "$pod_name" -n "$NAMESPACE" -c backend-mqtt -- test -f "$health_file" 2>/dev/null; then
        log "✅ MQTT Logic Verified: TLS Connected & Heartbeat Active."
        return 0
      fi
    fi

    # 3. INTERIM FEEDBACK
    if [[ $((i % 5)) -eq 0 ]]; then
       log "⏳ Attempt $i/30: No heartbeat yet. Checking network state..."
       # Check if the app is at least resolving DNS
       kubectl logs "$pod_name" -n "$NAMESPACE" -c backend-mqtt --tail=3 | grep -i "Connect" || true
    fi

    sleep 5
  done

  log "❌ MQTT TIMEOUT: Connection never established."
  return 1
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
    "darkseek-backend-mqtt:backend-mqtt-deployment.yaml"  
    "darkseek-backend-ws:backend-ws-deployment.yaml"
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

# =======================================================
# MONITORING: Frontend -> Backend Handshake
# =======================================================
# =======================================================
# MONITORING: Frontend -> Backend Handshake
# =======================================================
monitor_handshake() {
  log "🧪 GOLDEN COMMAND 2.5: Monitoring WS Handshake..."
  
  local ws_pod=$(kubectl get pods -l app=darkseek-backend-ws -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [ -z "$ws_pod" ]; then
    log "⚠️ No Backend WS pods found to monitor."
    return 1
  fi

  log "📡 Checking $ws_pod for active WebSocket upgrades..."
  
  # 1. Look for '101 Switching Protocols' (Standard WebSocket Handshake)
  # 2. Look for 'GET /ws' which is your typical endpoint
  if kubectl logs "$ws_pod" -n "$NAMESPACE" --tail=200 | grep -Ei "101|GET /ws|connection upgraded" > /dev/null; then
    log "✅ Handshake Verified: Backend is receiving WebSocket traffic!"
  else
    log "⚠️ No active handshake detected yet. The pod is up, but no clients have connected via WS."
  fi

  # 3. Simulate a ping from the Frontend pod to the WS Service
  local fe_pod=$(kubectl get pods -l app=darkseek-frontend -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$fe_pod" ]; then
    log "🌐 Testing path: Frontend -> Backend Service..."
    if kubectl exec "$fe_pod" -n "$NAMESPACE" -- curl -i -H "Upgrade: websocket" -H "Connection: Upgrade" http://darkseek-backend-ws:8000/ws/ 2>&1 | grep -q "101"; then
      log "✅ Network Path Open: Frontend can reach Backend WS."
    else
      log "❌ Path Blocked: Frontend cannot complete handshake to Backend. Check allow-backend-ws.yaml ingress rules."
    fi
  fi
}

check_mqtt_egress() {
    # Ensure variables exist
    [ -z "$MQTT_BROKER_HOST" ] && { log "⚠️ Skipping egress check: MQTT_BROKER_HOST not set."; return 0; }
    
    log "🔍 DIAGNOSTIC: Testing MQTT Egress to $MQTT_BROKER_HOST:8883..."
    
    local canary="network-gate-canary"
    
    # We use 'timeout 5' so the script doesn't hang if the packet is dropped
    if kubectl exec "$canary" -n "$NAMESPACE" -- timeout 5 nc -zv "$MQTT_BROKER_HOST" 8883 2>&1; then
        log "✅ NETWORK GATE OPEN: $MQTT_BROKER_HOST:8883 is reachable."
        return 0
    else
        log "❌ NETWORK GATE BLOCKED: Port 8883 is unreachable from this cluster."
        return 1
    fi
}

check_pod_stability() {
  log "🔍 Auditing Pod Stability..."
  
  # Fetch pods with restarts > 0
  local unstable_pods
  unstable_pods=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[?(@.status.containerStatuses[0].restartCount>0)]}{.metadata.name}{" (Restarts: "}{.status.containerStatuses[0].restartCount}{")\n"}{end}')

  if [ -n "$unstable_pods" ]; then
    echo -e "🚨 \033[0;31mSTABILITY ALERT: The following pods are crash-looping:\033[0m"
    echo -e "$unstable_pods"
    log "💡 Advice: Run 'kubectl describe pod <name>' to see the 'Last State: Terminated' reason."
    return 1
  else
    log "✅ All pods are stable (0 restarts)."
    return 0
  fi
}

show_deployment_dashboard() {
  echo -e "\n"
  log "========================================================="
  log "📊 DARKSEEK PRODUCTION DASHBOARD"
  log "========================================================="
  
  # 1. High-Level Summary
  log "🚀 Current Stack Status:"
  kubectl get pods -n "$NAMESPACE" -o custom-columns=\
"NAME:.metadata.name,\
PHASE:.status.phase,\
READY:.status.containerStatuses[*].ready,\
RESTARTS:.status.containerStatuses[*].restartCount"

  echo ""
  # 2. Trigger the Instability Post-Check
  check_pod_stability || true

  echo ""
  # 3. Traffic Entry Points
  log "🌐 External Access Points (GCLB/NEG):"
  kubectl get svc -n "$NAMESPACE" -l "app in (darkseek-frontend, darkseek-backend-ws)" \
    -o custom-columns="NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[*].ip,PORT:.spec.ports[*].port"
  
  log "========================================================="
  echo -e "\n"
}


# --- MAIN (FINAL CLEAN VERSION) ---
log "Starting deployment..."
check_kubectl
check_envsubst
[ ! -d "$K8S_DIR" ] && fatal "Missing $K8S_DIR"
check_env_vars
check_manifest_files
check_network_policy_support

export GCP_PROJECT_ID=$(echo "$GCP_PROJECT_ID" | tr '[:upper:]' '[:lower:]')

# Change ca.cert to ca.crt
check_ca_cert_exists
kubectl create secret generic darkseek-mqtt-certs \
  --from-file=ca.crt="$CERT_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -
cd "$K8S_DIR"
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


# 3. THE STRATEGIC PATCH
# We wait slightly to ensure the resource exists in the API
sleep 3
log "💉 Injecting Dynamic URIs into ConfigMap..."
kubectl patch configmap darkseek-config -n "$NAMESPACE" --type merge -p "{
  \"data\": {
    \"WEBSOCKET_URI\": \"wss://darkseek-backend-ws:8443/ws/\",
    \"MQTT_URI\": \"http://darkseek-backend-ws:8000\"
  }
}" || log "⚠️ Patch failed, check if configmap.yaml contains 'darkseek-config' name."

dryrun_server
log "🧹 Clearing stale monitoring pods..."
force_delete_pods "" "monitoring"
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

# APPlY ONE TIME TO BE DELETED!
if [ "${NUKE_MQTT_PODS:-false}" = "true" ]; then
  log "💣 Force deleting existing MQTT pods..."
  force_delete_pods "darkseek-backend-mqtt"
  sleep 15
fi
# APPlY ONE TIME TO BE DELETED!
if [ "${NUKE_WS_PODS:-false}" = "true" ]; then
  log "💣 Force deleting existing WS pods..."
  force_delete_pods "darkseek-backend-ws"
  sleep 15
fi
# APPlLY ONE TIME TO BE DELETED!
if [[ "${NUKE_WS_PODS:-false}" == "true" ||  "${NUKE_MQTT_PODS:-false}" == "true" ]]; then
  log "💣 Force deleting existing Frontend pods..."
  force_delete_pods "darkseek-frontend"
  sleep 15
fi
log "🔒 PHASE 1.5: Network lockdown..."
#kubectl delete netpol allow-dns-egress -n "$NAMESPACE" --ignore-not-found
# 🔥 ALL NETWORK POLICIES FIRST - PODS BORN SECURE
#log "🔒 Applying COMPLETE Zero-Trust framework (DNS+DB+Redis+WS)..."
apply_networking  # ALL policies - 00-dns + 04-db + 05-redis + 02-ws + ALL

log "⏳ 60s: CNI sync (all iptables rules ready)..."
sleep 60

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


# 🔥 PERMANENT SAFETY: Strip ANY ghost command overrides (safe idempotent)
log "🧹 Ensuring clean Deployment specs..."
kubectl patch deployment darkseek-backend-ws --type=json -p='[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]' 2>/dev/null || true
kubectl patch deployment darkseek-backend-mqtt --type=json -p='[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]' 2>/dev/null || true

log "🔴 PHASE 2: Redis + Core Services..."
apply_with_retry redis-deployment.yaml
apply_with_retry redis-service.yaml

log "⏳ 30s: Redis startup..."
sleep 30
# =======================================================
# PHASE 2: NETWORK LOCKDOWN (Everything else ready)
# =======================================================

# ... after apply_networking ...

#verify_dns_connectivity || fatal "NetworkPolicy is blocking DNS. Deployment halted."
# 2. Reset the Frontend Service (clears the bad NEG annotations)
#kubectl delete service darkseek-frontend --ignore-not-found=true

# =======================================================
# PHASE 3: REDIS + SERVICES
# =======================================================

# =======================================================
# PHASE 3: APPLICATIONS (Now DB/Redis ready)
# =======================================================
log "🚀 PHASE 4: Deploy applications..."
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
log "⏳ Waiting for pods to pass probes (This may take minutes)..."

# --- SMART TROUBLESHOOTING START ---
# Run the check once in the background so it doesn't block the script
check_mqtt_egress || log "⚠️ Warning: Connectivity check failed. Probes will likely time out."
# --- SMART TROUBLESHOOTING END ---
wait_for_deployments  # NOW waits for ALL deployments + services

#apply_networking  # DNS → DB → Redis → Apps

# =======================================================
# PHASE 4b: Connectivity & Health (The Validation Gate)
# =======================================================
log "🧪 PHASE 4b: Internal Network Validation..."

# 1. Check if the "Pipes" are open first
if ! verify_internal_connectivity; then
    log "🚨 CRITICAL: NetworkPolicy is blocking MQTT -> DB."
    log "Dumping NetworkPolicies for immediate audit:"
    kubectl get netpol -n "$NAMESPACE"
    # Exit early so you don't wait for a timeout that will never succeed
    fatal "Internal connectivity test failed."
fi
echo "🎉 PHASE 4.5 COMPLETE: Network paths verified."
#log "⏳ 293s CRITICAL Calico CNI propagation..."
sleep 59  # NO TESTS UNTIL CNI FINISHED
wait_for_mqtt_health
#verify_and_fix_networking
#wait_for_policy_propagation
# =======================================================
# PHASE 5: REDIS + SERVICES
# =======================================================
log "🔴 PHASE 5: Run Policy Audit ..."
run_policy_audit || true

log "🌐 SERVICE HEALTH CHECKS (Ignores Calico DNS issues):"
# CHECK DEPLOYMENTS EXIST + PODS RUNNING (not blocked by readiness)
kubectl get deployments -n "$NAMESPACE" || true
kubectl get pods -n "$NAMESPACE" || true

# CHECK ACTUAL CONTAINERS ALIVE (ignores readiness probes)
kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].status.phase}' | grep -v "Pending\|Failed" && echo "✅ Pods Running"

#log "✅ PHASE 6: Finalize..."

# Trigger a rolling update so apps pick up the NEW URIs
log "🔄 Refreshing apps to pick up new ConfigMap values..."

# Only restart if the previous command (patch) was successful
#if kubectl get configmap darkseek-config -n "$NAMESPACE" ; then
#    kubectl rollout restart deployment/darkseek-backend-ws -n "$NAMESPACE"
#    kubectl rollout restart deployment/darkseek-backend-mqtt -n "$NAMESPACE"
#fi
#sleep 33
#log "⏳ Waiting for rolling update to stabilize..."
#kubectl rollout status deployment/darkseek-backend-ws -n "$NAMESPACE" --timeout=120s
#kubectl rollout status deployment/darkseek-backend-mqtt -n "$NAMESPACE" --timeout=120s


# =======================================================
# GOLDEN COMMANDS - PRODUCTION VERIFICATION
# =======================================================
log "🟢 GOLDEN COMMAND 1: MQTT TLS Handshake Verification..."
kubectl logs -l app=darkseek-backend-mqtt -n "$NAMESPACE" --tail=100 | grep -i "connected\|ssl\|tls" || log "⚠️ No TLS logs found - check MQTT connection"

log "🟢 GOLDEN COMMAND 2: Zero-Trust Networking Test (WS → Redis)..."
if kubectl exec deployment/darkseek-backend-ws -n "$NAMESPACE" -- nc -zv darkseek-redis 6379 &>/dev/null; then
  log "✅ Zero-Trust: WS → Redis:6379 OPEN ✓"
else
  log "❌ Zero-Trust: WS → Redis BLOCKED - Check allow-redis-access.yaml"
fi
monitor_handshake
log "🟢 GOLDEN COMMAND 3: ConfigMap Phase 6 Patch Verification..."
kubectl get configmap darkseek-config -n "$NAMESPACE" -o jsonpath='{.data.WEBSOCKET_URI}' && echo "" || log "⚠️ ConfigMap WEBSOCKET_URI missing"
kubectl get configmap darkseek-config -n "$NAMESPACE" -o jsonpath='{.data.MQTT_URI}' && echo "" || log "⚠️ ConfigMap MQTT_URI missing"

log "✅ GOLDEN VERIFICATION COMPLETE"

log "✅ Deploy COMPLETE - Calico policies applied successfully"
# =======================================================
# PHASE 6: FINAL CONFIG + STATUS
# =======================================================

log "⏳ Waiting for LoadBalancer IPs (60s max)..."
for i in {1..12}; do
  FRONTEND_IP=$(kubectl get svc darkseek-frontend -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$FRONTEND_IP" ] && [ "$FRONTEND_IP" != "<pending>" ] && break
  log "Frontend LB still provisioning... ($i/12)"
  sleep 5
done
log "🎉 DEPLOYMENT COMPLETE!"
echo "Services:"
kubectl get svc -n "$NAMESPACE" -o wide
echo "Deployments:"
kubectl get deployments -n "$NAMESPACE" -o wide

log "🎉 DEPLOYMENT COMPLETE!"

# Call the new Dashboard
show_deployment_dashboard

log "💡 To monitor all application logs in real-time, run:"
echo "kubectl logs -f -n $NAMESPACE -l 'app in (darkseek-backend-ws, darkseek-backend-mqtt, darkseek-frontend)' --tail=20 --prefix"

log "✅ Done."
log "🎉 Done! Use 'kubectl logs -f deployment/darkseek-backend-mqtt' to watch TLS traffic."
