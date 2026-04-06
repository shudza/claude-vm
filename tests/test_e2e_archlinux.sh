#!/usr/bin/env bash
# test_e2e_archlinux.sh — End-to-end tests for claude-vm with Arch Linux flavor
#
# Runs real QEMU VMs with virtiofs, testing the full CLI workflow:
#   build → launch → use → stop → resume → reset → destroy
#
# Mirrors test_e2e.sh but uses FLAVOR=archlinux.
#
# Prerequisites: /dev/kvm, qemu-system-x86_64, virtiofsd, genisoimage, etc.
# Skips gracefully (exit 0) if prerequisites are missing.
#
# Run: bash tests/test_e2e_archlinux.sh
#   or: make test-e2e-archlinux

# Note: no set -e — test runner handles errors via pass/fail/skip
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLAUDE_VM="$PROJECT_DIR/claude-vm"

# ── Test framework ───────────────────────────────────────────────────────────

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() { (( ++TESTS_PASSED )); (( ++TESTS_RUN )); echo "  PASS: $1"; }
fail() { (( ++TESTS_FAILED )); (( ++TESTS_RUN )); echo "  FAIL: $1 — $2"; }
skip() { (( ++TESTS_SKIPPED )); (( ++TESTS_RUN )); echo "  SKIP: $1"; }

PHASE_OK=true
_require_phase() {
    if [[ "$PHASE_OK" != "true" ]]; then
        skip "$1 (prerequisite phase failed)"
        return 1
    fi
    return 0
}

# ── Prerequisites ────────────────────────────────────────────────────────────

check_prerequisites() {
    local missing=()

    if [[ ! -r /dev/kvm ]] || [[ ! -w /dev/kvm ]]; then
        echo "SKIP: /dev/kvm not accessible (need KVM for E2E tests)"
        exit 0
    fi

    for cmd in qemu-system-x86_64 qemu-img curl socat rsync jq ssh; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    local vfs_found=false
    for candidate in virtiofsd /usr/lib/virtiofsd /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd /usr/lib/kvm/virtiofsd; do
        if command -v "$candidate" &>/dev/null || [[ -x "$candidate" ]]; then
            vfs_found=true
            break
        fi
    done
    $vfs_found || missing+=("virtiofsd")

    local has_iso=false
    for cmd in genisoimage mkisofs xorrisofs; do
        command -v "$cmd" &>/dev/null && has_iso=true && break
    done
    $has_iso || missing+=("genisoimage/mkisofs/xorrisofs")

    if (( ${#missing[@]} > 0 )); then
        echo "SKIP: Missing prerequisites: ${missing[*]}"
        exit 0
    fi
}

# ── Global setup ─────────────────────────────────────────────────────────────

E2E_DIR=""
FAKE_PROJECT_A=""
FAKE_PROJECT_B=""

setup_e2e() {
    E2E_DIR="$(mktemp -d /tmp/claude-vm-e2e-arch-XXXXXX)"
    export CLAUDE_VM_DIR="$E2E_DIR/data"
    export SSH_PORT_BASE=16022
    export FLAVOR=archlinux
    export CLAUDE_VM_QUIET=true

    FAKE_PROJECT_A="$E2E_DIR/project-arch-a"
    FAKE_PROJECT_B="$E2E_DIR/project-arch-b"
    mkdir -p "$FAKE_PROJECT_A" "$FAKE_PROJECT_B"
    echo "hello from arch project A" > "$FAKE_PROJECT_A/testfile.txt"
    echo "hello from arch project B" > "$FAKE_PROJECT_B/testfile.txt"
}

cleanup_e2e() {
    echo ""
    echo "Cleaning up..."

    if [[ -d "${CLAUDE_VM_DIR:-}/run" ]]; then
        for pid_file in "$CLAUDE_VM_DIR"/run/*/qemu.pid; do
            [[ -f "$pid_file" ]] || continue
            local pid
            pid=$(cat "$pid_file" 2>/dev/null) || continue
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done
        for pid_file in "$CLAUDE_VM_DIR"/run/*/virtiofsd.pid; do
            [[ -f "$pid_file" ]] || continue
            local pid
            pid=$(cat "$pid_file" 2>/dev/null) || continue
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done
    fi

    pkill -f "claude-vm-e2e-arch" 2>/dev/null || true
    sleep 1
    rm -rf "$E2E_DIR" 2>/dev/null || true
}

# ── Helpers ──────────────────────────────────────────────────────────────────

_e2e_ssh() {
    local project_dir="$1"
    shift
    local hash ssh_port key

    hash=$(echo -n "$project_dir" | sha256sum | cut -c1-12)
    ssh_port=$(cat "$CLAUDE_VM_DIR/run/$hash/ssh_port" 2>/dev/null) || return 1
    key="$CLAUDE_VM_DIR/keys/id_ed25519"

    ssh -i "$key" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        -p "$ssh_port" \
        "${VM_USER:-$USER}@localhost" "$@"
}

_e2e_launch() {
    local project_dir="$1"
    echo y | timeout 180 bash "$CLAUDE_VM" launch "$project_dir" 2>&1 | grep -v "^Error: Input must be" || true
}

_e2e_cmd() {
    local project_dir="$1"
    shift
    (cd "$project_dir" && bash "$CLAUDE_VM" "$@")
}

# ── Phase 1: Build ──────────────────────────────────────────────────────────

phase_build() {
    echo ""
    echo "=== Phase 1: Build ==="

    local output
    if output=$(timeout 600 bash "$CLAUDE_VM" build --flavor archlinux 2>&1); then
        local base_img="$CLAUDE_VM_DIR/base/base.qcow2"
        if [[ -f "$base_img" ]] && qemu-img check "$base_img" &>/dev/null; then
            pass "build creates valid base image"
        else
            fail "build creates valid base image" "file missing or corrupt"
            PHASE_OK=false
            return
        fi
    else
        fail "build creates valid base image" "claude-vm build failed (rc=$?)"
        echo "  Build output (last 20 lines):"
        echo "$output" | tail -20 | sed 's/^/    /'
        PHASE_OK=false
        return
    fi

    # Test: build is idempotent
    local start_time
    start_time=$(date +%s)
    output=$(timeout 30 bash "$CLAUDE_VM" build --flavor archlinux 2>&1) || true
    local elapsed=$(( $(date +%s) - start_time ))
    if echo "$output" | grep -q "already exists" && (( elapsed < 10 )); then
        pass "build is idempotent (${elapsed}s, prints 'already exists')"
    else
        fail "build is idempotent" "took ${elapsed}s or missing message"
    fi

    # Test: SSH keypair created
    if [[ -f "$CLAUDE_VM_DIR/keys/id_ed25519" ]] && [[ -f "$CLAUDE_VM_DIR/keys/id_ed25519.pub" ]]; then
        pass "build creates SSH keypair"
    else
        fail "build creates SSH keypair" "key files missing"
    fi
}

# ── Phase 2: Launch project A ───────────────────────────────────────────────

phase_launch() {
    echo ""
    echo "=== Phase 2: Launch project A ==="
    _require_phase "launch" || return

    _e2e_launch "$FAKE_PROJECT_A"

    # Test: status shows running
    local status_output
    status_output=$(_e2e_cmd "$FAKE_PROJECT_A" status 2>&1) || true
    if echo "$status_output" | grep -q "RUNNING"; then
        pass "status shows RUNNING after launch"
    else
        fail "status shows RUNNING after launch" "got: $(echo "$status_output" | grep -i status | head -1)"
        PHASE_OK=false
        return
    fi

    # Test: snapshot exists with correct backing
    local hash base_img snap_path
    hash=$(echo -n "$FAKE_PROJECT_A" | sha256sum | cut -c1-12)
    base_img="$CLAUDE_VM_DIR/base/base.qcow2"
    snap_path="$CLAUDE_VM_DIR/snapshots/${hash}.qcow2"
    if [[ -f "$snap_path" ]]; then
        local backing
        backing=$(qemu-img info -U --output=json "$snap_path" | jq -r '.["backing-filename"] // empty' 2>/dev/null)
        local resolved_backing resolved_base
        resolved_backing=$(realpath -m "$backing" 2>/dev/null || echo "$backing")
        resolved_base=$(realpath -m "$base_img" 2>/dev/null || echo "$base_img")
        if [[ "$resolved_backing" == "$resolved_base" ]]; then
            pass "snapshot exists with correct backing file"
        else
            fail "snapshot backing" "expected $resolved_base, got $resolved_backing"
        fi
    else
        fail "snapshot exists" "file not found: $snap_path"
    fi

    # Test: SSH works
    local ssh_output
    if ssh_output=$(_e2e_ssh "$FAKE_PROJECT_A" "echo ok" 2>/dev/null) && [[ "$ssh_output" == "ok" ]]; then
        pass "SSH into VM works"
    else
        fail "SSH into VM works" "got: '$ssh_output'"
        PHASE_OK=false
        return
    fi

    # Test: correct distro
    local distro_id
    distro_id=$(_e2e_ssh "$FAKE_PROJECT_A" "grep ^ID= /etc/os-release | cut -d= -f2" 2>/dev/null) || true
    if [[ "$distro_id" == "arch" ]]; then
        pass "guest is Arch Linux"
    else
        fail "guest is Arch Linux" "got ID=$distro_id"
    fi

    # Test: virtiofs mounted
    if _e2e_ssh "$FAKE_PROJECT_A" "mount | grep -q virtiofs" 2>/dev/null; then
        pass "virtiofs is mounted in guest"
    else
        fail "virtiofs is mounted in guest" "no virtiofs mount found"
    fi

    # Test: virtiofs read
    local guest_content
    guest_content=$(_e2e_ssh "$FAKE_PROJECT_A" "cat /workspace/testfile.txt" 2>/dev/null) || true
    if [[ "$guest_content" == "hello from arch project A" ]]; then
        pass "virtiofs read: host file readable from guest"
    else
        fail "virtiofs read" "expected 'hello from arch project A', got '$guest_content'"
    fi

    # Test: virtiofs write
    _e2e_ssh "$FAKE_PROJECT_A" "echo 'written by guest' > /workspace/write-test.txt" 2>/dev/null || true
    if [[ -f "$FAKE_PROJECT_A/write-test.txt" ]]; then
        local host_content
        host_content=$(cat "$FAKE_PROJECT_A/write-test.txt")
        if [[ "$host_content" == "written by guest" ]]; then
            pass "virtiofs write: guest file visible on host"
        else
            fail "virtiofs write content" "expected 'written by guest', got '$host_content'"
        fi
        rm -f "$FAKE_PROJECT_A/write-test.txt"
    else
        fail "virtiofs write" "file not visible on host"
    fi

    # Test: core packages installed (these come from the packages: block in cloud-init)
    local missing_pkgs=()
    for pkg in git rsync jq ripgrep curl cmake strace socat tmux tree openssh openbsd-netcat; do
        if ! _e2e_ssh "$FAKE_PROJECT_A" "pacman -Q $pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done
    if (( ${#missing_pkgs[@]} == 0 )); then
        pass "core packages installed (pacman -Q)"
    else
        fail "core packages installed" "missing: ${missing_pkgs[*]}"
    fi

    # Test: pacman available (Arch package manager)
    if _e2e_ssh "$FAKE_PROJECT_A" "command -v pacman" &>/dev/null; then
        pass "pacman available in guest"
    else
        fail "pacman available in guest" "not found"
    fi

    # Test: Claude Code installed
    if _e2e_ssh "$FAKE_PROJECT_A" "command -v claude || test -x /home/${VM_USER:-$USER}/.local/bin/claude" &>/dev/null; then
        pass "Claude Code installed in VM"
    else
        fail "Claude Code not installed in VM" "claude binary not found in PATH or ~/.local/bin"
    fi

    # Test: config sync — .bashrc should exist (written by cloud-init + synced)
    if _e2e_ssh "$FAKE_PROJECT_A" "test -f /home/${VM_USER:-$USER}/.bashrc" 2>/dev/null; then
        pass "config sync: .bashrc present in guest"
    else
        fail "config sync: .bashrc present in guest" "file missing"
    fi
}

# ── Phase 3: Multi-instance ─────────────────────────────────────────────────

phase_multi_instance() {
    echo ""
    echo "=== Phase 3: Multi-instance ==="
    _require_phase "multi-instance" || return

    _e2e_launch "$FAKE_PROJECT_B"

    # Test: both VMs running
    local list_output
    list_output=$(bash "$CLAUDE_VM" list 2>&1) || true
    local running_count
    running_count=$(echo "$list_output" | grep -c "RUNNING" || true)
    if (( running_count >= 2 )); then
        pass "two VMs running simultaneously"
    else
        fail "two VMs running" "found $running_count RUNNING entries"
    fi

    # Test: isolation — write in B doesn't appear in A
    _e2e_ssh "$FAKE_PROJECT_B" "echo 'from B' > /workspace/isolation-test.txt" 2>/dev/null || true
    if [[ -f "$FAKE_PROJECT_B/isolation-test.txt" ]] && [[ ! -f "$FAKE_PROJECT_A/isolation-test.txt" ]]; then
        pass "virtiofs isolation: project B write not visible in project A"
        rm -f "$FAKE_PROJECT_B/isolation-test.txt"
    else
        fail "virtiofs isolation" "file leaked between projects"
        rm -f "$FAKE_PROJECT_A/isolation-test.txt" "$FAKE_PROJECT_B/isolation-test.txt"
    fi
}

# ── Phase 4: Stop ───────────────────────────────────────────────────────────

phase_stop() {
    echo ""
    echo "=== Phase 4: Stop ==="
    _require_phase "stop" || return

    # Test: stop single project
    _e2e_cmd "$FAKE_PROJECT_A" stop &>/dev/null || true
    local status_a
    status_a=$(_e2e_cmd "$FAKE_PROJECT_A" status 2>&1) || true
    local hash_a snap_a
    hash_a=$(echo -n "$FAKE_PROJECT_A" | sha256sum | cut -c1-12)
    snap_a="$CLAUDE_VM_DIR/snapshots/${hash_a}.qcow2"
    if echo "$status_a" | grep -q "STOPPED" && [[ -f "$snap_a" ]]; then
        pass "stop: VM stopped, snapshot preserved"
    else
        fail "stop single" "status=$(echo "$status_a" | grep -i status | head -1), snap exists=$([[ -f "$snap_a" ]] && echo y || echo n)"
    fi

    # Test: stop --all
    timeout 30 bash "$CLAUDE_VM" stop --all &>/dev/null || true
    local hash_b snap_b
    hash_b=$(echo -n "$FAKE_PROJECT_B" | sha256sum | cut -c1-12)
    snap_b="$CLAUDE_VM_DIR/snapshots/${hash_b}.qcow2"
    local status_b
    status_b=$(_e2e_cmd "$FAKE_PROJECT_B" status 2>&1) || true
    if echo "$status_b" | grep -q "STOPPED" && [[ -f "$snap_a" ]] && [[ -f "$snap_b" ]]; then
        pass "stop --all: all VMs stopped, all snapshots preserved"
    else
        fail "stop --all" "B status=$(echo "$status_b" | grep -i status | head -1), snaps: A=$([[ -f "$snap_a" ]] && echo y || echo n) B=$([[ -f "$snap_b" ]] && echo y || echo n)"
    fi
}

# ── Phase 5: Resume ─────────────────────────────────────────────────────────

phase_resume() {
    echo ""
    echo "=== Phase 5: Resume ==="
    _require_phase "resume" || return

    # Re-launch project A (snapshot exists, no prompt)
    _e2e_launch "$FAKE_PROJECT_A"

    # Test: VM boots and SSH works
    if _e2e_ssh "$FAKE_PROJECT_A" "echo ok" 2>/dev/null | grep -q "ok"; then
        pass "resume: VM boots, SSH works"
    else
        fail "resume: SSH" "could not connect after resume"
        return
    fi

    # Test: virtiofs still works
    local content
    content=$(_e2e_ssh "$FAKE_PROJECT_A" "cat /workspace/testfile.txt" 2>/dev/null) || true
    if [[ "$content" == "hello from arch project A" ]]; then
        pass "resume: virtiofs mount works"
    else
        fail "resume: virtiofs" "got '$content'"
    fi

    # Test: snapshot delta persists (cloud-init wrote .bashrc to the overlay)
    if _e2e_ssh "$FAKE_PROJECT_A" "test -f /home/${VM_USER:-$USER}/.bashrc" 2>/dev/null; then
        pass "resume: qcow2 overlay persists across stop+start"
    else
        fail "resume: overlay persistence" ".bashrc missing"
    fi

    # Stop for next phases
    _e2e_cmd "$FAKE_PROJECT_A" stop &>/dev/null || true
}

# ── Phase 6: Reset ──────────────────────────────────────────────────────────

phase_reset() {
    echo ""
    echo "=== Phase 6: Reset ==="
    _require_phase "reset" || return

    local hash_a snap_a
    hash_a=$(echo -n "$FAKE_PROJECT_A" | sha256sum | cut -c1-12)
    snap_a="$CLAUDE_VM_DIR/snapshots/${hash_a}.qcow2"

    # Test: reset removes snapshot
    _e2e_cmd "$FAKE_PROJECT_A" reset &>/dev/null || true
    if [[ ! -f "$snap_a" ]]; then
        pass "reset removes snapshot"
    else
        fail "reset removes snapshot" "file still exists"
    fi

    # Test: relaunch after reset creates fresh snapshot and boots
    _e2e_launch "$FAKE_PROJECT_A"
    if [[ -f "$snap_a" ]] && _e2e_ssh "$FAKE_PROJECT_A" "echo ok" 2>/dev/null | grep -q "ok"; then
        pass "reset+relaunch: fresh snapshot, VM boots"
    else
        fail "reset+relaunch" "snap exists=$([[ -f "$snap_a" ]] && echo y || echo n)"
    fi

    _e2e_cmd "$FAKE_PROJECT_A" stop &>/dev/null || true
}

# ── Phase 7: Destroy ────────────────────────────────────────────────────────

phase_destroy() {
    echo ""
    echo "=== Phase 7: Destroy ==="
    _require_phase "destroy" || return

    local hash_b snap_b run_b
    hash_b=$(echo -n "$FAKE_PROJECT_B" | sha256sum | cut -c1-12)
    snap_b="$CLAUDE_VM_DIR/snapshots/${hash_b}.qcow2"
    run_b="$CLAUDE_VM_DIR/run/$hash_b"

    # Ensure stopped first
    _e2e_cmd "$FAKE_PROJECT_B" stop &>/dev/null || true

    # Test: destroy removes artifacts
    _e2e_cmd "$FAKE_PROJECT_B" destroy &>/dev/null || true
    if [[ ! -f "$snap_b" ]] && [[ ! -d "$run_b" ]]; then
        pass "destroy removes snapshot and run directory"
    else
        fail "destroy" "snap=$([[ -f "$snap_b" ]] && echo exists || echo gone), run=$([[ -d "$run_b" ]] && echo exists || echo gone)"
    fi

    # Test: relaunch after destroy works (creates fresh snapshot from base)
    _e2e_launch "$FAKE_PROJECT_B"
    if [[ -f "$snap_b" ]] && _e2e_ssh "$FAKE_PROJECT_B" "echo ok" 2>/dev/null | grep -q "ok"; then
        pass "destroy+relaunch: fresh snapshot from base, VM boots"
    else
        fail "destroy+relaunch" "snap=$([[ -f "$snap_b" ]] && echo exists || echo gone)"
    fi

    _e2e_cmd "$FAKE_PROJECT_B" stop &>/dev/null || true
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    check_prerequisites
    setup_e2e
    trap cleanup_e2e EXIT INT TERM

    echo "=== claude-vm E2E tests (archlinux) ==="
    echo "E2E_DIR: $E2E_DIR"
    echo "CLAUDE_VM_DIR: $CLAUDE_VM_DIR"

    phase_build
    phase_launch
    phase_multi_instance
    phase_stop
    phase_resume
    phase_reset
    phase_destroy

    echo ""
    echo "=== Results (archlinux): $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped, $TESTS_RUN total ==="

    (( TESTS_FAILED > 0 )) && exit 1
    exit 0
}

main "$@"
