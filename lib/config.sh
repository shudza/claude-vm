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

    # Start with defaults
    VM_RAM="$DEFAULT_RAM"
    VM_CPUS="$DEFAULT_CPUS"
    SSH_PORT_BASE="$DEFAULT_SSH_PORT_BASE"
    FLAVOR="$DEFAULT_FLAVOR"
    VM_USER="$DEFAULT_VM_USER"

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
}

# Set a config key=value in the config file
set_config_value() {
    local key="$1"
    local value="$2"

    # Validate key is a known config option
    case "$key" in
        FLAVOR|VM_USER|VM_RAM|VM_CPUS|SSH_PORT_BASE|BASE_IMAGE_URL|BASE_IMAGE_NAME) ;;
        *)
            echo "Unknown config key: $key" >&2
            echo "Valid keys: FLAVOR, VM_USER, VM_RAM, VM_CPUS, SSH_PORT_BASE, BASE_IMAGE_URL, BASE_IMAGE_NAME" >&2
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
    esac

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

# Check if base image exists and is valid
base_image_exists() {
    local base_img
    base_img="$(base_image_path)"
    [[ -f "$base_img" ]] && qemu-img check "$base_img" &>/dev/null
}

# Check if project snapshot exists
project_snapshot_exists() {
    local snap
    snap="$(project_snapshot_path "${1:-$PWD}")"
    [[ -f "$snap" ]]
}
