#!/usr/bin/env bash
# wait-ready.sh — Fast SSH readiness detection for VM boot
#
# Uses aggressive polling with exponential backoff to detect
# when the VM's SSH daemon is accepting connections.
# Optimized for the resume case where SSH should be available
# within 2-5 seconds of QEMU loadvm.

set -euo pipefail

# Default SSH connection parameters
SSH_CONNECT_TIMEOUT=2
SSH_IDENTITY="${SSH_IDENTITY:-${HOME}/.claude-vm/ssh/id_ed25519}"

# Wait for SSH to become available on the VM
# Args:
#   $1 = host (default: localhost)
#   $2 = port (default: 2222)
#   $3 = timeout in seconds (default: 20)
# Returns: 0 if SSH is ready, 1 on timeout
wait_for_ssh() {
    local host="${1:-localhost}"
    local port="${2:-2222}"
    local timeout="${3:-20}"

    local start_time
    start_time=$(date +%s)
    local attempt=0
    local delay=0.2  # Start with 200ms polling interval

    while true; do
        attempt=$((attempt + 1))
        local now
        now=$(date +%s)
        local elapsed=$((now - start_time))

        if [[ $elapsed -ge $timeout ]]; then
            echo "error: SSH not ready after ${timeout}s (${attempt} attempts)" >&2
            return 1
        fi

        # Try SSH connection with minimal overhead
        # Use ssh -o BatchMode to avoid password prompts
        # ConnectTimeout=1 keeps each attempt fast
        if ssh_probe "$host" "$port" 2>/dev/null; then
            local final_elapsed=$(($(date +%s) - start_time))
            echo "SSH ready after ${final_elapsed}s (${attempt} attempts)"
            return 0
        fi

        # Exponential backoff: 0.2s → 0.4s → 0.8s → 1.0s (capped)
        sleep "$delay"
        delay=$(awk "BEGIN {d=$delay * 2; print (d > 1.0 ? 1.0 : d)}")
    done
}

# Probe SSH connectivity with minimal overhead
# Args: $1 = host, $2 = port
# Returns: 0 if SSH responds, 1 otherwise
ssh_probe() {
    local host="$1"
    local port="$2"

    # Method 1: Try nc (netcat) first — fastest, just checks port is open
    if command -v nc &>/dev/null; then
        nc -z -w "$SSH_CONNECT_TIMEOUT" "$host" "$port" 2>/dev/null
        return $?
    fi

    # Method 2: Use bash /dev/tcp (built-in, no external deps)
    if (echo >/dev/tcp/"$host"/"$port") 2>/dev/null; then
        return 0
    fi

    # Method 3: ssh with exit command — heavier but most accurate
    ssh -q \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -o LogLevel=ERROR \
        -p "$port" \
        -i "$SSH_IDENTITY" \
        "${VM_USER:-$USER}@${host}" \
        "exit 0" 2>/dev/null
}

# Wait for SSH with a full authentication check (not just port open)
# Use this when you need to verify the VM is fully booted and SSH keys work
# Args: same as wait_for_ssh
wait_for_ssh_auth() {
    local host="${1:-localhost}"
    local port="${2:-2222}"
    local timeout="${3:-20}"

    # First wait for port to be open (fast)
    if ! wait_for_ssh "$host" "$port" "$timeout"; then
        return 1
    fi

    # Then verify full SSH authentication works
    local start_time
    start_time=$(date +%s)
    local remaining=$((timeout - ($(date +%s) - start_time)))
    [[ $remaining -le 0 ]] && remaining=5

    local attempt=0
    while [[ $(($(date +%s) - start_time)) -lt $timeout ]]; do
        attempt=$((attempt + 1))
        if ssh -q \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
            -o LogLevel=ERROR \
            -p "$port" \
            -i "$SSH_IDENTITY" \
            "${VM_USER:-$USER}@${host}" \
            "echo ready" 2>/dev/null | grep -q "ready"; then
            echo "SSH auth verified (${attempt} attempts)"
            return 0
        fi
        sleep 0.5
    done

    echo "error: SSH auth failed within ${timeout}s" >&2
    return 1
}

# Quick check if a VM is currently running and SSH-accessible
# Args: $1 = host, $2 = port
# Returns: 0 if reachable, 1 if not
is_vm_ssh_reachable() {
    local host="${1:-localhost}"
    local port="${2:-2222}"
    ssh_probe "$host" "$port" 2>/dev/null
}
