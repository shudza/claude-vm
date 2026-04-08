#!/usr/bin/env bash
# virtiofs.sh — Virtiofs filesystem sharing between host and guest
#
# Manages the virtiofsd daemon on the host side and provides functions
# to verify that the guest has correctly mounted the shared filesystem
# with full read/write access.
#
# Architecture:
#   Host: virtiofsd --shared-dir=$PROJECT_DIR --socket-path=$SOCK
#   QEMU: -chardev socket + -device vhost-user-fs-pci,tag=workspace
#   Guest: mount -t virtiofs workspace /workspace (via fstab or systemd)

set -euo pipefail

# Mount tag used by both QEMU device and guest mount
VIRTIOFS_MOUNT_TAG="workspace"
# Guest mount point
VIRTIOFS_GUEST_MOUNT="/workspace"
# Default queue size for vhost-user-fs-pci
VIRTIOFS_QUEUE_SIZE=1024

# ─── Host-side: virtiofsd management ────────────────────────────────────────

# Locate the virtiofsd binary across common install locations
# Returns: path to virtiofsd binary, or empty string if not found
virtiofs_find_daemon() {
    local candidates=(
        virtiofsd                    # PATH (Arch: virtiofsd package)
        /usr/lib/virtiofsd           # Arch/CachyOS
        /usr/libexec/virtiofsd       # Fedora/RHEL
        /usr/lib/qemu/virtiofsd      # Debian/Ubuntu (legacy C version)
        /usr/libexec/qemu/virtiofsd  # Alternative Debian location
    )

    for candidate in "${candidates[@]}"; do
        if command -v "$candidate" &>/dev/null; then
            command -v "$candidate"
            return 0
        elif [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

# Ensure virtiofs is mounted inside the guest (mount if needed)
# Args: $1 = SSH port, $2 = SSH key (optional), $3 = SSH user (optional)
virtiofs_ensure_mounted() {
    local ssh_port="$1"
    local ssh_key="${2:-}"
    local ssh_user="${3:-${VM_USER:-$USER}}"

    local ssh_opts=(
        -p "$ssh_port"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ConnectTimeout=5
        -o BatchMode=yes
    )
    if [[ -n "$ssh_key" ]]; then
        ssh_opts+=(-i "$ssh_key")
    fi

    # Check if already mounted
    if ssh "${ssh_opts[@]}" "${ssh_user}@localhost" \
        "mount | grep -q 'type virtiofs'" 2>/dev/null; then
        return 0
    fi

    # Try to mount
    ssh "${ssh_opts[@]}" "${ssh_user}@localhost" \
        "sudo mkdir -p ${VIRTIOFS_GUEST_MOUNT} && sudo mount -t virtiofs ${VIRTIOFS_MOUNT_TAG} ${VIRTIOFS_GUEST_MOUNT} && sudo chown ${ssh_user}:${ssh_user} ${VIRTIOFS_GUEST_MOUNT}" 2>/dev/null
}
