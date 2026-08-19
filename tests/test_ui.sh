#!/usr/bin/env bash
# test_ui.sh — Tests for the console output layer (lib/ui.sh)
#
# Tests:
# 1. Plain mode: successful phase prints a permanent ✓ line
# 2. Plain mode: failed phase prints ✗ line with log path
# 3. Rich mode: successful phase leaves no committed output
# 4. Rich mode: failed phase commits a ✗ line
# 5. ui_init preserves a pre-existing EXIT trap
# 6. ui_progress redraws only in rich mode

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_DIR/lib/ui.sh"

# Disable strict mode for test runner
set +euo pipefail

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; (( TESTS_PASSED++ )); (( TESTS_RUN++ )); }
fail() { echo "  FAIL: $1"; (( TESTS_FAILED++ )); (( TESTS_RUN++ )); }

setup_test_env() {
    TEST_UI_DIR="$(mktemp -d)"
    UI_LOG="$TEST_UI_DIR/test.log"
}

teardown_test_env() {
    rm -rf "$TEST_UI_DIR" 2>/dev/null
}

# Strip carriage returns and ANSI escape sequences, keeping only committed lines
strip_transient() {
    sed 's/\r/\n/g' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -v '^$'
}

# ============================================================================
# Test 1: plain mode success prints permanent ✓ line
# ============================================================================
test_plain_success() {
    echo "Test 1: Plain mode success prints ✓ line"
    setup_test_env

    local output
    output=$(
        unset CLAUDE_VM_FORCE_TTY
        ui_init "$UI_LOG"
        ui_phase "doing the thing" true 2>&1
    )

    if echo "$output" | strip_transient | grep -q "✓ doing the thing"; then
        pass "plain success line committed"
    else
        fail "expected '✓ doing the thing', got: $output"
    fi

    teardown_test_env
}

# ============================================================================
# Test 2: plain mode failure prints ✗ line with log path
# ============================================================================
test_plain_failure() {
    echo "Test 2: Plain mode failure prints ✗ line and log path"
    setup_test_env

    local output
    output=$(
        unset CLAUDE_VM_FORCE_TTY
        ui_init "$UI_LOG"
        ui_phase "doing the thing" false 2>&1
    )

    local ok=true
    echo "$output" | strip_transient | grep -q "✗ doing the thing" || { fail "missing ✗ line: $output"; ok=false; }
    echo "$output" | grep -q "Log:" || { fail "missing log path: $output"; ok=false; }
    $ok && pass "plain failure line and log path committed"

    teardown_test_env
}

# ============================================================================
# Test 3: rich mode success leaves no committed output
# ============================================================================
test_rich_success_silent() {
    echo "Test 3: Rich mode success leaves nothing behind"
    setup_test_env

    local output committed
    output=$(
        export CLAUDE_VM_FORCE_TTY=true
        ui_init "$UI_LOG"
        ui_phase "doing the thing" true 2>&1
    )
    committed=$(echo "$output" | strip_transient)

    local ok=true
    echo "$committed" | grep -q "✓" && { fail "rich success committed a ✓ line: $output"; ok=false; }
    $ok && pass "rich success produced no committed line"

    teardown_test_env
}

# ============================================================================
# Test 4: rich mode failure commits a ✗ line
# ============================================================================
test_rich_failure_commits() {
    echo "Test 4: Rich mode failure commits ✗ line"
    setup_test_env

    local output
    output=$(
        export CLAUDE_VM_FORCE_TTY=true
        ui_init "$UI_LOG"
        ui_phase "doing the thing" false 2>&1
    )

    if echo "$output" | strip_transient | grep -q "✗ doing the thing"; then
        pass "rich failure line committed"
    else
        fail "expected '✗ doing the thing', got: $output"
    fi

    teardown_test_env
}

# ============================================================================
# Test 5: ui_init preserves a pre-existing EXIT trap
# ============================================================================
test_trap_preserved() {
    echo "Test 5: ui_init preserves existing EXIT trap"
    setup_test_env

    local trap_after
    trap_after=$(
        trap 'echo SENTINEL' EXIT
        ui_init "$UI_LOG" 2>/dev/null
        trap -p EXIT
        trap - EXIT
    )

    if echo "$trap_after" | grep -q "SENTINEL"; then
        pass "existing EXIT trap not clobbered"
    else
        fail "EXIT trap was replaced: $trap_after"
    fi

    teardown_test_env
}

# ============================================================================
# Test 6: ui_progress redraws in rich mode, silent in plain mode
# ============================================================================
test_progress_modes() {
    echo "Test 6: ui_progress rich vs plain"
    setup_test_env

    local rich_out plain_out
    rich_out=$(
        export CLAUDE_VM_FORCE_TTY=true
        ui_init "$UI_LOG"
        ui_progress "working (1/3)" 2>&1
        ui_progress_clear 2>&1
    )
    plain_out=$(
        unset CLAUDE_VM_FORCE_TTY
        ui_init "$UI_LOG"
        ui_progress "working (1/3)" 2>&1
        ui_progress_clear 2>&1
    )

    local ok=true
    echo "$rich_out" | grep -q "working (1/3)" || { fail "rich progress not drawn: $rich_out"; ok=false; }
    [[ -n "$plain_out" ]] && { fail "plain progress emitted output: $plain_out"; ok=false; }
    $ok && pass "progress drawn in rich mode only"

    teardown_test_env
}

# ============================================================================
# Run all tests
# ============================================================================
echo "=== claude-vm ui tests ==="
echo ""

test_plain_success
test_plain_failure
test_rich_success_silent
test_rich_failure_commits
test_trap_preserved
test_progress_modes

echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="

(( TESTS_FAILED > 0 )) && exit 1
exit 0
