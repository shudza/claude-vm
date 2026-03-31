#!/usr/bin/env bash
# test_virtiofs.sh — Tests for virtiofs filesystem sharing
#
# Tests cover:
#   1. virtiofsd binary detection
#   2. virtiofsd daemon lifecycle (start/stop)
#   3. QEMU argument generation
#   4. Guest mount verification (requires running VM)
#   5. Read/write round-trip correctness
#
# Unit tests (no VM required) run by default.
# Integration tests (require running VM) run with: --integration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"

# Source the module under test
source "$LIB_DIR/config.sh"
source "$LIB_DIR/virtiofs.sh"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Test helpers
pass() { TESTS_PASSED=$(( TESTS_PASSED + 1 )); echo "  PASS: $1"; }
fail() { TESTS_FAILED=$(( TESTS_FAILED + 1 )); echo "  FAIL: $1"; }
skip() { TESTS_SKIPPED=$(( TESTS_SKIPPED + 1 )); echo "  SKIP: $1"; }
run_test() {
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    local name="$1"
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name"
    fi
}

# ─── Unit Tests (no VM required) ───────────────────────────────────────────

test_find_daemon() {
    # Should find virtiofsd if installed
    local bin
    if bin=$(virtiofs_find_daemon 2>/dev/null); then
        [[ -x "$bin" ]]
    else
        # Not installed — skip rather than fail
        skip "virtiofsd not installed"
        return 0
    fi
}

test_qemu_args_contains_memfd() {
    local args
    args=$(virtiofs_qemu_args "/tmp/test.sock" "4G")
    echo "$args" | grep -q "memory-backend-memfd"
}

test_qemu_args_contains_share_on() {
    local args
    args=$(virtiofs_qemu_args "/tmp/test.sock" "4G")
    echo "$args" | grep -q "share=on"
}

test_qemu_args_contains_chardev() {
    local args
    args=$(virtiofs_qemu_args "/tmp/test.sock" "4G")
    echo "$args" | grep -q "socket,id=vhost-fs,path=/tmp/test.sock"
}

test_qemu_args_contains_device() {
    local args
    args=$(virtiofs_qemu_args "/tmp/test.sock" "4G")
    echo "$args" | grep -q "vhost-user-fs-pci,chardev=vhost-fs,tag=workspace"
}

test_qemu_args_queue_size() {
    local args
    args=$(virtiofs_qemu_args "/tmp/test.sock" "4G")
    echo "$args" | grep -q "queue-size=1024"
}

test_qemu_args_custom_ram() {
    local args
    args=$(virtiofs_qemu_args "/tmp/test.sock" "8G")
    echo "$args" | grep -q "size=8G"
}

test_mount_tag_constant() {
    [[ "$VIRTIOFS_MOUNT_TAG" == "workspace" ]]
}

test_guest_mount_constant() {
    [[ "$VIRTIOFS_GUEST_MOUNT" == "/workspace" ]]
}

test_start_daemon_rejects_missing_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local bad_dir="/tmp/claude-vm-test-nonexistent-$$"
    rm -rf "$bad_dir"

    # Should fail with nonexistent directory
    if virtiofs_start_daemon "$bad_dir" "$tmpdir/test.sock" "$tmpdir" 2>/dev/null; then
        rm -rf "$tmpdir"
        return 1  # Should have failed
    fi

    rm -rf "$tmpdir"
    return 0
}

test_stop_daemon_handles_no_pid() {
    local tmpdir
    tmpdir=$(mktemp -d)
    # Should succeed gracefully when no PID file exists
    virtiofs_stop_daemon "$tmpdir"
    local rc=$?
    rm -rf "$tmpdir"
    return $rc
}

test_is_running_returns_false_no_pid() {
    local tmpdir
    tmpdir=$(mktemp -d)
    if virtiofs_is_running "$tmpdir"; then
        rm -rf "$tmpdir"
        return 1  # Should not be running
    fi
    rm -rf "$tmpdir"
    return 0
}

test_is_running_returns_false_stale_pid() {
    local tmpdir
    tmpdir=$(mktemp -d)
    # Write a PID that doesn't exist
    echo "999999999" > "$tmpdir/virtiofsd.pid"
    if virtiofs_is_running "$tmpdir"; then
        rm -rf "$tmpdir"
        return 1  # Should not be running with stale PID
    fi
    rm -rf "$tmpdir"
    return 0
}

# ─── Daemon Lifecycle Test (requires virtiofsd) ────────────────────────────

test_daemon_lifecycle() {
    local virtiofsd_bin
    if ! virtiofsd_bin=$(virtiofs_find_daemon 2>/dev/null); then
        skip "virtiofsd not installed — skipping lifecycle test"
        return 0
    fi

    local tmpdir share_dir
    tmpdir=$(mktemp -d)
    share_dir=$(mktemp -d)
    local sock_path="$tmpdir/virtiofs.sock"

    # Create a test file in share dir
    echo "hello from host" > "$share_dir/testfile.txt"

    # Start daemon
    if ! virtiofs_start_daemon "$share_dir" "$sock_path" "$tmpdir" 2>/dev/null; then
        echo "    (virtiofsd failed to start — may need root or different caps)" >&2
        rm -rf "$tmpdir" "$share_dir"
        skip "virtiofsd could not start (permissions?)"
        return 0
    fi

    # Verify it's running
    if ! virtiofs_is_running "$tmpdir"; then
        rm -rf "$tmpdir" "$share_dir"
        return 1
    fi

    # Verify socket exists
    if [[ ! -S "$sock_path" ]]; then
        rm -rf "$tmpdir" "$share_dir"
        return 1
    fi

    # Stop daemon
    virtiofs_stop_daemon "$tmpdir"

    # Verify it stopped
    if virtiofs_is_running "$tmpdir"; then
        rm -rf "$tmpdir" "$share_dir"
        return 1
    fi

    rm -rf "$tmpdir" "$share_dir"
    return 0
}

# ─── Cloud-init fstab Test ──────────────────────────────────────────────────

test_cloud_init_has_virtiofs_fstab() {
    # Verify the cloud-init config includes virtiofs mount in fstab
    grep -q "virtiofs" "$LIB_DIR/cloud-init.sh"
}

test_cloud_init_has_workspace_mkdir() {
    # Verify cloud-init creates /workspace
    grep -q "mkdir.*workspace" "$LIB_DIR/cloud-init.sh"
}

test_cloud_init_mount_tag_matches() {
    # The fstab entry in cloud-init should use the same tag as VIRTIOFS_MOUNT_TAG
    grep -q "workspace /workspace virtiofs" "$LIB_DIR/cloud-init.sh"
}

# ─── Integration Tests (require running VM) ────────────────────────────────

test_integration_mount_exists() {
    local ssh_port="$1"
    virtiofs_is_mounted "$ssh_port"
}

test_integration_read_write_roundtrip() {
    local ssh_port="$1"
    local project_dir="$2"

    virtiofs_verify_mount "$ssh_port" "$project_dir"
}

test_integration_large_file() {
    local ssh_port="$1"
    local project_dir="$2"

    local ssh_opts=(
        -p "$ssh_port"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ConnectTimeout=5
        -o BatchMode=yes
    )

    # Create a 1MB file on host
    local test_file="${project_dir}/.claude-vm-large-test-$$"
    dd if=/dev/urandom of="$test_file" bs=1024 count=1024 2>/dev/null

    local host_checksum
    host_checksum=$(sha256sum "$test_file" | cut -d' ' -f1)

    # Read checksum from guest
    local guest_checksum
    guest_checksum=$(ssh "${ssh_opts[@]}" "claude@localhost" \
        "sha256sum ${VIRTIOFS_GUEST_MOUNT}/.claude-vm-large-test-$$ | cut -d' ' -f1" 2>/dev/null)

    rm -f "$test_file"

    [[ "$host_checksum" == "$guest_checksum" ]]
}

test_integration_symlinks() {
    local ssh_port="$1"
    local project_dir="$2"

    local ssh_opts=(
        -p "$ssh_port"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ConnectTimeout=5
        -o BatchMode=yes
    )

    # Create a file and symlink on host
    local test_dir="${project_dir}/.claude-vm-symlink-test-$$"
    mkdir -p "$test_dir"
    echo "target content" > "$test_dir/real-file.txt"
    ln -sf real-file.txt "$test_dir/link.txt"

    # Read via symlink from guest
    local guest_content
    guest_content=$(ssh "${ssh_opts[@]}" "claude@localhost" \
        "cat ${VIRTIOFS_GUEST_MOUNT}/.claude-vm-symlink-test-$$/link.txt" 2>/dev/null)

    rm -rf "$test_dir"

    [[ "$guest_content" == "target content" ]]
}

test_integration_guest_creates_directory() {
    local ssh_port="$1"
    local project_dir="$2"

    local ssh_opts=(
        -p "$ssh_port"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ConnectTimeout=5
        -o BatchMode=yes
    )

    local test_dir=".claude-vm-mkdir-test-$$"

    # Create directory from guest
    ssh "${ssh_opts[@]}" "claude@localhost" \
        "mkdir -p ${VIRTIOFS_GUEST_MOUNT}/${test_dir}/nested/deep" 2>/dev/null

    # Verify on host
    local result=1
    if [[ -d "${project_dir}/${test_dir}/nested/deep" ]]; then
        result=0
    fi

    rm -rf "${project_dir:?}/${test_dir}"
    return $result
}

# ─── Test Runner ────────────────────────────────────────────────────────────

run_unit_tests() {
    echo "=== Virtiofs Unit Tests ==="
    echo ""

    run_test "find virtiofsd binary" test_find_daemon
    run_test "QEMU args include memfd backend" test_qemu_args_contains_memfd
    run_test "QEMU args include share=on" test_qemu_args_contains_share_on
    run_test "QEMU args include chardev socket" test_qemu_args_contains_chardev
    run_test "QEMU args include vhost-user-fs device" test_qemu_args_contains_device
    run_test "QEMU args include queue-size" test_qemu_args_queue_size
    run_test "QEMU args respect custom RAM" test_qemu_args_custom_ram
    run_test "mount tag is 'workspace'" test_mount_tag_constant
    run_test "guest mount is '/workspace'" test_guest_mount_constant
    run_test "rejects nonexistent shared dir" test_start_daemon_rejects_missing_dir
    run_test "stop handles missing PID gracefully" test_stop_daemon_handles_no_pid
    run_test "is_running false with no PID" test_is_running_returns_false_no_pid
    run_test "is_running false with stale PID" test_is_running_returns_false_stale_pid
    run_test "cloud-init has virtiofs fstab" test_cloud_init_has_virtiofs_fstab
    run_test "cloud-init creates /workspace" test_cloud_init_has_workspace_mkdir
    run_test "cloud-init mount tag matches" test_cloud_init_mount_tag_matches
    run_test "daemon start/stop lifecycle" test_daemon_lifecycle
}

run_integration_tests() {
    echo ""
    echo "=== Virtiofs Integration Tests (requires running VM) ==="
    echo ""

    # Find running VM's SSH port
    load_config
    local project_dir="${1:-$PWD}"
    local run_dir
    run_dir="$(project_run_dir "$project_dir")"
    local ssh_port_file="$run_dir/ssh_port"

    if [[ ! -f "$ssh_port_file" ]]; then
        echo "No running VM found. Start one with 'claude-vm' first."
        echo "Skipping integration tests."
        return 0
    fi

    local ssh_port
    ssh_port=$(cat "$ssh_port_file")

    echo "Using VM on SSH port $ssh_port for project: $project_dir"
    echo ""

    # Ensure mount is up
    virtiofs_ensure_mounted "$ssh_port" 2>/dev/null || true

    run_test "virtiofs is mounted" test_integration_mount_exists "$ssh_port"
    run_test "read/write round-trip" test_integration_read_write_roundtrip "$ssh_port" "$project_dir"
    run_test "large file checksum (1MB)" test_integration_large_file "$ssh_port" "$project_dir"
    run_test "symlinks traversal" test_integration_symlinks "$ssh_port" "$project_dir"
    run_test "guest creates directory on host" test_integration_guest_creates_directory "$ssh_port" "$project_dir"
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    local run_integration=false
    local project_dir="$PWD"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --integration|-i)
                run_integration=true
                shift
                ;;
            --project)
                project_dir="$2"
                shift 2
                ;;
            *)
                echo "Usage: $0 [--integration] [--project DIR]" >&2
                exit 1
                ;;
        esac
    done

    run_unit_tests

    if $run_integration; then
        run_integration_tests "$project_dir"
    fi

    echo ""
    echo "─────────────────────────────────"
    echo "Results: $TESTS_RUN run, $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped"

    if (( TESTS_FAILED > 0 )); then
        exit 1
    fi
}

main "$@"
