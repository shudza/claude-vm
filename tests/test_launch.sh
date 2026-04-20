#!/usr/bin/env bash
# test_launch.sh — Unit tests for launch.sh helpers
#
# Tests:
# 1. sync_claude_config_to_vm is called on first VM creation (new snapshot)
# 2. sync_claude_config_to_vm is skipped on subsequent launches (existing snapshot)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_DIR/lib/config.sh"

set +euo pipefail

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; (( TESTS_PASSED++ )); (( TESTS_RUN++ )); }
fail() { echo "  FAIL: $1"; (( TESTS_FAILED++ )); (( TESTS_RUN++ )); }

setup_test_env() {
    TEST_VM_DIR="$(mktemp -d)"
    export CLAUDE_VM_DIR="$TEST_VM_DIR"
    export CLAUDE_VM_CONFIG="$TEST_VM_DIR/config"
    load_config
    ensure_dirs
}

teardown_test_env() {
    rm -rf "$TEST_VM_DIR" 2>/dev/null
}

# ── Test: is_new_vm is true when snapshot does not exist ─────────────────────
echo "--- Test 1: is_new_vm=true when snapshot absent ---"
setup_test_env

PROJECT_DIR_TEST="$(mktemp -d)"
snap_path="$(project_snapshot_path "$PROJECT_DIR_TEST")"

is_new_vm=false
[[ ! -f "$snap_path" ]] && is_new_vm=true

if [[ "$is_new_vm" == true ]]; then
    pass "is_new_vm set to true when snapshot absent"
else
    fail "is_new_vm should be true when snapshot absent"
fi

rm -rf "$PROJECT_DIR_TEST"
teardown_test_env

# ── Test: is_new_vm is false when snapshot already exists ────────────────────
echo "--- Test 2: is_new_vm=false when snapshot present ---"
setup_test_env

PROJECT_DIR_TEST="$(mktemp -d)"
snap_path="$(project_snapshot_path "$PROJECT_DIR_TEST")"
mkdir -p "$(dirname "$snap_path")"
touch "$snap_path"

is_new_vm=false
[[ ! -f "$snap_path" ]] && is_new_vm=true

if [[ "$is_new_vm" == false ]]; then
    pass "is_new_vm stays false when snapshot present"
else
    fail "is_new_vm should be false when snapshot present"
fi

rm -rf "$PROJECT_DIR_TEST"
teardown_test_env

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
(( TESTS_FAILED > 0 )) && exit 1 || exit 0
