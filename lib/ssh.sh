#!/usr/bin/env bash
# claude-vm SSH readiness module
# Provides functions for SSH connectivity checking, waiting, and session management.
# Source this file from the main CLI: source lib/ssh.sh

set -euo pipefail

# Default SSH settings
CLAUDE_VM_SSH_PORT="${CLAUDE_VM_SSH_PORT:-2222}"
CLAUDE_VM_SSH_USER="${CLAUDE_VM_SSH_USER:-${VM_USER:-$USER}}"
CLAUDE_VM_SSH_KEY="${CLAUDE_VM_SSH_KEY:-${HOME}/.claude-vm/keys/id_ed25519}"
CLAUDE_VM_SSH_TIMEOUT="${CLAUDE_VM_SSH_TIMEOUT:-5}"
CLAUDE_VM_SSH_READY_TIMEOUT="${CLAUDE_VM_SSH_READY_TIMEOUT:-60}"
CLAUDE_VM_SSH_POLL_INTERVAL="${CLAUDE_VM_SSH_POLL_INTERVAL:-1}"

# ─── SSH Key Management ───────────────────────────────────────────────────────

# Generate an SSH keypair for VM access if one doesn't exist
ssh_ensure_keypair() {
    local key_path="${1:-$CLAUDE_VM_SSH_KEY}"
    local key_dir
    key_dir="$(dirname "$key_path")"

    if [[ -f "$key_path" ]]; then
        return 0
    fi

    mkdir -p "$key_dir"
    chmod 700 "$key_dir"

    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "claude-vm" -q
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"

    echo "Generated SSH keypair: $key_path"
}

# Return the public key content (for injecting into guest)
ssh_public_key() {
    local key_path="${1:-$CLAUDE_VM_SSH_KEY}"
    if [[ ! -f "${key_path}.pub" ]]; then
        echo "ERROR: SSH public key not found: ${key_path}.pub" >&2
        return 1
    fi
    cat "${key_path}.pub"
}

# ─── SSH Connectivity ─────────────────────────────────────────────────────────

# Build the base SSH command array with standard options
_ssh_base_cmd() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"
    local timeout="${4:-$CLAUDE_VM_SSH_TIMEOUT}"

    echo ssh \
        -p "$port" \
        -i "$key" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout="$timeout" \
        -o BatchMode=yes \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        "${user}@localhost"
}

# Check if SSH is reachable right now (returns 0 if yes, 1 if no)
ssh_check() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"
    local timeout="${4:-$CLAUDE_VM_SSH_TIMEOUT}"

    ssh \
        -p "$port" \
        -i "$key" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout="$timeout" \
        -o BatchMode=yes \
        "${user}@localhost" \
        "echo ready" \
        >/dev/null 2>&1
}

# Wait for SSH to become available, with timeout and progress indication.
# Returns 0 when SSH is ready, 1 on timeout.
ssh_wait_ready() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"
    local max_wait="${4:-$CLAUDE_VM_SSH_READY_TIMEOUT}"
    local poll_interval="${5:-$CLAUDE_VM_SSH_POLL_INTERVAL}"
    local connect_timeout=3

    local elapsed=0
    local attempt=0

    while (( elapsed < max_wait )); do
        attempt=$(( attempt + 1 ))

        if ssh_check "$port" "$key" "$user" "$connect_timeout"; then
            return 0
        fi

        # Progressive backoff for connect timeout (start fast, slow down)
        if (( attempt > 10 )); then
            connect_timeout=5
        fi

        sleep "$poll_interval"
        elapsed=$(( elapsed + poll_interval ))
    done

    return 1
}

# ─── SSH Session ──────────────────────────────────────────────────────────────

# Open an interactive SSH session to the VM
ssh_connect() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"
    shift 3 2>/dev/null || true

    # For interactive sessions, we want a TTY and relaxed options
    ssh \
        -p "$port" \
        -i "$key" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        -t \
        "${user}@localhost" \
        "$@"
}

# Execute a command in the VM over SSH (non-interactive)
ssh_exec() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"
    shift 3

    ssh \
        -p "$port" \
        -i "$key" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout="$CLAUDE_VM_SSH_TIMEOUT" \
        -o BatchMode=yes \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        "${user}@localhost" \
        "$@"
}

# ─── QEMU SSH Port Forwarding ────────────────────────────────────────────────

# Return the QEMU netdev hostfwd argument for SSH port forwarding
qemu_ssh_netdev_arg() {
    local host_port="${1:-$CLAUDE_VM_SSH_PORT}"
    local guest_port="${2:-22}"

    echo "user,id=net0,hostfwd=tcp::${host_port}-:${guest_port}"
}

# Find an available port starting from a base, to avoid collisions
# when multiple VMs run simultaneously
ssh_find_available_port() {
    local base_port="${1:-2222}"
    local max_port="${2:-2322}"
    local port="$base_port"

    while (( port <= max_port )); do
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} " 2>/dev/null; then
            echo "$port"
            return 0
        fi
        port=$(( port + 1 ))
    done

    echo "ERROR: No available port in range ${base_port}-${max_port}" >&2
    return 1
}

# ─── Readiness Gate ───────────────────────────────────────────────────────────

# Full readiness check: waits for SSH and verifies the guest environment.
# This is the main function called by the launch flow before reporting "ready".
# Returns 0 if sandbox is fully ready, 1 on failure.
ssh_gate_ready() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"
    local max_wait="${4:-$CLAUDE_VM_SSH_READY_TIMEOUT}"

    echo -n "Waiting for SSH..."

    if ! ssh_wait_ready "$port" "$key" "$user" "$max_wait"; then
        echo " TIMEOUT (${max_wait}s)"
        echo "ERROR: SSH did not become available within ${max_wait} seconds" >&2
        return 1
    fi

    echo " connected."

    # Verify the guest environment is sane
    local checks_passed=true

    # Check workspace mount exists
    if ! ssh_exec "$port" "$key" "$user" "test -d /workspace" 2>/dev/null; then
        echo "WARNING: /workspace not mounted yet" >&2
        checks_passed=false
    fi

    # Check claude binary is available
    if ! ssh_exec "$port" "$key" "$user" "command -v claude >/dev/null 2>&1" 2>/dev/null; then
        echo "WARNING: claude not found in PATH" >&2
        # Non-fatal: claude-code may not be installed in base image yet
    fi

    if [[ "$checks_passed" == "false" ]]; then
        echo "WARNING: Some post-SSH checks failed, but SSH is available" >&2
    fi

    return 0
}

# ─── Port File Management ────────────────────────────────────────────────────

# Store the SSH port for a running project VM so other commands can find it
ssh_save_port() {
    local project_id="$1"
    local port="$2"
    local run_dir="${CLAUDE_VM_DIR:-${HOME}/.claude-vm}/run"

    mkdir -p "$run_dir"
    echo "$port" > "${run_dir}/${project_id}.port"
}

# Retrieve the stored SSH port for a project
ssh_load_port() {
    local project_id="$1"
    local run_dir="${CLAUDE_VM_DIR:-${HOME}/.claude-vm}/run"
    local port_file="${run_dir}/${project_id}.port"

    if [[ -f "$port_file" ]]; then
        cat "$port_file"
        return 0
    fi
    return 1
}

# Clean up the port file when a VM shuts down
ssh_cleanup_port() {
    local project_id="$1"
    local run_dir="${CLAUDE_VM_DIR:-${HOME}/.claude-vm}/run"

    rm -f "${run_dir}/${project_id}.port"
}
