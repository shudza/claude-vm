#!/usr/bin/env bash
# VM launch logic for claude-vm
# Handles: start VM from snapshot, setup virtiofs, SSH readiness

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/virtiofs.sh"
source "$SCRIPT_DIR/shutdown.sh"
source "$SCRIPT_DIR/ui.sh"

# Build SSH command array for connecting to VM
# Args: $1 = SSH port
# Sets: _ssh_cmd array (caller uses it)
_build_ssh_cmd() {
    local port="$1"
    local ssh_key="$CLAUDE_VM_DIR/keys/id_ed25519"
    _ssh_cmd=(ssh)
    if [[ -f "$ssh_key" ]]; then
        _ssh_cmd+=(-i "$ssh_key")
    fi
    _ssh_cmd+=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -p "$port"
        "$VM_USER@localhost"
    )
}

# Connect to a running VM — launches Claude Code by default
# Args: $1 = SSH port, $2 = command (optional, default: claude code)
connect_vm() {
    local port="$1"
    shift
    _build_ssh_cmd "$port"
    if [[ $# -gt 0 ]]; then
        exec "${_ssh_cmd[@]}" "$@"
    else
        # Launch Claude Code with full sandbox permissions
        exec "${_ssh_cmd[@]}" -t \
            "export PATH=\"\$HOME/.local/bin:\$PATH\"; cd /workspace 2>/dev/null; [ -f ~/.env ] && . ~/.env; exec claude --dangerously-skip-permissions"
    fi
}

# Connect to a running VM shell (no Claude Code)
# Args: $1 = SSH port
connect_vm_shell() {
    local port="$1"
    _build_ssh_cmd "$port"
    exec "${_ssh_cmd[@]}"
}

# Build rsync command that tunnels over the VM's SSH connection
# Sets: _rsync_cmd array (caller uses it)
_build_rsync_cmd() {
    local port="$1"
    local ssh_key="$CLAUDE_VM_DIR/keys/id_ed25519"
    local ssh_opts="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $port"
    if [[ -f "$ssh_key" ]]; then
        ssh_opts="ssh -i $ssh_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $port"
    fi
    _rsync_cmd=(rsync -az --no-perms --no-owner --no-group -e "$ssh_opts")
}

# Sync host config into the guest VM
# Syncs: ~/.claude/, ~/.claude.json, ~/.gitconfig, ~/.config/gh/
# Uses rsync for incremental transfer (only changed files after first launch)
sync_claude_config_to_vm() {
    local port="$1"

    _build_ssh_cmd "$port"
    local ssh_cmd=("${_ssh_cmd[@]}")
    _build_rsync_cmd "$port"

    # ── Claude Code config ────────────────────────────────────────────────
    # Include-list: only sync skills, plugins, auth, and settings
    if [[ -d "$HOME/.claude" ]]; then
        "${_rsync_cmd[@]}" \
            --include='settings.json' \
            --include='.credentials.json' \
            --include='credentials.json' \
            --include='plugins/***' \
            --include='skills/***' \
            --include='mcp.json' \
            --include='CLAUDE.md' \
            --exclude='*' \
            "$HOME/.claude/" "$VM_USER@localhost:~/.claude/" 2>/dev/null
    fi

    # ~/.claude.json (theme, onboarding state — skips welcome wizard)
    if [[ -f "$HOME/.claude.json" ]]; then
        "${_rsync_cmd[@]}" "$HOME/.claude.json" "$VM_USER@localhost:~/.claude.json" 2>/dev/null
    else
        "${ssh_cmd[@]}" "echo '{\"hasCompletedOnboarding\":true}' > ~/.claude.json" 2>/dev/null
    fi

    # ── Git config ────────────────────────────────────────────────────────
    # user.name/email are required for commits; aliases and tool prefs carry over
    if [[ -f "$HOME/.gitconfig" ]]; then
        "${_rsync_cmd[@]}" "$HOME/.gitconfig" "$VM_USER@localhost:~/.gitconfig" 2>/dev/null
    fi
    if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" ]]; then
        "${ssh_cmd[@]}" "mkdir -p ~/.config/git" 2>/dev/null
        "${_rsync_cmd[@]}" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" "$VM_USER@localhost:~/.config/git/config" 2>/dev/null
    fi

    # ── GitHub CLI auth ───────────────────────────────────────────────────
    # gh auth tokens — needed for PR/issue operations
    local gh_config="${XDG_CONFIG_HOME:-$HOME/.config}/gh"
    if [[ -d "$gh_config" ]]; then
        "${ssh_cmd[@]}" "mkdir -p ~/.config/gh" 2>/dev/null
        "${_rsync_cmd[@]}" "$gh_config/" "$VM_USER@localhost:~/.config/gh/" 2>/dev/null
    fi
}

# SSH key path for this install
_ssh_key_path() {
    echo "$CLAUDE_VM_DIR/keys/id_ed25519"
}

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

    # Check if VM is already running — attach another Claude Code instance
    if is_vm_running "$project_dir"; then
        local ssh_port
        ssh_port="$(get_project_ssh_port "$project_dir")"
        ui_info "Attaching to running VM..."
        connect_vm "$ssh_port"
    fi

    # First launch in this directory — explain and confirm
    if [[ ! -f "$snap_path" ]]; then
        echo ""
        echo "  claude-vm will create an isolated QEMU sandbox for this project."
        echo "  Your project directory is mounted into the VM via virtiofs —"
        echo "  files are shared, not copied."
        echo ""
        echo "  Project: $project_dir"
        if [[ ! -f "$base_img" ]]; then
            echo "  Base image will be built first (~90s on first ever run)."
        fi
        echo ""
        read -rp "  Continue? [Y/n] " confirm
        if [[ "$confirm" == [nN] ]]; then
            echo "  Cancelled."
            return 0
        fi
        echo ""
    fi

    # Initialize UI logging
    mkdir -p "$run_dir"
    ui_init "$run_dir/launch.log"

    # Build base image if needed
    if [[ ! -f "$base_img" ]]; then
        source "$SCRIPT_DIR/build.sh"
        ui_phase "Building base image" build_base_image
    fi

    # Create project snapshot if needed
    if [[ ! -f "$snap_path" ]]; then
        source "$SCRIPT_DIR/build.sh"
        ui_phase "Creating project snapshot" create_project_snapshot "$project_dir"
    fi

    # Find available SSH port
    local ssh_port
    ssh_port="$(find_available_port "$SSH_PORT_BASE")"
    echo "$ssh_port" > "$run_dir/ssh_port"

    # Determine acceleration
    local accel="kvm"
    if [[ ! -r /dev/kvm ]] || [[ ! -w /dev/kvm ]]; then
        ui_warn "KVM not accessible — falling back to TCG (slower)"
        accel="tcg"
    fi

    # Setup virtiofs socket path
    local virtiofs_sock="$run_dir/virtiofs.sock"

    # Start virtiofsd
    ui_phase "Setting up filesystem sharing" start_virtiofsd "$project_dir" "$virtiofs_sock" "$run_dir"

    # Build and launch QEMU
    _launch_qemu() {
        local qemu_args=(
            -name "claude-vm-$(project_hash "$project_dir")"
            -machine "type=q35,accel=$accel"
            -cpu host
            -smp "$VM_CPUS"
            -m "$VM_RAM"
            -object "memory-backend-memfd,id=mem,size=$VM_RAM,share=on"
            -numa "node,memdev=mem"
            -drive "file=$snap_path,format=qcow2,if=virtio,cache=writeback,discard=unmap,detect-zeroes=unmap"
            -netdev "user,id=net0,hostfwd=tcp::${ssh_port}-:22"
            -device "virtio-net-pci,netdev=net0"
            -chardev "socket,id=vhost-fs,path=$virtiofs_sock"
            -device "vhost-user-fs-pci,chardev=vhost-fs,tag=workspace,queue-size=1024"
            -display none
            -serial "file:$run_dir/serial.log"
            -monitor "unix:$run_dir/monitor.sock,server,nowait"
            -pidfile "$run_dir/qemu.pid"
            -daemonize
        )
        qemu-system-x86_64 "${qemu_args[@]}"
    }
    ui_phase "Starting VM" _launch_qemu

    # Wait for SSH
    local ssh_key
    ssh_key="$(_ssh_key_path)"
    ui_phase "Waiting for VM to boot" wait_for_ssh "$ssh_port" 60 "$ssh_key"

    # Verify virtiofs mount
    ui_phase "Mounting workspace" virtiofs_ensure_mounted "$ssh_port" "$ssh_key" "$VM_USER"

    # Sync Claude Code config
    ui_phase "Syncing config" sync_claude_config_to_vm "$ssh_port"

    local elapsed=$(( $(date +%s) - start_time ))
    ui_done "Ready in ${elapsed}s — $(basename "$project_dir")"

    # Drop into Claude Code
    connect_vm "$ssh_port"
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
    local ssh_key="${3:-}"
    local waited=0

    local key_opt=()
    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        key_opt=(-i "$ssh_key")
    fi

    while (( waited < timeout )); do
        if ssh "${key_opt[@]}" -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o BatchMode=yes \
               -p "$port" "$VM_USER@localhost" true 2>/dev/null; then
            echo "  SSH ready!"
            return 0
        fi
        sleep 1
        (( ++waited ))
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
