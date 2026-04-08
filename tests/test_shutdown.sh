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
# 5. _cleanup_runtime removes only runtime files, not snapshots
# 6. shutdown_vm stops virtiofsd process

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
# Test 5: _cleanup_runtime does NOT delete snapshot
# ============================================================================
test_cleanup_spares_snapshot() {
    echo "Test 5: _cleanup_runtime preserves snapshot"
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
# Test 6: shutdown kills virtiofsd
# ============================================================================
test_shutdown_stops_virtiofsd() {
    echo "Test 6: Shutdown stops virtiofsd"
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
# Test 8: stop_vm_by_run_dir resolves project dir via sidecar
# ============================================================================
test_stop_by_run_dir_with_sidecar() {
    echo "Test 8: stop_vm_by_run_dir resolves via .project sidecar"
    setup_test_env

    local project_dir="/tmp/test-stop-rundir-$$"
    setup_fake_vm "$project_dir"

    local run_dir snap_path hash
    run_dir="$(project_run_dir "$project_dir")"
    snap_path="$(project_snapshot_path "$project_dir")"
    hash="$(project_hash "$project_dir")"

    # Sidecar file is created by setup_fake_vm's snapshot path setup
    # but we need to write it explicitly (setup_fake_vm doesn't)
    echo "$project_dir" > "$SNAPSHOTS_DIR/${hash}.project"

    stop_vm_by_run_dir "$run_dir" >/dev/null 2>&1

    if [[ -f "$snap_path" ]] && [[ ! -f "$run_dir/qemu.pid" ]]; then
        pass "stop_vm_by_run_dir: snapshot preserved, runtime cleaned via sidecar"
    else
        fail "stop_vm_by_run_dir sidecar: snap exists=$([[ -f "$snap_path" ]] && echo y || echo n), pid exists=$([[ -f "$run_dir/qemu.pid" ]] && echo y || echo n)"
    fi

    cleanup_fake_vm
    teardown_test_env
}

# ============================================================================
# Test 9: stop_vm_by_run_dir falls back when no sidecar
# ============================================================================
test_stop_by_run_dir_no_sidecar() {
    echo "Test 9: stop_vm_by_run_dir handles missing .project sidecar"
    setup_test_env

    local project_dir="/tmp/test-stop-nosidecar-$$"
    setup_fake_vm "$project_dir"

    local run_dir snap_path hash
    run_dir="$(project_run_dir "$project_dir")"
    snap_path="$(project_snapshot_path "$project_dir")"
    hash="$(project_hash "$project_dir")"

    # Remove sidecar to force fallback path
    rm -f "$SNAPSHOTS_DIR/${hash}.project"

    stop_vm_by_run_dir "$run_dir" >/dev/null 2>&1

    if [[ -f "$snap_path" ]] && [[ ! -f "$run_dir/qemu.pid" ]]; then
        pass "stop_vm_by_run_dir: fallback shutdown works without sidecar"
    else
        fail "stop_vm_by_run_dir fallback: snap exists=$([[ -f "$snap_path" ]] && echo y || echo n), pid exists=$([[ -f "$run_dir/qemu.pid" ]] && echo y || echo n)"
    fi

    cleanup_fake_vm
    teardown_test_env
}

# ============================================================================
# Test 10: shutdown_vm_from_run_dir kills processes and cleans up
# ============================================================================
test_shutdown_from_run_dir() {
    echo "Test 10: shutdown_vm_from_run_dir kills QEMU and virtiofsd"
    setup_test_env

    local project_dir="/tmp/test-fromrundir-$$"
    setup_fake_vm "$project_dir"

    local run_dir hash
    run_dir="$(project_run_dir "$project_dir")"
    hash="$(project_hash "$project_dir")"

    local qemu_pid="$FAKE_QEMU_PID"
    local vfs_pid="$FAKE_VFS_PID"

    shutdown_vm_from_run_dir "$run_dir" "$hash" >/dev/null 2>&1
    sleep 0.5

    local ok=true
    if kill -0 "$qemu_pid" 2>/dev/null; then
        fail "QEMU process still running"; ok=false
    fi
    if kill -0 "$vfs_pid" 2>/dev/null; then
        fail "virtiofsd process still running"; ok=false
    fi
    if [[ -f "$run_dir/qemu.pid" ]]; then
        fail "PID file not cleaned"; ok=false
    fi
    $ok && pass "shutdown_vm_from_run_dir: processes killed, runtime cleaned"

    cleanup_fake_vm
    teardown_test_env
}

# ============================================================================
# Test 11: shutdown_vm_from_run_dir handles stale PID
# ============================================================================
test_shutdown_from_run_dir_stale_pid() {
    echo "Test 11: shutdown_vm_from_run_dir handles stale PID"
    setup_test_env

    local hash="deadbeef1234"
    local run_dir="$RUN_DIR/$hash"
    mkdir -p "$run_dir"
    echo "999999999" > "$run_dir/qemu.pid"
    echo "10022" > "$run_dir/ssh_port"

    shutdown_vm_from_run_dir "$run_dir" "$hash" >/dev/null 2>&1

    if [[ ! -f "$run_dir/qemu.pid" ]]; then
        pass "stale PID cleaned up"
    else
        fail "stale PID file remains"
    fi

    teardown_test_env
}

# ============================================================================
# Test 12: cmd_stop --all stops multiple VMs
# ============================================================================
test_cmd_stop_all() {
    echo "Test 12: cmd_stop --all stops multiple running VMs"
    setup_test_env

    # Set up two fake projects with running VMs
    local proj_a="/tmp/test-stopall-a-$$"
    local proj_b="/tmp/test-stopall-b-$$"

    setup_fake_vm "$proj_a"
    local pid_a="$FAKE_QEMU_PID"
    local vfs_a="$FAKE_VFS_PID"
    local hash_a
    hash_a="$(project_hash "$proj_a")"
    echo "$proj_a" > "$SNAPSHOTS_DIR/${hash_a}.project"

    setup_fake_vm "$proj_b"
    local pid_b="$FAKE_QEMU_PID"
    local vfs_b="$FAKE_VFS_PID"
    local hash_b
    hash_b="$(project_hash "$proj_b")"
    echo "$proj_b" > "$SNAPSHOTS_DIR/${hash_b}.project"

    # Source cmd_stop from the main script
    eval "$(sed -n '/^cmd_stop()/,/^}/p' "$PROJECT_DIR/claude-vm")"

    local output
    output=$(cmd_stop --all 2>&1)

    sleep 0.5

    local ok=true
    if kill -0 "$pid_a" 2>/dev/null; then
        fail "VM A still running"; ok=false
    fi
    if kill -0 "$pid_b" 2>/dev/null; then
        fail "VM B still running"; ok=false
    fi
    if echo "$output" | grep -q "Stopped 2 VM"; then
        $ok && pass "cmd_stop --all: both VMs stopped, correct count reported"
    else
        fail "cmd_stop --all output: $output"
    fi

    # Clean up any remaining processes
    kill "$pid_a" "$vfs_a" "$pid_b" "$vfs_b" 2>/dev/null || true
    wait "$pid_a" "$vfs_a" "$pid_b" "$vfs_b" 2>/dev/null || true
    teardown_test_env
}

# ============================================================================
# Test 13: cmd_stop --all with no running VMs
# ============================================================================
test_cmd_stop_all_none_running() {
    echo "Test 13: cmd_stop --all with no running VMs"
    setup_test_env

    eval "$(sed -n '/^cmd_stop()/,/^}/p' "$PROJECT_DIR/claude-vm")"

    local output
    output=$(cmd_stop --all 2>&1)

    if echo "$output" | grep -q "No running VMs"; then
        pass "cmd_stop --all: reports no running VMs"
    else
        fail "cmd_stop --all noop: got '$output'"
    fi

    teardown_test_env
}

# ============================================================================
# Test 14: cmd_stop --all skips stale PIDs, only counts live ones
# ============================================================================
test_cmd_stop_all_skips_stale() {
    echo "Test 14: cmd_stop --all skips stale PIDs"
    setup_test_env

    # Create a run dir with a stale PID (no actual process)
    local stale_hash="stale123dead"
    local stale_run="$RUN_DIR/$stale_hash"
    mkdir -p "$stale_run"
    echo "999999999" > "$stale_run/qemu.pid"

    # Create a run dir with a live PID
    local proj="/tmp/test-stopall-stale-$$"
    setup_fake_vm "$proj"
    local live_pid="$FAKE_QEMU_PID"
    local hash
    hash="$(project_hash "$proj")"
    echo "$proj" > "$SNAPSHOTS_DIR/${hash}.project"

    eval "$(sed -n '/^cmd_stop()/,/^}/p' "$PROJECT_DIR/claude-vm")"

    local output
    output=$(cmd_stop --all 2>&1)

    if echo "$output" | grep -q "Stopped 1 VM"; then
        pass "cmd_stop --all: only counted live VM, skipped stale"
    else
        fail "cmd_stop --all stale skip: got '$output'"
    fi

    cleanup_fake_vm
    teardown_test_env
}

# ============================================================================
# Test 15: cmd_stop --all preserves all snapshots
# ============================================================================
test_cmd_stop_all_preserves_snapshots() {
    echo "Test 15: cmd_stop --all preserves all snapshots"
    setup_test_env

    local proj_a="/tmp/test-stopall-snap-a-$$"
    local proj_b="/tmp/test-stopall-snap-b-$$"

    setup_fake_vm "$proj_a"
    local hash_a
    hash_a="$(project_hash "$proj_a")"
    echo "$proj_a" > "$SNAPSHOTS_DIR/${hash_a}.project"
    local pids_a=("$FAKE_QEMU_PID" "$FAKE_VFS_PID")

    setup_fake_vm "$proj_b"
    local hash_b
    hash_b="$(project_hash "$proj_b")"
    echo "$proj_b" > "$SNAPSHOTS_DIR/${hash_b}.project"
    local pids_b=("$FAKE_QEMU_PID" "$FAKE_VFS_PID")

    local snap_a snap_b
    snap_a="$(project_snapshot_path "$proj_a")"
    snap_b="$(project_snapshot_path "$proj_b")"

    eval "$(sed -n '/^cmd_stop()/,/^}/p' "$PROJECT_DIR/claude-vm")"

    cmd_stop --all >/dev/null 2>&1

    local ok=true
    if [[ ! -f "$snap_a" ]]; then
        fail "snapshot A deleted"; ok=false
    fi
    if [[ ! -f "$snap_b" ]]; then
        fail "snapshot B deleted"; ok=false
    fi
    $ok && pass "cmd_stop --all: all snapshots preserved"

    kill "${pids_a[@]}" "${pids_b[@]}" 2>/dev/null || true
    wait "${pids_a[@]}" "${pids_b[@]}" 2>/dev/null || true
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
test_cleanup_spares_snapshot
test_shutdown_stops_virtiofsd
test_stop_by_run_dir_with_sidecar
test_stop_by_run_dir_no_sidecar
test_shutdown_from_run_dir
test_shutdown_from_run_dir_stale_pid
test_cmd_stop_all
test_cmd_stop_all_none_running
test_cmd_stop_all_skips_stale
test_cmd_stop_all_preserves_snapshots

echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="

(( TESTS_FAILED > 0 )) && exit 1
exit 0
