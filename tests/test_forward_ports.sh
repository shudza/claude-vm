#!/usr/bin/env bash
# Tests for FORWARD_PORTS — validation, per-project storage, and hostfwd generation
# Run: bash tests/test_forward_ports.sh
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

_reset_env() {
    unset VM_RAM VM_CPUS SSH_PORT_BASE BASE_IMAGE_URL BASE_IMAGE_NAME FORWARD_PORTS FLAVOR VM_USER 2>/dev/null || true
}

# Source config.sh at top level so declare -A creates global associative arrays
source "$PROJECT_DIR/lib/config.sh"

_init_config() {
    _reset_env
    export CLAUDE_VM_DIR="$TEST_DIR/$1"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"
    mkdir -p "$CLAUDE_VM_DIR"
    load_config
}

# ─── Validation tests (_validate_forward_ports) ─────────────────────────────

test_validate_single_port() {
    _init_config "val-single"
    if _validate_forward_ports "8080" 2>/dev/null; then
        pass "accepts single port"
    else
        fail "single port" "rejected 8080"
    fi
    _reset_env
}

test_validate_host_guest_pair() {
    _init_config "val-pair"
    if _validate_forward_ports "3000:8080" 2>/dev/null; then
        pass "accepts host:guest pair"
    else
        fail "host:guest pair" "rejected 3000:8080"
    fi
    _reset_env
}

test_validate_simple_range() {
    _init_config "val-range"
    if _validate_forward_ports "9000-9005" 2>/dev/null; then
        pass "accepts simple range"
    else
        fail "simple range" "rejected 9000-9005"
    fi
    _reset_env
}

test_validate_mapped_range() {
    _init_config "val-mapped-range"
    if _validate_forward_ports "5000-5003:6000-6003" 2>/dev/null; then
        pass "accepts mapped range"
    else
        fail "mapped range" "rejected 5000-5003:6000-6003"
    fi
    _reset_env
}

test_validate_comma_separated() {
    _init_config "val-csv"
    if _validate_forward_ports "8080,3000:3000,9000-9002" 2>/dev/null; then
        pass "accepts comma-separated specs"
    else
        fail "comma-separated" "rejected mixed specs"
    fi
    _reset_env
}

test_validate_rejects_invalid_format() {
    _init_config "val-bad-fmt"
    if _validate_forward_ports "abc" 2>/dev/null; then
        fail "rejects non-numeric" "accepted abc"
    else
        pass "rejects non-numeric port spec"
    fi
    _reset_env
}

test_validate_rejects_port_zero() {
    _init_config "val-zero"
    if _validate_forward_ports "0" 2>/dev/null; then
        fail "rejects port 0" "accepted 0"
    else
        pass "rejects port 0"
    fi
    _reset_env
}

test_validate_rejects_port_over_65535() {
    _init_config "val-over"
    if _validate_forward_ports "70000" 2>/dev/null; then
        fail "rejects port >65535" "accepted 70000"
    else
        pass "rejects port >65535"
    fi
    _reset_env
}

test_validate_rejects_inverted_range() {
    _init_config "val-invert"
    if _validate_forward_ports "9005-9000" 2>/dev/null; then
        fail "rejects inverted range" "accepted 9005-9000"
    else
        pass "rejects inverted range (start > end)"
    fi
    _reset_env
}

test_validate_rejects_range_over_100() {
    _init_config "val-big-range"
    if _validate_forward_ports "8000-8200" 2>/dev/null; then
        fail "rejects range >100" "accepted 200-port range"
    else
        pass "rejects range exceeding 100 ports"
    fi
    _reset_env
}

test_validate_rejects_unequal_mapped_range() {
    _init_config "val-unequal"
    if _validate_forward_ports "5000-5003:6000-6010" 2>/dev/null; then
        fail "rejects unequal mapped range" "accepted mismatched lengths"
    else
        pass "rejects mapped range with unequal lengths"
    fi
    _reset_env
}

test_validate_accepts_boundary_port() {
    _init_config "val-boundary"
    if _validate_forward_ports "1" 2>/dev/null && _validate_forward_ports "65535" 2>/dev/null; then
        pass "accepts boundary ports 1 and 65535"
    else
        fail "boundary ports" "rejected port 1 or 65535"
    fi
    _reset_env
}

test_validate_accepts_empty_string() {
    _init_config "val-empty"
    if _validate_forward_ports "" 2>/dev/null; then
        pass "accepts empty string"
    else
        fail "empty string" "rejected empty FORWARD_PORTS"
    fi
    _reset_env
}

test_validate_range_exactly_100() {
    _init_config "val-100"
    if _validate_forward_ports "8000-8100" 2>/dev/null; then
        pass "accepts range of exactly 100 ports"
    else
        fail "range of 100" "rejected 8000-8100"
    fi
    _reset_env
}

# ─── Per-project storage tests ──────────────────────────────────────────────

test_set_and_get_project_ports() {
    _init_config "store-set-get"
    local project_dir="$TEST_DIR/project-a"
    mkdir -p "$project_dir"

    set_project_forward_ports "$project_dir" "8080,3000"
    local result
    result="$(get_project_forward_ports "$project_dir")"

    if [[ "$result" == "8080,3000" ]]; then
        pass "set/get round-trips port spec"
    else
        fail "set/get round-trip" "expected '8080,3000', got '$result'"
    fi
    _reset_env
}

test_clear_project_ports() {
    _init_config "store-clear"
    local project_dir="$TEST_DIR/project-clear"
    mkdir -p "$project_dir"

    set_project_forward_ports "$project_dir" "8080"
    set_project_forward_ports "$project_dir" ""
    local result
    result="$(get_project_forward_ports "$project_dir")"

    if [[ -z "$result" ]]; then
        pass "clearing ports removes sidecar file"
    else
        fail "clear ports" "expected empty, got '$result'"
    fi
    _reset_env
}

test_get_falls_back_to_global() {
    _reset_env
    export CLAUDE_VM_DIR="$TEST_DIR/store-fallback"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"
    mkdir -p "$CLAUDE_VM_DIR"
    cat > "$CLAUDE_VM_CONFIG" << 'EOF'
FORWARD_PORTS="4000"
EOF

    source "$PROJECT_DIR/lib/config.sh"
    load_config

    local project_dir="$TEST_DIR/project-no-sidecar"
    mkdir -p "$project_dir"

    local result
    result="$(get_project_forward_ports "$project_dir")"

    if [[ "$result" == "4000" ]]; then
        pass "falls back to global FORWARD_PORTS when no sidecar"
    else
        fail "global fallback" "expected '4000', got '$result'"
    fi
    _reset_env
}

test_project_ports_isolate_between_projects() {
    _init_config "store-isolate"
    local proj_a="$TEST_DIR/proj-iso-a"
    local proj_b="$TEST_DIR/proj-iso-b"
    mkdir -p "$proj_a" "$proj_b"

    set_project_forward_ports "$proj_a" "8080"
    set_project_forward_ports "$proj_b" "9090"

    local result_a result_b
    result_a="$(get_project_forward_ports "$proj_a")"
    result_b="$(get_project_forward_ports "$proj_b")"

    if [[ "$result_a" == "8080" && "$result_b" == "9090" ]]; then
        pass "per-project ports are isolated"
    else
        fail "port isolation" "proj_a='$result_a' proj_b='$result_b'"
    fi
    _reset_env
}

test_set_config_validates_forward_ports() {
    _init_config "store-validate"

    if set_config_value "FORWARD_PORTS" "abc" 2>/dev/null; then
        fail "set_config_value rejects invalid FORWARD_PORTS" "accepted 'abc'"
    else
        pass "set_config_value rejects invalid FORWARD_PORTS"
    fi
    _reset_env
}

test_set_config_accepts_valid_forward_ports() {
    _init_config "store-valid"

    if set_config_value "FORWARD_PORTS" "8080,3000:3000" >/dev/null 2>&1; then
        pass "set_config_value accepts valid FORWARD_PORTS"
    else
        fail "set_config_value valid" "rejected '8080,3000:3000'"
    fi
    _reset_env
}

test_set_config_clears_forward_ports() {
    _init_config "store-clear-cfg"

    set_config_value "FORWARD_PORTS" "8080" >/dev/null 2>&1
    set_config_value "FORWARD_PORTS" "" >/dev/null 2>&1

    local result
    result="$(get_project_forward_ports "$PWD")"

    if [[ -z "$result" ]]; then
        pass "set_config_value clears FORWARD_PORTS with empty string"
    else
        fail "clear via set_config_value" "expected empty, got '$result'"
    fi
    _reset_env
}

test_env_var_overrides_global_forward_ports() {
    _reset_env
    export CLAUDE_VM_DIR="$TEST_DIR/env-override"
    export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"
    mkdir -p "$CLAUDE_VM_DIR"
    cat > "$CLAUDE_VM_CONFIG" << 'EOF'
FORWARD_PORTS="4000"
EOF

    export FORWARD_PORTS="5000"

    source "$PROJECT_DIR/lib/config.sh"
    load_config

    if [[ "$FORWARD_PORTS" == "5000" ]]; then
        pass "env var FORWARD_PORTS overrides config file"
    else
        fail "env override" "expected '5000', got '$FORWARD_PORTS'"
    fi
    _reset_env
}

# ─── _build_hostfwd_args tests (launch.sh) ──────────────────────────────────

source "$PROJECT_DIR/lib/launch.sh"

test_hostfwd_ssh_only() {
    _init_config "hfwd-ssh"
    local result
    result="$(_build_hostfwd_args 10022 "")"

    if [[ "$result" == "hostfwd=tcp::10022-:22" ]]; then
        pass "SSH-only hostfwd"
    else
        fail "SSH-only hostfwd" "got '$result'"
    fi
    _reset_env
}

test_hostfwd_single_port() {
    _init_config "hfwd-single"
    local result
    result="$(_build_hostfwd_args 10022 "8080")"
    local expected="hostfwd=tcp::10022-:22,hostfwd=tcp::8080-:8080"

    if [[ "$result" == "$expected" ]]; then
        pass "hostfwd with single port"
    else
        fail "hostfwd single port" "expected '$expected', got '$result'"
    fi
    _reset_env
}

test_hostfwd_host_guest_pair() {
    _init_config "hfwd-pair"
    local result
    result="$(_build_hostfwd_args 10022 "3000:8080")"
    local expected="hostfwd=tcp::10022-:22,hostfwd=tcp::3000-:8080"

    if [[ "$result" == "$expected" ]]; then
        pass "hostfwd with host:guest pair"
    else
        fail "hostfwd host:guest" "expected '$expected', got '$result'"
    fi
    _reset_env
}

test_hostfwd_simple_range() {
    _init_config "hfwd-range"
    local result
    result="$(_build_hostfwd_args 10022 "9000-9002")"
    local expected="hostfwd=tcp::10022-:22,hostfwd=tcp::9000-:9000,hostfwd=tcp::9001-:9001,hostfwd=tcp::9002-:9002"

    if [[ "$result" == "$expected" ]]; then
        pass "hostfwd with simple range"
    else
        fail "hostfwd simple range" "expected '$expected', got '$result'"
    fi
    _reset_env
}

test_hostfwd_mapped_range() {
    _init_config "hfwd-mapped"
    local result
    result="$(_build_hostfwd_args 10022 "5000-5002:6000-6002")"
    local expected="hostfwd=tcp::10022-:22,hostfwd=tcp::5000-:6000,hostfwd=tcp::5001-:6001,hostfwd=tcp::5002-:6002"

    if [[ "$result" == "$expected" ]]; then
        pass "hostfwd with mapped range"
    else
        fail "hostfwd mapped range" "expected '$expected', got '$result'"
    fi
    _reset_env
}

test_hostfwd_multiple_specs() {
    _init_config "hfwd-multi"
    local result
    result="$(_build_hostfwd_args 10022 "8080,3000:3000,9000-9001")"
    local expected="hostfwd=tcp::10022-:22,hostfwd=tcp::8080-:8080,hostfwd=tcp::3000-:3000,hostfwd=tcp::9000-:9000,hostfwd=tcp::9001-:9001"

    if [[ "$result" == "$expected" ]]; then
        pass "hostfwd with multiple mixed specs"
    else
        fail "hostfwd multi specs" "expected '$expected', got '$result'"
    fi
    _reset_env
}

# ─── Run ──────────────────────────────────────────────────────────────────────

echo "=== claude-vm FORWARD_PORTS tests ==="
echo ""

echo "--- Validation ---"
run_test test_validate_single_port
run_test test_validate_host_guest_pair
run_test test_validate_simple_range
run_test test_validate_mapped_range
run_test test_validate_comma_separated
run_test test_validate_rejects_invalid_format
run_test test_validate_rejects_port_zero
run_test test_validate_rejects_port_over_65535
run_test test_validate_rejects_inverted_range
run_test test_validate_rejects_range_over_100
run_test test_validate_rejects_unequal_mapped_range
run_test test_validate_accepts_boundary_port
run_test test_validate_accepts_empty_string
run_test test_validate_range_exactly_100

echo ""
echo "--- Per-project storage ---"
run_test test_set_and_get_project_ports
run_test test_clear_project_ports
run_test test_get_falls_back_to_global
run_test test_project_ports_isolate_between_projects
run_test test_set_config_validates_forward_ports
run_test test_set_config_accepts_valid_forward_ports
run_test test_set_config_clears_forward_ports
run_test test_env_var_overrides_global_forward_ports

echo ""
echo "--- hostfwd generation ---"
run_test test_hostfwd_ssh_only
run_test test_hostfwd_single_port
run_test test_hostfwd_host_guest_pair
run_test test_hostfwd_simple_range
run_test test_hostfwd_mapped_range
run_test test_hostfwd_multiple_specs

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_RUN} total"

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
echo "All tests passed."
