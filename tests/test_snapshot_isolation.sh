#!/usr/bin/env bash
# test_snapshot_isolation.sh — Verify per-project QCOW2 linked snapshot isolation
#
# Tests:
#   1. Each project directory gets a unique snapshot path (different hash)
#   2. Snapshots are backed by the shared base image (COW)
#   3. Snapshot creation is idempotent (re-running doesn't overwrite)
#   4. Operations on one project's snapshot don't affect another's
#   5. Snapshot verification detects valid/invalid states

set -euo pipefail

if ! command -v qemu-img &>/dev/null; then
    echo "SKIP: qemu-img not found (required for snapshot isolation tests)"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Use a temp directory for all test data
TEST_DIR="$(mktemp -d /tmp/claude-vm-test-XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Override config to use test directory
export CLAUDE_VM_DIR="$TEST_DIR/claude-vm"

source "$LIB_DIR/config.sh"
source "$LIB_DIR/snapshot.sh"

PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$(( PASS + 1 ))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$(( FAIL + 1 ))
}

# Setup: create a fake base image
setup_base_image() {
    load_config
    ensure_dirs
    local base_img
    base_img="$(base_image_path)"
    # Create a minimal valid qcow2 file
    qemu-img create -f qcow2 "$base_img" 1G &>/dev/null
}

# ──────────────────────────────────────────────
# Test 1: Different projects get different hashes
# ──────────────────────────────────────────────
test_unique_hashes() {
    echo "Test 1: Different projects get unique hashes"

    local hash_a hash_b hash_c
    hash_a="$(project_hash "/home/user/project-alpha")"
    hash_b="$(project_hash "/home/user/project-beta")"
    hash_c="$(project_hash "/home/user/project-alpha")"

    if [[ "$hash_a" != "$hash_b" ]]; then
        pass "Different projects get different hashes ($hash_a != $hash_b)"
    else
        fail "Different projects got same hash: $hash_a"
    fi

    if [[ "$hash_a" == "$hash_c" ]]; then
        pass "Same project always gets same hash ($hash_a == $hash_c)"
    else
        fail "Same project got different hashes: $hash_a vs $hash_c"
    fi
}

# ──────────────────────────────────────────────
# Test 2: Different projects get different snapshot paths
# ──────────────────────────────────────────────
test_unique_snapshot_paths() {
    echo "Test 2: Different projects get unique snapshot paths"

    local path_a path_b
    path_a="$(project_snapshot_path "/home/user/project-alpha")"
    path_b="$(project_snapshot_path "/home/user/project-beta")"

    if [[ "$path_a" != "$path_b" ]]; then
        pass "Different snapshot paths ($path_a != $path_b)"
    else
        fail "Same snapshot path for different projects: $path_a"
    fi

    # Both should be under SNAPSHOTS_DIR
    if [[ "$path_a" == "$SNAPSHOTS_DIR"/* ]] && [[ "$path_b" == "$SNAPSHOTS_DIR"/* ]]; then
        pass "Both snapshots under SNAPSHOTS_DIR"
    else
        fail "Snapshot paths not under SNAPSHOTS_DIR"
    fi
}

# ──────────────────────────────────────────────
# Test 3: Snapshot is backed by base image (COW)
# ──────────────────────────────────────────────
test_snapshot_backing() {
    echo "Test 3: Snapshot is backed by base image"

    setup_base_image

    local project_dir="$TEST_DIR/fake-project-a"
    mkdir -p "$project_dir"

    create_project_snapshot "$project_dir" >/dev/null

    local snap_path base_img
    snap_path="$(project_snapshot_path "$project_dir")"
    base_img="$(base_image_path)"

    if [[ -f "$snap_path" ]]; then
        pass "Snapshot file created"
    else
        fail "Snapshot file not created"
        return
    fi

    # Check backing file
    local backing
    backing="$(qemu-img info --output=json "$snap_path" | \
        jq -r '.["backing-filename"] // empty' 2>/dev/null)"

    local resolved_backing resolved_base
    resolved_backing="$(realpath -m "$backing" 2>/dev/null || echo "$backing")"
    resolved_base="$(realpath -m "$base_img" 2>/dev/null || echo "$base_img")"

    if [[ "$resolved_backing" == "$resolved_base" ]]; then
        pass "Snapshot backing file is the base image"
    else
        fail "Backing file mismatch: expected=$resolved_base actual=$resolved_backing"
    fi

    # Check format is qcow2
    local format
    format="$(qemu-img info --output=json "$snap_path" | jq -r '.format' 2>/dev/null)"
    if [[ "$format" == "qcow2" ]]; then
        pass "Snapshot format is qcow2"
    else
        fail "Snapshot format is $format (expected qcow2)"
    fi
}

# ──────────────────────────────────────────────
# Test 4: Snapshot creation is idempotent
# ──────────────────────────────────────────────
test_idempotent_creation() {
    echo "Test 4: Snapshot creation is idempotent"

    setup_base_image

    local project_dir="$TEST_DIR/fake-project-idem"
    mkdir -p "$project_dir"

    create_project_snapshot "$project_dir" >/dev/null

    local snap_path
    snap_path="$(project_snapshot_path "$project_dir")"
    local mtime_before
    mtime_before="$(stat -c %Y "$snap_path")"

    sleep 1

    # Create again — should not overwrite
    create_project_snapshot "$project_dir" >/dev/null

    local mtime_after
    mtime_after="$(stat -c %Y "$snap_path")"

    if [[ "$mtime_before" == "$mtime_after" ]]; then
        pass "Second create did not overwrite existing snapshot"
    else
        fail "Second create overwrote existing snapshot"
    fi
}

# ──────────────────────────────────────────────
# Test 5: Project isolation — independent snapshots
# ──────────────────────────────────────────────
test_project_isolation() {
    echo "Test 5: Project isolation — independent snapshots"

    setup_base_image

    local proj_x="$TEST_DIR/project-x"
    local proj_y="$TEST_DIR/project-y"
    mkdir -p "$proj_x" "$proj_y"

    create_project_snapshot "$proj_x" >/dev/null
    create_project_snapshot "$proj_y" >/dev/null

    local snap_x snap_y
    snap_x="$(project_snapshot_path "$proj_x")"
    snap_y="$(project_snapshot_path "$proj_y")"

    # Verify they are different files
    if [[ "$snap_x" != "$snap_y" ]]; then
        pass "Projects have separate snapshot files"
    else
        fail "Projects share the same snapshot file"
        return
    fi

    # Delete one snapshot; the other should remain
    delete_snapshot "$proj_x" >/dev/null

    if [[ ! -f "$snap_x" ]] && [[ -f "$snap_y" ]]; then
        pass "Deleting project-x snapshot did not affect project-y"
    else
        fail "Snapshot isolation violation after delete"
    fi

    # Verify project-y snapshot is still valid
    if verify_snapshot "$proj_y" >/dev/null 2>&1; then
        pass "Project-y snapshot still valid after project-x deletion"
    else
        fail "Project-y snapshot corrupted after project-x deletion"
    fi
}

# ──────────────────────────────────────────────
# Test 6: Verify snapshot detects valid/invalid states
# ──────────────────────────────────────────────
test_verify_snapshot() {
    echo "Test 6: Snapshot verification"

    setup_base_image

    local project_dir="$TEST_DIR/fake-project-verify"
    mkdir -p "$project_dir"

    # Verify nonexistent snapshot fails
    if ! verify_snapshot "$TEST_DIR/nonexistent" >/dev/null 2>&1; then
        pass "Verify correctly rejects nonexistent snapshot"
    else
        fail "Verify accepted nonexistent snapshot"
    fi

    # Create and verify valid snapshot
    create_project_snapshot "$project_dir" >/dev/null

    if verify_snapshot "$project_dir" >/dev/null 2>&1; then
        pass "Verify accepts valid snapshot"
    else
        fail "Verify rejected valid snapshot"
    fi
}

# ──────────────────────────────────────────────
# Test 7: Snapshot initial size is small (COW overhead only)
# ──────────────────────────────────────────────
test_snapshot_cow_size() {
    echo "Test 7: Snapshot COW — initial size is small"

    setup_base_image

    local project_dir="$TEST_DIR/fake-project-cow"
    mkdir -p "$project_dir"

    create_project_snapshot "$project_dir" >/dev/null

    local snap_path
    snap_path="$(project_snapshot_path "$project_dir")"

    # A fresh COW snapshot should be very small (just qcow2 header, ~200KB)
    local actual_size
    actual_size="$(qemu-img info --output=json "$snap_path" | \
        jq -r '.["actual-size"]' 2>/dev/null || echo "999999999")"

    # Should be under 1MB (typically ~200KB for qcow2 header)
    if (( actual_size < 1048576 )); then
        pass "Fresh snapshot is small ($(( actual_size / 1024 ))KB) — COW working"
    else
        fail "Fresh snapshot is $(( actual_size / 1048576 ))MB — expected < 1MB"
    fi
}

# ──────────────────────────────────────────────
# Run all tests
# ──────────────────────────────────────────────
echo "=== claude-vm snapshot isolation tests ==="
echo ""

test_unique_hashes
echo ""
test_unique_snapshot_paths
echo ""
test_snapshot_backing
echo ""
test_idempotent_creation
echo ""
test_project_isolation
echo ""
test_verify_snapshot
echo ""
test_snapshot_cow_size
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="

if (( FAIL > 0 )); then
    exit 1
fi
