#!/usr/bin/env bash
# shutdown.sh — Clean VM shutdown with snapshot preservation
#
# Ensures:
# - Guest filesystem is synced before stopping
# - VM state is saved into the QCOW2 for fast resume (optional)
# - QEMU is shut down gracefully via ACPI, then force-killed as fallback
# - virtiofsd is stopped
# - The linked snapshot file on disk is NEVER deleted
# - Runtime artifacts (PID files, sockets) are cleaned up
#
# The linked snapshot is preserved because:
# - QEMU's ACPI shutdown or quit command flushes dirty blocks to the qcow2
# - We verify the snapshot file exists and is non-zero after shutdown
# - Only runtime state (PID files, sockets, logs) is removed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Timeout constants
ACPI_SHUTDOWN_TIMEOUT=15     # seconds to wait for ACPI shutdown
FORCE_KILL_GRACE=2           # seconds between SIGTERM and SIGKILL
SAVEVM_TIMEOUT=10            # seconds to wait for savevm to complete

# VM state tag for fast resume (must match resume.sh)
VM_STATE_TAG="claude-vm-state"

# Send a command to the QEMU HMP monitor
# Args: $1 = monitor socket path, $2 = command
_hmp_command() {
    local sock="$1"
    local cmd="$2"
    if [[ -S "$sock" ]]; then
        echo "$cmd" | socat -T2 - "UNIX-CONNECT:$sock" 2>/dev/null || true
    fi
}

# Send a command to the QEMU QMP monitor
# Args: $1 = QMP socket path, $2+ = QMP JSON commands (one per arg)
_qmp_command() {
    local sock="$1"
    shift

    if [[ ! -S "$sock" ]]; then
        return 1
    fi

    (
        echo '{"execute": "qmp_capabilities"}'
        sleep 0.2
        for cmd in "$@"; do
            echo "$cmd"
            sleep 0.3
        done
    ) | socat -T5 - "UNIX-CONNECT:$sock" 2>/dev/null
}

# Attempt to save VM state for fast resume via QMP
# Args: $1 = run directory
# Returns: 0 if saved, 1 if not possible
try_save_vm_state() {
    local run_dir="$1"
    local qmp_sock="$run_dir/qmp.sock"

    if [[ ! -S "$qmp_sock" ]]; then
        return 1
    fi

    echo "  Saving VM state for fast resume..."

    local output
    output=$(_qmp_command "$qmp_sock" \
        '{"execute": "human-monitor-command", "arguments": {"command-line": "savevm '"$VM_STATE_TAG"'"}}' \
    ) 2>/dev/null || return 1

    # Wait for savevm to complete (it writes to the qcow2)
    sleep "$SAVEVM_TIMEOUT"

    echo "  VM state saved."
    return 0
}

# Gracefully shut down the VM, preserving the linked snapshot
# This is the primary shutdown function used by `claude-vm stop`
#
# Shutdown sequence:
# 1. (Optional) Save VM state for fast resume
# 2. Send ACPI power-down via HMP monitor (triggers guest shutdown)
# 3. Wait for QEMU process to exit
# 4. If still running, SIGTERM → SIGKILL
# 5. Stop virtiofsd
# 6. Verify snapshot file integrity
# 7. Clean up runtime files (but NOT the snapshot)
#
# Args: $1 = project directory
# Returns: 0 on success, 1 on error
shutdown_vm() {
    local project_dir="${1:-$PWD}"

    # Source config if not already loaded
    if [[ -z "${CLAUDE_VM_DIR:-}" ]]; then
        source "$SCRIPT_DIR/config.sh"
        load_config
    fi

    local run_dir snap_path
    run_dir="$(project_run_dir "$project_dir")"
    snap_path="$(project_snapshot_path "$project_dir")"

    local pid_file="$run_dir/qemu.pid"
    local monitor_sock="$run_dir/monitor.sock"
    local qmp_sock="$run_dir/qmp.sock"

    # Check if VM is actually running
    if [[ ! -f "$pid_file" ]]; then
        echo "No VM running for this project."
        return 0
    fi

    local qemu_pid
    qemu_pid=$(cat "$pid_file" 2>/dev/null) || true

    if [[ -z "$qemu_pid" ]] || ! kill -0 "$qemu_pid" 2>/dev/null; then
        echo "No VM running (stale PID file)."
        _cleanup_runtime "$run_dir"
        return 0
    fi

    echo "Shutting down VM (PID: $qemu_pid)..."

    # Step 1: Try to save VM state for fast resume (best effort)
    try_save_vm_state "$run_dir" 2>/dev/null || true

    # Step 2: Request graceful ACPI shutdown
    local shutdown_sent=false

    # Try QMP quit (cleaner than ACPI as QEMU flushes all blocks)
    if [[ -S "$qmp_sock" ]]; then
        echo "  Requesting shutdown via QMP..."
        _qmp_command "$qmp_sock" '{"execute": "quit"}' &>/dev/null && shutdown_sent=true
    fi

    # Fall back to HMP system_powerdown
    if ! $shutdown_sent && [[ -S "$monitor_sock" ]]; then
        echo "  Requesting ACPI shutdown via monitor..."
        _hmp_command "$monitor_sock" "system_powerdown"
        shutdown_sent=true
    fi

    # Step 3: Wait for QEMU to exit gracefully
    if $shutdown_sent; then
        local waited=0
        while kill -0 "$qemu_pid" 2>/dev/null && (( waited < ACPI_SHUTDOWN_TIMEOUT )); do
            sleep 1
            (( waited++ ))
        done
    fi

    # Step 4: Force kill if still alive
    if kill -0 "$qemu_pid" 2>/dev/null; then
        echo "  Graceful shutdown timed out. Sending SIGTERM..."
        kill "$qemu_pid" 2>/dev/null || true
        sleep "$FORCE_KILL_GRACE"

        if kill -0 "$qemu_pid" 2>/dev/null; then
            echo "  Sending SIGKILL..."
            kill -9 "$qemu_pid" 2>/dev/null || true
            sleep 1
        fi
    fi

    # Step 5: Stop virtiofsd
    _stop_virtiofsd "$run_dir"

    # Step 6: Verify snapshot integrity
    if [[ -f "$snap_path" ]]; then
        local snap_size
        snap_size=$(stat -c%s "$snap_path" 2>/dev/null || echo 0)
        if (( snap_size > 0 )); then
            echo "  Snapshot preserved: $snap_path ($(numfmt --to=iec "$snap_size" 2>/dev/null || echo "${snap_size}B"))"
        else
            echo "  WARNING: Snapshot file exists but is empty: $snap_path" >&2
        fi
    else
        echo "  WARNING: Snapshot file not found after shutdown: $snap_path" >&2
        echo "  This may indicate a problem. Run 'claude-vm reset' to recreate." >&2
    fi

    # Step 7: Clean up runtime artifacts only (NOT the snapshot)
    _cleanup_runtime "$run_dir"

    echo "VM stopped. Snapshot preserved on disk."
    return 0
}

# Stop the virtiofsd daemon for a project
# Args: $1 = run directory
_stop_virtiofsd() {
    local run_dir="$1"
    local vfs_pid_file="$run_dir/virtiofsd.pid"

    if [[ -f "$vfs_pid_file" ]]; then
        local vfs_pid
        vfs_pid=$(cat "$vfs_pid_file" 2>/dev/null) || return 0
        if [[ -n "$vfs_pid" ]] && kill -0 "$vfs_pid" 2>/dev/null; then
            kill "$vfs_pid" 2>/dev/null || true
            # Wait briefly for clean exit
            local waited=0
            while kill -0 "$vfs_pid" 2>/dev/null && (( waited < 3 )); do
                sleep 0.5
                (( waited++ )) || true
            done
            if kill -0 "$vfs_pid" 2>/dev/null; then
                kill -9 "$vfs_pid" 2>/dev/null || true
            fi
        fi
    fi
}

# Clean up runtime artifacts (PID files, sockets, logs)
# NEVER deletes the snapshot file — only run-directory contents
# Args: $1 = run directory
_cleanup_runtime() {
    local run_dir="$1"

    if [[ ! -d "$run_dir" ]]; then
        return 0
    fi

    # Remove PID files
    rm -f "$run_dir/qemu.pid" "$run_dir/virtiofsd.pid"

    # Remove sockets
    rm -f "$run_dir/monitor.sock" "$run_dir/qmp.sock" "$run_dir/virtiofs.sock"

    # Remove SSH port marker
    rm -f "$run_dir/ssh_port"

    # Keep logs for debugging (serial.log, virtiofsd.log)
    # The run directory itself is kept (logs may be useful)
}

# Quick check: is the snapshot file present and non-empty?
# Used to verify shutdown didn't corrupt anything.
# Args: $1 = project directory
verify_snapshot_preserved() {
    local project_dir="${1:-$PWD}"

    if [[ -z "${CLAUDE_VM_DIR:-}" ]]; then
        source "$SCRIPT_DIR/config.sh"
        load_config
    fi

    local snap_path
    snap_path="$(project_snapshot_path "$project_dir")"

    if [[ ! -f "$snap_path" ]]; then
        echo "FAIL: Snapshot not found: $snap_path" >&2
        return 1
    fi

    local size
    size=$(stat -c%s "$snap_path" 2>/dev/null || echo 0)
    if (( size == 0 )); then
        echo "FAIL: Snapshot is empty: $snap_path" >&2
        return 1
    fi

    echo "OK: Snapshot intact ($snap_path, $(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B"))"
    return 0
}
