#!/usr/bin/env bash
# test_resume_boot.sh — Tests for fast resume boot (<20 seconds)
#
# Tests cover:
# - VM state snapshot detection
# - SSH readiness polling
# - Boot timing measurement
# - Resume vs cold boot path selection
# - Performance threshold validation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  ✅ $1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  ❌ $1: $2"
}

# --- Unit tests for wait-ready.sh ---

test_ssh_probe_unreachable() {
    source "${LIB_DIR}/wait-ready.sh"
    # Probe a port that's definitely not listening
    if ! ssh_probe "localhost" "59999" 2>/dev/null; then
        pass "ssh_probe returns failure for unreachable port"
    else
        fail "ssh_probe returns failure for unreachable port" "expected failure"
    fi
}

test_wait_for_ssh_timeout() {
    source "${LIB_DIR}/wait-ready.sh"
    # Should timeout quickly when nothing is listening
    local start
    start=$(date +%s)
    if ! wait_for_ssh "localhost" "59999" 3 2>/dev/null; then
        local elapsed=$(($(date +%s) - start))
        if [[ $elapsed -ge 2 && $elapsed -le 5 ]]; then
            pass "wait_for_ssh times out within expected window"
        else
            fail "wait_for_ssh times out within expected window" "took ${elapsed}s"
        fi
    else
        fail "wait_for_ssh times out within expected window" "should have timed out"
    fi
}

test_is_vm_ssh_reachable_negative() {
    source "${LIB_DIR}/wait-ready.sh"
    if ! is_vm_ssh_reachable "localhost" "59999"; then
        pass "is_vm_ssh_reachable returns false for closed port"
    else
        fail "is_vm_ssh_reachable returns false for closed port" "expected false"
    fi
}

# --- Unit tests for boot-timer.sh ---

test_check_boot_target_pass() {
    source "${LIB_DIR}/boot-timer.sh"
    if check_boot_target 15000; then
        pass "check_boot_target passes for 15s (under 20s target)"
    else
        fail "check_boot_target passes for 15s" "expected pass"
    fi
}

test_check_boot_target_fail() {
    source "${LIB_DIR}/boot-timer.sh"
    if ! check_boot_target 25000; then
        pass "check_boot_target fails for 25s (over 20s target)"
    else
        fail "check_boot_target fails for 25s" "expected fail"
    fi
}

test_check_boot_target_boundary() {
    source "${LIB_DIR}/boot-timer.sh"
    if check_boot_target 20000; then
        pass "check_boot_target passes at exactly 20s"
    else
        fail "check_boot_target passes at exactly 20s" "expected pass"
    fi
}

test_log_boot_timing() {
    source "${LIB_DIR}/boot-timer.sh"
    local tmpdir
    tmpdir=$(mktemp -d)
    TIMING_LOG="${tmpdir}/timing.log"

    log_boot_timing "test-project" "resume" "3500" "ok"

    if [[ -f "$TIMING_LOG" ]] && grep -q "test-project resume 3500ms ok" "$TIMING_LOG"; then
        pass "log_boot_timing writes correct entry"
    else
        fail "log_boot_timing writes correct entry" "log content: $(cat "$TIMING_LOG" 2>/dev/null)"
    fi

    rm -rf "$tmpdir"
}

test_get_avg_resume_time() {
    source "${LIB_DIR}/boot-timer.sh"
    local tmpdir
    tmpdir=$(mktemp -d)
    TIMING_LOG="${tmpdir}/timing.log"

    # Write some test entries
    echo "2026-01-01T00:00:00+00:00 proj1 resume 3000ms ok" > "$TIMING_LOG"
    echo "2026-01-01T00:01:00+00:00 proj1 resume 5000ms ok" >> "$TIMING_LOG"
    echo "2026-01-01T00:02:00+00:00 proj1 coldboot 30000ms ok" >> "$TIMING_LOG"
    echo "2026-01-01T00:03:00+00:00 proj2 resume 4000ms ok" >> "$TIMING_LOG"

    local avg
    avg=$(get_avg_resume_time "proj1")
    if [[ "$avg" == "4000" ]]; then
        pass "get_avg_resume_time calculates correct average"
    else
        fail "get_avg_resume_time calculates correct average" "got $avg, expected 4000"
    fi

    rm -rf "$tmpdir"
}

# --- Unit tests for resume.sh ---

test_has_vm_state_missing_file() {
    source "${LIB_DIR}/resume.sh"
    if ! has_vm_state "/nonexistent/file.qcow2"; then
        pass "has_vm_state returns false for missing file"
    else
        fail "has_vm_state returns false for missing file" "expected false"
    fi
}

test_build_resume_args_no_state() {
    source "${LIB_DIR}/resume.sh"
    local tmpdir
    tmpdir=$(mktemp -d)
    local fake_qcow2="${tmpdir}/test.qcow2"
    touch "$fake_qcow2"

    # build_resume_args should return exit code 1 (cold boot)
    if ! build_resume_args "$fake_qcow2" >/dev/null 2>&1; then
        pass "build_resume_args returns cold-boot mode for snapshot without VM state"
    else
        fail "build_resume_args returns cold-boot mode" "expected exit code 1"
    fi

    rm -rf "$tmpdir"
}

test_elapsed_ms() {
    source "${LIB_DIR}/resume.sh"
    local start
    start=$(date +%s%N)
    sleep 0.1
    local elapsed
    elapsed=$(elapsed_ms "$start")
    if [[ $elapsed -ge 50 && $elapsed -le 500 ]]; then
        pass "elapsed_ms measures ~100ms correctly (got ${elapsed}ms)"
    else
        fail "elapsed_ms measures ~100ms correctly" "got ${elapsed}ms"
    fi
}

# --- Unit tests for qemu-opts.sh ---

test_build_base_qemu_args() {
    source "${LIB_DIR}/qemu-opts.sh"
    local tmpdir
    tmpdir=$(mktemp -d)
    local args
    args=$(build_base_qemu_args "${tmpdir}/test.qcow2" "4G" "2" "2222" "${tmpdir}/qmp.sock" "${tmpdir}/vm.pid")

    # Verify key arguments are present
    local checks_ok=true
    for expected in "-enable-kvm" "-cpu" "host" "-smp" "2" "-m" "4G" "-daemonize" "-nographic" "io_uring"; do
        if ! echo "$args" | grep -qF -- "$expected"; then
            fail "build_base_qemu_args contains '$expected'" "not found in output"
            checks_ok=false
            break
        fi
    done
    if $checks_ok; then
        pass "build_base_qemu_args contains all required flags"
    fi

    rm -rf "$tmpdir"
}

test_build_resume_qemu_args() {
    source "${LIB_DIR}/qemu-opts.sh"
    local tmpdir
    tmpdir=$(mktemp -d)
    local args
    args=$(build_resume_qemu_args "${tmpdir}/test.qcow2" "4G" "2" "2222" "${tmpdir}/qmp.sock" "${tmpdir}/vm.pid" "claude-vm-state")

    if echo "$args" | grep -q "\-loadvm" && echo "$args" | grep -q "claude-vm-state"; then
        pass "build_resume_qemu_args includes -loadvm flag"
    else
        fail "build_resume_qemu_args includes -loadvm flag" "not found"
    fi

    rm -rf "$tmpdir"
}

test_build_virtiofs_qemu_args() {
    source "${LIB_DIR}/qemu-opts.sh"
    local args
    args=$(build_virtiofs_qemu_args "/tmp/vfs.sock" "workspace")

    if echo "$args" | grep -q "vhost-user-fs-pci" && echo "$args" | grep -q "workspace"; then
        pass "build_virtiofs_qemu_args includes virtiofs device"
    else
        fail "build_virtiofs_qemu_args includes virtiofs device" "not found"
    fi
}

# --- Run all tests ---

echo ""
echo "=== claude-vm Resume Boot Tests ==="
echo ""

echo "SSH Readiness Tests:"
test_ssh_probe_unreachable
test_wait_for_ssh_timeout
test_is_vm_ssh_reachable_negative

echo ""
echo "Boot Timer Tests:"
test_check_boot_target_pass
test_check_boot_target_fail
test_check_boot_target_boundary
test_log_boot_timing
test_get_avg_resume_time

echo ""
echo "Resume Logic Tests:"
test_has_vm_state_missing_file
test_build_resume_args_no_state
test_elapsed_ms

echo ""
echo "QEMU Options Tests:"
test_build_base_qemu_args
test_build_resume_qemu_args
test_build_virtiofs_qemu_args

echo ""
echo "=== Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed ==="
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
