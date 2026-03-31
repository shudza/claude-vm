#!/usr/bin/env bash
# Integration test: spin up a temporary sshd and verify ssh_gate_ready succeeds.
# Requires: sshd installed, not run as root (uses unprivileged port).
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

# Create workspace dir to satisfy the readiness check
mkdir -p "$TEST_DIR/workspace"

# Find an available port
PORT=23456
while ss -tlnp 2>/dev/null | grep -q ":${PORT} " 2>/dev/null; do
    PORT=$((PORT + 1))
    if (( PORT > 23500 )); then
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

# Give sshd a moment to start
sleep 0.5

if ! kill -0 "$SSHD_PID" 2>/dev/null; then
    echo "SKIP: test sshd failed to start"
    exit 0
fi

# Source SSH module
export CLAUDE_VM_SSH_PORT="$PORT"
export CLAUDE_VM_SSH_KEY="$TEST_DIR/client_key"
export CLAUDE_VM_SSH_USER="$(whoami)"
export CLAUDE_VM_SSH_TIMEOUT=3
export CLAUDE_VM_SSH_READY_TIMEOUT=10
export CLAUDE_VM_DIR="$TEST_DIR"

source "$PROJECT_DIR/lib/ssh.sh"

echo "=== SSH Integration Tests ==="
echo ""

PASSED=0
FAILED=0

# Test 1: ssh_check succeeds against real sshd
if ssh_check "$PORT" "$TEST_DIR/client_key" "$(whoami)" 3; then
    echo "  ✓ ssh_check succeeds against running sshd"
    PASSED=$((PASSED + 1))
else
    echo "  ✗ ssh_check failed against running sshd"
    FAILED=$((FAILED + 1))
fi

# Test 2: ssh_wait_ready returns quickly when SSH is already available
START=$(date +%s%N)
if ssh_wait_ready "$PORT" "$TEST_DIR/client_key" "$(whoami)" 10 1; then
    END=$(date +%s%N)
    ELAPSED_MS=$(( (END - START) / 1000000 ))
    if (( ELAPSED_MS < 5000 )); then
        echo "  ✓ ssh_wait_ready returns immediately when SSH is up (${ELAPSED_MS}ms)"
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ ssh_wait_ready too slow: ${ELAPSED_MS}ms"
        FAILED=$((FAILED + 1))
    fi
else
    echo "  ✗ ssh_wait_ready failed when sshd is running"
    FAILED=$((FAILED + 1))
fi

# Test 3: ssh_exec can run a command
OUTPUT=$(ssh_exec "$PORT" "$TEST_DIR/client_key" "$(whoami)" "echo hello-from-vm")
if [[ "$OUTPUT" == "hello-from-vm" ]]; then
    echo "  ✓ ssh_exec returns command output correctly"
    PASSED=$((PASSED + 1))
else
    echo "  ✗ ssh_exec output: '$OUTPUT', expected 'hello-from-vm'"
    FAILED=$((FAILED + 1))
fi

# Test 4: ssh_gate_ready completes (workspace check will fail since it checks /workspace)
if ssh_gate_ready "$PORT" "$TEST_DIR/client_key" "$(whoami)" 10 2>/dev/null; then
    echo "  ✓ ssh_gate_ready succeeds (SSH layer)"
    PASSED=$((PASSED + 1))
else
    echo "  ✗ ssh_gate_ready failed"
    FAILED=$((FAILED + 1))
fi

# Test 5: Verify SSH responds after sshd stop (should fail)
kill "$SSHD_PID" 2>/dev/null || true
wait "$SSHD_PID" 2>/dev/null || true
rm -f "$TEST_DIR/sshd.pid"
sleep 0.3

if ssh_check "$PORT" "$TEST_DIR/client_key" "$(whoami)" 1; then
    echo "  ✗ ssh_check should fail after sshd shutdown"
    FAILED=$((FAILED + 1))
else
    echo "  ✓ ssh_check correctly fails after sshd shutdown"
    PASSED=$((PASSED + 1))
fi

echo ""
echo "Results: ${PASSED} passed, ${FAILED} failed"
if (( FAILED > 0 )); then
    exit 1
fi
echo "All integration tests passed."
