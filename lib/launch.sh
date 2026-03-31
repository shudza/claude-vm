#!/usr/bin/env bash
# VM launch logic for claude-vm
# Handles: start VM from snapshot, setup virtiofs, SSH readiness

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/virtiofs.sh"
source "$SCRIPT_DIR/shutdown.sh"

# Find an available port starting from a base
find_available_port() {
    local base_port="$1"
    local port="$base_port"
    while (( port < base_port + 100 )); do
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
        (( port++ ))
    done
    echo "ERROR: No available port found in range ${base_port}-$(( base_port + 99 ))" >&2
    return 1
}

# Get the SSH port for a running project VM
get_project_ssh_port() {
    local project_dir="${1:-$PWD}"
    local run_dir
    run_dir="$(project_run_dir "$project_dir")"
    if [[ -f "$run_dir/ssh_port" ]]; then
        cat "$run_dir/ssh_port"
    fi
}

# Check if a project VM is already running
is_vm_running() {
    local project_dir="${1:-$PWD}"
    local run_dir pid_file
    run_dir="$(project_run_dir "$project_dir")"
    pid_file="$run_dir/qemu.pid"

    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        # Stale PID file, clean up
        rm -f "$pid_file"
    fi
    return 1
}

# Launch a VM for the current project
# This is the main entry point for `claude-vm` (no subcommand)
launch_vm() {
    local project_dir="${1:-$PWD}"
    local start_time
    start_time=$(date +%s)

    load_config
    ensure_dirs

    local snap_path base_img run_dir
    snap_path="$(project_snapshot_path "$project_dir")"
    base_img="$(base_image_path)"
    run_dir="$(project_run_dir "$project_dir")"

    # Check if VM is already running
    if is_vm_running "$project_dir"; then
        local ssh_port
        ssh_port="$(get_project_ssh_port "$project_dir")"
        echo "VM already running for this project."
        echo "SSH: ssh -p $ssh_port claude@localhost"
        return 0
    fi

    # Build base image if needed
    if [[ ! -f "$base_img" ]]; then
        echo "No base image found. Building one first..."
        echo ""
        source "$SCRIPT_DIR/build.sh"
        build_base_image
        echo ""
    fi

    # Create project snapshot if needed
    if [[ ! -f "$snap_path" ]]; then
        echo "Creating project snapshot..."
        source "$SCRIPT_DIR/build.sh"
        create_project_snapshot "$project_dir"
        echo ""
    fi

    # Setup run directory
    mkdir -p "$run_dir"

    # Find available SSH port
    local ssh_port
    ssh_port="$(find_available_port "$SSH_PORT_BASE")"
    echo "$ssh_port" > "$run_dir/ssh_port"

    # Determine acceleration
    local accel="kvm"
    if [[ ! -r /dev/kvm ]] || [[ ! -w /dev/kvm ]]; then
        echo "WARNING: KVM not accessible, falling back to TCG (slower)"
        accel="tcg"
    fi

    # Setup virtiofs socket path
    local virtiofs_sock="$run_dir/virtiofs.sock"

    # Start virtiofsd for sharing project directory
    echo "Starting virtiofs daemon for $project_dir..."
    start_virtiofsd "$project_dir" "$virtiofs_sock" "$run_dir"

    # Build QEMU command
    echo "Launching VM..."
    echo "  RAM: $VM_RAM | CPUs: $VM_CPUS | SSH port: $ssh_port"

    local qemu_args=(
        -name "claude-vm-$(project_hash "$project_dir")"
        -machine "type=q35,accel=$accel"
        -cpu host
        -smp "$VM_CPUS"
        -m "$VM_RAM"

        # Memory backend for virtiofs (requires shared memory)
        -object "memory-backend-memfd,id=mem,size=$VM_RAM,share=on"
        -numa "node,memdev=mem"

        # Project snapshot disk
        -drive "file=$snap_path,format=qcow2,if=virtio,cache=writeback"

        # Network with SSH port forward
        -netdev "user,id=net0,hostfwd=tcp::${ssh_port}-:22"
        -device "virtio-net-pci,netdev=net0"

        # Virtiofs for project directory
        -chardev "socket,id=vhost-fs,path=$virtiofs_sock"
        -device "vhost-user-fs-pci,chardev=vhost-fs,tag=workspace,queue-size=1024"

        # No graphics
        -nographic
        -serial "file:$run_dir/serial.log"
        -monitor "unix:$run_dir/monitor.sock,server,nowait"

        # PID file
        -pidfile "$run_dir/qemu.pid"

        # Daemonize
        -daemonize
    )

    qemu-system-x86_64 "${qemu_args[@]}"

    echo "  VM started (PID: $(cat "$run_dir/qemu.pid"))"

    # Wait for SSH to become available
    echo "  Waiting for SSH..."
    wait_for_ssh "$ssh_port" 60

    # Ensure virtiofs workspace is mounted in guest
    echo "  Verifying virtiofs mount..."
    virtiofs_ensure_mounted "$ssh_port" "" "claude"

    local elapsed=$(( $(date +%s) - start_time ))
    echo ""
    echo "==> VM ready in ${elapsed}s"
    echo "    SSH: ssh -p $ssh_port claude@localhost"
    echo "    Project: $project_dir → /workspace (virtiofs)"
    echo ""
    echo "    Run 'claude-vm ssh' to connect"
}

# Start virtiofsd for a project directory
start_virtiofsd() {
    local project_dir="$1"
    local sock_path="$2"
    local run_dir="$3"

    rm -f "$sock_path"

    # Try the new rust-based virtiofsd first, then fall back to legacy
    local virtiofsd_bin=""
    if command -v virtiofsd &>/dev/null; then
        virtiofsd_bin="virtiofsd"
    elif [[ -x /usr/lib/virtiofsd ]]; then
        virtiofsd_bin="/usr/lib/virtiofsd"
    elif [[ -x /usr/libexec/virtiofsd ]]; then
        virtiofsd_bin="/usr/libexec/virtiofsd"
    elif command -v /usr/lib/qemu/virtiofsd &>/dev/null; then
        virtiofsd_bin="/usr/lib/qemu/virtiofsd"
    else
        echo "ERROR: virtiofsd not found. Install virtiofsd package." >&2
        echo "  Arch/CachyOS: sudo pacman -S virtiofsd" >&2
        echo "  Ubuntu/Debian: sudo apt install virtiofsd" >&2
        return 1
    fi

    # Start virtiofsd in background
    "$virtiofsd_bin" \
        --socket-path="$sock_path" \
        --shared-dir="$project_dir" \
        --cache=auto \
        --announce-submounts \
        &>"$run_dir/virtiofsd.log" &

    local vfs_pid=$!
    echo "$vfs_pid" > "$run_dir/virtiofsd.pid"

    # Wait for socket to appear
    local waited=0
    while [[ ! -S "$sock_path" ]] && (( waited < 5 )); do
        sleep 0.2
        (( waited++ )) || true
    done

    if [[ ! -S "$sock_path" ]]; then
        echo "ERROR: virtiofsd failed to start. Check $run_dir/virtiofsd.log" >&2
        return 1
    fi
}

# Wait for SSH to become available
wait_for_ssh() {
    local port="$1"
    local timeout="${2:-60}"
    local waited=0

    while (( waited < timeout )); do
        if ssh -o ConnectTimeout=1 -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o BatchMode=yes \
               -p "$port" claude@localhost true 2>/dev/null; then
            echo "  SSH ready!"
            return 0
        fi
        sleep 1
        (( waited++ ))
        if (( waited % 5 == 0 )); then
            echo "  ... waiting for SSH (${waited}s)"
        fi
    done

    echo "WARNING: SSH did not become available within ${timeout}s" >&2
    echo "         VM may still be booting. Try 'claude-vm ssh' later." >&2
    return 1
}

# Stop a running VM gracefully, preserving the linked snapshot on disk
# Delegates to shutdown.sh for the full clean shutdown sequence:
#   1. Save VM state for fast resume (if QMP available)
#   2. ACPI shutdown or QMP quit
#   3. SIGTERM → SIGKILL fallback
#   4. Stop virtiofsd
#   5. Verify snapshot preserved
#   6. Clean up runtime artifacts (not the snapshot)
stop_vm() {
    local project_dir="${1:-$PWD}"
    shutdown_vm "$project_dir"
}
