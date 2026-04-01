#!/usr/bin/env bash
# Tests for lib/claude-code.sh — Claude Code invocation and credential forwarding
# Run: bash tests/test_claude_code.sh
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

# ─── Setup ───────────────────────────────────────────────────────────────────

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Set up SSH module env (claude-code.sh sources ssh.sh)
export CLAUDE_VM_SSH_KEY="${TEST_DIR}/test_key"
export CLAUDE_VM_SSH_PORT="29999"
export CLAUDE_VM_SSH_USER="testuser"
export CLAUDE_VM_DIR="$TEST_DIR"

# Generate a dummy SSH key so ssh.sh doesn't complain
ssh-keygen -t ed25519 -f "$TEST_DIR/test_key" -N "" -q

source "$PROJECT_DIR/lib/claude-code.sh"

# ─── Auth Detection Tests ───────────────────────────────────────────────────

test_detect_auth_api_key_only() {
    local orig_key="${ANTHROPIC_API_KEY:-}"
    local orig_dir="${CLAUDE_CONFIG_DIR:-}"
    export ANTHROPIC_API_KEY="sk-ant-test-key-123"
    export CLAUDE_CONFIG_DIR="$TEST_DIR/nonexistent_dir"

    local method
    method=$(detect_auth_method)
    if [[ "$method" == "api_key" ]]; then
        pass "detect_auth: api_key only"
    else
        fail "detect_auth: api_key only" "got '$method'"
    fi

    # Restore
    if [[ -n "$orig_key" ]]; then export ANTHROPIC_API_KEY="$orig_key"; else unset ANTHROPIC_API_KEY; fi
    if [[ -n "$orig_dir" ]]; then export CLAUDE_CONFIG_DIR="$orig_dir"; else unset CLAUDE_CONFIG_DIR 2>/dev/null || true; fi
}

test_detect_auth_config_dir_only() {
    local orig_key="${ANTHROPIC_API_KEY:-}"
    local orig_dir="${CLAUDE_CONFIG_DIR:-}"
    unset ANTHROPIC_API_KEY 2>/dev/null || true

    # Create a fake claude config dir with content
    mkdir -p "$TEST_DIR/fake_claude"
    echo "fake-token" > "$TEST_DIR/fake_claude/auth.json"
    export CLAUDE_CONFIG_DIR="$TEST_DIR/fake_claude"

    local method
    method=$(detect_auth_method)
    if [[ "$method" == "config_dir" ]]; then
        pass "detect_auth: config_dir only"
    else
        fail "detect_auth: config_dir only" "got '$method'"
    fi

    # Restore
    if [[ -n "$orig_key" ]]; then export ANTHROPIC_API_KEY="$orig_key"; else unset ANTHROPIC_API_KEY 2>/dev/null || true; fi
    if [[ -n "$orig_dir" ]]; then export CLAUDE_CONFIG_DIR="$orig_dir"; else unset CLAUDE_CONFIG_DIR 2>/dev/null || true; fi
}

test_detect_auth_both() {
    local orig_key="${ANTHROPIC_API_KEY:-}"
    local orig_dir="${CLAUDE_CONFIG_DIR:-}"
    export ANTHROPIC_API_KEY="sk-ant-test-key-123"

    mkdir -p "$TEST_DIR/fake_claude2"
    echo "fake-token" > "$TEST_DIR/fake_claude2/auth.json"
    export CLAUDE_CONFIG_DIR="$TEST_DIR/fake_claude2"

    local method
    method=$(detect_auth_method)
    if [[ "$method" == "both" ]]; then
        pass "detect_auth: both methods available"
    else
        fail "detect_auth: both methods" "got '$method'"
    fi

    # Restore
    if [[ -n "$orig_key" ]]; then export ANTHROPIC_API_KEY="$orig_key"; else unset ANTHROPIC_API_KEY 2>/dev/null || true; fi
    if [[ -n "$orig_dir" ]]; then export CLAUDE_CONFIG_DIR="$orig_dir"; else unset CLAUDE_CONFIG_DIR 2>/dev/null || true; fi
}

test_detect_auth_none() {
    local orig_key="${ANTHROPIC_API_KEY:-}"
    local orig_dir="${CLAUDE_CONFIG_DIR:-}"
    unset ANTHROPIC_API_KEY 2>/dev/null || true
    export CLAUDE_CONFIG_DIR="$TEST_DIR/nonexistent_dir_xyz"

    local method
    method=$(detect_auth_method)
    if [[ "$method" == "none" ]]; then
        pass "detect_auth: no auth available"
    else
        fail "detect_auth: no auth" "got '$method'"
    fi

    # Restore
    if [[ -n "$orig_key" ]]; then export ANTHROPIC_API_KEY="$orig_key"; else unset ANTHROPIC_API_KEY 2>/dev/null || true; fi
    if [[ -n "$orig_dir" ]]; then export CLAUDE_CONFIG_DIR="$orig_dir"; else unset CLAUDE_CONFIG_DIR 2>/dev/null || true; fi
}

# ─── has_api_key Tests ───────────────────────────────────────────────────────

test_has_api_key_set() {
    local orig="${ANTHROPIC_API_KEY:-}"
    export ANTHROPIC_API_KEY="sk-ant-test"
    if has_api_key; then
        pass "has_api_key returns true when set"
    else
        fail "has_api_key" "returned false when ANTHROPIC_API_KEY is set"
    fi
    if [[ -n "$orig" ]]; then export ANTHROPIC_API_KEY="$orig"; else unset ANTHROPIC_API_KEY 2>/dev/null || true; fi
}

test_has_api_key_unset() {
    local orig="${ANTHROPIC_API_KEY:-}"
    unset ANTHROPIC_API_KEY 2>/dev/null || true
    if has_api_key; then
        fail "has_api_key" "returned true when ANTHROPIC_API_KEY is unset"
    else
        pass "has_api_key returns false when unset"
    fi
    if [[ -n "$orig" ]]; then export ANTHROPIC_API_KEY="$orig"; else unset ANTHROPIC_API_KEY 2>/dev/null || true; fi
}

test_has_api_key_empty() {
    local orig="${ANTHROPIC_API_KEY:-}"
    export ANTHROPIC_API_KEY=""
    if has_api_key; then
        fail "has_api_key" "returned true when ANTHROPIC_API_KEY is empty"
    else
        pass "has_api_key returns false when empty string"
    fi
    if [[ -n "$orig" ]]; then export ANTHROPIC_API_KEY="$orig"; else unset ANTHROPIC_API_KEY 2>/dev/null || true; fi
}

# ─── has_claude_config_dir Tests ─────────────────────────────────────────────

test_has_config_dir_exists() {
    local orig="${CLAUDE_CONFIG_DIR:-}"
    mkdir -p "$TEST_DIR/claude_cfg"
    echo "data" > "$TEST_DIR/claude_cfg/token"
    export CLAUDE_CONFIG_DIR="$TEST_DIR/claude_cfg"
    if has_claude_config_dir; then
        pass "has_claude_config_dir: true when dir exists with files"
    else
        fail "has_claude_config_dir" "returned false for populated dir"
    fi
    if [[ -n "$orig" ]]; then export CLAUDE_CONFIG_DIR="$orig"; else unset CLAUDE_CONFIG_DIR 2>/dev/null || true; fi
}

test_has_config_dir_empty() {
    local orig="${CLAUDE_CONFIG_DIR:-}"
    mkdir -p "$TEST_DIR/empty_claude"
    export CLAUDE_CONFIG_DIR="$TEST_DIR/empty_claude"
    if has_claude_config_dir; then
        fail "has_claude_config_dir" "returned true for empty dir"
    else
        pass "has_claude_config_dir: false when dir is empty"
    fi
    if [[ -n "$orig" ]]; then export CLAUDE_CONFIG_DIR="$orig"; else unset CLAUDE_CONFIG_DIR 2>/dev/null || true; fi
}

test_has_config_dir_missing() {
    local orig="${CLAUDE_CONFIG_DIR:-}"
    export CLAUDE_CONFIG_DIR="$TEST_DIR/no_such_dir_abcdef"
    if has_claude_config_dir; then
        fail "has_claude_config_dir" "returned true for nonexistent dir"
    else
        pass "has_claude_config_dir: false when dir doesn't exist"
    fi
    if [[ -n "$orig" ]]; then export CLAUDE_CONFIG_DIR="$orig"; else unset CLAUDE_CONFIG_DIR 2>/dev/null || true; fi
}

# ─── Constants / Config Tests ────────────────────────────────────────────────

test_guest_workspace_path() {
    if [[ "$GUEST_WORKSPACE" == "/workspace" ]]; then
        pass "GUEST_WORKSPACE is /workspace"
    else
        fail "GUEST_WORKSPACE" "got '$GUEST_WORKSPACE'"
    fi
}

test_sandbox_flags_include_skip_permissions() {
    if [[ "$CLAUDE_SANDBOX_FLAGS" == *"--dangerously-skip-permissions"* ]]; then
        pass "CLAUDE_SANDBOX_FLAGS includes --dangerously-skip-permissions"
    else
        fail "CLAUDE_SANDBOX_FLAGS" "missing --dangerously-skip-permissions: '$CLAUDE_SANDBOX_FLAGS'"
    fi
}

test_guest_claude_dir() {
    if [[ "$GUEST_CLAUDE_DIR" == "/home/claude/.claude" ]]; then
        pass "GUEST_CLAUDE_DIR is /home/claude/.claude"
    else
        fail "GUEST_CLAUDE_DIR" "got '$GUEST_CLAUDE_DIR'"
    fi
}

# ─── forward_credentials Tests (without live SSH) ───────────────────────────

test_forward_credentials_no_auth() {
    local orig_key="${ANTHROPIC_API_KEY:-}"
    local orig_dir="${CLAUDE_CONFIG_DIR:-}"
    unset ANTHROPIC_API_KEY 2>/dev/null || true
    export CLAUDE_CONFIG_DIR="$TEST_DIR/nonexistent"

    if forward_credentials "29999" "$TEST_DIR/test_key" "testuser" 2>/dev/null; then
        fail "forward_credentials with no auth" "should return 1"
    else
        pass "forward_credentials returns 1 when no auth available"
    fi

    if [[ -n "$orig_key" ]]; then export ANTHROPIC_API_KEY="$orig_key"; else unset ANTHROPIC_API_KEY 2>/dev/null || true; fi
    if [[ -n "$orig_dir" ]]; then export CLAUDE_CONFIG_DIR="$orig_dir"; else unset CLAUDE_CONFIG_DIR 2>/dev/null || true; fi
}

test_run_claude_command_no_prompt() {
    if run_claude_command "29999" "$TEST_DIR/test_key" "testuser" "" 2>/dev/null; then
        fail "run_claude_command with empty prompt" "should return 1"
    else
        pass "run_claude_command returns 1 with empty prompt"
    fi
}

# ─── Run ─────────────────────────────────────────────────────────────────────

echo "=== claude-vm Claude Code module tests ==="
echo ""

echo "--- Auth Detection ---"
run_test test_detect_auth_api_key_only
run_test test_detect_auth_config_dir_only
run_test test_detect_auth_both
run_test test_detect_auth_none

echo ""
echo "--- has_api_key ---"
run_test test_has_api_key_set
run_test test_has_api_key_unset
run_test test_has_api_key_empty

echo ""
echo "--- has_claude_config_dir ---"
run_test test_has_config_dir_exists
run_test test_has_config_dir_empty
run_test test_has_config_dir_missing

echo ""
echo "--- Constants ---"
run_test test_guest_workspace_path
run_test test_sandbox_flags_include_skip_permissions
run_test test_guest_claude_dir

echo ""
echo "--- Credential Forwarding ---"
run_test test_forward_credentials_no_auth
run_test test_run_claude_command_no_prompt

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_RUN} total"

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
echo "All tests passed."
