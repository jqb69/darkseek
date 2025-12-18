#!/bin/bash
# k8s/run-mqtt-tests-with-fix.sh — RECOVERY WRAPPER
# This script runs the health checks and attempts a network reset if they fail.

set -u

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $1"; }

# Faster parallel pod wait
wait_for_debug_pod() {
    log "⏳ Waiting for debug-mqtt pod to reach Ready state..."
    timeout 30 kubectl wait --for=condition=Ready pod/debug-mqtt --timeout=30s 2>/dev/null || true
}

# Ensure all necessary scripts are executable before starting
if [ -f "./k8s/mqtt-testk8s.sh" ]; then
    chmod +x ./k8s/mqtt-testk8s.sh
fi

if [ -f "./k8s/reset-network-state.sh" ]; then
    chmod +x ./k8s/reset-network-state.sh
fi

log "🐛 Ensuring debug-mqtt pod exists..."
# Use debug script to ensure environment is primed (non-blocking)
./k8s/mqtt-debugk8s.sh || true
wait_for_debug_pod

for attempt in 1 2; do
    log "🚀 Connectivity Check: Attempt $attempt/2"
    
    # Run the non-destructive monitor script
    if ./k8s/mqtt-testk8s.sh; then
        log "✅ HEALTH CHECK PASS (attempt $attempt)"
        exit 0
    fi

    if [ "$attempt" -eq 1 ]; then
        log "⚠️  Attempt 1 failed. Triggering Network State Reset..."
        
        # Reset script is already chmod'd above
        if [ -f "./k8s/reset-network-state.sh" ]; then
            ./k8s/reset-network-state.sh
            
            log "⏳ Waiting 15s for network convergence after reset..."
            sleep 15
            wait_for_debug_pod
        else
            log "❌ Recovery skipped: ./k8s/reset-network-state.sh not found."
        fi
    fi
done

log "💥 FINAL FAILURE: Connectivity could not be restored after reset."
exit 1
