#!/usr/bin/env bash
# resume.sh — Fast VM resume using QEMU VM state snapshots
#
# Uses QEMU's savevm/loadvm mechanism for near-instant resume.
# When a VM is suspended (not destroyed), its full memory state is saved
# into the qcow2 file. On resume, loadvm restores that state in ~2-5 seconds,
# achieving the <20 second target easily.
#
# Flow:
#   1. Check if snapshot has saved VM state ("claude-vm-state")
#   2. If yes: launch QEMU with -loadvm → resume in seconds
#   3. If no: cold boot from linked snapshot → slower but first-time only
#   4. Wait for SSH readiness
#   5. Report total time

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/wait-ready.sh"

# Name of the VM state snapshot stored inside the qcow2
VM_STATE_TAG="claude-vm-state"

# Maximum time (seconds) to wait for SSH after resume
RESUME_SSH_TIMEOUT=15
COLDBOOT_SSH_TIMEOUT=90

# Check if a qcow2 file contains a saved VM state snapshot
# Args: $1 = path to qcow2 file
has_vm_state() {
    local snapshot_file="$1"
    if [[ ! -f "$snapshot_file" ]]; then
        return 1
    fi
    # qemu-img snapshot -l lists internal snapshots including VM state
    qemu-img snapshot -l "$snapshot_file" 2>/dev/null | grep -q "$VM_STATE_TAG"
}

# Save VM state via QEMU monitor (QMP)
# Args: $1 = QMP socket path
save_vm_state() {
    local qmp_socket="$1"

    if [[ ! -S "$qmp_socket" ]]; then
        echo "error: QMP socket not found: $qmp_socket" >&2
        return 1
    fi

    # Send QMP commands: negotiate capabilities, then savevm
    # Using socat for QMP communication
    (
        echo '{"execute": "qmp_capabilities"}'
        sleep 0.2
        echo '{"execute": "human-monitor-command", "arguments": {"command-line": "savevm '"$VM_STATE_TAG"'"}}'
        sleep 2
    ) | socat - UNIX-CONNECT:"$qmp_socket" > /dev/null 2>&1

    local rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "VM state saved as '$VM_STATE_TAG'"
    else
        echo "warning: failed to save VM state (rc=$rc)" >&2
    fi
    return $rc
}

# Stop (suspend) the VM by saving state then quitting QEMU
# Args: $1 = QMP socket path
suspend_vm() {
    local qmp_socket="$1"

    if [[ ! -S "$qmp_socket" ]]; then
        echo "error: QMP socket not found: $qmp_socket" >&2
        return 1
    fi

    echo "Suspending VM (saving state)..."
    # Save VM state first, then quit
    (
        echo '{"execute": "qmp_capabilities"}'
        sleep 0.2
        echo '{"execute": "human-monitor-command", "arguments": {"command-line": "savevm '"$VM_STATE_TAG"'"}}'
        sleep 3
        echo '{"execute": "quit"}'
        sleep 0.5
    ) | socat - UNIX-CONNECT:"$qmp_socket" > /dev/null 2>&1

    echo "VM suspended."
}

# Build QEMU launch arguments for resume (loadvm) vs cold boot
# Args: $1 = snapshot qcow2 path
# Returns: prints extra QEMU args to stdout
# Exit code: 0 = resume mode, 1 = cold boot mode
build_resume_args() {
    local snapshot_file="$1"

    if has_vm_state "$snapshot_file"; then
        # Resume mode: load saved VM state
        echo "-loadvm $VM_STATE_TAG"
        return 0
    else
        # Cold boot mode: no extra args
        return 1
    fi
}

# Launch VM with resume support and wait for readiness
# Args:
#   $1 = snapshot qcow2 path
#   $2 = SSH port
#   $3 = QMP socket path
#   $4+ = additional QEMU args (passed through)
# Returns: 0 if VM is ready, 1 on timeout
launch_and_wait() {
    local snapshot_file="$1"
    local ssh_port="$2"
    local qmp_socket="$3"
    shift 3
    local extra_args=("$@")

    local start_time
    start_time=$(date +%s%N)

    local is_resume=false
    local resume_args=""
    local ssh_timeout=$COLDBOOT_SSH_TIMEOUT

    if has_vm_state "$snapshot_file"; then
        is_resume=true
        resume_args="-loadvm $VM_STATE_TAG"
        ssh_timeout=$RESUME_SSH_TIMEOUT
        echo "⚡ Resuming VM from saved state..."
    else
        echo "🔄 Cold-booting VM..."
    fi

    # Build full QEMU command
    local qemu_cmd=(
        qemu-system-x86_64
        -enable-kvm
        -cpu host
        -drive "file=${snapshot_file},format=qcow2,if=virtio,cache=writeback"
        -qmp "unix:${qmp_socket},server,nowait"
        -nographic
        -daemonize
        -pidfile "${snapshot_file%.qcow2}.pid"
    )

    # Add resume args if applicable
    if [[ -n "$resume_args" ]]; then
        # shellcheck disable=SC2206
        qemu_cmd+=($resume_args)
    fi

    # Add any extra args (RAM, CPU, network, virtiofs, etc.)
    qemu_cmd+=("${extra_args[@]}")

    # Launch QEMU
    if ! "${qemu_cmd[@]}"; then
        echo "error: QEMU failed to start" >&2
        return 1
    fi

    # Wait for SSH readiness
    if ! wait_for_ssh "localhost" "$ssh_port" "$ssh_timeout"; then
        local elapsed
        elapsed=$(elapsed_ms "$start_time")
        echo "error: VM did not become ready within ${ssh_timeout}s (${elapsed}ms elapsed)" >&2
        return 1
    fi

    local elapsed
    elapsed=$(elapsed_ms "$start_time")
    local elapsed_sec=$((elapsed / 1000))

    if $is_resume; then
        if [[ $elapsed_sec -le 20 ]]; then
            echo "✅ VM resumed and ready in ${elapsed}ms (within 20s target)"
        else
            echo "⚠️  VM resumed but took ${elapsed}ms (exceeds 20s target)"
        fi
    else
        echo "✅ VM cold-booted and ready in ${elapsed}ms"
    fi

    return 0
}

# Calculate elapsed time in milliseconds from a nanosecond timestamp
# Args: $1 = start time from $(date +%s%N)
elapsed_ms() {
    local start_ns="$1"
    local now_ns
    now_ns=$(date +%s%N)
    echo $(( (now_ns - start_ns) / 1000000 ))
}

# Delete saved VM state from a snapshot (force cold boot next time)
# Args: $1 = snapshot qcow2 path
delete_vm_state() {
    local snapshot_file="$1"
    if has_vm_state "$snapshot_file"; then
        qemu-img snapshot -d "$VM_STATE_TAG" "$snapshot_file" 2>/dev/null
        echo "Deleted saved VM state from $snapshot_file"
    fi
}
