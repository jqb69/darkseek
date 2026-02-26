#!/bin/bash
# k8s/mqtt-testk8s.sh — FINAL MERGED PRODUCTION MONITOR
set -euo pipefail

# --- CONFIGURATION ---
NAMESPACE="${NAMESPACE:-default}"
BACKEND_NAME="${BACKEND_NAME:-darkseek-backend-mqtt}"
BACKEND_WS="${BACKEND_WS:-darkseek-backend-ws}"
REDIS_NAME="${REDIS_NAME:-darkseek-redis}"
DB_NAME="${DB_NAME:-darkseek-db}"
DEBUG_POD="${DEBUG_POD:-debug-mqtt}"
POLICY_DIR="${POLICY_DIR:-k8s/policies}"
LOGFILE="/tmp/mqtt-test-$(date +%Y%m%d-%H%M%S).log"
RECOVERY_LOCK="/tmp/mqtt-test-recovery-${NAMESPACE}.lock"

exec &> >(tee -a "$LOGFILE")
trap 'rm -f "$RECOVERY_LOCK"' EXIT

log() { 
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" 
}

# =======================================================
# 🛠️ CORE HELPERS
# =======================================================

get_broker() {
    local host=""
    host=$(kubectl get secret darkseek-secrets -n "$NAMESPACE" -o jsonpath='{.data.MQTT_BROKER_HOST}' 2>/dev/null | base64 --decode || echo "")
    if [[ -z "$host" ]]; then
        host=$(kubectl exec deployment/"$BACKEND_NAME" -n "$NAMESPACE" -- sh -c 'echo $MQTT_BROKER_HOST' 2>/dev/null || echo "")
    fi
    if [[ -z "$host" ]]; then
        log "❌ CRITICAL: MQTT_BROKER_HOST missing."
        return 1
    fi
    echo "$host"
}

check_tcp_python() {
    local source_pod="$1" host="$2" port="$3" label="$4"
    log "📡 Testing $label ($host:$port)..."
    if kubectl exec "$source_pod" -n "$NAMESPACE" -- python3 -c \
        "import socket; s=socket.socket(); s.settimeout(5); exit(s.connect_ex(('$host', $port)))" &>/dev/null; then
        log "   🟢 SUCCESS: $label"
        return 0
    else
        log "   ⚠️ FAILED: $label"
        return 1
    fi
}

check_dns_python() {
    local source_pod="$1" target_host="$2"
    log "🔍 DNS Check: $source_pod -> $target_host"
    if kubectl exec "$source_pod" -n "$NAMESPACE" -- python3 -c \
        "import socket; socket.gethostbyname('$target_host')" &>/dev/null; then
        log "   🟢 DNS OK: $target_host resolved"
        return 0
    else
        log "   🔴 DNS FAIL: $target_host unresolved"
        return 1
    fi
}

# --- NEW: DNS TEMPLATING LOGIC ---
template_policies() {
    log "🎯 Detecting Cluster DNS..."
    # Fetch the real IP of kube-dns
    local dns_ip
    dns_ip=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    [[ -z "$dns_ip" ]] && dns_ip="34.118.224.10" # Your GKE fallback
    log "🎯 GKE_DNS DETECTED: $dns_ip"

    # Replace placeholder in ALL files and create .tmp versions
    for f in "$POLICY_DIR"/*.yaml; do
        sed "s/DNS_IP_PLACEHOLDER/$dns_ip/g" "$f" > "$f.tmp"
    done
}

run_surgical_diagnostic() {
    local pod_name=""
    local retry_limit=10
    local count=0

    log "🕵️ DISCOVERING TARGET POD..."
    while [[ -z "$pod_name" && $count -lt $retry_limit ]]; do
        pod_name=$(kubectl get pods -l app="$BACKEND_NAME" -n "$NAMESPACE" \
            --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        [[ -z "$pod_name" ]] && { log "   ⏳ Waiting for Running pod... ($((count+1))/$retry_limit)"; sleep 3; ((count++)); }
    done

    [[ -z "$pod_name" ]] && { log "❌ CRITICAL: No Running pod found."; return 1; }
    
    # --- KERNEL BINDING CHECK (BULLETPROOF) ---
    log "🔍 Checking Kernel TCP Table for Port 8001 (1F41)..."
    
    local tcp_table
    tcp_table=$(kubectl exec "$pod_name" -n "$NAMESPACE" -- cat /proc/net/tcp 2>/dev/null || echo "EXEC_FAILED")
    
    if [[ "$tcp_table" == "EXEC_FAILED" ]]; then
        log "❌ FAILURE: Pod is in a crashloop or unresponsive to exec."
        
        # Dump logs and exit early so we don't run greps on "EXEC_FAILED"
        log "📜 Scrape: Last 20 lines of pod logs..."
        kubectl logs "$pod_name" -n "$NAMESPACE" --tail=20 || true
        return 1
    fi

    local tcp_hex
    tcp_hex=$(echo "$tcp_table" | grep "1F41" || true)
    
    if [[ -z "$tcp_hex" ]]; then
        log "❌ FAILURE: No process is listening on 8001 (1F41). The App did not start the server."
    elif echo "$tcp_hex" | grep -q "0100007F:1F41"; then
        log "🚨 LOCALHOST TRAP: App is bound to 127.0.0.1:8001. Connections REFUSED."
    elif echo "$tcp_hex" | grep -q "00000000:1F41"; then
        log "🟢 BINDING OK: App is listening on 0.0.0.0:8001."
    fi
    
    # --- 2. OUTBOUND CONNECTIONS (ESTABLISHED = 01) ---
    log "🔍 Checking Outbound Dependencies (State 01 = Established)..."
    
    # DB (5432 -> 1538) using a single safe regex grep
    if echo "$tcp_table" | grep -q -E ":1538 .* 01 "; then
        log "   🟢 DB (5432): Connected."
    else
        log "   ❌ DB (5432): Disconnected/Blocked."
    fi

    # REDIS (6379 -> 18EB)
    if echo "$tcp_table" | grep -q -E ":18EB .* 01 "; then
        log "   🟢 REDIS (6379): Connected."
    else
        log "   ❌ REDIS (6379): Disconnected/Blocked."
    fi

    # BROKER (8885 -> 22B5)
    if echo "$tcp_table" | grep -q -E ":22B5 .* 01 "; then
        log "   🟢 BROKER (8885): Connected."
    else
        log "   ❌ BROKER (8885): Disconnected/Blocked."
    fi

    # ALWAYS dump the logs, no matter what happened above
    log "📜 Scrape: Last 20 lines of pod logs..."
    kubectl logs "$pod_name" -n "$NAMESPACE" --tail=20 || true
}
# --- UPDATED: RECOVERY BLOCK ---
controlled_recovery() {
    [[ -f "$RECOVERY_LOCK" ]] && { log "⚠️ Recovery lock active. Skipping."; return 1; }
    touch "$RECOVERY_LOCK"
    
    log "🔧 TRIGGERING DNS-AWARE RECOVERY..."
    
    # 1. Create the valid YAMLs
    template_policies

    # 2. Nuclear Clean (optional, but keeps things fresh)
    kubectl delete netpol allow-backend-ws allow-to-redis allow-to-backend-mqtt allow-dns-global -n "$NAMESPACE" --ignore-not-found 
    sleep 5
    
    # 3. Apply in specific order
    log "🛡️ Applying DNS-Aware Policies..."
    kubectl apply -f "$POLICY_DIR/00-allow-dns.yaml.tmp" -n "$NAMESPACE"
    kubectl apply -f "$POLICY_DIR/05-allow-redis-access.yaml.tmp" -n "$NAMESPACE"
    kubectl apply -f "$POLICY_DIR/02-allow-backend-ws.yaml.tmp" -n "$NAMESPACE"
    kubectl apply -f "$POLICY_DIR/03-allow-backend-mqtt.yaml.tmp" -n "$NAMESPACE"
    
    log "⏳ Waiting 45s for CNI propagation..."
    sleep 45
    
    # 4. Cleanup temp files
    rm -f "$POLICY_DIR"/*.tmp
    rm -f "$RECOVERY_LOCK"
}

# =======================================================
# 🔍 DIAGNOSTICS & TRACE
# =======================================================
fix_mqtt_health() {
    log "🔧 CHECKING MQTT HEALTH (Liveness Probe Guard)..."
    local healthy=false

    for attempt in {1..6}; do
        log "   ⏳ Waiting for /tmp/mqtt-healthy ($attempt/6)..."
        
        # Check if the health file exists
        if kubectl exec deployment/"$BACKEND_NAME" -n "$NAMESPACE" -- ls /tmp/mqtt-healthy >/dev/null 2>&1; then
            log "🟢 HEALTHY: Signal detected."
            healthy=true
            break  # Exit the loop early on success
        fi
    
        # If we reached the final attempt and still aren't healthy
        if [ "$attempt" -eq 6 ] && [ "$healthy" = false ]; then
            log "❌ HEALTH FILE MISSING → DIAGNOSING BEFORE RECOVERY..."
            
            run_surgical_diagnostic
    
            log "🛠️ Removal of Liveness Probe and Triggering Recovery..."
            kubectl patch deployment "$BACKEND_NAME" -n "$NAMESPACE" --type json -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/livenessProbe"}]'
            
            template_policies
            controlled_recovery
            exit 1 # Hard exit because the environment is unstable
        fi

        sleep 10
    done

    # If we broke out of the loop because of success
    return 0
}

test_tcp_connectivity() {
    log "🌐 STARTING INFRASTRUCTURE TRACE (DNS + TCP)..."
    local failed=0
    
    # 1. MQTT External Path
    local broker_host
    if broker_host=$(get_broker); then
        check_tcp_python "deployment/$BACKEND_NAME" "$broker_host" 8885 "MQTT -> External Broker" || failed=1
    else
        failed=1
    fi

    # 2. Redis Path
    check_dns_python "deployment/$BACKEND_WS" "$REDIS_NAME" || failed=1
    check_tcp_python "deployment/$BACKEND_WS" "$REDIS_NAME" 6379 "WS -> Redis" || failed=1

    # 3. Database Path
    check_dns_python "deployment/$BACKEND_WS" "$DB_NAME" || failed=1
    check_tcp_python "deployment/$BACKEND_WS" "$DB_NAME" 5432 "WS -> Postgres" || failed=1

    return $failed
}


# =======================================================
# 🎬 MAIN
# =======================================================

main() {
    log "🚀 DarkSeek Health Monitor Starting..."
    
    fix_mqtt_health

    if ! test_tcp_connectivity; then
        log "🚨 CORE PATH FAILURE → Attempting recovery..."
        if ! controlled_recovery; then
            log "💀 FATAL: Recovery failed."
            exit 1
        fi
        
        log "🔄 Verifying paths after recovery..."
        test_tcp_connectivity || { log "💀 FATAL: Still broken."; exit 1; }
    fi
    
    log "🎉 ALL SYSTEMS OPERATIONAL"
}

main "$@"
