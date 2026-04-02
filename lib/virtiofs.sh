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

# Start the virtiofsd daemon for a project directory
# Args:
#   $1 = project directory to share (host path)
#   $2 = socket path for QEMU communication
#   $3 = run directory (for PID file and logs)
# Returns: 0 on success, 1 on failure
virtiofs_start_daemon() {
    local project_dir="$1"
    local sock_path="$2"
    local run_dir="$3"
    local pid_file="$run_dir/virtiofsd.pid"
    local log_file="$run_dir/virtiofsd.log"

    # Validate project directory exists and is accessible
    if [[ ! -d "$project_dir" ]]; then
        echo "ERROR: Project directory does not exist: $project_dir" >&2
        return 1
    fi

    if [[ ! -r "$project_dir" ]] || [[ ! -w "$project_dir" ]]; then
        echo "ERROR: Project directory is not readable/writable: $project_dir" >&2
        return 1
    fi

    # Find virtiofsd
    local virtiofsd_bin
    if ! virtiofsd_bin=$(virtiofs_find_daemon); then
        echo "ERROR: virtiofsd not found." >&2
        echo "Install it:" >&2
        echo "  Arch/CachyOS: sudo pacman -S virtiofsd" >&2
        echo "  Ubuntu/Debian: sudo apt install virtiofsd" >&2
        echo "  Fedora: sudo dnf install virtiofsd" >&2
        return 1
    fi

    # Clean up any stale socket
    rm -f "$sock_path"

    # Ensure run directory exists
    mkdir -p "$run_dir"

    # Detect virtiofsd version/variant for correct flags
    local daemon_args=(
        --socket-path="$sock_path"
        --shared-dir="$project_dir"
        --cache=auto
    )

    # The Rust virtiofsd supports --announce-submounts; the C version does not.
    # Detect by checking help output.
    if "$virtiofsd_bin" --help 2>&1 | grep -q 'announce-submounts'; then
        daemon_args+=(--announce-submounts)
    fi

    # --sandbox=none avoids userns issues on some systems; the Rust version
    # uses --sandbox=chroot by default which is fine, but we prefer none
    # for compatibility with host user permissions.
    if "$virtiofsd_bin" --help 2>&1 | grep -q 'sandbox'; then
        daemon_args+=(--sandbox=none)
    fi

    # Start virtiofsd in background
    "$virtiofsd_bin" "${daemon_args[@]}" \
        &>"$log_file" &

    local vfs_pid=$!
    echo "$vfs_pid" > "$pid_file"

    # Wait for socket to appear (up to 3 seconds)
    local waited=0
    while [[ ! -S "$sock_path" ]] && (( waited < 30 )); do
        sleep 0.1
        (( waited++ )) || true
    done

    if [[ ! -S "$sock_path" ]]; then
        echo "ERROR: virtiofsd failed to create socket within 3s" >&2
        echo "  Check log: $log_file" >&2
        if [[ -f "$log_file" ]]; then
            echo "  Last lines:" >&2
            tail -5 "$log_file" >&2
        fi
        kill "$vfs_pid" 2>/dev/null || true
        return 1
    fi

    echo "virtiofsd started (PID $vfs_pid) sharing $project_dir"
    return 0
}

# Stop the virtiofsd daemon for a project
# Args:
#   $1 = run directory containing virtiofsd.pid
virtiofs_stop_daemon() {
    local run_dir="$1"
    local pid_file="$run_dir/virtiofsd.pid"

    if [[ ! -f "$pid_file" ]]; then
        return 0
    fi

    local vfs_pid
    vfs_pid=$(cat "$pid_file")

    if kill -0 "$vfs_pid" 2>/dev/null; then
        kill "$vfs_pid" 2>/dev/null || true
        # Wait briefly for clean exit
        local waited=0
        while kill -0 "$vfs_pid" 2>/dev/null && (( waited < 10 )); do
            sleep 0.1
            (( waited++ )) || true
        done
        # Force kill if still alive
        if kill -0 "$vfs_pid" 2>/dev/null; then
            kill -9 "$vfs_pid" 2>/dev/null || true
        fi
    fi

    rm -f "$pid_file"
    rm -f "$run_dir/virtiofs.sock"
}

# Check if virtiofsd is running for a project
# Args: $1 = run directory
virtiofs_is_running() {
    local run_dir="$1"
    local pid_file="$run_dir/virtiofsd.pid"

    if [[ -f "$pid_file" ]]; then
        local vfs_pid
        vfs_pid=$(cat "$pid_file")
        kill -0 "$vfs_pid" 2>/dev/null
        return $?
    fi
    return 1
}

# ─── QEMU arguments for virtiofs ────────────────────────────────────────────

# Generate QEMU arguments for virtiofs device
# QEMU requires: shared memory backend + chardev socket + vhost-user-fs device
# Args:
#   $1 = virtiofsd socket path
#   $2 = RAM size (e.g., "4G") — needed for memory backend
# Returns: prints QEMU arguments, one per line
virtiofs_qemu_args() {
    local sock_path="$1"
    local ram_size="${2:-4G}"

    # Memory backend with share=on (required for virtiofs DAX/mmap)
    echo "-object"
    echo "memory-backend-memfd,id=mem,size=${ram_size},share=on"
    echo "-numa"
    echo "node,memdev=mem"

    # Chardev socket connecting to virtiofsd
    echo "-chardev"
    echo "socket,id=vhost-fs,path=${sock_path}"

    # Vhost-user filesystem device with mount tag
    echo "-device"
    echo "vhost-user-fs-pci,chardev=vhost-fs,tag=${VIRTIOFS_MOUNT_TAG},queue-size=${VIRTIOFS_QUEUE_SIZE}"
}

# ─── Guest-side: mount verification via SSH ─────────────────────────────────

# Verify that virtiofs is mounted and functional inside the guest.
# Performs a series of checks: mount exists, is writable, and round-trips data.
# Args:
#   $1 = SSH port
#   $2 = project directory (host side, for verification)
#   $3 = SSH key path (optional)
#   $4 = SSH user (optional, default: claude)
# Returns: 0 if all checks pass, 1 on failure
virtiofs_verify_mount() {
    local ssh_port="$1"
    local project_dir="$2"
    local ssh_key="${3:-}"
    local ssh_user="${4:-${VM_USER:-$USER}}"

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

    local failures=0

    # Check 1: /workspace exists and is a mount point
    echo -n "  Checking virtiofs mount... "
    if ssh "${ssh_opts[@]}" "${ssh_user}@localhost" \
        "mountpoint -q ${VIRTIOFS_GUEST_MOUNT} 2>/dev/null || mount | grep -q 'type virtiofs'" 2>/dev/null; then
        echo "OK (mounted)"
    else
        echo "FAIL (not mounted)"
        # Try to mount it manually
        echo -n "  Attempting manual mount... "
        if ssh "${ssh_opts[@]}" "${ssh_user}@localhost" \
            "sudo mount -t virtiofs ${VIRTIOFS_MOUNT_TAG} ${VIRTIOFS_GUEST_MOUNT} 2>/dev/null" 2>/dev/null; then
            echo "OK"
        else
            echo "FAIL"
            failures=$(( failures + 1 ))
        fi
    fi

    # Check 2: Read test — can we list files from the host project?
    echo -n "  Checking read access... "
    local guest_ls
    if guest_ls=$(ssh "${ssh_opts[@]}" "${ssh_user}@localhost" \
        "ls -la ${VIRTIOFS_GUEST_MOUNT}/ 2>&1 | head -5" 2>/dev/null); then
        if [[ -n "$guest_ls" ]]; then
            echo "OK (can list files)"
        else
            echo "FAIL (empty listing)"
            failures=$(( failures + 1 ))
        fi
    else
        echo "FAIL (cannot read)"
        failures=$(( failures + 1 ))
    fi

    # Check 3: Write test — create a file from guest, verify on host
    local test_file=".claude-vm-virtiofs-test-$$"
    local test_content="virtiofs-write-test-$(date +%s)"

    echo -n "  Checking write access (guest→host)... "
    if ssh "${ssh_opts[@]}" "${ssh_user}@localhost" \
        "echo '${test_content}' > ${VIRTIOFS_GUEST_MOUNT}/${test_file}" 2>/dev/null; then
        # Verify the file appeared on the host
        if [[ -f "${project_dir}/${test_file}" ]]; then
            local host_content
            host_content=$(cat "${project_dir}/${test_file}")
            if [[ "$host_content" == "$test_content" ]]; then
                echo "OK (data matches)"
            else
                echo "FAIL (content mismatch)"
                failures=$(( failures + 1 ))
            fi
            rm -f "${project_dir}/${test_file}"
        else
            echo "FAIL (file not visible on host)"
            failures=$(( failures + 1 ))
        fi
    else
        echo "FAIL (cannot write)"
        failures=$(( failures + 1 ))
    fi

    # Check 4: Write test — create a file on host, verify from guest
    local test_file_h2g=".claude-vm-virtiofs-h2g-test-$$"
    local test_content_h2g="virtiofs-h2g-test-$(date +%s)"

    echo -n "  Checking read access (host→guest)... "
    echo "$test_content_h2g" > "${project_dir}/${test_file_h2g}"

    local guest_read
    if guest_read=$(ssh "${ssh_opts[@]}" "${ssh_user}@localhost" \
        "cat ${VIRTIOFS_GUEST_MOUNT}/${test_file_h2g}" 2>/dev/null); then
        if [[ "$guest_read" == "$test_content_h2g" ]]; then
            echo "OK (data matches)"
        else
            echo "FAIL (content mismatch: expected '$test_content_h2g', got '$guest_read')"
            failures=$(( failures + 1 ))
        fi
    else
        echo "FAIL (cannot read from guest)"
        failures=$(( failures + 1 ))
    fi

    # Cleanup host test file
    rm -f "${project_dir}/${test_file_h2g}"
    # Cleanup guest test file (best effort)
    ssh "${ssh_opts[@]}" "${ssh_user}@localhost" \
        "rm -f ${VIRTIOFS_GUEST_MOUNT}/${test_file_h2g}" 2>/dev/null || true

    # Check 5: Permissions — verify file ownership is correct
    echo -n "  Checking file permissions... "
    local perm_test_file=".claude-vm-perm-test-$$"
    if ssh "${ssh_opts[@]}" "${ssh_user}@localhost" \
        "touch ${VIRTIOFS_GUEST_MOUNT}/${perm_test_file} && stat -c '%U' ${VIRTIOFS_GUEST_MOUNT}/${perm_test_file}" 2>/dev/null | grep -q .; then
        echo "OK"
        ssh "${ssh_opts[@]}" "${ssh_user}@localhost" \
            "rm -f ${VIRTIOFS_GUEST_MOUNT}/${perm_test_file}" 2>/dev/null || true
        rm -f "${project_dir}/${perm_test_file}"
    else
        echo "WARN (could not verify)"
    fi

    if (( failures > 0 )); then
        echo "  RESULT: $failures check(s) failed"
        return 1
    fi

    echo "  RESULT: All virtiofs checks passed"
    return 0
}

# Quick check if virtiofs is mounted (no read/write test)
# Args: $1 = SSH port, $2 = SSH key (optional), $3 = SSH user (optional)
virtiofs_is_mounted() {
    local ssh_port="$1"
    local ssh_key="${2:-}"
    local ssh_user="${3:-${VM_USER:-$USER}}"

    local ssh_opts=(
        -p "$ssh_port"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ConnectTimeout=3
        -o BatchMode=yes
    )
    if [[ -n "$ssh_key" ]]; then
        ssh_opts+=(-i "$ssh_key")
    fi

    ssh "${ssh_opts[@]}" "${ssh_user}@localhost" \
        "mount | grep -q 'type virtiofs'" 2>/dev/null
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
