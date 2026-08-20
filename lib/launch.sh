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

# Name Claude Code uses for the guest's ~/.claude/projects/<name> transcript
# dir. Every project mounts at /workspace, so without this every VM would
# write to ~/.claude/projects/-workspace. Claude Code (2.1.236) accepts the
# name only when it matches ^[A-Za-z0-9_-]{1,64}$ and is not a Windows
# reserved device name — anything else is silently ignored — so the basename
# is squeezed into exactly that shape here.
# Args: $1 = project directory
_guest_project_dir_name() {
    local project_dir="$1"
    local name
    name="$(basename "$(cd "$project_dir" 2>/dev/null && pwd || echo "$project_dir")")"
    name="${name//[^A-Za-z0-9_-]/}"
    name="${name:0:64}"
    case "${name,,}" in
        con|prn|aux|nul|com[0-9]|lpt[0-9]) name="" ;;
    esac
    [[ -n "$name" ]] || name="workspace"
    echo "$name"
}

# Remote-command prefix shared by connect_vm and connect_vm_shell. Exports
# come before ~/.env is sourced so a user's ~/.env can still override them.
# CLAUDE_CONFIG_DIR is set to its default location because Claude Code only
# honors CLAUDE_CODE_PROJECT_DIR_NAME when a config dir is explicitly set
# (verified against the 2.1.236 binary).
#
# The two guarded commands after ~/.env migrate VMs created before
# CLAUDE_CONFIG_DIR was exported, on their next connect: with a config dir
# set, Claude Code reads the global json from ~/.claude/.claude.json and
# transcripts from ~/.claude/projects/$CLAUDE_CODE_PROJECT_DIR_NAME, so
# without this an existing VM re-runs onboarding and hides its previous
# conversations. Runs after ~/.env so an overridden (or emptied) name is
# respected; both guards make it a one-time, idempotent no-op afterwards.
# The mv never merges — if both dirs exist, -workspace is left untouched.
# Args: $1 = project directory
_guest_env_prefix() {
    local project_dir="$1"
    local dir_name
    dir_name="$(_guest_project_dir_name "$project_dir")"
    echo "export PATH=\"\$HOME/.local/bin:\$PATH\"; export COLORTERM=truecolor; export CLAUDE_CONFIG_DIR=\"\$HOME/.claude\"; export CLAUDE_CODE_PROJECT_DIR_NAME=\"$dir_name\"; cd /workspace 2>/dev/null; [ -f ~/.env ] && . ~/.env; { [ -f \"\$HOME/.claude.json\" ] && [ ! -f \"\$HOME/.claude/.claude.json\" ] && mkdir -p \"\$HOME/.claude\" && cp \"\$HOME/.claude.json\" \"\$HOME/.claude/.claude.json\"; } 2>/dev/null; { [ -n \"\$CLAUDE_CODE_PROJECT_DIR_NAME\" ] && [ -d \"\$HOME/.claude/projects/-workspace\" ] && [ ! -e \"\$HOME/.claude/projects/\$CLAUDE_CODE_PROJECT_DIR_NAME\" ] && mv \"\$HOME/.claude/projects/-workspace\" \"\$HOME/.claude/projects/\$CLAUDE_CODE_PROJECT_DIR_NAME\"; } 2>/dev/null;"
}

# Connect to a running VM — launches Claude Code by default
# Args: $1 = SSH port, $2 = project directory, remaining args passed to claude
connect_vm() {
    local port="$1"
    local project_dir="$2"
    shift 2
    _build_ssh_cmd "$port"
    local claude_args="$CLAUDE_ARGS"
    if [[ $# -gt 0 ]]; then
        claude_args="$claude_args $*"
    fi
    exec "${_ssh_cmd[@]}" -t \
        "$(_guest_env_prefix "$project_dir") exec claude $claude_args"
}

# Connect to a running VM shell (no Claude Code). Same environment as
# connect_vm so `claude` started by hand lands in the same transcript dir.
# Args: $1 = SSH port, $2 = project directory
connect_vm_shell() {
    local port="$1"
    local project_dir="$2"
    _build_ssh_cmd "$port"
    exec "${_ssh_cmd[@]}" -t \
        "$(_guest_env_prefix "$project_dir") exec \"\${SHELL:-/bin/bash}\" -l"
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

# Build rsync command that runs as root on the guest and preserves
# permissions/ownership. Used for REBASE_BACKUP_PATHS entries (e.g. /etc,
# ~/.ssh) where root-only files and exact modes matter. --fake-super stashes
# root ownership in xattrs on the unprivileged host side and replays it as
# real attributes when pushed back.
# Sets: _rsync_sudo_cmd array (caller uses it)
_build_rsync_sudo_cmd() {
    local port="$1"
    local ssh_key="$CLAUDE_VM_DIR/keys/id_ed25519"
    local ssh_opts="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $port"
    if [[ -f "$ssh_key" ]]; then
        ssh_opts="ssh -i $ssh_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $port"
    fi
    _rsync_sudo_cmd=(rsync -az --fake-super --rsync-path="sudo rsync" -e "$ssh_opts")
}

# Sync host config into the guest VM
# Syncs: ~/.claude/, ~/.claude.json, ~/.gitconfig, ~/.config/gh/, ~/.config/glab-cli/
# Uses rsync for incremental transfer (only changed files after first launch)
sync_claude_config_to_vm() {
    local port="$1"

    _build_ssh_cmd "$port"
    local ssh_cmd=("${_ssh_cmd[@]}")
    _build_rsync_cmd "$port"

    # ── Claude Code config ────────────────────────────────────────────────
    # Include-list: settings, auth, and user-scope customizations (plugins,
    # skills, agents, commands, workflows, keybindings) — never runtime state
    if [[ -d "$HOME/.claude" ]]; then
        "${_rsync_cmd[@]}" \
            --include='settings.json' \
            --include='.credentials.json' \
            --include='credentials.json' \
            --include='plugins/***' \
            --include='skills/***' \
            --include='agents/***' \
            --include='commands/***' \
            --include='workflows/***' \
            --include='keybindings.json' \
            --include='mcp.json' \
            --include='CLAUDE.md' \
            --include='statusline-command.sh' \
            --exclude='*' \
            "$HOME/.claude/" "$VM_USER@localhost:~/.claude/" 2>/dev/null
    fi

    # Host ~/.claude.json (theme, onboarding state — skips welcome wizard)
    # → guest ~/.claude/.claude.json: connect_vm exports CLAUDE_CONFIG_DIR, and
    # with a config dir set Claude Code reads the global config json from
    # $CLAUDE_CONFIG_DIR/.claude.json instead of ~/.claude.json.
    # Also carries user-scoped MCP servers (top-level mcpServers). Local-scoped
    # MCP servers live under projects[<host-path>] and do NOT resolve in the guest
    # because the project mounts at /workspace — re-add those with `claude mcp add`
    # inside the VM, or define them user-scoped (-s user). See docs/architecture.md.
    "${ssh_cmd[@]}" "mkdir -p ~/.claude" 2>/dev/null
    if [[ -f "$HOME/.claude.json" ]]; then
        "${_rsync_cmd[@]}" "$HOME/.claude.json" "$VM_USER@localhost:~/.claude/.claude.json" 2>/dev/null
    else
        "${ssh_cmd[@]}" "echo '{\"hasCompletedOnboarding\":true}' > ~/.claude/.claude.json" 2>/dev/null
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

    # ── GitLab CLI auth ───────────────────────────────────────────────────
    # glab auth tokens — needed for MR/issue operations
    local glab_config="${XDG_CONFIG_HOME:-$HOME/.config}/glab-cli"
    if [[ -d "$glab_config" ]]; then
        "${ssh_cmd[@]}" "mkdir -p ~/.config/glab-cli" 2>/dev/null
        "${_rsync_cmd[@]}" "$glab_config/" "$VM_USER@localhost:~/.config/glab-cli/" 2>/dev/null
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

# Build the hostfwd argument string for QEMU netdev
# Starts with SSH forwarding, appends any user-configured FORWARD_PORTS
_build_hostfwd_args() {
    local ssh_port="$1"
    local forward_ports="${2:-}"
    local result="hostfwd=tcp::${ssh_port}-:22"

    [[ -z "$forward_ports" ]] && { echo "$result"; return 0; }

    local IFS=','
    local specs
    read -ra specs <<< "$forward_ports"

    local spec
    for spec in "${specs[@]}"; do
        spec="$(echo "$spec" | tr -d ' ')"
        [[ -z "$spec" ]] && continue

        if [[ "$spec" =~ ^([0-9]+)-([0-9]+):([0-9]+)-([0-9]+)$ ]]; then
            local hs="${BASH_REMATCH[1]}" he="${BASH_REMATCH[2]}" gs="${BASH_REMATCH[3]}"
            local i
            for (( i = 0; i <= he - hs; i++ )); do
                result+=",hostfwd=tcp::$(( hs + i ))-:$(( gs + i ))"
            done
        elif [[ "$spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local rs="${BASH_REMATCH[1]}" re="${BASH_REMATCH[2]}"
            local p
            for (( p = rs; p <= re; p++ )); do
                result+=",hostfwd=tcp::${p}-:${p}"
            done
        elif [[ "$spec" =~ ^([0-9]+):([0-9]+)$ ]]; then
            result+=",hostfwd=tcp::${BASH_REMATCH[1]}-:${BASH_REMATCH[2]}"
        elif [[ "$spec" =~ ^([0-9]+)$ ]]; then
            result+=",hostfwd=tcp::${BASH_REMATCH[1]}-:${BASH_REMATCH[1]}"
        fi
    done

    echo "$result"
}

# Detect QEMU acceleration method
_detect_accel() {
    if [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
        echo "kvm"
    else
        echo "tcg"
    fi
}

# Build QEMU argument array and store in _qemu_args
# Reads from caller's locals/globals: project_dir, snap_path, run_dir, accel,
#   ssh_port, VM_CPUS, VM_RAM
# Sets: _qemu_args array
_build_qemu_args() {
    local project_dir="$1"
    local snap_path="$2"
    local run_dir="$3"
    local accel="$4"
    local ssh_port="$5"

    local virtiofs_sock="$run_dir/virtiofs.sock"

    local project_forward_ports
    project_forward_ports="$(get_project_forward_ports "$project_dir")"
    local hostfwd_args
    hostfwd_args="$(_build_hostfwd_args "$ssh_port" "$project_forward_ports")"

    _qemu_args=(
        -name "claude-vm-$(project_hash "$project_dir")"
        -machine "type=q35,accel=$accel"
        -cpu host
        -smp "$VM_CPUS"
        -m "$VM_RAM"
        -object "memory-backend-memfd,id=mem,size=$VM_RAM,share=on"
        -numa "node,memdev=mem"
        -drive "file=$snap_path,format=qcow2,if=virtio,cache=writeback,discard=unmap,detect-zeroes=unmap"
        -netdev "user,id=net0,${hostfwd_args}"
        -device "virtio-net-pci,netdev=net0"
        -chardev "socket,id=vhost-fs,path=$virtiofs_sock"
        -device "vhost-user-fs-pci,chardev=vhost-fs,tag=workspace,queue-size=1024"
        -display none
        -serial "file:$run_dir/serial.log"
        -monitor "unix:$run_dir/monitor.sock,server,nowait"
        -pidfile "$run_dir/qemu.pid"
        -daemonize
    )
}

# Launch a VM for the current project
# This is the main entry point for `claude-vm` (no subcommand)
launch_vm() {
    local project_dir="${1:-$PWD}"
    shift 2>/dev/null || true
    local claude_extra_args=("$@")

    load_config
    ensure_dirs

    local snap_path base_img run_dir
    snap_path="$(project_snapshot_path "$project_dir")"
    base_img="$(base_image_path)"
    run_dir="$(project_run_dir "$project_dir")"
    local is_new_vm=false
    [[ ! -f "$snap_path" ]] && is_new_vm=true

    # Check if VM is already running — attach another Claude Code instance
    if is_vm_running "$project_dir"; then
        local ssh_port
        ssh_port="$(get_project_ssh_port "$project_dir")"
        ui_info "Attaching to running VM..."
        connect_vm "$ssh_port" "$project_dir" "${claude_extra_args[@]}"
    fi

    # Acquire shared lock — prevents concurrent rebase from clobbering the base
    local _launch_lock_fd
    local rebase_lock="$CLAUDE_VM_DIR/rebase.lock"
    exec {_launch_lock_fd}>"$rebase_lock"
    if ! flock -n -s "$_launch_lock_fd" 2>/dev/null; then
        ui_warn "Rebase in progress — cannot launch VM until it completes"
        exec {_launch_lock_fd}>&- 2>/dev/null || true
        _launch_lock_fd=""
        return 1
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
            echo "  Base image ($FLAVOR) will be built first (2-3 minutes, plus the image download on the first ever run)."
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

    # Build base image only when a new snapshot needs it — existing snapshots
    # carry their own backing reference, which may be a different flavor's base
    if [[ ! -f "$snap_path" && ! -f "$base_img" ]]; then
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
    local accel
    accel="$(_detect_accel)"
    if [[ "$accel" != "kvm" ]]; then
        ui_warn "KVM not accessible — falling back to TCG (slower)"
    fi

    # Start virtiofsd
    ui_phase "Setting up filesystem sharing" start_virtiofsd "$project_dir" "$run_dir/virtiofs.sock" "$run_dir"

    # Build and launch QEMU
    _build_qemu_args "$project_dir" "$snap_path" "$run_dir" "$accel" "$ssh_port"
    ui_phase "Starting VM" qemu-system-x86_64 "${_qemu_args[@]}"

    # Wait for SSH
    local ssh_key
    ssh_key="$(_ssh_key_path)"
    if ! ui_phase "Waiting for VM to boot" wait_for_ssh "$ssh_port" 60 "$ssh_key"; then
        _dump_boot_diagnostics "$run_dir" "$snap_path"
        return 1
    fi

    # Verify virtiofs mount
    ui_phase "Mounting workspace" virtiofs_ensure_mounted "$ssh_port" "$ssh_key" "$VM_USER"

    # Sync Claude Code config — only on first VM creation
    if [[ "$is_new_vm" == true ]]; then
        ui_phase "Syncing config" sync_claude_config_to_vm "$ssh_port"
    fi

    # Restore VM state saved by `claude-vm rebase` (overlays host-sync so
    # refreshed VM-side credentials win)
    if declare -f _has_pending_restore &>/dev/null && _has_pending_restore "$project_dir"; then
        ui_phase "Restoring VM state from rebase" _restore_one_vm "$project_dir" "$ssh_port"
    fi

    # Drop into Claude Code
    connect_vm "$ssh_port" "$project_dir" "${claude_extra_args[@]}"
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

    _check_virtiofsd_idmap "$virtiofsd_bin" || return 1

    # Start virtiofsd in background
    "$virtiofsd_bin" \
        --socket-path="$sock_path" \
        --shared-dir="$project_dir" \
        --cache=auto \
        --announce-submounts \
        &>"$run_dir/virtiofsd.log" &

    local vfs_pid=$!
    echo "$vfs_pid" > "$run_dir/virtiofsd.pid"

    # Wait for the socket, but watch the process while doing it. virtiofsd
    # binds the socket before it finishes sandbox setup, so the socket file
    # existing is not proof of a live listener — a daemon that dies during
    # setup leaves the file behind and QEMU reports it, several steps later,
    # as "Failed to connect ...: Connection refused".
    local waited=0
    while (( waited < 50 )); do
        if ! _pid_alive "$vfs_pid"; then
            _virtiofsd_failed "$run_dir" "virtiofsd exited during startup"
            return 1
        fi
        if [[ -S "$sock_path" ]]; then
            break
        fi
        sleep 0.1
        (( waited++ )) || true
    done

    if [[ ! -S "$sock_path" ]]; then
        kill "$vfs_pid" 2>/dev/null || true
        _virtiofsd_failed "$run_dir" "virtiofsd did not create its socket within 5s"
        return 1
    fi

    # Socket is there — confirm the daemon survived binding it. Anything that
    # kills virtiofsd after the bind (namespace setup, permissions on the
    # shared dir) lands here instead of surfacing as a QEMU chardev error.
    if ! _pid_alive "$vfs_pid"; then
        _virtiofsd_failed "$run_dir" "virtiofsd exited after creating its socket"
        return 1
    fi
}

# True while $1 is a running process. Read the state from /proc rather than
# using `kill -0`: virtiofsd is our own background child, so between its exit
# and the shell reaping it there is a window where it is a zombie that still
# answers signals.
_pid_alive() {
    local pid="$1" rest state
    [[ -r "/proc/$pid/stat" ]] || return 1
    read -r _ rest < "/proc/$pid/stat" || return 1
    state="${rest##*) }"      # strip through the comm field, which may hold spaces
    state="${state%% *}"
    [[ "$state" != "Z" && "$state" != "X" ]]
}

# Rust virtiofsd runs with --sandbox=namespace by default and shells out to
# newuidmap/newgidmap to build its unprivileged user namespace. On Debian and
# Ubuntu those live in the separate `uidmap` package, which is not installed
# by default; without them virtiofsd dies at startup.
# Args: $1 = virtiofsd binary path
_check_virtiofsd_idmap() {
    local virtiofsd_bin="$1"
    local missing=()
    local cmd

    # Root doesn't need the setuid helpers, and the legacy C daemon shipped as
    # qemu's virtiofsd doesn't use them at all.
    if (( EUID == 0 )) || [[ "$virtiofsd_bin" == */qemu/virtiofsd ]]; then
        return 0
    fi

    for cmd in newuidmap newgidmap; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} == 0 )); then
        return 0
    fi

    echo "ERROR: virtiofsd needs ${missing[*]} to set up its user namespace." >&2
    echo "  Ubuntu/Debian: sudo apt install uidmap" >&2
    echo "  Fedora:        sudo dnf install shadow-utils" >&2
    echo "  Arch/CachyOS:  provided by the base 'shadow' package" >&2
    return 1
}

# Report a virtiofsd startup failure. The cause is only ever in virtiofsd's own
# log, so dump its tail — before the summary line, because ui_phase surfaces
# only the last few lines of the launch log and the fix should be what's left.
# Args: $1 = run_dir, $2 = message
_virtiofsd_failed() {
    local run_dir="$1" msg="$2"
    local log="$run_dir/virtiofsd.log"

    if [[ -s "$log" ]]; then
        echo "  virtiofsd log ($log):"
        tail -10 "$log" | sed 's/^/  | /'
    fi

    echo "ERROR: $msg — see $log" >&2
}

# Diagnostics dump used when `wait_for_ssh` times out. Surfaces what the guest
# is actually doing — without this, the failure is just "ssh didn't connect"
# with no visibility into whether the kernel booted, sshd started, etc.
# Args: $1 = run_dir, $2 = snap_path
_dump_boot_diagnostics() {
    local run_dir="$1"
    local snap_path="$2"
    local serial_log="$run_dir/serial.log"
    local pid_file="$run_dir/qemu.pid"

    {
        printf '\n──────── boot diagnostics ────────\n'
        printf 'run_dir:    %s\n' "$run_dir"

        if [[ -f "$pid_file" ]]; then
            local qpid
            qpid=$(cat "$pid_file" 2>/dev/null || echo "?")
            if kill -0 "$qpid" 2>/dev/null; then
                printf 'qemu pid:   %s (alive)\n' "$qpid"
            else
                printf 'qemu pid:   %s (DEAD — guest crashed or exited)\n' "$qpid"
            fi
        else
            printf 'qemu pid:   (no pidfile — qemu never started?)\n'
        fi

        if [[ -f "$snap_path" ]]; then
            printf 'snapshot:   %s (%s)\n' "$snap_path" "$(du -h "$snap_path" 2>/dev/null | cut -f1)"
            local backing
            backing="$(qemu-img info --output=json "$snap_path" 2>/dev/null | \
                jq -r '.["backing-filename"] // empty' 2>/dev/null || true)"
            if [[ -n "$backing" ]]; then
                printf 'backing:    %s\n' "$backing"
                qemu-img check "$backing" 2>&1 | head -1 | sed 's/^/base check: /'
            else
                printf 'backing:    (none — not a linked snapshot?)\n'
            fi
        fi

        printf '\n──── guest serial log (tail 80) ────\n'
        if [[ -f "$serial_log" ]]; then
            tail -80 "$serial_log" 2>/dev/null || echo "(could not read $serial_log)"
        else
            printf '(no serial log at %s)\n' "$serial_log"
        fi

        # If the base was just rebuilt, surface the build logs too — boot
        # failures often trace back to a provisioning step that misfired.
        local build_qemu="$CLAUDE_VM_DIR/run/build-qemu.log"
        if [[ -s "$build_qemu" ]]; then
            printf '\n──── last base build qemu stderr (tail 30) ────\n'
            tail -30 "$build_qemu" 2>/dev/null
        fi

        local build_log="$CLAUDE_VM_DIR/run/build-serial.log"
        if [[ -s "$build_log" ]]; then
            printf '\n──── last base build guest serial (tail 50) ────\n'
            tail -50 "$build_log" 2>/dev/null
        fi

        printf '──────── end diagnostics ────────\n'
    } >&2
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
