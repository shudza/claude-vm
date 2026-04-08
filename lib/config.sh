#!/usr/bin/env bash
# claude-vm configuration defaults and loading
# Provides: CLAUDE_VM_DIR, config defaults, load_config()

set -euo pipefail

# Base directory for all claude-vm data
CLAUDE_VM_DIR="${CLAUDE_VM_DIR:-$HOME/.claude-vm}"
CLAUDE_VM_CONFIG="${CLAUDE_VM_CONFIG:-$CLAUDE_VM_DIR/config}"

# Defaults (overridable via config file)
DEFAULT_RAM="4G"
DEFAULT_CPUS="2"
DEFAULT_SSH_PORT_BASE="10022"
DEFAULT_FLAVOR="debian"
DEFAULT_VM_USER="$USER"
DEFAULT_FORWARD_PORTS=""
DEFAULT_CLAUDE_ARGS="--dangerously-skip-permissions"

# ── Flavor registry ──────────────────────────────────────────────────────────
# Each flavor defines: image URL, image filename, package manager family
# Cloud-init userdata generation is dispatched by flavor in cloud-init.sh

declare -A FLAVOR_IMAGE_URL=(
    [debian]="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
    [ubuntu]="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
    [archlinux]="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
    [fedora]="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
)

declare -A FLAVOR_IMAGE_NAME=(
    [debian]="debian-13-genericcloud-amd64.qcow2"
    [ubuntu]="ubuntu-24.04-minimal-cloudimg-amd64.img"
    [archlinux]="Arch-Linux-x86_64-cloudimg.qcow2"
    [fedora]="Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
)

declare -A FLAVOR_PKG_FAMILY=(
    [debian]="apt"
    [ubuntu]="apt"
    [archlinux]="pacman"
    [fedora]="dnf"
)

# Upstream checksum file URLs (fetched at download time to verify image integrity)
# Debian publishes SHA512SUMS, Ubuntu publishes SHA256SUMS
declare -A FLAVOR_CHECKSUM_URL=(
    [debian]="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
    [ubuntu]="https://cloud-images.ubuntu.com/minimal/releases/noble/release/SHA256SUMS"
    [archlinux]="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2.SHA256"
    [fedora]="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-41-1.4-x86_64-CHECKSUM"
)

declare -A FLAVOR_CHECKSUM_TYPE=(
    [debian]="sha512"
    [ubuntu]="sha256"
    [archlinux]="sha256"
    [fedora]="sha256"
)

# List valid flavor names
valid_flavors() {
    echo "${!FLAVOR_IMAGE_URL[@]}" | tr ' ' '\n' | sort
}

# Check if a flavor name is valid
is_valid_flavor() {
    [[ -n "${FLAVOR_IMAGE_URL[$1]+x}" ]]
}

# Derived paths
BASE_IMAGES_DIR="$CLAUDE_VM_DIR/base"
SNAPSHOTS_DIR="$CLAUDE_VM_DIR/snapshots"
CLOUD_INIT_DIR="$CLAUDE_VM_DIR/cloud-init"
RUN_DIR="$CLAUDE_VM_DIR/run"

# Load user config (simple key=value file)
# Priority: defaults → config file → environment variables
load_config() {
    # Save any env var overrides before loading config file
    local _env_ram="${VM_RAM:-}"
    local _env_cpus="${VM_CPUS:-}"
    local _env_ssh_port="${SSH_PORT_BASE:-}"
    local _env_flavor="${FLAVOR:-}"
    local _env_image_url="${BASE_IMAGE_URL:-}"
    local _env_image_name="${BASE_IMAGE_NAME:-}"
    local _env_vm_user="${VM_USER:-}"
    local _env_forward_ports="${FORWARD_PORTS:-}"
    local _env_claude_args="${CLAUDE_ARGS:-}"

    # Start with defaults
    VM_RAM="$DEFAULT_RAM"
    VM_CPUS="$DEFAULT_CPUS"
    SSH_PORT_BASE="$DEFAULT_SSH_PORT_BASE"
    FLAVOR="$DEFAULT_FLAVOR"
    VM_USER="$DEFAULT_VM_USER"
    FORWARD_PORTS="$DEFAULT_FORWARD_PORTS"
    CLAUDE_ARGS="$DEFAULT_CLAUDE_ARGS"

    # Override from config file if it exists
    if [[ -f "$CLAUDE_VM_CONFIG" ]]; then
        # shellcheck source=/dev/null
        source "$CLAUDE_VM_CONFIG"
    fi

    # Environment variables take highest priority
    [[ -n "$_env_ram" ]] && VM_RAM="$_env_ram"
    [[ -n "$_env_cpus" ]] && VM_CPUS="$_env_cpus"
    [[ -n "$_env_ssh_port" ]] && SSH_PORT_BASE="$_env_ssh_port"
    [[ -n "$_env_flavor" ]] && FLAVOR="$_env_flavor"
    [[ -n "$_env_vm_user" ]] && VM_USER="$_env_vm_user"
    [[ -n "$_env_forward_ports" ]] && FORWARD_PORTS="$_env_forward_ports"
    [[ -n "$_env_claude_args" ]] && CLAUDE_ARGS="$_env_claude_args"

    # Derive image URL/name from flavor (explicit overrides still win)
    if is_valid_flavor "$FLAVOR"; then
        BASE_IMAGE_URL="${_env_image_url:-${FLAVOR_IMAGE_URL[$FLAVOR]}}"
        BASE_IMAGE_NAME="${_env_image_name:-${FLAVOR_IMAGE_NAME[$FLAVOR]}}"
    else
        echo "WARNING: Unknown flavor '$FLAVOR', falling back to debian" >&2
        FLAVOR="debian"
        BASE_IMAGE_URL="${_env_image_url:-${FLAVOR_IMAGE_URL[debian]}}"
        BASE_IMAGE_NAME="${_env_image_name:-${FLAVOR_IMAGE_NAME[debian]}}"
    fi

    return 0
}

# Show current effective configuration
show_config() {
    load_config
    echo "# claude-vm configuration (effective values)"
    echo "# Priority: defaults < config file < environment variables"
    echo "#"
    echo "# Config file: $CLAUDE_VM_CONFIG"
    if [[ -f "$CLAUDE_VM_CONFIG" ]]; then
        echo "# Status: loaded"
    else
        echo "# Status: not found (using defaults)"
    fi
    echo ""
    echo "FLAVOR=\"$FLAVOR\""
    echo "VM_USER=\"$VM_USER\""
    echo "VM_RAM=\"$VM_RAM\""
    echo "VM_CPUS=\"$VM_CPUS\""
    echo "SSH_PORT_BASE=\"$SSH_PORT_BASE\""
    echo "BASE_IMAGE_URL=\"$BASE_IMAGE_URL\"  # derived from FLAVOR"
    echo "BASE_IMAGE_NAME=\"$BASE_IMAGE_NAME\"  # derived from FLAVOR"
    echo "FORWARD_PORTS=\"$(get_project_forward_ports "$PWD")\"  # per-project"
    echo "CLAUDE_ARGS=\"$CLAUDE_ARGS\""
}

# Set a config key=value in the config file
set_config_value() {
    local key="$1"
    local value="$2"

    # Validate key is a known config option
    case "$key" in
        FLAVOR|VM_USER|VM_RAM|VM_CPUS|SSH_PORT_BASE|BASE_IMAGE_URL|BASE_IMAGE_NAME|FORWARD_PORTS|CLAUDE_ARGS) ;;
        *)
            echo "Unknown config key: $key" >&2
            echo "Valid keys: FLAVOR, VM_USER, VM_RAM, VM_CPUS, SSH_PORT_BASE, BASE_IMAGE_URL, BASE_IMAGE_NAME, FORWARD_PORTS, CLAUDE_ARGS" >&2
            return 1
            ;;
    esac

    # Validate resource values
    case "$key" in
        FLAVOR)
            if ! is_valid_flavor "$value"; then
                echo "Unknown flavor: $value" >&2
                echo "Valid flavors: $(valid_flavors | tr '\n' ' ')" >&2
                return 1
            fi
            ;;
        VM_RAM)
            if ! [[ "$value" =~ ^[0-9]+[GMgm]$ ]]; then
                echo "Invalid RAM value: $value (use e.g., 4G, 8G, 512M)" >&2
                return 1
            fi
            ;;
        VM_CPUS)
            if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 )); then
                echo "Invalid CPU count: $value (must be a positive integer)" >&2
                return 1
            fi
            ;;
        SSH_PORT_BASE)
            if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1024 || value > 65535 )); then
                echo "Invalid port: $value (must be 1024-65535)" >&2
                return 1
            fi
            ;;
        FORWARD_PORTS)
            if [[ -n "$value" ]]; then
                _validate_forward_ports "$value" || return 1
            fi
            ;;
    esac

    # FORWARD_PORTS is per-project (stored as sidecar, not in global config)
    if [[ "$key" == "FORWARD_PORTS" ]]; then
        load_config
        set_project_forward_ports "$PWD" "$value"
        if [[ -n "$value" ]]; then
            echo "Set FORWARD_PORTS=$value for project $PWD"
        else
            echo "Cleared FORWARD_PORTS for project $PWD"
        fi
        return 0
    fi

    ensure_dirs

    # Create config file if it doesn't exist
    if [[ ! -f "$CLAUDE_VM_CONFIG" ]]; then
        cat > "$CLAUDE_VM_CONFIG" << 'HEADER'
# claude-vm configuration
# This file is sourced as bash. Use KEY="VALUE" format.
# See: claude-vm config --help
HEADER
    fi

    # Update existing key or append
    if grep -q "^${key}=" "$CLAUDE_VM_CONFIG" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CLAUDE_VM_CONFIG"
    else
        echo "${key}=\"${value}\"" >> "$CLAUDE_VM_CONFIG"
    fi

    echo "Set $key=$value in $CLAUDE_VM_CONFIG"
}

# Ensure directory structure exists
ensure_dirs() {
    mkdir -p "$BASE_IMAGES_DIR" "$SNAPSHOTS_DIR" "$CLOUD_INIT_DIR" "$RUN_DIR"
}

# Generate a stable project hash from directory path
project_hash() {
    local project_dir="${1:-$PWD}"
    echo -n "$project_dir" | sha256sum | cut -c1-12
}

# Get project snapshot path
project_snapshot_path() {
    local hash
    hash="$(project_hash "${1:-$PWD}")"
    echo "$SNAPSHOTS_DIR/${hash}.qcow2"
}

# Get project run directory (for PID files, sockets, etc.)
project_run_dir() {
    local hash
    hash="$(project_hash "${1:-$PWD}")"
    echo "$RUN_DIR/$hash"
}

# Get the base image path (the provisioned golden image)
base_image_path() {
    echo "$BASE_IMAGES_DIR/base.qcow2"
}

# Get the downloaded cloud image path (the raw download)
cloud_image_path() {
    echo "$BASE_IMAGES_DIR/$BASE_IMAGE_NAME"
}

# Validate FORWARD_PORTS spec string
# Accepts comma-separated specs: PORT, HOST:GUEST, START-END, HSTART-HEND:GSTART-GEND
_validate_forward_ports() {
    local value="$1"
    local IFS=','
    local specs
    read -ra specs <<< "$value"

    local spec
    for spec in "${specs[@]}"; do
        spec="$(echo "$spec" | tr -d ' ')"
        [[ -z "$spec" ]] && continue

        if [[ "$spec" =~ ^([0-9]+)-([0-9]+):([0-9]+)-([0-9]+)$ ]]; then
            local hs="${BASH_REMATCH[1]}" he="${BASH_REMATCH[2]}" gs="${BASH_REMATCH[3]}" ge="${BASH_REMATCH[4]}"
            _validate_port "$hs" && _validate_port "$he" && _validate_port "$gs" && _validate_port "$ge" || return 1
            if (( hs > he )); then
                echo "Invalid port range: $spec (start > end)" >&2; return 1
            fi
            if (( gs > ge )); then
                echo "Invalid port range: $spec (start > end)" >&2; return 1
            fi
            if (( he - hs != ge - gs )); then
                echo "Invalid port range: $spec (host and guest ranges must be equal length)" >&2; return 1
            fi
            if (( he - hs > 100 )); then
                echo "Invalid port range: $spec (max 100 ports per range)" >&2; return 1
            fi
        elif [[ "$spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local rs="${BASH_REMATCH[1]}" re="${BASH_REMATCH[2]}"
            _validate_port "$rs" && _validate_port "$re" || return 1
            if (( rs > re )); then
                echo "Invalid port range: $spec (start > end)" >&2; return 1
            fi
            if (( re - rs > 100 )); then
                echo "Invalid port range: $spec (max 100 ports per range)" >&2; return 1
            fi
        elif [[ "$spec" =~ ^([0-9]+):([0-9]+)$ ]]; then
            _validate_port "${BASH_REMATCH[1]}" && _validate_port "${BASH_REMATCH[2]}" || return 1
        elif [[ "$spec" =~ ^([0-9]+)$ ]]; then
            _validate_port "${BASH_REMATCH[1]}" || return 1
        else
            echo "Invalid port spec: $spec (use PORT, HOST:GUEST, START-END, or HSTART-HEND:GSTART-GEND)" >&2
            return 1
        fi
    done
    return 0
}

_validate_port() {
    local port="$1"
    if (( port < 1 || port > 65535 )); then
        echo "Invalid port number: $port (must be 1-65535)" >&2
        return 1
    fi
    return 0
}

# Get per-project FORWARD_PORTS (falls back to global config value)
get_project_forward_ports() {
    local project_dir="${1:-$PWD}"
    local hash
    hash="$(project_hash "$project_dir")"
    local ports_file="$SNAPSHOTS_DIR/${hash}.ports"

    if [[ -f "$ports_file" ]]; then
        cat "$ports_file"
    else
        echo "${FORWARD_PORTS:-}"
    fi
}

# Set per-project FORWARD_PORTS
set_project_forward_ports() {
    local project_dir="$1"
    local value="$2"
    local hash
    hash="$(project_hash "$project_dir")"

    ensure_dirs
    if [[ -z "$value" ]]; then
        rm -f "$SNAPSHOTS_DIR/${hash}.ports"
    else
        echo "$value" > "$SNAPSHOTS_DIR/${hash}.ports"
    fi
}

# Check if base image exists and is valid
base_image_exists() {
    local base_img
    base_img="$(base_image_path)"
    [[ -f "$base_img" ]] && qemu-img check "$base_img" &>/dev/null
}

