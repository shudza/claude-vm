#!/usr/bin/env bash
# qemu-opts.sh — QEMU launch options optimized for fast boot and resume
#
# Provides pre-tuned QEMU argument sets for:
# - Fast cold boot (minimal devices, direct kernel boot if available)
# - Fast resume via loadvm (optimized memory backend)
# - virtiofs filesystem sharing

set -euo pipefail

# Default resource allocation (overridden by config)
DEFAULT_RAM="4G"
DEFAULT_CPUS="2"
DEFAULT_SSH_PORT="2222"

# Build base QEMU arguments common to both cold boot and resume
# Args:
#   $1 = snapshot qcow2 path
#   $2 = RAM (e.g., "4G")
#   $3 = CPU cores (e.g., "2")
#   $4 = SSH port
#   $5 = QMP socket path
#   $6 = PID file path
build_base_qemu_args() {
    local snapshot="$1"
    local ram="${2:-$DEFAULT_RAM}"
    local cpus="${3:-$DEFAULT_CPUS}"
    local ssh_port="${4:-$DEFAULT_SSH_PORT}"
    local qmp_socket="$5"
    local pid_file="$6"

    local args=(
        qemu-system-x86_64
        -enable-kvm

        # CPU: host passthrough for maximum performance
        -cpu host
        -smp "$cpus"

        # Memory: memfd backend required for virtiofs, share=on for DAX
        -object "memory-backend-memfd,id=mem,size=${ram},share=on"
        -numa "node,memdev=mem"
        -m "$ram"

        # Drive: virtio for best I/O, writeback cache for speed
        -drive "file=${snapshot},format=qcow2,if=virtio,cache=writeback,discard=unmap,detect-zeroes=unmap"

        # Network: user-mode with SSH port forward (fast, no bridge setup)
        -netdev "user,id=net0,hostfwd=tcp::${ssh_port}-:22"
        -device "virtio-net-pci,netdev=net0"

        # No graphics — headless operation
        -nographic
        -serial none

        # QMP for VM control (savevm, quit, etc.)
        -qmp "unix:${qmp_socket},server,nowait"

        # Daemonize and track PID
        -daemonize
        -pidfile "$pid_file"

        # Performance: disable unnecessary emulation
        -no-hpet
        -no-reboot
    )

    printf '%s\n' "${args[@]}"
}

# Build QEMU arguments for resume (loadvm) mode
# Args: same as build_base_qemu_args + $7 = VM state tag
build_resume_qemu_args() {
    local snapshot="$1"
    local ram="${2:-$DEFAULT_RAM}"
    local cpus="${3:-$DEFAULT_CPUS}"
    local ssh_port="${4:-$DEFAULT_SSH_PORT}"
    local qmp_socket="$5"
    local pid_file="$6"
    local vm_state_tag="${7:-claude-vm-state}"

    # Get base args
    build_base_qemu_args "$snapshot" "$ram" "$cpus" "$ssh_port" "$qmp_socket" "$pid_file"

    # Add loadvm for instant resume
    echo "-loadvm"
    echo "$vm_state_tag"
}

# Build virtiofs arguments
# Args:
#   $1 = virtiofsd socket path
#   $2 = mount tag (default: "workspace")
build_virtiofs_qemu_args() {
    local vfs_socket="$1"
    local mount_tag="${2:-workspace}"

    local args=(
        -chardev "socket,id=char-fs,path=${vfs_socket}"
        -device "vhost-user-fs-pci,chardev=char-fs,tag=${mount_tag},queue-size=1024"
    )

    printf '%s\n' "${args[@]}"
}

# Start virtiofsd for a project directory
# Args:
#   $1 = project directory to share
#   $2 = virtiofsd socket path
#   $3 = PID file for virtiofsd
start_virtiofsd() {
    local project_dir="$1"
    local vfs_socket="$2"
    local vfs_pid_file="$3"

    # Remove stale socket
    rm -f "$vfs_socket"

    # Detect virtiofsd binary location
    local virtiofsd_bin=""
    for candidate in /usr/lib/virtiofsd /usr/libexec/virtiofsd /usr/bin/virtiofsd; do
        if [[ -x "$candidate" ]]; then
            virtiofsd_bin="$candidate"
            break
        fi
    done

    if [[ -z "$virtiofsd_bin" ]]; then
        echo "error: virtiofsd not found. Install virtiofsd package." >&2
        return 1
    fi

    # Launch virtiofsd in background
    "$virtiofsd_bin" \
        --socket-path="$vfs_socket" \
        --shared-dir="$project_dir" \
        --cache=always \
        --sandbox=none &

    local vfs_pid=$!
    echo "$vfs_pid" > "$vfs_pid_file"

    # Wait briefly for socket to appear
    local i=0
    while [[ ! -S "$vfs_socket" && $i -lt 20 ]]; do
        sleep 0.1
        i=$((i + 1))
    done

    if [[ ! -S "$vfs_socket" ]]; then
        echo "error: virtiofsd socket did not appear" >&2
        kill "$vfs_pid" 2>/dev/null
        return 1
    fi

    echo "virtiofsd started (PID $vfs_pid)"
}
