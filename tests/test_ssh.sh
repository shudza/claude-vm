#!/usr/bin/env bash
# Tests for lib/ssh.sh — SSH readiness module
# Run: bash tests/test_ssh.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  ✓ $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  ✗ $1: $2"; }

run_test() { "$@"; }

# ─── Setup ────────────────────────────────────────────────────────────────────

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export CLAUDE_VM_SSH_KEY="${TEST_DIR}/test_key"
export CLAUDE_VM_SSH_PORT="29999"
export CLAUDE_VM_SSH_USER="testuser"
export CLAUDE_VM_DIR="$TEST_DIR"

source "$PROJECT_DIR/lib/ssh.sh"

# ─── Tests ────────────────────────────────────────────────────────────────────

test_keypair_generation() {
    ssh_ensure_keypair "$TEST_DIR/test_key"
    if [[ -f "$TEST_DIR/test_key" && -f "$TEST_DIR/test_key.pub" ]]; then
        pass "keypair generated"
    else
        fail "keypair generated" "missing key files"
    fi

    # Check permissions
    local priv_perms
    priv_perms=$(stat -c %a "$TEST_DIR/test_key")
    if [[ "$priv_perms" == "600" ]]; then
        pass "private key permissions correct (600)"
    else
        fail "private key permissions" "got $priv_perms, expected 600"
    fi
}

test_keypair_idempotent() {
    local before after
    ssh_ensure_keypair "$TEST_DIR/test_key"
    before=$(md5sum "$TEST_DIR/test_key" | cut -d' ' -f1)
    ssh_ensure_keypair "$TEST_DIR/test_key"
    after=$(md5sum "$TEST_DIR/test_key" | cut -d' ' -f1)
    if [[ "$before" == "$after" ]]; then
        pass "keypair generation is idempotent"
    else
        fail "keypair idempotent" "key changed on second call"
    fi
}

test_public_key_readable() {
    ssh_ensure_keypair "$TEST_DIR/test_key"
    local pubkey
    pubkey=$(ssh_public_key "$TEST_DIR/test_key")
    if [[ "$pubkey" == ssh-ed25519* ]]; then
        pass "public key is readable and valid ed25519"
    else
        fail "public key readable" "unexpected format: $pubkey"
    fi
}

test_public_key_missing() {
    if ssh_public_key "$TEST_DIR/nonexistent_key" 2>/dev/null; then
        fail "missing public key returns error" "returned 0"
    else
        pass "missing public key returns error"
    fi
}

test_ssh_check_unreachable() {
    # Port 29999 should not have anything listening
    if ssh_check 29999 "$TEST_DIR/test_key" "testuser" 1; then
        fail "ssh_check returns 1 when unreachable" "returned 0"
    else
        pass "ssh_check returns 1 when unreachable"
    fi
}

test_ssh_wait_ready_timeout() {
    local start end elapsed
    start=$(date +%s)
    if ssh_wait_ready 29999 "$TEST_DIR/test_key" "testuser" 3 1; then
        fail "ssh_wait_ready times out correctly" "returned 0"
    else
        end=$(date +%s)
        elapsed=$((end - start))
        if (( elapsed >= 2 && elapsed <= 6 )); then
            pass "ssh_wait_ready times out after ~3s (took ${elapsed}s)"
        else
            fail "ssh_wait_ready timeout duration" "took ${elapsed}s, expected ~3s"
        fi
    fi
}

test_ssh_gate_ready_timeout() {
    if ssh_gate_ready 29999 "$TEST_DIR/test_key" "testuser" 2 2>/dev/null; then
        fail "ssh_gate_ready returns 1 on timeout" "returned 0"
    else
        pass "ssh_gate_ready returns 1 on timeout"
    fi
}

test_qemu_netdev_arg() {
    local arg
    arg=$(qemu_ssh_netdev_arg 2222 22)
    if [[ "$arg" == "user,id=net0,hostfwd=tcp::2222-:22" ]]; then
        pass "qemu_ssh_netdev_arg formats correctly"
    else
        fail "qemu_ssh_netdev_arg" "got: $arg"
    fi
}

test_find_available_port() {
    local port
    port=$(ssh_find_available_port 39000 39010)
    if (( port >= 39000 && port <= 39010 )); then
        pass "find_available_port returns port in range ($port)"
    else
        fail "find_available_port" "got $port, expected 39000-39010"
    fi
}

test_port_file_management() {
    local project_id="test-project-abc"

    ssh_save_port "$project_id" "2345"
    local loaded
    loaded=$(ssh_load_port "$project_id")
    if [[ "$loaded" == "2345" ]]; then
        pass "port save/load round-trip works"
    else
        fail "port save/load" "got $loaded, expected 2345"
    fi

    ssh_cleanup_port "$project_id"
    if ssh_load_port "$project_id" 2>/dev/null; then
        fail "port cleanup removes file" "port file still exists"
    else
        pass "port cleanup removes file"
    fi
}

test_port_load_missing() {
    if ssh_load_port "nonexistent-project" 2>/dev/null; then
        fail "load_port returns 1 for missing project" "returned 0"
    else
        pass "load_port returns 1 for missing project"
    fi
}

# ─── Run ──────────────────────────────────────────────────────────────────────

echo "=== claude-vm SSH module tests ==="
echo ""

run_test test_keypair_generation
run_test test_keypair_idempotent
run_test test_public_key_readable
run_test test_public_key_missing
run_test test_ssh_check_unreachable
run_test test_ssh_wait_ready_timeout
run_test test_ssh_gate_ready_timeout
run_test test_qemu_netdev_arg
run_test test_find_available_port
run_test test_port_file_management
run_test test_port_load_missing

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_RUN} total"

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
echo "All tests passed."
