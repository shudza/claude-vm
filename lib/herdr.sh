#!/usr/bin/env bash
# herdr.sh — SSH host aliases for VMs and herdr (https://herdr.dev) integration
#
# Every VM gets a stable name and is reachable as `ssh claude-vm-<name>`
# through one static block in ~/.claude-vm/ssh_config:
#
#   Host claude-vm-*
#     ProxyCommand claude-vm proxy %n    → resolves name → current SSH port
#     HostKeyAlias claude-vm             → one pinned host key for all VMs
#
# `claude-vm setup-herdr` includes that file from ~/.ssh/config (after
# asking) — herdr only resolves hosts through the user's OpenSSH config, and
# its saved machines store nothing but the target string. Once set up, VMs
# register as herdr machines on start, are disabled on stop and removed on
# reset/destroy. herdr failures never fail a claude-vm command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/cloud-init.sh"
source "$SCRIPT_DIR/ui.sh"

VM_ALIAS_PREFIX="claude-vm-"
VM_NAME_MAX=16
HERDR_INCLUDE_MARKER="# Added by claude-vm setup-herdr (remove with: claude-vm setup-herdr --remove)"

# ── VM names ─────────────────────────────────────────────────────────────────

# Squeeze a project dir's basename into a short host-alias-safe name:
# lowercase [a-z0-9-], dash runs collapsed, at most VM_NAME_MAX chars.
# Args: $1 = project directory
_sanitize_vm_name() {
    local name
    name="$(basename "$1")"
    name="${name,,}"
    name="${name//[^a-z0-9-]/-}"
    while [[ "$name" == *--* ]]; do
        name="${name//--/-}"
    done
    name="${name#-}"
    name="${name:0:VM_NAME_MAX}"
    name="${name%-}"
    [[ -n "$name" ]] || name="vm"
    echo "$name"
}

# Hash of the project owning a VM name, if any
# Args: $1 = name (without prefix)
vm_hash_for_name() {
    local name="$1" f
    for f in "$SNAPSHOTS_DIR"/*.name; do
        [[ -f "$f" ]] || continue
        if [[ "$(cat "$f")" == "$name" ]]; then
            basename "$f" .name
            return 0
        fi
    done
    return 1
}

# A project's VM name, assigned on first use and kept in the <hash>.name
# sidecar so it never changes. A name another project already holds gets a
# -2, -3, … suffix (still within VM_NAME_MAX).
# Args: $1 = project directory
project_vm_name() {
    local project_dir="$1"
    local hash name_file base candidate owner suffix n=2
    hash="$(project_hash "$project_dir")"
    name_file="$SNAPSHOTS_DIR/${hash}.name"
    if [[ -s "$name_file" ]]; then
        cat "$name_file"
        return 0
    fi

    base="$(_sanitize_vm_name "$project_dir")"
    candidate="$base"
    while owner="$(vm_hash_for_name "$candidate")" && [[ "$owner" != "$hash" ]]; do
        suffix="-$n"
        candidate="${base:0:VM_NAME_MAX-${#suffix}}"
        candidate="${candidate%-}$suffix"
        (( ++n ))
    done
    mkdir -p "$SNAPSHOTS_DIR"
    echo "$candidate" > "$name_file"
    echo "$candidate"
}

# Args: $1 = project directory
project_vm_alias() {
    echo "${VM_ALIAS_PREFIX}$(project_vm_name "$1")"
}

# ── SSH config ───────────────────────────────────────────────────────────────

# Write ~/.claude-vm/ssh_config. Static apart from VM_USER and the paths, so
# it is rewritten (not edited) whenever setup or a VM start touches it.
write_vm_ssh_config() {
    local config key known proxy
    config="$(vm_ssh_config_path)"
    key="$CLAUDE_VM_DIR/keys/id_ed25519"
    known="$(vm_known_hosts_path)"
    # ssh runs ProxyCommand through /bin/sh; CLAUDE_VM_DIR is carried along
    # because herdr's background server may not share this environment
    printf -v proxy 'env CLAUDE_VM_DIR=%q %q proxy %%n' "$CLAUDE_VM_DIR" "${CLAUDE_VM_BIN:-claude-vm}"

    mkdir -p "$(dirname "$config")"
    cat > "$config" << EOF
# Managed by claude-vm — rewritten by 'claude-vm setup-herdr' and VM starts.
# Reach a running VM with: ssh ${VM_ALIAS_PREFIX}<name>   (names: claude-vm list)
Host ${VM_ALIAS_PREFIX}*
  User $VM_USER
  IdentityFile "$key"
  IdentitiesOnly yes
  HostKeyAlias $VM_HOST_KEY_ALIAS
  UserKnownHostsFile "$known"
  StrictHostKeyChecking yes
  ProxyCommand $proxy
EOF
}

# Connect stdin/stdout to a running VM's sshd (ssh ProxyCommand target)
# Args: $1 = host alias (claude-vm-<name>) or bare name
vm_proxy() {
    local name="${1#"$VM_ALIAS_PREFIX"}"
    local hash run_dir port pid project=""

    if ! hash="$(vm_hash_for_name "$name")"; then
        echo "claude-vm: no VM named '$name' (see 'claude-vm list')" >&2
        return 1
    fi
    [[ -f "$SNAPSHOTS_DIR/${hash}.project" ]] && project="$(cat "$SNAPSHOTS_DIR/${hash}.project")"

    run_dir="$RUN_DIR/$hash"
    pid="$(cat "$run_dir/qemu.pid" 2>/dev/null || true)"
    port="$(cat "$run_dir/ssh_port" 2>/dev/null || true)"
    if [[ -z "$pid" || -z "$port" ]] || ! kill -0 "$pid" 2>/dev/null; then
        echo "claude-vm: VM '$name' is not running — start it with: claude-vm start ${project:-<project-dir>}" >&2
        return 1
    fi

    if command -v socat &>/dev/null; then
        exec socat - "TCP:127.0.0.1:$port"
    fi
    # bash fallback: no half-close, but ssh never needs one — it tears the
    # proxy down when the session ends
    exec 3<>"/dev/tcp/127.0.0.1/$port"
    cat <&3 &
    cat >&3
}

# Strict check that a VM presents the pinned host key. Bases built before
# host keys were pinned fail it until _pin_vm_host_key runs. The inner quotes
# matter: UserKnownHostsFile takes a space-separated list of files.
# Args: $1 = SSH port
vm_host_key_pinned() {
    local port="$1"
    ssh -i "$CLAUDE_VM_DIR/keys/id_ed25519" \
        -o IdentitiesOnly=yes \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=yes \
        -o HostKeyAlias="$VM_HOST_KEY_ALIAS" \
        -o "UserKnownHostsFile=\"$(vm_known_hosts_path)\"" \
        -o LogLevel=ERROR \
        -p "$port" "$VM_USER@localhost" true </dev/null &>/dev/null
}

# Give a running VM whose base predates pinning the pinned host key.
# claude-vm's own ssh skips host-key checks, so it can still log in; the
# snapshot keeps the change, so this happens once per VM. The key file is
# overwritten in place to keep its owner, mode and SELinux label (Fedora
# labels host keys sshd_key_t). sshd re-reads host keys on reload; a
# socket-activated sshd (Ubuntu) reads them per connection anyway.
# Args: $1 = SSH port
_pin_vm_host_key() {
    local port="$1" key
    key="$(vm_host_key_path)"
    _build_ssh_cmd "$port"
    "${_ssh_cmd[@]}" "sudo sh -s" << SCRIPT
set -e
k=/etc/ssh/ssh_host_ed25519_key
t=\$(mktemp)
trap 'rm -f "\$t"' EXIT
cat > "\$t" << 'KEY'
$(cat "$key")
KEY
[ "\$(ssh-keygen -y -f "\$t" | cut -d' ' -f1-2)" = "$(cut -d' ' -f1-2 "${key}.pub")" ]
[ -e "\$k" ] || install -m 600 /dev/null "\$k"
cat "\$t" > "\$k"
printf '%s\n' '$(cat "${key}.pub")' > "\$k.pub"
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
SCRIPT
}

# Older bases also lack the ~/.bashrc line sourcing ~/.claude-vm-env, and
# VMs created before it existed lack the file. Add whichever is missing so
# herdr panes use the project's transcript dir. Both steps are guarded.
# Args: $1 = SSH port, $2 = project directory
_upgrade_guest_env() {
    local port="$1" project_dir="$2"
    _build_ssh_cmd "$port"
    # The line holds no single quotes, so '...' carries it verbatim
    "${_ssh_cmd[@]}" "sh -s" << SCRIPT
grep -qxF '$GUEST_ENV_SOURCE_LINE' ~/.bashrc 2>/dev/null || printf '%s\n' '$GUEST_ENV_SOURCE_LINE' >> ~/.bashrc
[ -f ~/.claude-vm-env ] || cat > ~/.claude-vm-env << 'ENV'
$(_guest_env_file "$project_dir")
ENV
SCRIPT
}

# Make sure a VM presents the pinned host key. Older VMs get it installed,
# together with the guest env upgrade — the same VMs need both, once.
# Args: $1 = SSH port, $2 = project directory
ensure_vm_host_key_pinned() {
    local port="$1" project_dir="$2" tries
    vm_host_key_pinned "$port" && return 0
    _upgrade_guest_env "$port" "$project_dir" >>"${_UI_LOG:-/dev/null}" 2>&1 || true
    _pin_vm_host_key "$port" >>"${_UI_LOG:-/dev/null}" 2>&1 || return 1
    # sshd's reload re-execs it; give the new listener a moment
    for tries in 1 2 3 4 5; do
        vm_host_key_pinned "$port" && return 0
        sleep 1
    done
    return 1
}

# True when the user's OpenSSH config resolves an alias through our proxy
# (however the include was added). Reads $HOME/.ssh/config explicitly, like
# herdr's managed config does — plain ssh would use the passwd home instead.
# Args: $1 = alias
_ssh_resolves_alias() {
    local cfg
    cfg="$(_user_ssh_config_path)"
    [[ -f "$cfg" ]] || return 1
    ssh -F "$cfg" -G "$1" 2>/dev/null | grep -qi '^proxycommand .* proxy '
}

# ── ~/.ssh/config include ────────────────────────────────────────────────────

_user_ssh_config_path() {
    echo "$HOME/.ssh/config"
}

_herdr_include_line() {
    printf 'Include "%s"' "$(vm_ssh_config_path)"
}

_user_ssh_config_has_include() {
    local cfg
    cfg="$(_user_ssh_config_path)"
    [[ -f "$cfg" ]] && grep -qxF "$(_herdr_include_line)" "$cfg"
}

# Prepend the include: an Include after a Host/Match block would only apply
# inside it, and first-match-wins means our block must come first. Written
# through `cat >` so a symlinked config (dotfile managers) stays a symlink.
_add_user_ssh_include() {
    local cfg tmp
    cfg="$(_user_ssh_config_path)"
    mkdir -p "$(dirname "$cfg")"
    chmod 700 "$(dirname "$cfg")"
    tmp="$(mktemp)"
    {
        echo "$HERDR_INCLUDE_MARKER"
        _herdr_include_line
        echo
        echo
        [[ -f "$cfg" ]] && cat "$cfg"
    } > "$tmp"
    if [[ -f "$cfg" ]]; then
        cp -p "$cfg" "${cfg}.claude-vm.bak"
        cat "$tmp" > "$cfg"
    else
        install -m 600 "$tmp" "$cfg"
    fi
    rm -f "$tmp"
}

# Drop the marker + include lines (and the blank line we added after them)
_remove_user_ssh_include() {
    local cfg tmp
    cfg="$(_user_ssh_config_path)"
    [[ -f "$cfg" ]] || return 0
    _user_ssh_config_has_include || grep -qxF "$HERDR_INCLUDE_MARKER" "$cfg" || return 0
    tmp="$(mktemp)"
    awk -v marker="$HERDR_INCLUDE_MARKER" -v inc="$(_herdr_include_line)" '
        $0 == marker { next }
        $0 == inc    { skip_blank = 1; next }
        skip_blank && $0 == "" { skip_blank = 0; next }
        { skip_blank = 0; print }
    ' "$cfg" > "$tmp"
    cp -p "$cfg" "${cfg}.claude-vm.bak"
    cat "$tmp" > "$cfg"
    rm -f "$tmp"
}

# ── herdr machines ───────────────────────────────────────────────────────────

# herdr hooks run only after setup-herdr and with herdr on the host
herdr_enabled() {
    [[ -f "$(vm_ssh_config_path)" ]] && command -v herdr &>/dev/null
}

# Saved-machine row for a target as "<id> <enabled|disabled>"
# (herdr machine list: id, label, target, session, state — tab-separated)
# Args: $1 = SSH target
_herdr_machine() {
    herdr machine list 2>/dev/null | awk -F'\t' -v t="$1" '$3 == t { print $1, $5; exit }'
}

# Start hook: give the VM its alias name, refresh the ssh config, then
# register or re-enable it in herdr. Only after setup-herdr; never fails.
# Args: $1 = project directory, $2 = SSH port
herdr_vm_started() {
    local project_dir="$1" port="$2"
    [[ -f "$(vm_ssh_config_path)" ]] || return 0

    local alias row id state
    alias="$(project_vm_alias "$project_dir")"
    write_vm_ssh_config
    command -v herdr &>/dev/null || return 0

    if ! _ssh_resolves_alias "$alias"; then
        ui_warn "herdr: ~/.ssh/config does not include $(vm_ssh_config_path) — run 'claude-vm setup-herdr'"
        return 0
    fi
    if ! ensure_vm_host_key_pinned "$port" "$project_dir"; then
        ui_warn "herdr: could not install the pinned host key in this VM — run 'claude-vm rebase' to use it with herdr"
        return 0
    fi

    row="$(_herdr_machine "$alias")"
    if [[ -z "$row" ]]; then
        # stdin from /dev/null: never prompt mid-launch (setup can't install
        # herdr in the guest then — that is what the cloud-init overlay is for)
        if herdr machine add "$alias" </dev/null >>"${_UI_LOG:-/dev/null}" 2>&1; then
            ui_info "herdr: registered $alias"
        else
            ui_warn "herdr: could not register $alias — is herdr installed in the guest? Run 'herdr machine add $alias' to install it interactively, or see 'Herdr' in docs/usage.md"
        fi
        return 0
    fi

    read -r id state <<< "$row"
    if [[ "$state" != enabled ]]; then
        herdr machine enable "$id" >>"${_UI_LOG:-/dev/null}" 2>&1 \
            || ui_warn "herdr: could not enable $alias"
    fi
    return 0
}

# Disable a stopped VM's machine so herdr doesn't retry it. Never fails.
# Args: $1 = project hash
herdr_vm_stopped() {
    local hash="$1" name row id state
    herdr_enabled || return 0
    name="$(cat "$SNAPSHOTS_DIR/${hash}.name" 2>/dev/null)" || return 0
    row="$(_herdr_machine "${VM_ALIAS_PREFIX}$name")"
    [[ -n "$row" ]] || return 0
    read -r id state <<< "$row"
    if [[ "$state" == enabled ]]; then
        herdr machine disable "$id" &>/dev/null || true
    fi
    return 0
}

# Forget a VM: remove its herdr machine and release its name (reset/destroy)
# Args: $1 = project hash
herdr_vm_removed() {
    local hash="$1" name row id
    local name_file="$SNAPSHOTS_DIR/${hash}.name"
    name="$(cat "$name_file" 2>/dev/null)" || return 0
    if command -v herdr &>/dev/null; then
        row="$(_herdr_machine "${VM_ALIAS_PREFIX}$name")"
        if [[ -n "$row" ]]; then
            herdr machine remove "${row%% *}" &>/dev/null || true
        fi
    fi
    rm -f "$name_file"
    return 0
}

# Remove every claude-vm-* herdr machine (setup-herdr --remove, destroy --all)
herdr_remove_all_machines() {
    command -v herdr &>/dev/null || return 0
    local id
    while read -r id; do
        [[ -n "$id" ]] && { herdr machine remove "$id" &>/dev/null || true; }
    done < <(herdr machine list 2>/dev/null \
        | awk -F'\t' -v p="$VM_ALIAS_PREFIX" 'index($3, p) == 1 { print $1 }')
    return 0
}

# Hashes of running VMs (live qemu pid)
_running_vm_hashes() {
    local d pid
    for d in "$RUN_DIR"/*/; do
        [[ -f "${d}qemu.pid" ]] || continue
        pid="$(cat "${d}qemu.pid" 2>/dev/null)" || continue
        kill -0 "$pid" 2>/dev/null && basename "$d"
    done
    return 0
}

# ── setup-herdr ──────────────────────────────────────────────────────────────

# Args: [--yes] [--remove]
setup_herdr() {
    local assume_yes=false remove=false arg
    for arg in "$@"; do
        case "$arg" in
            --yes|-y) assume_yes=true ;;
            --remove) remove=true ;;
            -h|--help)
                cat << 'EOF'
Usage: claude-vm setup-herdr [--yes] [--remove]

Make VMs reachable as `ssh claude-vm-<name>` and show them in herdr
(https://herdr.dev) as saved machines.

  - writes ~/.claude-vm/ssh_config (one Host claude-vm-* block) and the
    pinned VM host key
  - asks to add one Include line at the top of ~/.ssh/config (backup:
    ~/.ssh/config.claude-vm.bak) — herdr only resolves hosts via OpenSSH
  - registers running VMs; others register when started, are disabled in
    herdr when stopped and removed on reset/destroy

The guest needs herdr in ~/.local/bin (where herdr looks first). Bake it into
the base image with a cloud-init overlay (claude-vm config set cloud-init):

  runcmd:
    - runuser -l "$(id -nu 1000)" -c 'curl -fsSL https://herdr.dev/install.sh | sh'

or run `herdr machine add claude-vm-<name>` once in a terminal to install it
interactively (lost on rebase). VMs on a base built before this feature get
the pinned host key installed on their first start after setup.

  --yes      Don't ask before editing ~/.ssh/config
  --remove   Remove the Include line, the alias config and herdr machines
EOF
                return 0
                ;;
            *)
                echo "Unknown option: $arg" >&2
                echo "Usage: claude-vm setup-herdr [--yes] [--remove]" >&2
                return 1
                ;;
        esac
    done

    load_config
    ensure_dirs

    if $remove; then
        herdr_remove_all_machines
        _remove_user_ssh_include
        rm -f "$(vm_ssh_config_path)"
        echo "Removed the claude-vm SSH aliases and herdr machines."
        return 0
    fi

    ensure_vm_host_key
    write_vm_ssh_config

    local cfg
    cfg="$(_user_ssh_config_path)"
    if _user_ssh_config_has_include; then
        echo "~/.ssh/config already includes $(vm_ssh_config_path)"
    else
        echo "herdr reaches hosts only through your OpenSSH config. This adds one line"
        echo "at the top of $cfg (a backup goes to ${cfg}.claude-vm.bak):"
        echo ""
        echo "    $(_herdr_include_line)"
        echo ""
        if ! $assume_yes; then
            local confirm=""
            read -rp "Add it? [y/N] " confirm || true
            if [[ "$confirm" != [yY] ]]; then
                echo "Not changed. To finish by hand, add the line above at the top of $cfg"
                echo "and run 'claude-vm setup-herdr' again."
                return 0
            fi
        fi
        _add_user_ssh_include
        echo "Added."
    fi

    # Name (and, with herdr, register) the VMs already running
    local hash project port
    echo ""
    echo "Running VMs:"
    for hash in $(_running_vm_hashes); do
        project="$(cat "$SNAPSHOTS_DIR/${hash}.project" 2>/dev/null)" || continue
        port="$(cat "$RUN_DIR/$hash/ssh_port" 2>/dev/null)" || continue
        herdr_vm_started "$project" "$port"
        echo "  ${VM_ALIAS_PREFIX}$(project_vm_name "$project")  $project"
    done

    echo ""
    if ! command -v herdr &>/dev/null; then
        echo "herdr is not installed on this host — 'ssh claude-vm-<name>' works now;"
        echo "VMs register with herdr once it is installed and they are (re)started."
        return 0
    fi
    echo "Done. VMs register with herdr when they start and are disabled when they stop."
    echo "The guest needs herdr installed — see 'claude-vm setup-herdr --help'."
}
