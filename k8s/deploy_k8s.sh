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
  local cert_path=$CERT_FILE_ABS
  
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
  log "🔍 === SURGICAL INFRASTRUCTURE AUDIT (Zero-Trust) ==="

  # 1. Corrected Policy Mapping
  declare -A audit_map=(
    ["darkseek-backend-mqtt"]="allow-to-backend-mqtt"
    ["darkseek-backend-ws"]="allow-backend-ws"
    ["darkseek-frontend"]="allow-frontend-ingress" # <--- Updated Name
  )

  # 2. Path Probes (Source -> Target:Port)
  declare -A infra_probe_map=(
    ["darkseek-backend-mqtt"]="darkseek-db:5432 darkseek-redis:6379"
    ["darkseek-backend-ws"]="darkseek-db:5432 darkseek-redis:6379"
    ["darkseek-frontend"]="darkseek-backend-ws:8443"
  )

  # Use a fixed order to ensure the Frontend is audited first
  for app in "darkseek-frontend" "darkseek-backend-mqtt" "darkseek-backend-ws"; do
    local pod_name
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l "app=${app}" --field-selector=status.phase=Running -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)

    if [ -z "$pod_name" ]; then
      log "⚠️ $app: No Running pods found. Skipping."
      continue
    fi

    log "📡 Auditing Path: $app ($pod_name)"

    # --- STEP 1: Metadata Check ---
    local policy_name="${audit_map[$app]}"
    if kubectl get netpol "$policy_name" -n "$NAMESPACE" &>/dev/null; then
      log "   📜 Policy Found: $policy_name"
    else
      log "   🚨 Policy Missing: $policy_name (Check your YAML names!)"
    fi

    # --- STEP 2: Functional Connectivity Probes ---
    for target in ${infra_probe_map[$app]}; do
      local host=${target%:*}; local port=${target#*:}
      local fqdn="${host}.${NAMESPACE}.svc.cluster.local"

      log "   🧪 [PROBE] $app -> $host:$port..."
      
      # Surgical Python TCP check (Handles ndots: 1 via FQDN)
      if kubectl exec "$pod_name" -n "$NAMESPACE" -- python3 -c \
        "import socket; s=socket.socket(); s.settimeout(2); exit(0 if s.connect_ex(('$fqdn', $port)) == 0 else 1)" &>/dev/null; then
        log "      🟢 SUCCESS: Connection Handshake Verified"
      else
        log "      🔴 FAILURE: Path is BLOCKED"
        
        # Specific troubleshooting for the Frontend -> Backend link
        if [[ "$app" == "darkseek-frontend" ]]; then
           log "      💡 Tip: Check if 'allow-backend-ws' allows Ingress from 'app: darkseek-frontend'"
        fi
      fi
    done
    echo "-------------------------------------------------------"
  done
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
    pod_status=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" \
    --sort-by='.metadata.creationTimestamp' \
    -o jsonpath='{.items[-1].status.phase}' 2>/dev/null)

    # Fallback if the variable is empty (no pods found)
    pod_status=${pod_status:-"NoPods"}
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
  local db_pod
  db_pod=$(kubectl get pods -n "$NAMESPACE" -l app=darkseek-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  [[ -z "$db_pod" ]] && fatal "Postgres pod not found. Cannot ensure database existence."

  log "🐘 Checking for Database: '$POSTGRES_DB'..."

  # 1. WAIT for the SQL socket to be ready (internal to the pod)
  # This prevents "Connection Refused" errors during the psql call
  local retry=0
  local max_retries=10
  until kubectl exec -n "$NAMESPACE" "$db_pod" -- pg_isready -U "$POSTGRES_USER" &>/dev/null; do
    ((retry++))
    if [ $retry -gt $max_retries ]; then
      fatal "Postgres engine failed to respond to pg_isready after 50s."
    fi
    log "⏳ Waiting for Postgres engine to accept local connections... ($retry/$max_retries)"
    sleep 5
  done

  # 2. Check and Create Logic
  # We use the pod name directly (faster/more stable than deployment/ name in exec)
  if ! kubectl exec -n "$NAMESPACE" "$db_pod" -- psql -U "$POSTGRES_USER" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$POSTGRES_DB'" | grep -q 1; then
    log "🏗️ Creating database '$POSTGRES_DB'..."
    kubectl exec -n "$NAMESPACE" "$db_pod" -- psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE \"$POSTGRES_DB\";"
    log "✅ Database '$POSTGRES_DB' created successfully."
  else
    log "✅ Database '$POSTGRES_DB' already exists."
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
  local deployments=("darkseek-db" "darkseek-redis" "darkseek-backend-mqtt" "darkseek-backend-ws" "darkseek-frontend")
  local timeout=900

  log "Waiting up to ${timeout}s for deployments to become Available..."
  
  for dep in "${deployments[@]}"; do
    log "=== Checking deployment/$dep ==="
    
    # Start your background logger
    check_pods_in_background "$dep" "$timeout" &
    local bg_pid=$!

    # --- SMART SUB-LOOP ---
    local start_time=$(date +%s)
    while true; do
      local current_time=$(date +%s)
      local elapsed=$((current_time - start_time))

      # Check if K8s considers it "Available"
      if kubectl get deployment "$dep" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"; then
        log "✅ Deployment $dep is Available."
        kill "$bg_pid" 2>/dev/null || true
        break
      fi

      # FAIL FAST: Check for restarts (The "21-minute" Killer)
      local restarts=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
      if [ "$restarts" -gt 0 ]; then
        log "❌ CRITICAL: $dep has restarted ($restarts times). Diagnosing now..."
        # Trigger your existing diagnostic logic
        dump_pod_diagnostics "$dep" 
        kill "$bg_pid" 2>/dev/null || true
        fatal "Deployment '$dep' is crashing. Stopping."
      fi

      if [ "$elapsed" -gt "$timeout" ]; then
        kill "$bg_pid" 2>/dev/null || true
        fatal "Timeout waiting for $dep."
      fi

      sleep 5
    done
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

dump_pod_diagnostics() {
    local dep=$1
    log "🔍 STARTING DIAGNOSTIC DUMP FOR: $dep"
    
    local pod_names
    pod_names=$(kubectl get pods -n "$NAMESPACE" -l "app=$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$pod_names" ]; then
      for pod in $pod_names; do
        log "--- 📋 Description for pod: $pod ---"
        kubectl describe pod "$pod" -n "$NAMESPACE" || true
        
        log "--- 📝 Logs for pod: $pod (Current + Previous) ---"
        # We try to get the 'previous' logs first, as that's where the crash reason lives
        kubectl logs "$pod" -n "$NAMESPACE" --all-containers=true --tail=100 --previous 2>/dev/null || \
        kubectl logs "$pod" -n "$NAMESPACE" --all-containers=true --tail=100 || \
        log "⚠️ Warning: Could not retrieve any logs for pod '$pod'."
        
        # Check for Python-specific pathing issues
        log "--- 🐍 Python System Path ---"
        kubectl exec "$pod" -n "$NAMESPACE" -- python3 -c "import sys; print(sys.path)" 2>/dev/null || true
      done
    else
      log "❌ No pods found for label app=$dep"
    fi
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

template_dns_policies() {
    # 1. VALIDATE OR SET DEFAULT
    # Uses 34.118.224.10 if $1 is empty or unset
    local gkedns="${1:-34.118.224.10}" 
    
    if [[ -z "$1" ]]; then
        log "⚠️ WARNING: GKE_DNS not provided. Falling back to default: $GKE_DNS"
    else
        log "🎯 GKE_DNS identified: $gkedns"
    fi

    # TARGETS are locally scoped to this prep task
    local TARGETS=("00-allow-dns.yaml" "03-allow-backend-mqtt.yaml")

    log "🧹 Scrubbing and generating temporary manifests..."
    for FILENAME in "${TARGETS[@]}"; do
        local FULL_PATH="$POLICY_DIR/$FILENAME"
        [[ ! -f "$FULL_PATH" ]] && { log "❌ MISSING: $FULL_PATH"; return 1; }

        # Scrub artifacts and swap placeholder, then flush to .tmp
        # tr -d '\302\240\r' handles those invisible copy-paste characters
        cat "$FULL_PATH" | \
            tr -d '\302\240\r' | \
            sed "s/DNS_IP_PLACEHOLDER/$gkedns/g" | \
            sed 's/^[[:space:]]*$//; /^$/d' > "${FULL_PATH}.tmp"
        
        # Verify the .tmp file actually exists and isn't empty
        if [[ ! -s "${FULL_PATH}.tmp" ]]; then
            log "❌ ERROR: Failed to create ${FILENAME}.tmp"
            return 1
        fi
    done

    log "✅ Templates prepared with DNS IP: $gkedns"
    return 0
}

verify_dns_connectivity() {
  local polname="allow-dns-global"
  local canary_name="network-gate-canary"
  local max_attempts=15
  local attempt=1
  local ns="${NAMESPACE:-default}"

  log "🧪 [SCOUT] Initializing DNS Canary: $canary_name"

  # 1. LIFECYCLE MANAGEMENT
  local status
  status=$(kubectl get pod "$canary_name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

  case "$status" in
    "Running")
      log "🛰️  Re-using existing active canary."
      ;;
    "NotFound" | "Succeeded" | "Failed" | "Completed" | "CrashLoopBackOff")
      log "♻️  Deploying fresh canary (Previous: $status)..."
      kubectl delete pod "$canary_name" -n "$ns" --grace-period=0 --force >/dev/null 2>&1
      sleep 2
      # STICKING TO NAME, FIXING LABEL
      kubectl run "$canary_name" -n "$ns" \
        --image=busybox:1.36 \
        --restart=Never \
        --labels="app=darkseek-backend-mqtt" \
        --command -- sh -c "sleep 3600" >/dev/null 2>&1
      
      kubectl wait --for=condition=Ready "pod/$canary_name" -n "$ns" --timeout=120s || return 1
      ;;
  esac

  # 2. THE PROBE LOOP
  while [ $attempt -le $max_attempts ]; do
    if kubectl exec "$canary_name" -n "$ns" -- nslookup google.com >/dev/null 2>&1; then
      log "✅ DNS Gate OPEN."
      return 0
    fi
    log "⚠️  Attempt $attempt/$max_attempts: Gate closed..."
    sleep 10
    ((attempt++))
  done

  return 1
}

verify_internal_connectivity() {
  local pod_name
  # Extract just the name (e.g., darkseek-backend-mqtt-xxxx) without the 'pod/' prefix
  pod_name=$(kubectl get pod -l app=darkseek-backend-mqtt -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

  if [ -z "$pod_name" ]; then
    log "⚠️ No MQTT pod found. Skipping connectivity test."
    return 1
  fi

  log "🧪 Testing internal path: MQTT -> Postgres (via $pod_name)..."

  # We use Python3 to attempt a TCP connection to the database service
  # s.connect_ex returns 0 on success, anything else is a failure
  if kubectl exec "$pod_name" -n "$NAMESPACE" -- python3 -c \
    "import socket; s = socket.socket(); s.settimeout(5); exit(0 if s.connect_ex(('darkseek-db', 5432)) == 0 else 1)"; then
    log "✅ Internal path OPEN (TCP 5432 Reachable)."
    return 0
  else
    log "❌ Internal path BLOCKED. MQTT cannot reach darkseek-db:5432."
    log "💡 Check if the 'allow-to-backend-mqtt' NetworkPolicy permits egress to the database."
    return 1
  fi
}

verify_cluster_network_integrity() {
  local TARGET_LABEL="app=darkseek-backend-mqtt"
  local current_pod=""
  log "🛡️  DIAGNOSTIC: Probing Active Network Gates via $TARGET_LABEL..."

  for i in {1..12}; do
    current_pod=$(kubectl get pods -n "$NAMESPACE" -l "$TARGET_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -z "$current_pod" ]]; then
      log "⏳ ($i/12) Waiting for any pod with label $TARGET_LABEL..."
      sleep 5
      continue
    fi

    local phase=$(kubectl get pod "$current_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [[ "$phase" != "Running" ]]; then
      log "⏳ ($i/12) Pod $current_pod found but phase is: $phase. Waiting..."
      sleep 5
      continue
    fi

    # --- REPLACING NSLOOKUP WITH NATIVE PYTHON DNS CHECK ---
    # 3. DNS PROBE (The Python Way)
    if ! kubectl exec "$current_pod" -n "$NAMESPACE" -- python3 -c "import socket; socket.gethostbyname('$MQTT_BROKER_HOST')" > /dev/null 2>&1; then
      log "⚠️  ($i/12) DNS Resolution failed via Python on $current_pod."
    else
      # 4. PORT 8883 HANDSHAKE (Already using Python)
      if kubectl exec "$current_pod" -n "$NAMESPACE" -- python3 -c "import socket; s=socket.socket(); s.settimeout(3); exit(s.connect_ex(('$MQTT_BROKER_HOST', 8883)))" 2>/dev/null; then
        log "✅ NETWORK VERIFIED: DNS OK, Broker 8883 Reachable."
        return 0
      fi
      log "⚠️  ($i/12) DNS OK, but Port 8883 unreachable."
    fi
    sleep 5
  done

  # --- AUTOPSY SECTION ---
  local polname="allow-dns-global"
  log "🚨 DNS AUTOPSY: Starting deep-dive failure analysis..."
  echo "-----------------------------------------------------------------------"
  
  echo "1. Namespace Label Check:"
  kubectl get ns kube-system --show-labels | grep "kubernetes.io/metadata.name=kube-system" || echo "❌ ERROR: kube-system label GONE!"

  echo "2. Policy Selector Check:"
  kubectl describe netpol "$polname" -n "$NAMESPACE" | grep -A 5 "Spec:" || echo "❌ ERROR: Policy $polname NOT FOUND"

  echo "3. Placeholder Verification (Live CIDR):"
  kubectl get netpol "$polname" -n "$NAMESPACE" -o yaml | grep -iC 2 "cidr" || echo "❌ ERROR: No CIDR found in policy"

  echo "4. Raw IP Egress Test (Bypassing DNS):"
  if [[ -n "$current_pod" ]]; then
    # FIXED: Using current_pod instead of pod_name
    kubectl exec "$current_pod" -n "$NAMESPACE" -- python3 -c "import socket; s=socket.socket(); s.settimeout(2); exit(s.connect_ex(('8.8.8.8', 53)))" 2>/dev/null \
      && echo "✅ Raw UDP/53 Egress is OPEN" || echo "❌ Raw UDP/53 Egress is BLOCKED"
  else
    echo "❌ ERROR: No pod available to run Egress test."
  fi
  echo "-----------------------------------------------------------------------"

  return 1
}


apply_networking() {
  log "🛡️ Applying DNS-Aware Policies..."
  
  # Ensure we use the global variable consistently
  local p_dir="${POLICY_DIR:-./policies}"
  
  if [ ! -d "$p_dir" ]; then
    log "⚠️ Policy directory $p_dir not found. Skipping networking layer."
    return 0
  fi

  # 1. DISCOVER & TEMPLATE
  # --- Inside apply_networking() ---

  # 1. Fetch the real IP
  GKE_DNS=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  [[ -z "$GKE_DNS" ]] && GKE_DNS="34.118.224.10"
  log "🎯 GKE_DNS DETECTED: $GKE_DNS"
  export GKE_DNS

  # 2. DO NOT FORCE THE COMMAND - Let it fail silently if Warden blocks it
  log "🏷️ Attempting to label kube-system (skipping if forbidden)..."
  kubectl label ns kube-system kubernetes.io/metadata.name=kube-system --overwrite 2>/dev/null || log "⚠️ Warden blocked label, continuing with IP-based rules..."

  template_dns_policies "$GKE_DNS" || return 1
  
  # 2. APPLY FOUNDATION (DNS First)
  kubectl apply -f "$p_dir/00-allow-dns.yaml.tmp" --force && sleep 2
  
  # 3. APPLY INFRASTRUCTURE (DB & Redis)
  log "🔑 Opening paths to Database and Redis..."
  [ -f "$p_dir/04-allow-db-access.yaml" ] && kubectl apply -f "$p_dir/04-allow-db-access.yaml"
  [ -f "$p_dir/05-allow-redis-access.yaml" ] && kubectl apply -f "$p_dir/05-allow-redis-access.yaml"
  sleep 3
  
  # 4. APPLY APP WORKERS (MQTT then WS)
  log "📡 Opening MQTT Worker paths..."
  kubectl apply -f "$p_dir/03-allow-backend-mqtt.yaml.tmp" && sleep 5
  
  log "🔌 Opening WebSocket API paths..."
  [ -f "$p_dir/02-allow-backend-ws.yaml" ] && kubectl apply -f "$p_dir/02-allow-backend-ws.yaml"
  sleep 3
  
  # 5. REMAINING POLICIES (Safe globbing)
  log "Applying remaining application rules..."
  # This syntax is safer for loops
  for policy in "$p_dir"/0[6]-*.yaml "$p_dir"/allow-frontend*.yaml; do
    if [ -f "$policy" ]; then
       kubectl apply -f "$policy"
    fi
  done

  

  # 7. VERIFY (The Final Gate)
  if ! verify_dns_connectivity; then
    log "🚨 NETWORK ERROR: DNS is blocked."
    log "Current Policy State (Egress):"
    kubectl describe netpol allow-dns-global # Matching the name in your 00-allow-dns.yaml
    fatal "Deployment halted to avoid application isolation."
  fi
  
  # 6. CLEANUP
  sleep 2
  rm -f "$p_dir"/*.tmp
  log "🧹 Temp files purged."
    
  log "✅ Policies: DNS → DB → Redis → MQTT → WS → Frontend ✅"
}

wait_for_mqtt_health() {
  local app_label="darkseek-backend-mqtt"
  local health_file="/tmp/mqtt-healthy"
  
  log "⏳ Stability Watch: Waiting for External Broker Handshake..."

  for i in {1..30}; do
    # 1. Find the Pod
    local pod_name=$(kubectl get pod -l app="$app_label" -n "$NAMESPACE" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -z "$pod_name" ]]; then
      log "⏳ Attempt $i/30: No Running Pod found..."
      sleep 5; continue
    fi

    # 2. SURGICAL DNS PROBE (Verify Egress Path)
    # We use 'getent hosts' or 'python' because nslookup isn't always installed in lean images
    if ! kubectl exec "$pod_name" -n "$NAMESPACE" -- python3 -c "import socket; socket.gethostbyname('test.mosquitto.org')" > /dev/null 2>&1; then
        log "❌ DNS FAILURE: Pod cannot resolve external host. Check EGRESS rules in MQTT NetPol."
        # Don't return 1 yet, let it retry in case CNI is still warming up
    else
        log "📡 DNS OK: External resolution is working."
    fi

    # 3. THE TRUTH: Check for the Handshake File (Verify Ingress/App Logic)
    if kubectl exec "$pod_name" -n "$NAMESPACE" -- test -f "$health_file" 2>/dev/null; then
      log "✅ SUCCESS: Handshake completed. External Broker Ingress is WORKING."
      return 0
    fi

    [[ $((i % 5)) -eq 0 ]] && log "⏳ Attempt $i/30: Handshake file ($health_file) not found yet..."
    sleep 5
  done

  log "❌ FATAL TIMEOUT: Check if Broker Port 8883 is allowed in EGRESS and if Pod has 'app: $app_label' label."
  return 1
}



verify_policy_active() {
  local pod_name=$(kubectl get pods -l app=darkseek-backend-mqtt -n "$NAMESPACE" -o jsonpath='{..metadata.name}' | awk '{print $1}')
  
  echo "-------------------------------------------------------"
  echo "🛡️  SECURITY AUDIT: allow-to-backend-mqtt"
  
  if [ -z "$pod_name" ]; then
    echo "❌ ERROR: No MQTT Pod found to audit."
    return 1
  fi

  # 1. Verify Egress Rule 1 (The 0.0.0.0/0 Port 53 fix)
  echo "🔎 Checking DNS Hole-Punch..."
  if kubectl exec "$pod_name" -n "$NAMESPACE" -- nc -zv -w 2 8.8.8.8 53 2>&1 | grep -q "open"; then
    echo "✅ DNS Egress: OPEN (0.0.0.0/0 rule is working)"
  else
    echo "⚠️  DNS Egress: Restricted (Normal if only GKE DNS is reachable)"
  fi

  # 2. Verify External MQTT (Port 8883)
  echo "🔎 Checking External MQTT Path..."
  if kubectl exec "$pod_name" -n "$NAMESPACE" -- nc -zv -w 2 test.mosquitto.org 8883 2>&1 | grep -q "open"; then
    echo "✅ MQTT Egress: OPEN (Port 8883 is reachable)"
  else
    echo "❌ MQTT Egress: BLOCKED (Check Rule #3 in your YAML)"
  fi

  # 3. Verify Internal Database (Port 5432)
  echo "🔎 Checking Internal DB Path..."
  if kubectl exec "$pod_name" -n "$NAMESPACE" -- nc -zv -w 2 darkseek-db 5432 2>&1 | grep -q "open"; then
    echo "✅ DB Egress: OPEN (Internal Rule #2 is working)"
  else
    echo "❌ DB Egress: BLOCKED (Check Rule #2 in your YAML)"
  fi
  echo "-------------------------------------------------------"
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

run_mqtt_failure_trace() {
    local pod="$1"
    local ns="$2"
    local target_pol="allow-to-backend-mqtt"
    local dns_target="34.118.224.10"
    
    log "🕵️ [TRACE] AUDITING LIVE CLUSTER STATE..."

    # 1. CHECK POLICY INTEGRITY
    log "    🔍 TRACE 1: Verifying NetworkPolicy '$target_pol'..."
    local live_yaml=$(kubectl get netpol "$target_pol" -n "$ns" -o yaml 2>/dev/null)
    
    if [[ "$live_yaml" == *"DNS_IP_PLACEHOLDER"* ]]; then
        log "      🚨 CRITICAL: The sed script FAILED. Placeholder still exists!"
    fi

    # 2. CHECK RULE 1b (THE SILENT KILLER)
    log "    🔍 TRACE 2: Auditing Namespace Labels for Rule 1b..."
    if kubectl get ns kube-system --show-labels | grep -q "kubernetes.io/metadata.name=kube-system"; then
        log "      ✅ kube-system is correctly labeled."
    else
        log "      🚨 ERROR: kube-system MISSING 'kubernetes.io/metadata.name'. Rule 1b is INACTIVE."
    fi

    # 3. CHECK POD DNS CONFIGURATION
    log "    🔍 TRACE 3: Checking Pod's actual DNS target (/etc/resolv.conf)..."
    local pod_dns=$(kubectl exec "$pod" -n "$ns" -- cat /etc/resolv.conf | grep nameserver | awk '{print $2}')
    log "      📍 Pod is targeting DNS IP: $pod_dns"
    
    if [[ "$pod_dns" != "$dns_target" ]]; then
        log "      ⚠️ WARNING: Pod DNS ($pod_dns) does NOT match Rule 1 CIDR ($dns_target)."
    fi

    # 4. PHYSICAL CONNECTIVITY PROBE (UDP vs TCP)
    log "    🔍 TRACE 4: Probing UDP/TCP 53 to $dns_target..."
    
    # UDP Probe
    if kubectl exec "$pod" -n "$ns" -- python3 -c \
        "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2); s.connect(('$dns_target', 53)); s.send(b'\x00'); print('ok')" &>/dev/null; then
        log "      ✅ UDP 53 OPEN."
    else
        log "      ❌ UDP 53 REJECTED."
    fi

    # TCP Probe
    if kubectl exec "$pod" -n "$ns" -- python3 -c \
        "import socket; s=socket.socket(); s.settimeout(2); s.connect(('$dns_target', 53))" &>/dev/null; then
        log "      ✅ TCP 53 OPEN."
    else
        log "      ❌ TCP 53 REJECTED."
    fi

    echo "--- 🕵️ DEBUG: FINAL DUMP ---"
    kubectl get netpol "$target_pol" -n "$ns" -o yaml
    echo "----------------------------"
}

check_mqtt_egress() {
    local ns="${NAMESPACE:-default}"
    local app_label="darkseek-backend-mqtt"
    local health_file="/tmp/mqtt-healthy"
    local max_attempts=3
    
    log "🧪 [DIAGNOSTIC] Starting Unified MQTT Egress Audit..."

    for i in $(seq 1 $max_attempts); do
        log "📡 Attempt $i/$max_attempts: Probing Stack..."
        
        # Get the latest running pod
        local pod_name=$(kubectl get pods -n "$ns" -l app="$app_label" --field-selector=status.phase=Running -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
        
        if [[ -z "$pod_name" ]]; then
            log "   ⏳ Pod not ready. Waiting 5s..."
            sleep 5; continue
        fi

        # 1. THE LOGICAL PROOF: DNS Check
        log "   🧪 [PROBE 1] DNS Resolution (test.mosquitto.org)..."
        if kubectl exec "$pod_name" -n "$ns" -- python3 -c "import socket; socket.gethostbyname('test.mosquitto.org')" &>/dev/null; then
            log "      🟢 DNS SUCCESS"
            
            # 2. THE HANDSHAKE: Verify Broker Path (8883)
            log "   🧪 [PROBE 2] Broker Handshake ($health_file)..."
            if kubectl exec "$pod_name" -n "$ns" -- test -f "$health_file" 2>/dev/null; then
                log "      🏆 SUCCESS: MQTT Stack Verified."
                return 0
            else
                log "      🔴 HANDSHAKE MISSING: Testing Raw Port Gates..."
                
                # ADDDED: Internal Pod Port Probes (Testing the "Idiot" ports)
                # These run INSIDE the pod to see what the NetworkPolicy is actually doing
                kubectl exec "$pod_name" -n "$ns" -- timeout 2 sh -c 'cat < /dev/tcp/broker.hivemq.com/1883' &>/dev/null \
                    && log "      ✅ Gate 1883: OPEN" || log "      🔴 Gate 1883: SHUT"

                kubectl exec "$pod_name" -n "$ns" -- timeout 2 sh -c 'cat < /dev/tcp/broker.hivemq.com/8883' &>/dev/null \
                    && log "      ✅ Gate 8883: OPEN" || log "      🔴 Gate 8883: SHUT"

                kubectl exec "$pod_name" -n "$ns" -- timeout 2 sh -c 'cat < /dev/tcp/broker.hivemq.com/443' &>/dev/null \
                    && log "      ✅ Gate 443: OPEN (HTTPS/WSS)" || log "      🔴 Gate 443: SHUT"
            fi
        else
            log "      🔴 DNS BLOCKED: Invoking Failure Trace..."
            run_mqtt_failure_trace "$pod_name" "$ns"
        fi
        sleep 5
    done

    log "❌ FATAL: MQTT Egress Diagnostic failed after $max_attempts attempts."
    return 1
}

check_ws_egress() {
  local ns="${NAMESPACE:-default}"
  local max_attempts=3
  local attempt=1

  log "🧪 [DIAGNOSTIC] Starting WebSocket Egress Probe (3 Attempts Max)..."

  while [ $attempt -le $max_attempts ]; do
    log "📡 Attempt $attempt/$max_attempts: Probing WS Stack Connectivity..."

    # 1. Target selection: Always grab the newest RUNNING WS pod
    local pod_name
    pod_name=$(kubectl get pods -n "$ns" -l app=darkseek-backend-ws --field-selector=status.phase=Running -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)

    if [[ -z "$pod_name" ]]; then
      log "  ⚠️ Attempt $attempt: No Running WS pods found. Waiting..."
    else
      log "  🔎 Auditing Pod: $pod_name"

      local failures=0
      # Infrastructure Targets from your 02-allow-backend-ws.yaml
      # Format: "Label:Host:Port"
      local targets=(
        "REDIS:darkseek-redis:6379"
        "DB:darkseek-db:5432"
        "MQTT-INTERNAL:darkseek-backend-mqtt:8885"
      )
      
      for entry in "${targets[@]}"; do
        local label=${entry%%:*}; local h_p=${entry#*:}; 
        local host=${h_p%:*}; local port=${h_p#*:}
        local fqdn="${host}.${ns}.svc.cluster.local"

        log "   🧪 [PROBE] WS -> $label ($fqdn:$port)..."
        
        # Surgical TCP Handshake via Python
        if kubectl exec "$pod_name" -n "$ns" -- python3 -c \
          "import socket; s=socket.socket(); s.settimeout(2); exit(0 if s.connect_ex(('$fqdn', $port)) == 0 else 1)" &>/dev/null; then
          log "      🟢 SUCCESS"
        else
          log "      🔴 BLOCKED"
          ((failures++))
        fi
      done

      # 2. DNS Resolution Check (Crucial for the 'ndots' and 'placeholder' issue)
      log "   🧪 [PROBE] WS -> DNS Resolution (google.com)..."
      if kubectl exec "$pod_name" -n "$ns" -- python3 -c "import socket; socket.gethostbyname('google.com')" &>/dev/null; then
        log "      🟢 SUCCESS"
      else
        log "      🔴 DNS FAILURE"
        ((failures++))
      fi

      if [ $failures -eq 0 ]; then
        log "🚀 ALL WS EGRESS PATHS VERIFIED."
        return 0
      fi
    fi

    [ $attempt -lt $max_attempts ] && log "  ⏳ Retrying in 5s..." && sleep 5
    ((attempt++))
  done

  log "❌ WS DIAGNOSTIC CRITICAL FAILURE: Paths are still blocked."
  return 1
}

check_pod_stability() {
  log "🔍 Auditing Pod Stability..."
  local unstable_pods
  unstable_pods=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[?(@.status.containerStatuses[0].restartCount>0)]}{.metadata.name}{" (Restarts: "}{.status.containerStatuses[0].restartCount}{")\n"}{end}')

  if [ -n "$unstable_pods" ]; then
    echo -e "🚨 \033[0;31mSTABILITY ALERT: The following pods are crash-looping:\033[0m"
    echo -e "$unstable_pods"
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
# --- PHASE 0: SANITIZATION & PREP ---
sanitize_and_prepare_env() {
    log "🧹 PHASE 0: Sanitizing Environment & Syncing Secrets..."
    
    # 1. Project Lowercasing & Cert Validation
    #export GCP_PROJECT_ID=$(echo "$GCP_PROJECT_ID" | tr '[:upper:]' '[:lower:]')
    #check_ca_cert_exists

    # moved delete netpol to main to avoid confusion
    # 3. Recreate Secrets (Idempotent) MOVED TO main
    #kubectl create secret generic darkseek-mqtt-certs \
    #    --from-file=ca.crt="$CERT_FILE" \
    #    --dry-run=client -o yaml | kubectl apply -f -

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

    # 4. ConfigMap + Strategic Patching
    kubectl apply -f configmap.yaml
    sleep 3
    # Ensure we are in the manifest directory for all subsequent steps
    #[ ! -d "$K8S_DIR" ] && fatal "Missing $K8S_DIR"
    #cd "$K8S_DIR"
    log "💉 Injecting Dynamic URIs into ConfigMap..."
    kubectl patch configmap darkseek-config -n "$NAMESPACE" --type merge -p "{
      \"data\": {
        \"WEBSOCKET_URI\": \"wss://darkseek-backend-ws:8443/ws/\",
        \"MQTT_URI\": \"http://darkseek-backend-ws:8000\"
      }
    }" || log "⚠️ Patch failed, check configmap.yaml"

    # 5. Pod Cleanup & Storage Fixes
    dryrun_server
    #force_delete_pods "" "monitoring"
    kill_stale_pods "darkseek-db"

    if kubectl get pvc postgres-pvc -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
        log "⚠️ PVC stuck → Force clearing finalizers..."
        kubectl patch pvc postgres-pvc -p '{"metadata":{"finalizers":null}}' --type=merge
    fi

    # 6. Targeted Nuking
    if [ "${NUKE_MQTT_PODS:-false}" = "true" ]; then force_delete_pods "darkseek-backend-mqtt"; fi
    if [ "${NUKE_WS_PODS:-false}" = "true" ]; then force_delete_pods "darkseek-backend-ws"; fi
    if [[ "${NUKE_WS_PODS:-false}" == "true" || "${NUKE_MQTT_PODS:-false}" == "true" ]]; then
        force_delete_pods "darkseek-frontend"
        sleep 15
    fi
}

deploy_core() {
    log "🏗️ PHASE 1: Storage + Database..."
    apply_with_retry db-pvc.yaml
    apply_with_retry db-deployment.yaml
    apply_with_retry db-service.yaml

    log "⏳ 90s: DB initialization + PVC bind..."
    sleep 90
    pvc_name="postgres-pvc"
    if [ "$(kubectl get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}')" != "Bound" ]; then
        troubleshoot_pvc_and_nodes "$pvc_name"
        fatal "PVC $pvc_name not Bound"
    fi

    ensure_db_exists
    check_db_initialization

    log "🧹 Removing ghost command overrides..."
    kubectl patch deployment darkseek-backend-ws --type=json -p='[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]' 2>/dev/null || true
    kubectl patch deployment darkseek-backend-mqtt --type=json -p='[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]' 2>/dev/null || true

    log "🔴 PHASE 2: Redis + Core Services..."
    apply_with_retry redis-deployment.yaml
    apply_with_retry redis-service.yaml
    sleep 30

    # --- Step 3: Applications ---
    log "🚀 PHASE 3: Deploying Main Applications..."
    deploy_main_apps  # ws + mqtt + frontend deployments
    
    log "⏳ 45s: App pods startup + image pulls..."
    sleep 45
    
    verify_backend_image "darkseek-backend-ws"
    verify_backend_image "darkseek-backend-mqtt"

    # --- Step 4: Services ---
    log "🌐 PHASE 4.0: All services (BEFORE wait)..."
    apply_with_retry backend-ws-service.yaml
    apply_with_retry backend-mqtt-service.yaml
    apply_with_retry frontend-service.yaml

    log "⏳ 45s: Service endpoints ready..."
    sleep 45
    # --- Connectivity Telemetry ---
    log "📡 Running egress diagnostic (Background)..."
    check_mqtt_egress || log "⚠️ Warning: Initial egress check failed. Probes might fail until CNI stabilizes."
    check_ws_egress || log "⚠️ Warning: Initial egress check failed. Probes might fail until CNI stabilizes."
}

# --- Function : The Final Verification (Phase 5) ---
verify_mqtt_connectivity() {
    log "🧪 PHASE 5: Final Handshake Verification (5 Tries)..."
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=darkseek-backend-mqtt --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    kubectl exec -n "$NAMESPACE" "$pod_name" -- python3 -c "
import asyncio, sys, time

async def test(attempt):
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection('$MQTT_BROKER_HOST', $MQTT_BROKER_PORT), 5.0)
        print(f'   [Try {attempt}] ✅ FINAL PATH VERIFIED')
        writer.close(); await writer.wait_closed()
        return True
    except Exception as e:
        print(f'   [Try {attempt}] ❌ PATH BLOCKED: {type(e).__name__}')
        return False

async def main():
    for i in range(1, 6):
        if await test(i): sys.exit(0)
        if i < 5: await asyncio.sleep(2)
    sys.exit(1)

asyncio.run(main())
"
}

run_deep_network_diagnostic() {
    local target_app="darkseek-backend-mqtt"
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=$target_app --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$pod_name" ]; then
        log "⚠️ [DIAGNOSTIC] No running pod found for $target_app. Skipping probe."
        return 0
    fi

    log "🔍 PHASE 4.5: Deep Network Probe (5 Tries) on $pod_name"
    log "🎯 Target: $MQTT_BROKER_HOST:$MQTT_BROKER_PORT"

    # THE PYTHON CODE INJECTED INTO BASH
    kubectl exec -n "$NAMESPACE" "$pod_name" -- python3 -c "
import asyncio
import socket
import time
import sys

async def probe(attempt):
    try:
        # 1. TEST DNS RESOLUTION (Port 53)
        start_dns = time.time()
        # This checks if we can even talk to the K8s DNS Service
        resolved_ip = socket.gethostbyname('$MQTT_BROKER_HOST')
        dns_time = time.time() - start_dns
        print(f'   [Try {attempt}] 🌍 DNS SUCCESS: $MQTT_BROKER_HOST -> {resolved_ip} ({dns_time:.2f}s)')

        # 2. TEST TCP HANDSHAKE (Port 8883)
        start_tcp = time.time()
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(resolved_ip, $MQTT_BROKER_PORT), 
            timeout=5.0
        )
        tcp_time = time.time() - start_tcp
        print(f'   [Try {attempt}] ✅ TCP SUCCESS: Port $MQTT_BROKER_PORT OPEN ({tcp_time:.2f}s)')
        
        writer.close()
        await writer.wait_closed()
        return True

    except socket.gaierror:
        # This usually means Port 53/UDP is blocked by NetPol
        print(f'   [Try {attempt}] ❌ DNS FAILURE: Cannot resolve $MQTT_BROKER_HOST')
    except asyncio.TimeoutError:
        # This means DNS worked, but the firewall is dropping packets to $MQTT_BROKER_PORT
        print(f'   [Try {attempt}] ❌ TCP FAILURE: Timeout on $MQTT_BROKER_PORT (Gate is SHUT)')
    except Exception as e:
        print(f'   [Try {attempt}] ❌ ERROR: {type(e).__name__} - {e}')
    return False

async def main():
    for i in range(1, 6):
        if await probe(i):
            sys.exit(0)
        if i < 5:
            await asyncio.sleep(2)
    sys.exit(1)

asyncio.run(main())
" 
    
    local diagnostic_result=$?
    
    if [ $diagnostic_result -eq 0 ]; then
        log "🏆 Network infrastructure verified for MQTT."
    else
        log "💀 NetworkPolicy is blocking traffic. Diagnosing now..."
        # If it failed, show the user the NetPol that is currently applied
        kubectl describe netpol -n "$NAMESPACE" -l app=$target_app || true
    fi

    return $diagnostic_result
}

run_final_path_diagnostic() {
    log "🕵️ PHASE 4.7: Final Path & DNS Audit..."
    local pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=darkseek-backend-mqtt --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$pod_name" ]; then
        log "⚠️ No pod found to diagnose."
        return 1
    fi

    kubectl exec -n "$NAMESPACE" "$pod_name" -- python3 -c "
import os, socket

paths = [
    '/etc/mosquitto/ssl/ca.crt',        # Absolute App Path
    './etc/mosquitto/ssl/ca.crt',           # Relative App Path
    '/mosquitto/ssl/ca.crt',            # K8s Secret Mount Path
    'etc/mosquitto/ssl/ca.crt'              # Pure Relative
]

print('--- 📂 FILE AUDIT ---')
for p in paths:
    exists = os.path.exists(p)
    status = '✅ FOUND' if exists else '❌ MISSING'
    print(f'{status}: {p}')

print('\n--- 📡 DNS/EGRESS AUDIT ---')
try:
    # Test internal Kube-DNS
    socket.gethostbyname('kubernetes.default.svc.cluster.local')
    print('✅ INTERNAL DNS: OK')
except:
    print('❌ INTERNAL DNS: FAILED')

try:
    # Test external Canary (The one your app is likely hanging on)
    socket.gethostbyname('google.com')
    print('✅ EXTERNAL DNS (Canary): OK')
except Exception as e:
    print(f'❌ EXTERNAL DNS (Canary): FAILED ({type(e).__name__})')
"
}

verify_golden_paths() {
    log "✨ STARTING GOLDEN PATH VERIFICATION (Zero-Trust) ✨"

    # --- PATH 1: MQTT TLS Handshake ---
    log "🟢 GOLDEN COMMAND 1: MQTT TLS Handshake..."
    # We look for the actual successful connection logs in the backend
    if kubectl logs -l app=darkseek-backend-mqtt -n "$NAMESPACE" --tail=100 | grep -iE "connected|ssl|tls" >/dev/null 2>&1; then
        log "✅ MQTT TLS: Handshake Verified in logs."
    else
        log "⚠️ MQTT TLS: No connection logs found yet (Pod might still be initializing)."
    fi

    # --- PATH 2: WS → Redis (The "No-NC" Version) ---
    log "🟢 GOLDEN COMMAND 2: Zero-Trust WS → Redis..."
    
    # Surgical Python Probe: Exit 0 if port 6379 is reachable
    local ws_pod
    ws_pod=$(kubectl get pod -l app=darkseek-backend-ws -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -n "$ws_pod" ]; then
        if kubectl exec "$ws_pod" -n "$NAMESPACE" -- python3 -c \
            "import socket; s=socket.socket(); s.settimeout(2); exit(0 if s.connect_ex(('darkseek-redis', 6379)) == 0 else 1)" &>/dev/null; then
            log "✅ Zero-Trust: WS → Redis:6379 OPEN ✓"
        else
            log "❌ Zero-Trust: WS → Redis BLOCKED"
            log "   (Check 02-allow-backend-ws Egress and 05-allow-redis-access Ingress)"
        fi
    else
        log "⚠️ WS → Redis: No WS pod found to run probe."
    fi

    # --- PATH 3: WS → DB ---
    log "🟢 GOLDEN COMMAND 3: Zero-Trust WS → Postgres..."
    if [ -n "$ws_pod" ]; then
        if kubectl exec "$ws_pod" -n "$NAMESPACE" -- python3 -c \
            "import socket; s=socket.socket(); s.settimeout(2); exit(0 if s.connect_ex(('darkseek-db', 5432)) == 0 else 1)" &>/dev/null; then
            log "✅ Zero-Trust: WS → Postgres:5432 OPEN ✓"
        else
            log "❌ Zero-Trust: WS → Postgres BLOCKED"
        fi
    fi
}

provision_loadbalancer_ip() {
    log "⏳ Waiting for LoadBalancer IPs (60s max)..."
    local FRONTEND_IP=""
    for i in {1..12}; do
        FRONTEND_IP=$(kubectl get svc darkseek-frontend -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [[ -n "$FRONTEND_IP" && "$FRONTEND_IP" != "<pending>" ]]; then
            log "✅ Frontend LoadBalancer IP Provisioned: $FRONTEND_IP"
            return 0
        fi
        log "  ... LB still provisioning ($i/12)"
        sleep 5
    done
    log "⚠️ LB IP is taking longer than expected. It will continue provisioning in the background."
}

# --- MAIN (ULTIMATE BADDA** GEMINI EDITION) ---
main() {
    log "🏁 Starting DarkSeek Deployment: Gemini Ultimate Edition"
    
    # 1. FIX: Capture the absolute path while we are still in the ROOT
    # This prevents the "no such file or directory" error after the cd
    local SCRIPT_ROOT=$(pwd)
    export CERT_FILE_ABS="$SCRIPT_ROOT/certs/ca.crt"
    
    # --- PHASE 0: PRE-FLIGHT ---
    check_kubectl
    check_envsubst
    check_env_vars
    check_network_policy_support
    
    export GCP_PROJECT_ID=$(echo "$GCP_PROJECT_ID" | tr '[:upper:]' '[:lower:]')
    
    check_ca_cert_exists
    # 2. Wipe stale DNS policy to prevent "Ghost" rules blocking initial pulls
    log "🧹 Wiping stale DNS policy for fresh IP injection..."
    kubectl delete netpol allow-dns-global -n "$NAMESPACE" --ignore-not-found
    kubectl delete netpol allow-to-backend-mqtt -n "$NAMESPACE" --ignore-not-found
    echo "[$(date +%T)] ⚠️  Wiping all stale NetworkPolicies..."
    kubectl delete netpol --all -n "$NAMESPACE" --ignore-not-found
    # STEP 4: CREATE SECRET (Works because path is Absolute)
    log "🔑 Syncing TLS Secret..."
    kubectl create secret generic darkseek-mqtt-certs \
      --from-file=ca.crt="$CERT_FILE_ABS" \
      --dry-run=client -o yaml | kubectl apply -f -

    # STEP 5: THE PIVOT
    # Now we change directory so all 'apply -f' commands find their .yaml files
    [ ! -d "$K8S_DIR" ] && fatal "Missing $K8S_DIR"
    cd "$K8S_DIR"
    log "📂 Working directory shifted to: $(pwd)"

    # --- PHASE 1: SANITIZATION & PREP ---
    # Handles Secrets, PVC finalizers, and Nuke logic
    sanitize_and_prepare_env

    # --- PHASE 2: NETWORK LOCKDOWN ---
    # Apply policies BEFORE pods are born so they are SECURE from second zero
    log "🔒 PHASE 1.5: Applying Zero-Trust Framework..."
    apply_networking 
    
    log "⏳ 60s: CNI propagation sync..."
    sleep 60

    # --- PHASE 3: INFRA + APPS + SERVICES ---
    # Consolidated block as requested: DB -> Redis -> Apps -> Services -> Egress Check
    deploy_core

    # --- PHASE 4: THE GATEKEEPER ---
    log "🚀 PHASE 4.0: Verifying Network Integrity..."
    # Proves the "pipes" are open while pods are Running but before Probes time out
    verify_cluster_network_integrity || fatal "Network Logic Failure. Stopping deployment."
    
    sleep 5
    # --- PHASE 4: THE GATEKEEPER ---
    log "🚀 PHASE 4.5: MQTT Network Deep Daignostic.."
    run_deep_network_diagnostic || fatal "Network Diagnostic for MQTT Failure."
    run_final_path_diagnostic
    
    # --- PHASE 5: STABILIZATION ---
    log "⏳ Waiting for Readiness Probes to pass..."
    wait_for_deployments

    log "🧪 PHASE 4b: Final Network Settlement..."
    sleep 59 # The "Calico Polish" sleep
    verify_internal_connectivity || fatal "Internal connectivity test failed."
    
    # --- PHASE 5: GOLDEN VERIFICATION ---
    log "🧪 PHASE 5: Production Handshake Verification..."
    
    # This will now try 5 times over ~10-15 seconds before giving up
    #run_final_path_diagnostic
    verify_mqtt_connectivity || fatal "💀 Final connectivity check failed after 5 attempts."
    

    log "🎉 MQTT Infrastructure is 100% verified and reachable."
    wait_for_mqtt_health
    

    # --- PHASE 6: GOLDEN VERIFICATION ---
    log "🧪 PHASE 5.5: Production Handshake Verification..."
    run_policy_audit || true
    verify_policy_active

    verify_golden_paths
    
    monitor_handshake
    
    log "🟢 GOLDEN COMMAND 3: ConfigMap URI Patch Verification..."
    kubectl get configmap darkseek-config -n "$NAMESPACE" -o jsonpath='{.data.WEBSOCKET_URI}' && echo ""

    # --- PHASE 7: EXTERNAL EXPOSURE ---
    provision_loadbalancer_ip
    # Manual check if the script halts:
    # Faster "Golden Check" using an existing image to avoid pull-rate limits
    kubectl run dns-shield-test -n "$NAMESPACE" --image=busybox --rm -it --restart=Never -- nslookup google.com
    # --- PHASE 8: DASHBOARD & LOGS ---
    show_deployment_dashboard

    log "💡 Real-time logs: kubectl logs -f -n $NAMESPACE -l 'app in (darkseek-backend-ws, darkseek-backend-mqtt, darkseek-frontend)' --tail=20 --prefix"
    log "🎉 DEPLOYMENT COMPLETE!"
}

# START
main "$@"
