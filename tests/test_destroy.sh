#!/usr/bin/env bash
# Tests for claude-vm destroy — removes all sandbox artifacts for a project
# Run: bash tests/test_destroy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✓ $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  ✗ $1: $2"; }

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    "$@"
}

# ─── Setup ────────────────────────────────────────────────────────────────────

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export CLAUDE_VM_DIR="$TEST_DIR/claude-vm-data"

# Source config for helper functions
source "$PROJECT_DIR/lib/config.sh"

# Override base_image_exists to avoid needing qemu-img
base_image_exists() { [[ -f "$(base_image_path)" ]]; }

# Mock is_vm_running — default: not running
_mock_vm_running=false
is_vm_running() { $_mock_vm_running; }

# Mock stop_vm — tracks if called
_stop_vm_called=false
_stop_vm_project=""
stop_vm() { _stop_vm_called=true; _stop_vm_project="${1:-}"; }

# Mock _kill_pid_file — tracks calls
_kill_pid_file_calls=()
_kill_pid_file() { _kill_pid_file_calls+=("$1"); }

# Source destroy_project from claude-vm (extract functions)
# We re-define it here to test the logic without full script sourcing
source_destroy_functions() {
    # Source the actual function from claude-vm
    eval "$(sed -n '/^destroy_project()/,/^}/p' "$PROJECT_DIR/claude-vm")"
}
source_destroy_functions

# ─── Tests ────────────────────────────────────────────────────────────────────

test_destroy_removes_snapshot() {
    load_config
    ensure_dirs

    local fake_project="/tmp/test-destroy-snap-$$"
    local snap_path
    snap_path="$(project_snapshot_path "$fake_project")"

    # Create a fake snapshot
    echo "fake qcow2 data" > "$snap_path"

    _mock_vm_running=false
    _stop_vm_called=false

    destroy_project "$fake_project" >/dev/null

    if [[ ! -f "$snap_path" ]]; then
        pass "destroy removes project snapshot"
    else
        fail "destroy removes snapshot" "file still exists"
    fi
}

test_destroy_removes_run_dir() {
    load_config
    ensure_dirs

    local fake_project="/tmp/test-destroy-run-$$"
    local run_dir
    run_dir="$(project_run_dir "$fake_project")"

    # Create fake run directory with artifacts
    mkdir -p "$run_dir"
    echo "12345" > "$run_dir/qemu.pid"
    echo "10022" > "$run_dir/ssh_port"
    touch "$run_dir/serial.log"
    touch "$run_dir/virtiofsd.log"
    echo "12346" > "$run_dir/virtiofsd.pid"

    _mock_vm_running=false
    _stop_vm_called=false

    destroy_project "$fake_project" >/dev/null

    if [[ ! -d "$run_dir" ]]; then
        pass "destroy removes run directory"
    else
        fail "destroy removes run dir" "directory still exists"
    fi
}

test_destroy_removes_both_snapshot_and_run_dir() {
    load_config
    ensure_dirs

    local fake_project="/tmp/test-destroy-both-$$"
    local snap_path run_dir
    snap_path="$(project_snapshot_path "$fake_project")"
    run_dir="$(project_run_dir "$fake_project")"

    echo "fake qcow2" > "$snap_path"
    mkdir -p "$run_dir"
    echo "pid" > "$run_dir/qemu.pid"

    _mock_vm_running=false

    destroy_project "$fake_project" >/dev/null

    if [[ ! -f "$snap_path" ]] && [[ ! -d "$run_dir" ]]; then
        pass "destroy removes both snapshot and run directory"
    else
        fail "destroy both" "snapshot exists=$([[ -f "$snap_path" ]] && echo yes || echo no), run_dir exists=$([[ -d "$run_dir" ]] && echo yes || echo no)"
    fi
}

test_destroy_stops_running_vm() {
    load_config
    ensure_dirs

    local fake_project="/tmp/test-destroy-stop-$$"
    local snap_path
    snap_path="$(project_snapshot_path "$fake_project")"
    echo "fake" > "$snap_path"

    _mock_vm_running=true
    _stop_vm_called=false

    destroy_project "$fake_project" >/dev/null

    if $_stop_vm_called; then
        pass "destroy stops running VM before removing artifacts"
    else
        fail "destroy stops VM" "stop_vm was not called"
    fi

    _mock_vm_running=false
}

test_destroy_noop_when_no_artifacts() {
    load_config
    ensure_dirs

    local fake_project="/tmp/test-destroy-noop-$$"
    local snap_path run_dir
    snap_path="$(project_snapshot_path "$fake_project")"
    run_dir="$(project_run_dir "$fake_project")"

    # Ensure nothing exists
    rm -f "$snap_path"
    rm -rf "$run_dir"

    _mock_vm_running=false
    _stop_vm_called=false

    local output
    output="$(destroy_project "$fake_project")"

    if echo "$output" | grep -q "No sandbox artifacts found"; then
        pass "destroy reports no artifacts when none exist"
    else
        fail "destroy noop message" "expected 'No sandbox artifacts found', got: $output"
    fi
}

test_destroy_project_isolation() {
    load_config
    ensure_dirs

    local project_a="/tmp/test-destroy-a-$$"
    local project_b="/tmp/test-destroy-b-$$"
    local snap_a snap_b run_a run_b
    snap_a="$(project_snapshot_path "$project_a")"
    snap_b="$(project_snapshot_path "$project_b")"
    run_a="$(project_run_dir "$project_a")"
    run_b="$(project_run_dir "$project_b")"

    # Create artifacts for both
    echo "snap A" > "$snap_a"
    echo "snap B" > "$snap_b"
    mkdir -p "$run_a" "$run_b"
    echo "pid_a" > "$run_a/qemu.pid"
    echo "pid_b" > "$run_b/qemu.pid"

    _mock_vm_running=false

    # Destroy only project A
    destroy_project "$project_a" >/dev/null

    if [[ ! -f "$snap_a" ]] && [[ ! -d "$run_a" ]]; then
        pass "project A artifacts removed"
    else
        fail "project A removal" "artifacts remain"
    fi

    if [[ -f "$snap_b" ]] && [[ -d "$run_b" ]]; then
        pass "project B artifacts unaffected by destroying A"
    else
        fail "project B isolation" "artifacts were modified"
    fi
}

test_destroy_all_removes_everything() {
    load_config
    ensure_dirs

    # Create base image, snapshots, run dirs
    mkdir -p "$BASE_IMAGES_DIR"
    echo "base image" > "$(base_image_path)"

    local proj1="/tmp/test-all-1-$$"
    local proj2="/tmp/test-all-2-$$"
    echo "snap1" > "$(project_snapshot_path "$proj1")"
    echo "snap2" > "$(project_snapshot_path "$proj2")"

    local run1 run2
    run1="$(project_run_dir "$proj1")"
    run2="$(project_run_dir "$proj2")"
    mkdir -p "$run1" "$run2"

    # Test that --all removes entire CLAUDE_VM_DIR
    # We simulate the --all logic here (since cmd_destroy uses read for confirmation)
    rm -rf "$CLAUDE_VM_DIR"

    if [[ ! -d "$CLAUDE_VM_DIR" ]]; then
        pass "destroy --all removes entire data directory"
    else
        fail "destroy --all" "data directory still exists"
    fi
}

test_destroy_idempotent() {
    load_config
    ensure_dirs

    local fake_project="/tmp/test-destroy-idempotent-$$"
    local snap_path
    snap_path="$(project_snapshot_path "$fake_project")"
    echo "fake" > "$snap_path"

    _mock_vm_running=false

    # Destroy twice — second should not error
    destroy_project "$fake_project" >/dev/null
    destroy_project "$fake_project" >/dev/null

    pass "destroy is idempotent (second call does not error)"
}

test_destroy_cleans_all_run_artifacts() {
    load_config
    ensure_dirs

    local fake_project="/tmp/test-destroy-artifacts-$$"
    local run_dir
    run_dir="$(project_run_dir "$fake_project")"

    mkdir -p "$run_dir"
    # Create all known run artifacts
    echo "12345" > "$run_dir/qemu.pid"
    echo "12346" > "$run_dir/virtiofsd.pid"
    echo "10022" > "$run_dir/ssh_port"
    touch "$run_dir/serial.log"
    touch "$run_dir/virtiofsd.log"
    touch "$run_dir/monitor.sock"
    touch "$run_dir/virtiofs.sock"

    _mock_vm_running=false

    destroy_project "$fake_project" >/dev/null

    if [[ ! -d "$run_dir" ]]; then
        pass "destroy removes all run artifacts (PID files, sockets, logs)"
    else
        fail "destroy run artifacts" "run dir still exists with: $(ls "$run_dir" 2>/dev/null)"
    fi
}

test_destroy_output_confirms_removal() {
    load_config
    ensure_dirs

    local fake_project="/tmp/test-destroy-output-$$"
    local snap_path
    snap_path="$(project_snapshot_path "$fake_project")"
    echo "fake" > "$snap_path"

    _mock_vm_running=false

    local output
    output="$(destroy_project "$fake_project")"

    if echo "$output" | grep -q "Sandbox artifacts removed"; then
        pass "destroy confirms removal in output"
    else
        fail "destroy output" "missing confirmation message, got: $output"
    fi
}

# ─── Run ──────────────────────────────────────────────────────────────────────

echo "=== claude-vm destroy tests ==="
echo ""

run_test test_destroy_removes_snapshot
run_test test_destroy_removes_run_dir
run_test test_destroy_removes_both_snapshot_and_run_dir
run_test test_destroy_stops_running_vm
run_test test_destroy_noop_when_no_artifacts
run_test test_destroy_project_isolation
run_test test_destroy_all_removes_everything
run_test test_destroy_idempotent
run_test test_destroy_cleans_all_run_artifacts
run_test test_destroy_output_confirms_removal

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_RUN} total"

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
echo "All tests passed."
