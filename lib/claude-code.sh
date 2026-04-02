#!/usr/bin/env bash
# claude-code.sh — Claude Code invocation and credential forwarding
#
# Handles:
# - Detecting host-side Claude authentication credentials
# - Forwarding credentials into the guest VM via SSH
# - Launching Claude Code inside the sandbox with full permissions
# - Verifying Claude Code is installed and functional in the guest
#
# Claude Code auth methods (checked in order):
# 1. ANTHROPIC_API_KEY environment variable (simplest)
# 2. ~/.claude/ directory (OAuth tokens, session data)
#
# The guest runs Claude Code with --dangerously-skip-permissions so it
# can execute any tool without interactive approval — the VM itself is
# the sandbox boundary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source SSH module if not already loaded
if ! declare -f ssh_exec &>/dev/null; then
    source "${SCRIPT_DIR}/ssh.sh"
fi

# ─── Constants ───────────────────────────────────────────────────────────────

# Guest paths
GUEST_WORKSPACE="/workspace"
GUEST_USER="${VM_USER:-$USER}"
GUEST_HOME="/home/$GUEST_USER"
GUEST_CLAUDE_DIR="$GUEST_HOME/.claude"
GUEST_CLAUDE_BIN_PATHS=(
    "$GUEST_HOME/.local/bin/claude"
    "/usr/local/bin/claude"
    "/usr/bin/claude"
)

# Default Claude Code flags for sandbox mode
CLAUDE_SANDBOX_FLAGS="--dangerously-skip-permissions"

# ─── Credential Detection (Host Side) ───────────────────────────────────────

# Check if ANTHROPIC_API_KEY is set on the host
has_api_key() {
    [[ -n "${ANTHROPIC_API_KEY:-}" ]]
}

# Check if ~/.claude directory exists with auth data
has_claude_config_dir() {
    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    [[ -d "$claude_dir" ]] && [[ -n "$(ls -A "$claude_dir" 2>/dev/null)" ]]
}

# Detect which auth method is available
# Returns: "api_key", "config_dir", "both", or "none"
detect_auth_method() {
    local has_key=false
    local has_dir=false

    has_api_key && has_key=true
    has_claude_config_dir && has_dir=true

    if $has_key && $has_dir; then
        echo "both"
    elif $has_key; then
        echo "api_key"
    elif $has_dir; then
        echo "config_dir"
    else
        echo "none"
    fi
}

# ─── Credential Forwarding (Host → Guest) ───────────────────────────────────

# Forward ANTHROPIC_API_KEY to the guest by writing it to the claude user's
# environment file. This persists across SSH sessions.
forward_api_key() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"
    local api_key="${ANTHROPIC_API_KEY:-}"

    if [[ -z "$api_key" ]]; then
        echo "WARNING: ANTHROPIC_API_KEY not set, skipping API key forwarding" >&2
        return 1
    fi

    # Write to ~/.env so it's picked up by bash sessions
    ssh_exec "$port" "$key" "$user" \
        "mkdir -p ~/.config/claude && echo 'export ANTHROPIC_API_KEY=${api_key}' > ~/.env && chmod 600 ~/.env"

    # Also add sourcing to .bashrc if not already there
    ssh_exec "$port" "$key" "$user" \
        "grep -q 'source ~/.env' ~/.bashrc 2>/dev/null || echo '[ -f ~/.env ] && source ~/.env' >> ~/.bashrc"

    return 0
}

# Sync the host's ~/.claude directory to the guest for OAuth/session auth.
# Uses rsync over SSH for efficiency (only syncs changed files).
sync_claude_config() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"
    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

    if [[ ! -d "$claude_dir" ]]; then
        echo "WARNING: Claude config directory not found: $claude_dir" >&2
        return 1
    fi

    # Ensure target directory exists
    ssh_exec "$port" "$key" "$user" "mkdir -p $GUEST_CLAUDE_DIR"

    # Use rsync if available, fall back to scp
    if command -v rsync &>/dev/null; then
        rsync -az --delete \
            -e "ssh -p $port -i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
            --exclude='*.log' \
            --exclude='projects/' \
            "$claude_dir/" \
            "${user}@localhost:${GUEST_CLAUDE_DIR}/"
    else
        # Fallback: tar + ssh pipe (works without rsync)
        tar -C "$claude_dir" --exclude='*.log' --exclude='projects' -czf - . | \
            ssh -p "$port" -i "$key" \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o LogLevel=ERROR \
                "${user}@localhost" \
                "mkdir -p $GUEST_CLAUDE_DIR && tar -C $GUEST_CLAUDE_DIR -xzf -"
    fi
}

# Forward all available credentials to the guest
# This is the main function called during sandbox launch
forward_credentials() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"

    local auth_method
    auth_method=$(detect_auth_method)

    case "$auth_method" in
        both)
            echo "Forwarding API key and Claude config to sandbox..."
            forward_api_key "$port" "$key" "$user"
            sync_claude_config "$port" "$key" "$user"
            ;;
        api_key)
            echo "Forwarding API key to sandbox..."
            forward_api_key "$port" "$key" "$user"
            ;;
        config_dir)
            echo "Syncing Claude config to sandbox..."
            sync_claude_config "$port" "$key" "$user"
            ;;
        none)
            echo "WARNING: No Claude authentication found on host." >&2
            echo "  Set ANTHROPIC_API_KEY or run 'claude login' on the host first." >&2
            return 1
            ;;
    esac

    return 0
}

# ─── Claude Code Verification (Guest Side) ──────────────────────────────────

# Check if Claude Code binary exists in the guest
guest_has_claude() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"

    ssh_exec "$port" "$key" "$user" \
        "command -v claude >/dev/null 2>&1 || \
         test -x $GUEST_HOME/.local/bin/claude" 2>/dev/null
}

# Get the Claude Code version installed in the guest
guest_claude_version() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"

    ssh_exec "$port" "$key" "$user" \
        "claude --version 2>/dev/null || echo 'unknown'"
}

# Verify Claude Code can start (non-interactive, just check it launches)
guest_claude_health_check() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"

    # Run claude with --help to verify it starts without errors
    ssh_exec "$port" "$key" "$user" \
        "claude --help >/dev/null 2>&1"
}

# Full verification: binary exists, version retrievable, can start
verify_claude_in_guest() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"

    echo -n "Verifying Claude Code in sandbox... "

    if ! guest_has_claude "$port" "$key" "$user"; then
        echo "NOT FOUND"
        echo "ERROR: Claude Code is not installed in the sandbox." >&2
        echo "  Rebuild the base image: claude-vm build" >&2
        return 1
    fi

    local version
    version=$(guest_claude_version "$port" "$key" "$user" 2>/dev/null || echo "unknown")
    echo "found (${version})"

    return 0
}

# ─── Claude Code Launch ─────────────────────────────────────────────────────

# Launch Claude Code interactively inside the sandbox.
# This SSHs into the VM and starts Claude Code in /workspace
# with --dangerously-skip-permissions (the VM IS the sandbox).
launch_claude_in_sandbox() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"
    shift 3 2>/dev/null || true
    local extra_args=("$@")

    # Forward credentials before launching
    forward_credentials "$port" "$key" "$user" || {
        echo "WARNING: Proceeding without credentials. Claude may not be authenticated." >&2
    }

    # Verify Claude is available
    if ! guest_has_claude "$port" "$key" "$user"; then
        echo "ERROR: Claude Code not found in sandbox. Run 'claude-vm build' to rebuild." >&2
        return 1
    fi

    echo "Launching Claude Code in sandbox..."
    echo "  Workspace: $GUEST_WORKSPACE"
    echo "  Mode: full permissions (sandbox-isolated)"
    echo ""

    # Build the remote command
    local remote_cmd="cd $GUEST_WORKSPACE 2>/dev/null; "
    # Source env for API key
    remote_cmd+="[ -f ~/.env ] && source ~/.env; "
    # Launch Claude Code with full permissions
    remote_cmd+="exec claude $CLAUDE_SANDBOX_FLAGS"

    # Append any extra args (e.g., --model, -p "prompt", etc.)
    if [[ ${#extra_args[@]} -gt 0 ]]; then
        for arg in "${extra_args[@]}"; do
            remote_cmd+=" $(printf '%q' "$arg")"
        done
    fi

    # Interactive SSH session with TTY allocation
    ssh_connect "$port" "$key" "$user" "$remote_cmd"
}

# Run a single Claude Code command non-interactively in the sandbox.
# Useful for scripted/automated workflows.
run_claude_command() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"
    local prompt="$4"

    if [[ -z "$prompt" ]]; then
        echo "ERROR: No prompt provided for non-interactive Claude run" >&2
        return 1
    fi

    # Forward credentials
    forward_credentials "$port" "$key" "$user" 2>/dev/null || true

    # Build command with credential sourcing
    local remote_cmd="cd $GUEST_WORKSPACE 2>/dev/null; "
    remote_cmd+="[ -f ~/.env ] && source ~/.env; "
    remote_cmd+="claude $CLAUDE_SANDBOX_FLAGS -p $(printf '%q' "$prompt")"

    ssh_exec "$port" "$key" "$user" "$remote_cmd"
}

# ─── Setup (called during first launch) ─────────────────────────────────────

# One-time setup tasks for Claude Code in a new sandbox.
# Called after first cold boot of a project snapshot.
setup_claude_in_sandbox() {
    local port="${1:-$CLAUDE_VM_SSH_PORT}"
    local key="${2:-$CLAUDE_VM_SSH_KEY}"
    local user="${3:-$CLAUDE_VM_SSH_USER}"

    echo "Setting up Claude Code in sandbox..."

    # Forward credentials
    if ! forward_credentials "$port" "$key" "$user"; then
        echo "WARNING: Could not forward credentials. Claude Code may need manual auth." >&2
    fi

    # Set git config if available on host
    local git_name git_email
    git_name=$(git config --global user.name 2>/dev/null || true)
    git_email=$(git config --global user.email 2>/dev/null || true)

    if [[ -n "$git_name" ]]; then
        ssh_exec "$port" "$key" "$user" "git config --global user.name $(printf '%q' "$git_name")" 2>/dev/null || true
    fi
    if [[ -n "$git_email" ]]; then
        ssh_exec "$port" "$key" "$user" "git config --global user.email $(printf '%q' "$git_email")" 2>/dev/null || true
    fi

    # Ensure workspace directory exists and is writable
    ssh_exec "$port" "$key" "$user" "mkdir -p $GUEST_WORKSPACE && test -w $GUEST_WORKSPACE" || {
        echo "WARNING: /workspace may not be writable. Check virtiofs mount." >&2
    }

    echo "Claude Code setup complete."
}
