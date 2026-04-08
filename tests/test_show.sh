#!/usr/bin/env bash
# Tests for claude-vm show command
# Run: bash tests/test_show.sh
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

source "$PROJECT_DIR/lib/config.sh"
source "$PROJECT_DIR/lib/launch.sh"

# Mock is_vm_running — default: not running
_mock_vm_running=false
is_vm_running() { $_mock_vm_running; }
get_project_ssh_port() { echo "10055"; }

_reset_env() {
    unset VM_RAM VM_CPUS SSH_PORT_BASE BASE_IMAGE_URL BASE_IMAGE_NAME FORWARD_PORTS FLAVOR VM_USER 2>/dev/null || true
    _mock_vm_running=false
}

_init() {
    _reset_env
    export CLAUDE_VM_DIR="$TEST_DIR/$1"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"
    mkdir -p "$CLAUDE_VM_DIR"
    load_config
}

# Source cmd_show from claude-vm (extract the function)
eval "$(sed -n '/^cmd_show()/,/^}/p' "$PROJECT_DIR/claude-vm")"

# ─── Tests ────────────────────────────────────────────────────────────────────

test_show_contains_qemu_command() {
    _init "show-qemu"
    local output
    output="$(cmd_show "$TEST_DIR/myproject" 2>/dev/null)"

    if echo "$output" | grep -q "^qemu-system-x86_64"; then
        pass "output contains qemu-system-x86_64 command"
    else
        fail "qemu command" "qemu-system-x86_64 not found in output"
    fi
    _reset_env
}

test_show_contains_ssh_command() {
    _init "show-ssh"
    local output
    output="$(cmd_show "$TEST_DIR/myproject" 2>/dev/null)"

    if echo "$output" | grep -q "^ssh "; then
        pass "output contains ssh command"
    else
        fail "ssh command" "ssh not found in output"
    fi
    _reset_env
}

test_show_includes_ram_and_cpus() {
    _reset_env
    export CLAUDE_VM_DIR="$TEST_DIR/show-resources"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"
    mkdir -p "$CLAUDE_VM_DIR"
    cat > "$CLAUDE_VM_CONFIG" << 'EOF'
VM_RAM="16G"
VM_CPUS="8"
EOF
    load_config

    local output
    output="$(cmd_show "$TEST_DIR/myproject" 2>/dev/null)"

    local ok=true
    if ! echo "$output" | grep -q "\-m 16G"; then
        fail "RAM in QEMU args" "-m 16G not found"; ok=false
    fi
    if ! echo "$output" | grep -q "\-smp 8"; then
        fail "CPUs in QEMU args" "-smp 8 not found"; ok=false
    fi
    if $ok; then
        pass "QEMU args reflect configured RAM and CPUs"
    fi
    _reset_env
}

test_show_includes_project_hash_in_name() {
    _init "show-hash"
    local project_dir="$TEST_DIR/myproject"
    mkdir -p "$project_dir"
    local expected_hash
    expected_hash="$(project_hash "$project_dir")"

    local output
    output="$(cmd_show "$project_dir" 2>/dev/null)"

    if echo "$output" | grep -q "claude-vm-${expected_hash}"; then
        pass "QEMU -name includes project hash"
    else
        fail "project hash in name" "claude-vm-${expected_hash} not found"
    fi
    _reset_env
}

test_show_uses_base_port_when_stopped() {
    _init "show-stopped"
    _mock_vm_running=false

    local output
    output="$(cmd_show "$TEST_DIR/myproject" 2>/dev/null)"

    if echo "$output" | grep -q "hostfwd=tcp::${SSH_PORT_BASE}-:22"; then
        pass "uses SSH_PORT_BASE when VM is stopped"
    else
        fail "base port when stopped" "hostfwd with port $SSH_PORT_BASE not found"
    fi
    _reset_env
}

test_show_uses_running_port_when_active() {
    _init "show-running"
    _mock_vm_running=true

    local output
    output="$(cmd_show "$TEST_DIR/myproject" 2>/dev/null)"

    if echo "$output" | grep -q "hostfwd=tcp::10055-:22"; then
        pass "uses actual SSH port when VM is running"
    else
        fail "running port" "hostfwd with port 10055 not found"
    fi
    _reset_env
}

test_show_includes_forward_ports() {
    _init "show-fwd"
    local project_dir="$TEST_DIR/project-fwd"
    mkdir -p "$project_dir"
    set_project_forward_ports "$project_dir" "8080,3000:3000"

    local output
    output="$(cmd_show "$project_dir" 2>/dev/null)"

    local ok=true
    if ! echo "$output" | grep -q "hostfwd=tcp::8080-:8080"; then
        fail "forward port 8080" "not found in output"; ok=false
    fi
    if ! echo "$output" | grep -q "hostfwd=tcp::3000-:3000"; then
        fail "forward port 3000:3000" "not found in output"; ok=false
    fi
    if $ok; then
        pass "QEMU args include FORWARD_PORTS"
    fi
    _reset_env
}

test_show_includes_kvm_accel() {
    _init "show-accel"
    local output
    output="$(cmd_show "$TEST_DIR/myproject" 2>/dev/null)"

    if echo "$output" | grep -q "accel="; then
        pass "QEMU args include acceleration type"
    else
        fail "acceleration" "accel= not found"
    fi
    _reset_env
}

test_show_ssh_includes_user() {
    _init "show-user"
    local output
    output="$(cmd_show "$TEST_DIR/myproject" 2>/dev/null)"

    if echo "$output" | grep -q "${VM_USER}@localhost"; then
        pass "SSH command includes user@localhost"
    else
        fail "ssh user" "${VM_USER}@localhost not found"
    fi
    _reset_env
}

test_show_has_section_headers() {
    _init "show-headers"
    local output
    output="$(cmd_show "$TEST_DIR/myproject" 2>/dev/null)"

    local ok=true
    if ! echo "$output" | grep -q "^# QEMU command"; then
        fail "QEMU header" "missing '# QEMU command'"; ok=false
    fi
    if ! echo "$output" | grep -q "^# SSH command"; then
        fail "SSH header" "missing '# SSH command'"; ok=false
    fi
    if $ok; then
        pass "output has section headers"
    fi
    _reset_env
}

test_show_snapshot_not_yet_created() {
    _init "show-nosnap"
    local project_dir="$TEST_DIR/project-nosnap"
    mkdir -p "$project_dir"

    local output
    output="$(cmd_show "$project_dir" 2>/dev/null)"

    if echo "$output" | grep -q "not yet created"; then
        pass "shows 'not yet created' when snapshot missing"
    else
        fail "missing snapshot note" "'not yet created' not found"
    fi
    _reset_env
}

# ─── Run ──────────────────────────────────────────────────────────────────────

echo "=== claude-vm show tests ==="
echo ""

run_test test_show_contains_qemu_command
run_test test_show_contains_ssh_command
run_test test_show_includes_ram_and_cpus
run_test test_show_includes_project_hash_in_name
run_test test_show_uses_base_port_when_stopped
run_test test_show_uses_running_port_when_active
run_test test_show_includes_forward_ports
run_test test_show_includes_kvm_accel
run_test test_show_ssh_includes_user
run_test test_show_has_section_headers
run_test test_show_snapshot_not_yet_created

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_RUN} total"

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
echo "All tests passed."
