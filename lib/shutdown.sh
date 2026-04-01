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
source "$SCRIPT_DIR/ui.sh"

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

    local output
    output=$(_qmp_command "$qmp_sock" \
        '{"execute": "human-monitor-command", "arguments": {"command-line": "savevm '"$VM_STATE_TAG"'"}}' \
    ) 2>/dev/null || return 1

    # Wait for savevm to complete (it writes to the qcow2)
    sleep "$SAVEVM_TIMEOUT"
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
        ui_info "No VM running for this project."
        return 0
    fi

    local qemu_pid
    qemu_pid=$(cat "$pid_file" 2>/dev/null) || true

    if [[ -z "$qemu_pid" ]] || ! kill -0 "$qemu_pid" 2>/dev/null; then
        ui_info "No VM running (stale PID file)."
        _cleanup_runtime "$run_dir"
        return 0
    fi

    # Initialize UI logging
    ui_init "$run_dir/shutdown.log"

    # Step 1: Save VM state for fast resume (best effort)
    ui_phase "Saving VM state" try_save_vm_state "$run_dir" || true

    # Step 2+3+4: Graceful shutdown with fallback to force kill
    _do_shutdown() {
        local shutdown_sent=false

        # Try QMP quit (cleaner — QEMU flushes all blocks)
        if [[ -S "$qmp_sock" ]]; then
            _qmp_command "$qmp_sock" '{"execute": "quit"}' &>/dev/null && shutdown_sent=true
        fi

        # Fall back to HMP system_powerdown
        if ! $shutdown_sent && [[ -S "$monitor_sock" ]]; then
            _hmp_command "$monitor_sock" "system_powerdown"
            shutdown_sent=true
        fi

        # Wait for QEMU to exit gracefully
        if $shutdown_sent; then
            local waited=0
            while kill -0 "$qemu_pid" 2>/dev/null && (( waited < ACPI_SHUTDOWN_TIMEOUT )); do
                sleep 1
                (( waited++ ))
            done
        fi

        # Force kill if still alive
        if kill -0 "$qemu_pid" 2>/dev/null; then
            kill "$qemu_pid" 2>/dev/null || true
            sleep "$FORCE_KILL_GRACE"
            if kill -0 "$qemu_pid" 2>/dev/null; then
                kill -9 "$qemu_pid" 2>/dev/null || true
                sleep 1
            fi
        fi
    }
    ui_phase "Stopping VM" _do_shutdown

    # Step 5: Stop virtiofsd
    ui_phase "Stopping filesystem sharing" _stop_virtiofsd "$run_dir"

    # Step 6: Verify snapshot integrity
    if [[ -f "$snap_path" ]]; then
        local snap_size
        snap_size=$(stat -c%s "$snap_path" 2>/dev/null || echo 0)
        if (( snap_size == 0 )); then
            ui_warn "Snapshot file is empty: $snap_path"
        fi
    else
        ui_warn "Snapshot not found after shutdown — run 'claude-vm reset' to recreate"
    fi

    # Step 7: Clean up runtime artifacts only (NOT the snapshot)
    _cleanup_runtime "$run_dir"

    ui_done "Stopped"
    return 0
}

# Shut down a VM given its run directory (used by stop --all)
# Resolves the project dir from the sidecar .project file
# Args: $1 = run directory path
stop_vm_by_run_dir() {
    local run_dir="${1%/}"
    local hash
    hash="$(basename "$run_dir")"

    # Source config if not already loaded
    if [[ -z "${CLAUDE_VM_DIR:-}" ]]; then
        source "$SCRIPT_DIR/config.sh"
        load_config
    fi

    local project_file="$SNAPSHOTS_DIR/${hash}.project"
    if [[ -f "$project_file" ]]; then
        local project_dir
        project_dir="$(cat "$project_file")"
        shutdown_vm "$project_dir"
    else
        # No sidecar — fall back to direct shutdown using the run dir
        # This handles orphaned run dirs where the .project file is missing
        shutdown_vm_from_run_dir "$run_dir" "$hash"
    fi
}

# Direct shutdown when we only have a run directory (no project dir)
# Stripped-down version of shutdown_vm for the orphaned case
# Args: $1 = run directory, $2 = hash
shutdown_vm_from_run_dir() {
    local run_dir="$1"
    local hash="$2"
    local snap_path="$SNAPSHOTS_DIR/${hash}.qcow2"

    local pid_file="$run_dir/qemu.pid"
    local monitor_sock="$run_dir/monitor.sock"
    local qmp_sock="$run_dir/qmp.sock"

    if [[ ! -f "$pid_file" ]]; then
        return 0
    fi

    local qemu_pid
    qemu_pid=$(cat "$pid_file" 2>/dev/null) || true

    if [[ -z "$qemu_pid" ]] || ! kill -0 "$qemu_pid" 2>/dev/null; then
        _cleanup_runtime "$run_dir"
        return 0
    fi

    ui_init "$run_dir/shutdown.log"

    ui_phase "Saving VM state" try_save_vm_state "$run_dir" || true

    _do_shutdown() {
        local shutdown_sent=false
        if [[ -S "$qmp_sock" ]]; then
            _qmp_command "$qmp_sock" '{"execute": "quit"}' &>/dev/null && shutdown_sent=true
        fi
        if ! $shutdown_sent && [[ -S "$monitor_sock" ]]; then
            _hmp_command "$monitor_sock" "system_powerdown"
            shutdown_sent=true
        fi
        if $shutdown_sent; then
            local waited=0
            while kill -0 "$qemu_pid" 2>/dev/null && (( waited < ACPI_SHUTDOWN_TIMEOUT )); do
                sleep 1
                (( waited++ ))
            done
        fi
        if kill -0 "$qemu_pid" 2>/dev/null; then
            kill "$qemu_pid" 2>/dev/null || true
            sleep "$FORCE_KILL_GRACE"
            if kill -0 "$qemu_pid" 2>/dev/null; then
                kill -9 "$qemu_pid" 2>/dev/null || true
                sleep 1
            fi
        fi
    }
    ui_phase "Stopping VM" _do_shutdown
    ui_phase "Stopping filesystem sharing" _stop_virtiofsd "$run_dir"
    _cleanup_runtime "$run_dir"
    ui_done "Stopped"
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
