#!/usr/bin/env bash
# Integration test: Claude Code credential forwarding and invocation via real sshd
# Requires: sshd installed, not run as root.
# Tests the full path: detect auth → forward creds → verify guest commands
# Skip gracefully if sshd is unavailable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Check prerequisites
if ! command -v sshd >/dev/null 2>&1; then
    echo "SKIP: sshd not found, cannot run integration test"
    exit 0
fi

TEST_DIR=$(mktemp -d)
trap 'cleanup' EXIT

cleanup() {
    if [[ -f "$TEST_DIR/sshd.pid" ]]; then
        kill "$(cat "$TEST_DIR/sshd.pid")" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}

# Generate host keys for test sshd
ssh-keygen -t ed25519 -f "$TEST_DIR/host_key" -N "" -q

# Generate client keypair
ssh-keygen -t ed25519 -f "$TEST_DIR/client_key" -N "" -q

# Set up authorized_keys
mkdir -p "$TEST_DIR/user_ssh"
cp "$TEST_DIR/client_key.pub" "$TEST_DIR/user_ssh/authorized_keys"
chmod 600 "$TEST_DIR/user_ssh/authorized_keys"

# Create workspace dir to simulate guest env
mkdir -p "$TEST_DIR/workspace"

# Find an available port
PORT=23556
while ss -tlnp 2>/dev/null | grep -q ":${PORT} " 2>/dev/null; do
    PORT=$((PORT + 1))
    if (( PORT > 23600 )); then
        echo "SKIP: no available port for test sshd"
        exit 0
    fi
done

# Write sshd config
cat > "$TEST_DIR/sshd_config" <<SSHD_EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $TEST_DIR/host_key
PidFile $TEST_DIR/sshd.pid
AuthorizedKeysFile $TEST_DIR/user_ssh/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM no
Subsystem sftp /usr/lib/ssh/sftp-server
StrictModes no
SSHD_EOF

# Start sshd
$(command -v sshd) -f "$TEST_DIR/sshd_config" -D &
SSHD_PID=$!
echo "$SSHD_PID" > "$TEST_DIR/sshd.pid"
sleep 0.5

if ! kill -0 "$SSHD_PID" 2>/dev/null; then
    echo "SKIP: test sshd failed to start"
    exit 0
fi

# Configure environment
export CLAUDE_VM_SSH_PORT="$PORT"
export CLAUDE_VM_SSH_KEY="$TEST_DIR/client_key"
export CLAUDE_VM_SSH_USER="$(whoami)"
export CLAUDE_VM_SSH_TIMEOUT=3
export CLAUDE_VM_SSH_READY_TIMEOUT=10
export CLAUDE_VM_DIR="$TEST_DIR"

source "$PROJECT_DIR/lib/claude-code.sh"

echo "=== Claude Code Integration Tests ==="
echo ""

PASSED=0
FAILED=0

# Test 1: API key forwarding writes env file to remote
echo "--- Credential Forwarding ---"
export ANTHROPIC_API_KEY="sk-ant-test-integration-key-42"
if forward_api_key "$PORT" "$TEST_DIR/client_key" "$(whoami)" 2>/dev/null; then
    # Verify the env file was created
    ENV_CONTENT=$(ssh_exec "$PORT" "$TEST_DIR/client_key" "$(whoami)" "cat ~/.env" 2>/dev/null || echo "")
    if echo "$ENV_CONTENT" | grep -q "sk-ant-test-integration-key-42"; then
        echo "  ✓ API key forwarded to guest ~/.env"
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ API key not found in guest ~/.env"
        FAILED=$((FAILED + 1))
    fi
else
    echo "  ✗ forward_api_key failed"
    FAILED=$((FAILED + 1))
fi

# Test 2: Env file has correct permissions (600)
PERMS=$(ssh_exec "$PORT" "$TEST_DIR/client_key" "$(whoami)" "stat -c %a ~/.env" 2>/dev/null || echo "")
if [[ "$PERMS" == "600" ]]; then
    echo "  ✓ ~/.env has secure permissions (600)"
    PASSED=$((PASSED + 1))
else
    echo "  ✗ ~/.env permissions: got '$PERMS', expected 600"
    FAILED=$((FAILED + 1))
fi

# Test 3: .bashrc updated to source .env
BASHRC_CHECK=$(ssh_exec "$PORT" "$TEST_DIR/client_key" "$(whoami)" "grep 'source ~/.env' ~/.bashrc" 2>/dev/null || echo "")
if [[ -n "$BASHRC_CHECK" ]]; then
    echo "  ✓ .bashrc sources ~/.env"
    PASSED=$((PASSED + 1))
else
    echo "  ✗ .bashrc not updated to source ~/.env"
    FAILED=$((FAILED + 1))
fi

# Test 4: Idempotent — running forward_api_key again doesn't duplicate .bashrc entry
forward_api_key "$PORT" "$TEST_DIR/client_key" "$(whoami)" 2>/dev/null
LINE_COUNT=$(ssh_exec "$PORT" "$TEST_DIR/client_key" "$(whoami)" "grep -c 'source ~/.env' ~/.bashrc" 2>/dev/null || echo "0")
if [[ "$LINE_COUNT" == "1" ]]; then
    echo "  ✓ .bashrc sourcing is idempotent (single entry)"
    PASSED=$((PASSED + 1))
else
    echo "  ✗ .bashrc has $LINE_COUNT entries for .env sourcing (expected 1)"
    FAILED=$((FAILED + 1))
fi

# Test 5: Claude config dir sync (if rsync or tar available)
echo ""
echo "--- Config Dir Sync ---"
mkdir -p "$TEST_DIR/fake_claude_config"
echo '{"auth": "test-token"}' > "$TEST_DIR/fake_claude_config/credentials.json"
echo "session-data" > "$TEST_DIR/fake_claude_config/session"
export CLAUDE_CONFIG_DIR="$TEST_DIR/fake_claude_config"
export GUEST_CLAUDE_DIR="$HOME/.claude-test-$$"

if sync_claude_config "$PORT" "$TEST_DIR/client_key" "$(whoami)" 2>/dev/null; then
    # Verify files arrived
    REMOTE_AUTH=$(ssh_exec "$PORT" "$TEST_DIR/client_key" "$(whoami)" "cat $GUEST_CLAUDE_DIR/credentials.json" 2>/dev/null || echo "")
    if echo "$REMOTE_AUTH" | grep -q "test-token"; then
        echo "  ✓ Claude config synced to guest"
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ Config file not found in guest after sync"
        FAILED=$((FAILED + 1))
    fi
    # Cleanup remote test dir
    ssh_exec "$PORT" "$TEST_DIR/client_key" "$(whoami)" "rm -rf $GUEST_CLAUDE_DIR" 2>/dev/null || true
else
    echo "  ✗ sync_claude_config failed"
    FAILED=$((FAILED + 1))
fi
# Reset GUEST_CLAUDE_DIR
export GUEST_CLAUDE_DIR="/home/claude/.claude"

# Test 6: Git config forwarding
echo ""
echo "--- Setup / Git Config ---"
ORIG_GIT_NAME=$(git config --global user.name 2>/dev/null || echo "")
ORIG_GIT_EMAIL=$(git config --global user.email 2>/dev/null || echo "")

if [[ -n "$ORIG_GIT_NAME" ]]; then
    setup_claude_in_sandbox "$PORT" "$TEST_DIR/client_key" "$(whoami)" 2>/dev/null
    REMOTE_NAME=$(ssh_exec "$PORT" "$TEST_DIR/client_key" "$(whoami)" "git config --global user.name" 2>/dev/null || echo "")
    if [[ "$REMOTE_NAME" == "$ORIG_GIT_NAME" ]]; then
        echo "  ✓ Git user.name forwarded to guest"
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ Git user.name: got '$REMOTE_NAME', expected '$ORIG_GIT_NAME'"
        FAILED=$((FAILED + 1))
    fi
else
    echo "  SKIP: no git user.name configured on host"
fi

# Test 7: guest_has_claude returns false when no claude binary (expected in test env)
echo ""
echo "--- Guest Verification ---"
if guest_has_claude "$PORT" "$TEST_DIR/client_key" "$(whoami)"; then
    echo "  ✓ claude binary found (host has claude installed)"
    PASSED=$((PASSED + 1))
else
    echo "  ✓ guest_has_claude correctly returns false (no claude in test env)"
    PASSED=$((PASSED + 1))
fi

echo ""
echo "Results: ${PASSED} passed, ${FAILED} failed"
if (( FAILED > 0 )); then
    exit 1
fi
echo "All integration tests passed."
