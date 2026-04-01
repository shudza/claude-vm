#!/usr/bin/env bash
# Tests for claude-vm config — resource allocation and configuration
# Run: bash tests/test_config.sh
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

# Helper: reset config state for each test
_reset_config_env() {
    unset VM_RAM VM_CPUS SSH_PORT_BASE BASE_IMAGE_URL BASE_IMAGE_NAME 2>/dev/null || true
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_defaults_without_config_file() {
    _reset_config_env
    export CLAUDE_VM_DIR="$TEST_DIR/test-defaults"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    source "$PROJECT_DIR/lib/config.sh"
    load_config

    if [[ "$VM_RAM" == "4G" ]]; then
        pass "default RAM is 4G"
    else
        fail "default RAM" "expected 4G, got $VM_RAM"
    fi

    if [[ "$VM_CPUS" == "2" ]]; then
        pass "default CPUs is 2"
    else
        fail "default CPUs" "expected 2, got $VM_CPUS"
    fi

    if [[ "$SSH_PORT_BASE" == "10022" ]]; then
        pass "default SSH port base is 10022"
    else
        fail "default SSH port base" "expected 10022, got $SSH_PORT_BASE"
    fi
    _reset_config_env
}

test_config_file_overrides_defaults() {
    _reset_config_env
    export CLAUDE_VM_DIR="$TEST_DIR/test-config-override"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    mkdir -p "$CLAUDE_VM_DIR"
    cat > "$CLAUDE_VM_CONFIG" << 'EOF'
VM_RAM="8G"
VM_CPUS="4"
SSH_PORT_BASE="20022"
EOF

    source "$PROJECT_DIR/lib/config.sh"
    load_config

    if [[ "$VM_RAM" == "8G" ]]; then
        pass "config file overrides RAM to 8G"
    else
        fail "config file RAM override" "expected 8G, got $VM_RAM"
    fi

    if [[ "$VM_CPUS" == "4" ]]; then
        pass "config file overrides CPUs to 4"
    else
        fail "config file CPUs override" "expected 4, got $VM_CPUS"
    fi

    if [[ "$SSH_PORT_BASE" == "20022" ]]; then
        pass "config file overrides SSH port base to 20022"
    else
        fail "config file SSH port override" "expected 20022, got $SSH_PORT_BASE"
    fi
    _reset_config_env
}

test_env_vars_override_config_file() {
    export CLAUDE_VM_DIR="$TEST_DIR/test-env-override"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    mkdir -p "$CLAUDE_VM_DIR"
    cat > "$CLAUDE_VM_CONFIG" << 'EOF'
VM_RAM="8G"
VM_CPUS="4"
EOF

    # Set env vars that should take priority over config file
    export VM_RAM="16G"
    export VM_CPUS="8"

    source "$PROJECT_DIR/lib/config.sh"
    load_config

    if [[ "$VM_RAM" == "16G" ]]; then
        pass "env var VM_RAM overrides config file"
    else
        fail "env var RAM override" "expected 16G, got $VM_RAM"
    fi

    if [[ "$VM_CPUS" == "8" ]]; then
        pass "env var VM_CPUS overrides config file"
    else
        fail "env var CPUs override" "expected 8, got $VM_CPUS"
    fi
    _reset_config_env
}

test_env_vars_override_defaults() {
    export CLAUDE_VM_DIR="$TEST_DIR/test-env-defaults"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"
    # No config file exists

    export VM_RAM="32G"
    export VM_CPUS="16"

    source "$PROJECT_DIR/lib/config.sh"
    load_config

    if [[ "$VM_RAM" == "32G" ]]; then
        pass "env var VM_RAM overrides default"
    else
        fail "env var override default RAM" "expected 32G, got $VM_RAM"
    fi

    if [[ "$VM_CPUS" == "16" ]]; then
        pass "env var VM_CPUS overrides default"
    else
        fail "env var override default CPUs" "expected 16, got $VM_CPUS"
    fi
    _reset_config_env
}

test_partial_config_file() {
    _reset_config_env
    export CLAUDE_VM_DIR="$TEST_DIR/test-partial"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    mkdir -p "$CLAUDE_VM_DIR"
    # Only override RAM, leave CPUs at default
    cat > "$CLAUDE_VM_CONFIG" << 'EOF'
VM_RAM="6G"
EOF

    source "$PROJECT_DIR/lib/config.sh"
    load_config

    if [[ "$VM_RAM" == "6G" ]]; then
        pass "partial config overrides RAM"
    else
        fail "partial config RAM" "expected 6G, got $VM_RAM"
    fi

    if [[ "$VM_CPUS" == "2" ]]; then
        pass "partial config leaves CPUs at default"
    else
        fail "partial config CPUs default" "expected 2, got $VM_CPUS"
    fi
    _reset_config_env
}

test_set_config_value_creates_file() {
    _reset_config_env
    export CLAUDE_VM_DIR="$TEST_DIR/test-set-create"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    source "$PROJECT_DIR/lib/config.sh"
    set_config_value "VM_RAM" "12G" >/dev/null

    if [[ -f "$CLAUDE_VM_CONFIG" ]]; then
        pass "set_config_value creates config file"
    else
        fail "config file creation" "file not found"
        return
    fi

    if grep -q 'VM_RAM="12G"' "$CLAUDE_VM_CONFIG"; then
        pass "set_config_value writes correct value"
    else
        fail "config value written" "VM_RAM=12G not found in file"
    fi
    _reset_config_env
}

test_set_config_value_updates_existing() {
    _reset_config_env
    export CLAUDE_VM_DIR="$TEST_DIR/test-set-update"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    mkdir -p "$CLAUDE_VM_DIR"
    cat > "$CLAUDE_VM_CONFIG" << 'EOF'
VM_RAM="4G"
VM_CPUS="2"
EOF

    source "$PROJECT_DIR/lib/config.sh"
    set_config_value "VM_RAM" "16G" >/dev/null

    if grep -q 'VM_RAM="16G"' "$CLAUDE_VM_CONFIG"; then
        pass "set_config_value updates existing key"
    else
        fail "config value update" "VM_RAM=16G not found"
    fi

    if grep -q 'VM_CPUS="2"' "$CLAUDE_VM_CONFIG"; then
        pass "set_config_value preserves other keys"
    else
        fail "other keys preserved" "VM_CPUS=2 not found"
    fi

    # Should not have duplicate entries
    local count
    count=$(grep -c 'VM_RAM=' "$CLAUDE_VM_CONFIG")
    if [[ "$count" == "1" ]]; then
        pass "set_config_value does not create duplicates"
    else
        fail "no duplicates" "found $count VM_RAM entries"
    fi
    _reset_config_env
}

test_set_config_rejects_invalid_key() {
    _reset_config_env
    export CLAUDE_VM_DIR="$TEST_DIR/test-set-invalid-key"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    source "$PROJECT_DIR/lib/config.sh"

    if set_config_value "BOGUS_KEY" "value" 2>/dev/null; then
        fail "rejects invalid key" "did not return error"
    else
        pass "rejects unknown config key"
    fi
    _reset_config_env
}

test_set_config_validates_ram_format() {
    _reset_config_env
    export CLAUDE_VM_DIR="$TEST_DIR/test-validate-ram"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    source "$PROJECT_DIR/lib/config.sh"

    if set_config_value "VM_RAM" "8G" >/dev/null 2>&1; then
        pass "accepts valid RAM format 8G"
    else
        fail "valid RAM format" "rejected 8G"
    fi

    if set_config_value "VM_RAM" "512M" >/dev/null 2>&1; then
        pass "accepts valid RAM format 512M"
    else
        fail "valid RAM format" "rejected 512M"
    fi

    if set_config_value "VM_RAM" "notram" 2>/dev/null; then
        fail "rejects invalid RAM format" "accepted notram"
    else
        pass "rejects invalid RAM format"
    fi
    _reset_config_env
}

test_set_config_validates_cpu_count() {
    _reset_config_env
    export CLAUDE_VM_DIR="$TEST_DIR/test-validate-cpus"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    source "$PROJECT_DIR/lib/config.sh"

    if set_config_value "VM_CPUS" "4" >/dev/null 2>&1; then
        pass "accepts valid CPU count"
    else
        fail "valid CPU count" "rejected 4"
    fi

    if set_config_value "VM_CPUS" "0" 2>/dev/null; then
        fail "rejects zero CPUs" "accepted 0"
    else
        pass "rejects zero CPU count"
    fi

    if set_config_value "VM_CPUS" "abc" 2>/dev/null; then
        fail "rejects non-numeric CPUs" "accepted abc"
    else
        pass "rejects non-numeric CPU count"
    fi
    _reset_config_env
}

test_show_config_output() {
    _reset_config_env
    export CLAUDE_VM_DIR="$TEST_DIR/test-show"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    mkdir -p "$CLAUDE_VM_DIR"
    cat > "$CLAUDE_VM_CONFIG" << 'EOF'
VM_RAM="8G"
VM_CPUS="4"
EOF

    source "$PROJECT_DIR/lib/config.sh"
    local output
    output=$(show_config)

    if echo "$output" | grep -q 'VM_RAM="8G"'; then
        pass "show_config displays RAM from config file"
    else
        fail "show_config RAM" "8G not in output"
    fi

    if echo "$output" | grep -q 'VM_CPUS="4"'; then
        pass "show_config displays CPUs from config file"
    else
        fail "show_config CPUs" "4 not in output"
    fi

    if echo "$output" | grep -q "Status: loaded"; then
        pass "show_config reports config file loaded"
    else
        fail "show_config status" "loaded status not shown"
    fi
    _reset_config_env
}

test_launch_uses_config_values() {
    # Verify that load_config picks up values that launch.sh would use
    _reset_config_env
    export CLAUDE_VM_DIR="$TEST_DIR/test-launch-config"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    mkdir -p "$CLAUDE_VM_DIR"
    cat > "$CLAUDE_VM_CONFIG" << 'EOF'
VM_RAM="8G"
VM_CPUS="6"
EOF

    source "$PROJECT_DIR/lib/config.sh"
    load_config

    if [[ "$VM_RAM" == "8G" && "$VM_CPUS" == "6" ]]; then
        pass "launch would use config file values (8G RAM, 6 CPUs)"
    else
        fail "launch config values" "got VM_RAM=$VM_RAM VM_CPUS=$VM_CPUS"
    fi
    _reset_config_env
}

test_config_priority_full_chain() {
    # Test the full priority chain: defaults < config file < env vars
    export CLAUDE_VM_DIR="$TEST_DIR/test-priority"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"

    mkdir -p "$CLAUDE_VM_DIR"
    cat > "$CLAUDE_VM_CONFIG" << 'EOF'
VM_RAM="8G"
VM_CPUS="4"
SSH_PORT_BASE="15022"
EOF

    # Override only RAM via env var; clear others
    export VM_RAM="32G"
    unset VM_CPUS SSH_PORT_BASE 2>/dev/null || true

    source "$PROJECT_DIR/lib/config.sh"
    load_config

    # RAM: env var wins
    if [[ "$VM_RAM" == "32G" ]]; then
        pass "priority: env var (32G) beats config file (8G) for RAM"
    else
        fail "priority RAM" "expected 32G, got $VM_RAM"
    fi

    # CPUs: config file wins over default
    if [[ "$VM_CPUS" == "4" ]]; then
        pass "priority: config file (4) beats default (2) for CPUs"
    else
        fail "priority CPUs" "expected 4, got $VM_CPUS"
    fi

    # SSH port: config file wins over default
    if [[ "$SSH_PORT_BASE" == "15022" ]]; then
        pass "priority: config file (15022) beats default (10022) for SSH port"
    else
        fail "priority SSH port" "expected 15022, got $SSH_PORT_BASE"
    fi
    _reset_config_env
}

# ─── Run ──────────────────────────────────────────────────────────────────────

echo "=== claude-vm config tests ==="
echo ""

run_test test_defaults_without_config_file
run_test test_config_file_overrides_defaults
run_test test_env_vars_override_config_file
run_test test_env_vars_override_defaults
run_test test_partial_config_file
run_test test_set_config_value_creates_file
run_test test_set_config_value_updates_existing
run_test test_set_config_rejects_invalid_key
run_test test_set_config_validates_ram_format
run_test test_set_config_validates_cpu_count
run_test test_show_config_output
run_test test_launch_uses_config_values
run_test test_config_priority_full_chain

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_RUN} total"

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
echo "All tests passed."
