#!/usr/bin/env bash
# test_shutdown.sh — Tests for clean VM shutdown with snapshot preservation
#
# Validates AC 9: VM shuts down cleanly on exit while preserving the linked snapshot
#
# Tests:
# 1. shutdown_vm preserves the linked snapshot file on disk
# 2. shutdown_vm cleans up runtime artifacts (PID files, sockets)
# 3. shutdown_vm handles already-stopped VMs gracefully
# 4. shutdown_vm handles stale PID files
# 5. verify_snapshot_preserved detects missing/empty/valid snapshots
# 6. _cleanup_runtime removes only runtime files, not snapshots
# 7. shutdown_vm stops virtiofsd process

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries once at top level
source "$PROJECT_DIR/lib/config.sh"
source "$PROJECT_DIR/lib/shutdown.sh"

# Disable strict mode for test runner
set +euo pipefail

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; (( TESTS_PASSED++ )); (( TESTS_RUN++ )); }
fail() { echo "  FAIL: $1"; (( TESTS_FAILED++ )); (( TESTS_RUN++ )); }

# Per-test environment setup
setup_test_env() {
    TEST_VM_DIR="$(mktemp -d)"
    export CLAUDE_VM_DIR="$TEST_VM_DIR"
    export CLAUDE_VM_CONFIG="$TEST_VM_DIR/config"
    BASE_IMAGES_DIR="$CLAUDE_VM_DIR/base"
    SNAPSHOTS_DIR="$CLAUDE_VM_DIR/snapshots"
    CLOUD_INIT_DIR="$CLAUDE_VM_DIR/cloud-init"
    RUN_DIR="$CLAUDE_VM_DIR/run"
    load_config
    ensure_dirs
}

teardown_test_env() {
    rm -rf "$TEST_VM_DIR" 2>/dev/null
}

# Create fake VM processes and write PID/snapshot files
# Sets global vars: FAKE_QEMU_PID, FAKE_VFS_PID
setup_fake_vm() {
    local project_dir="$1"
    local run_dir snap_path

    run_dir="$(project_run_dir "$project_dir")"
    snap_path="$(project_snapshot_path "$project_dir")"
    mkdir -p "$run_dir" "$(dirname "$snap_path")"

    # Create fake snapshot file (64KB)
    dd if=/dev/urandom of="$snap_path" bs=1024 count=64 2>/dev/null

    # Create fake QEMU process
    sleep 300 &
    FAKE_QEMU_PID=$!
    echo "$FAKE_QEMU_PID" > "$run_dir/qemu.pid"

    # Create fake virtiofsd process
    sleep 300 &
    FAKE_VFS_PID=$!
    echo "$FAKE_VFS_PID" > "$run_dir/virtiofsd.pid"

    # Create SSH port file
    echo "10022" > "$run_dir/ssh_port"
}

cleanup_fake_vm() {
    kill "$FAKE_QEMU_PID" 2>/dev/null
    kill "$FAKE_VFS_PID" 2>/dev/null
    wait "$FAKE_QEMU_PID" 2>/dev/null
    wait "$FAKE_VFS_PID" 2>/dev/null
}

# ============================================================================
# Test 1: shutdown preserves snapshot file on disk
# ============================================================================
test_shutdown_preserves_snapshot() {
    echo "Test 1: Shutdown preserves linked snapshot on disk"
    setup_test_env

    local project_dir="/tmp/test-shut1-$$"
    setup_fake_vm "$project_dir"

    local snap_path
    snap_path="$(project_snapshot_path "$project_dir")"
    local snap_size_before
    snap_size_before=$(stat -c%s "$snap_path")

    shutdown_vm "$project_dir" >/dev/null 2>&1

    if [[ -f "$snap_path" ]]; then
        local snap_size_after
        snap_size_after=$(stat -c%s "$snap_path")
        if (( snap_size_after == snap_size_before )); then
            pass "Snapshot preserved ($snap_size_after bytes)"
        else
            fail "Snapshot size changed: $snap_size_before → $snap_size_after"
        fi
    else
        fail "Snapshot file deleted"
    fi

    cleanup_fake_vm
    teardown_test_env
}

# ============================================================================
# Test 2: shutdown cleans up runtime artifacts
# ============================================================================
test_shutdown_cleans_runtime() {
    echo "Test 2: Shutdown cleans up runtime artifacts"
    setup_test_env

    local project_dir="/tmp/test-shut2-$$"
    setup_fake_vm "$project_dir"

    local run_dir
    run_dir="$(project_run_dir "$project_dir")"

    shutdown_vm "$project_dir" >/dev/null 2>&1

    local all_clean=true
    for f in qemu.pid virtiofsd.pid ssh_port; do
        if [[ -f "$run_dir/$f" ]]; then
            fail "$f not cleaned up"
            all_clean=false
        fi
    done
    $all_clean && pass "All runtime artifacts cleaned up"

    cleanup_fake_vm
    teardown_test_env
}

# ============================================================================
# Test 3: shutdown handles already-stopped VM
# ============================================================================
test_shutdown_already_stopped() {
    echo "Test 3: Shutdown handles already-stopped VM"
    setup_test_env

    local project_dir="/tmp/test-shut3-$$"
    local run_dir
    run_dir="$(project_run_dir "$project_dir")"
    mkdir -p "$run_dir"

    local output
    output=$(shutdown_vm "$project_dir" 2>&1)

    if echo "$output" | grep -qi "no vm running"; then
        pass "Graceful no-op for stopped VM"
    else
        fail "Unexpected output: $output"
    fi

    teardown_test_env
}

# ============================================================================
# Test 4: shutdown with stale PID file
# ============================================================================
test_shutdown_stale_pid() {
    echo "Test 4: Shutdown handles stale PID file"
    setup_test_env

    local project_dir="/tmp/test-shut4-$$"
    local run_dir snap_path
    run_dir="$(project_run_dir "$project_dir")"
    snap_path="$(project_snapshot_path "$project_dir")"
    mkdir -p "$run_dir" "$(dirname "$snap_path")"
    dd if=/dev/urandom of="$snap_path" bs=1024 count=16 2>/dev/null
    echo "999999999" > "$run_dir/qemu.pid"

    shutdown_vm "$project_dir" >/dev/null 2>&1

    if [[ -f "$snap_path" ]] && (( $(stat -c%s "$snap_path") > 0 )); then
        pass "Stale PID handled, snapshot preserved"
    else
        fail "Snapshot damaged after stale PID shutdown"
    fi

    teardown_test_env
}

# ============================================================================
# Test 5: verify_snapshot_preserved
# ============================================================================
test_verify_snapshot() {
    echo "Test 5: verify_snapshot_preserved detects states"
    setup_test_env
    local ok=true

    # Missing snapshot
    if verify_snapshot_preserved "/tmp/nonexistent-$$" >/dev/null 2>&1; then
        fail "Should fail for missing snapshot"; ok=false
    fi

    # Empty snapshot
    local project_dir="/tmp/test-shut5-$$"
    local snap_path
    snap_path="$(project_snapshot_path "$project_dir")"
    mkdir -p "$(dirname "$snap_path")"
    touch "$snap_path"
    if verify_snapshot_preserved "$project_dir" >/dev/null 2>&1; then
        fail "Should fail for empty snapshot"; ok=false
    fi

    # Valid snapshot
    dd if=/dev/urandom of="$snap_path" bs=1024 count=16 2>/dev/null
    if ! verify_snapshot_preserved "$project_dir" >/dev/null 2>&1; then
        fail "Should succeed for valid snapshot"; ok=false
    fi

    $ok && pass "Correctly detects missing/empty/valid snapshots"

    teardown_test_env
}

# ============================================================================
# Test 6: _cleanup_runtime does NOT delete snapshot
# ============================================================================
test_cleanup_spares_snapshot() {
    echo "Test 6: _cleanup_runtime preserves snapshot"
    setup_test_env

    local project_dir="/tmp/test-shut6-$$"
    local run_dir snap_path
    run_dir="$(project_run_dir "$project_dir")"
    snap_path="$(project_snapshot_path "$project_dir")"
    mkdir -p "$run_dir" "$(dirname "$snap_path")"

    dd if=/dev/urandom of="$snap_path" bs=1024 count=16 2>/dev/null
    echo "12345" > "$run_dir/qemu.pid"
    echo "12346" > "$run_dir/virtiofsd.pid"
    echo "10022" > "$run_dir/ssh_port"

    _cleanup_runtime "$run_dir"

    if [[ -f "$snap_path" ]] && [[ ! -f "$run_dir/qemu.pid" ]]; then
        pass "Snapshot preserved, runtime cleaned"
    else
        fail "Snapshot or runtime state incorrect"
    fi

    teardown_test_env
}

# ============================================================================
# Test 7: shutdown kills virtiofsd
# ============================================================================
test_shutdown_stops_virtiofsd() {
    echo "Test 7: Shutdown stops virtiofsd"
    setup_test_env

    local project_dir="/tmp/test-shut7-$$"
    setup_fake_vm "$project_dir"
    local vfs_pid="$FAKE_VFS_PID"

    shutdown_vm "$project_dir" >/dev/null 2>&1
    sleep 0.5

    if kill -0 "$vfs_pid" 2>/dev/null; then
        fail "virtiofsd still running (PID $vfs_pid)"
        kill "$vfs_pid" 2>/dev/null
    else
        pass "virtiofsd stopped"
    fi

    cleanup_fake_vm
    teardown_test_env
}

# ============================================================================
# Run all tests
# ============================================================================
echo "=== claude-vm shutdown tests ==="
echo ""

test_shutdown_preserves_snapshot
test_shutdown_cleans_runtime
test_shutdown_already_stopped
test_shutdown_stale_pid
test_verify_snapshot
test_cleanup_spares_snapshot
test_shutdown_stops_virtiofsd

echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="

(( TESTS_FAILED > 0 )) && exit 1
exit 0
