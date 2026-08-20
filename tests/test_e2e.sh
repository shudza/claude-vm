#!/usr/bin/env bash
# test_e2e.sh — End-to-end tests for claude-vm
#
# Runs real QEMU VMs with virtiofs, testing the full CLI workflow:
#   build → launch → config sync → use → stop → resume → rebase → reset → destroy → full flavor
#
# Prerequisites: /dev/kvm, qemu-system-x86_64, virtiofsd, genisoimage, etc.
# Skips gracefully (exit 0) if prerequisites are missing.
#
# Expected environment: a claude-vm instance (nested KVM) or any
# KVM-capable Linux host with all deps installed.
#
# Run: bash tests/test_e2e.sh
#   or: make test-e2e

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

# Phase gating — if a critical phase fails, skip dependent phases
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

    # virtiofsd is often not in PATH — check common install locations
    local vfs_found=false
    for candidate in virtiofsd /usr/lib/virtiofsd /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd /usr/lib/kvm/virtiofsd; do
        if command -v "$candidate" &>/dev/null || [[ -x "$candidate" ]]; then
            vfs_found=true
            break
        fi
    done
    $vfs_found || missing+=("virtiofsd")

    # Need at least one ISO tool
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
FAKE_PROJECT_C=""
FAKE_PROJECT_D=""

setup_e2e() {
    E2E_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-e2e-XXXXXX")"
    export CLAUDE_VM_DIR="$E2E_DIR/data"
    export SSH_PORT_BASE=15022
    export CLAUDE_VM_QUIET=true

    FAKE_PROJECT_A="$E2E_DIR/project-a"
    FAKE_PROJECT_B="$E2E_DIR/project-b"
    FAKE_PROJECT_C="$E2E_DIR/project-c"
    FAKE_PROJECT_D="$E2E_DIR/project-d"
    mkdir -p "$FAKE_PROJECT_A" "$FAKE_PROJECT_B" "$FAKE_PROJECT_C" "$FAKE_PROJECT_D"
    echo "hello from project A" > "$FAKE_PROJECT_A/testfile.txt"
    echo "hello from project B" > "$FAKE_PROJECT_B/testfile.txt"
    echo "hello from project C" > "$FAKE_PROJECT_C/testfile.txt"
}

cleanup_e2e() {
    echo ""
    echo "Cleaning up..."

    # Stop all VMs gracefully (best effort)
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

    # Safety net
    pkill -f "claude-vm-e2e" 2>/dev/null || true

    sleep 1
    rm -rf "$E2E_DIR" 2>/dev/null || true
}

# ── Helpers ──────────────────────────────────────────────────────────────────

# SSH into a project's VM
# Usage: _e2e_ssh /path/to/project "command"
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

# Launch a project VM for testing
# Handles the interactive prompt and the exec-ssh exit
_e2e_launch() {
    local project_dir="$1"
    # echo y answers the first-launch confirmation prompt.
    # After the prompt is consumed, stdin hits EOF. The VM setup completes
    # fully, then exec ssh -t tries to launch Claude Code which fails
    # because there's no TTY/input. That error is expected and filtered.
    echo y | timeout 180 bash "$CLAUDE_VM" launch "$project_dir" 2>&1 | grep -v "^Error: Input must be" || true
}

# Run claude-vm from a project directory
_e2e_cmd() {
    local project_dir="$1"
    shift
    (cd "$project_dir" && bash "$CLAUDE_VM" "$@")
}

# ── Phase 1: Build ──────────────────────────────────────────────────────────

phase_build() {
    echo ""
    echo "=== Phase 1: Build ==="

    # Test: build creates base image (default flavor is debian-slim)
    local output
    if output=$(timeout 600 bash "$CLAUDE_VM" build 2>&1); then
        local base_img="$CLAUDE_VM_DIR/base/base-debian-slim.qcow2"
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
    output=$(timeout 30 bash "$CLAUDE_VM" build 2>&1) || true
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
    base_img="$CLAUDE_VM_DIR/base/base-debian-slim.qcow2"
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

    # Test: virtiofs mounted
    if _e2e_ssh "$FAKE_PROJECT_A" "mount | grep -q virtiofs" 2>/dev/null; then
        pass "virtiofs is mounted in guest"
    else
        fail "virtiofs is mounted in guest" "no virtiofs mount found"
    fi

    # Test: virtiofs read
    local guest_content
    guest_content=$(_e2e_ssh "$FAKE_PROJECT_A" "cat /workspace/testfile.txt" 2>/dev/null) || true
    if [[ "$guest_content" == "hello from project A" ]]; then
        pass "virtiofs read: host file readable from guest"
    else
        fail "virtiofs read" "expected 'hello from project A', got '$guest_content'"
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

    # Test: slim packages installed (these come from the packages: block in cloud-init)
    local missing_pkgs=()
    for pkg in git rsync jq ripgrep curl less zip unzip gh nodejs npm python3-venv; do
        if ! _e2e_ssh "$FAKE_PROJECT_A" "dpkg -s $pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done
    if (( ${#missing_pkgs[@]} == 0 )); then
        pass "slim packages installed (dpkg -s)"
    else
        fail "slim packages installed" "missing: ${missing_pkgs[*]}"
    fi

    # Test: full-only packages are NOT in the slim image
    if ! _e2e_ssh "$FAKE_PROJECT_A" "dpkg -s tmux" &>/dev/null; then
        pass "full-only package (tmux) absent from slim image"
    else
        fail "slim excludes full tools" "tmux is installed in slim image"
    fi

    # Test: node and gh actually run
    local ver_failures="" ver_cmd ver_out
    for ver_cmd in "node --version" "npm --version" "gh --version"; do
        if ! ver_out=$(_e2e_ssh "$FAKE_PROJECT_A" "$ver_cmd" 2>&1); then
            ver_failures+="'$ver_cmd' → ${ver_out:0:120}; "
        fi
    done
    if [[ -z "$ver_failures" ]]; then
        pass "node, npm, and gh run in the guest"
    else
        fail "node/npm/gh run" "$ver_failures"
    fi

    # Test: Claude Code installed
    if _e2e_ssh "$FAKE_PROJECT_A" "command -v claude || test -x /home/${VM_USER:-$USER}/.local/bin/claude" &>/dev/null; then
        pass "Claude Code installed in VM"
    else
        fail "Claude Code not installed in VM" "claude binary not found in PATH or ~/.local/bin"
    fi

    # Test: default CPU count reaches the guest (4, clamped to host cores)
    local host_cpus expected_cpus guest_cpus
    host_cpus=$(nproc 2>/dev/null || echo 4)
    expected_cpus=$(( host_cpus < 4 ? host_cpus : 4 ))
    guest_cpus=$(_e2e_ssh "$FAKE_PROJECT_A" "nproc" 2>/dev/null) || true
    if [[ "$guest_cpus" == "$expected_cpus" ]]; then
        pass "guest nproc is $expected_cpus (default VM_CPUS clamped to host)"
    else
        fail "guest nproc" "expected $expected_cpus, got '$guest_cpus'"
    fi

    # Test: `claude-vm ssh` shell exports CLAUDE_CODE_PROJECT_DIR_NAME. With
    # stdin not a tty, ssh -t degrades to a plain command and the login shell
    # reads the piped command.
    local shell_env
    shell_env=$(echo 'echo "name=$CLAUDE_CODE_PROJECT_DIR_NAME cfg=$CLAUDE_CONFIG_DIR"' | _e2e_cmd "$FAKE_PROJECT_A" ssh 2>/dev/null) || true
    if echo "$shell_env" | grep -q "^name=project-a cfg=.*/.claude$"; then
        pass "claude-vm ssh exports CLAUDE_CODE_PROJECT_DIR_NAME=project-a and CLAUDE_CONFIG_DIR"
    else
        fail "claude-vm ssh project dir name" "got: '$shell_env'"
    fi

    # Test: upgrade path — a VM created before CLAUDE_CONFIG_DIR was exported
    # (config at ~/.claude.json, transcripts in projects/-workspace) must be
    # migrated by the next connect, not re-run onboarding with empty history
    _e2e_ssh "$FAKE_PROJECT_A" "rm -f ~/.claude/.claude.json \
        && echo '{\"legacy\":\"cfg-sentinel\"}' > ~/.claude.json \
        && rm -rf ~/.claude/projects \
        && mkdir -p ~/.claude/projects/-workspace \
        && echo transcript > ~/.claude/projects/-workspace/legacy-convo.jsonl" 2>/dev/null || true

    echo "" | _e2e_cmd "$FAKE_PROJECT_A" ssh &>/dev/null || true

    local migrated_cfg
    migrated_cfg=$(_e2e_ssh "$FAKE_PROJECT_A" "cat ~/.claude/.claude.json" 2>/dev/null) || true
    if echo "$migrated_cfg" | grep -q "cfg-sentinel"; then
        pass "upgrade: legacy ~/.claude.json copied to ~/.claude/.claude.json on connect"
    else
        fail "upgrade config migration" "got: '$migrated_cfg'"
    fi
    if _e2e_ssh "$FAKE_PROJECT_A" "test -f ~/.claude/projects/project-a/legacy-convo.jsonl && test ! -e ~/.claude/projects/-workspace" 2>/dev/null; then
        pass "upgrade: -workspace transcripts renamed to projects/project-a on connect"
    else
        fail "upgrade transcript migration" "$(_e2e_ssh "$FAKE_PROJECT_A" "ls ~/.claude/projects" 2>/dev/null | tr '\n' ' ')"
    fi
}

# ── Phase 2b: Config sync ───────────────────────────────────────────────────

phase_config_sync() {
    echo ""
    echo "=== Phase 2b: Config sync (fake HOME) ==="
    _require_phase "config sync" || return

    # The other launches sync the real $HOME. A fake home makes the
    # include-list assertable: user-scope customizations in, runtime state out.
    local fake_home="$E2E_DIR/home"
    mkdir -p "$fake_home/.claude/agents" "$fake_home/.claude/commands" \
             "$fake_home/.claude/workflows" "$fake_home/.claude/skills/demo" \
             "$fake_home/.claude/sessions" "$fake_home/.claude/cache" \
             "$fake_home/.config/gh" "$fake_home/.config/glab-cli"
    echo '{"e2e":"settings"}'          > "$fake_home/.claude/settings.json"
    echo "agent body"                  > "$fake_home/.claude/agents/e2e-agent.md"
    echo "command body"                > "$fake_home/.claude/commands/e2e-cmd.md"
    echo "workflow body"               > "$fake_home/.claude/workflows/e2e-wf.md"
    echo '{"e2e":"keys"}'              > "$fake_home/.claude/keybindings.json"
    echo "skill body"                  > "$fake_home/.claude/skills/demo/SKILL.md"
    echo "junk"                        > "$fake_home/.claude/sessions/junk"
    echo "junk"                        > "$fake_home/.claude/cache/junk"
    echo '{"hasCompletedOnboarding":true}' > "$fake_home/.claude.json"
    echo "gh: e2e"                     > "$fake_home/.config/gh/hosts.yml"
    echo "glab: e2e-sentinel"          > "$fake_home/.config/glab-cli/config.yml"

    HOME="$fake_home" _e2e_launch "$FAKE_PROJECT_D"

    if ! _e2e_ssh "$FAKE_PROJECT_D" "echo ok" 2>/dev/null | grep -q ok; then
        fail "config-sync VM launch" "SSH not reachable for project D"
        _e2e_cmd "$FAKE_PROJECT_D" stop &>/dev/null || true
        return
    fi

    local missing=() f
    for f in .claude/settings.json .claude/.claude.json .claude/agents/e2e-agent.md \
             .claude/commands/e2e-cmd.md .claude/workflows/e2e-wf.md \
             .claude/keybindings.json .claude/skills/demo/SKILL.md \
             .config/gh/hosts.yml .config/glab-cli/config.yml; do
        _e2e_ssh "$FAKE_PROJECT_D" "test -f ~/$f" &>/dev/null || missing+=("$f")
    done
    if (( ${#missing[@]} == 0 )); then
        pass "agents, commands, workflows, keybindings, skills, gh and glab-cli synced into guest"
    else
        fail "config sync includes" "missing in guest: ${missing[*]}"
    fi

    local glab_guest
    glab_guest=$(_e2e_ssh "$FAKE_PROJECT_D" "cat ~/.config/glab-cli/config.yml" 2>/dev/null) || true
    if [[ "$glab_guest" == "glab: e2e-sentinel" ]]; then
        pass "glab-cli config content matches host"
    else
        fail "glab-cli config content" "got '$glab_guest'"
    fi

    # Note: guests DO have a ~/.claude.json — the Claude Code installer bakes
    # one (machineID, installMethod) into the base image. Claude ignores it
    # when CLAUDE_CONFIG_DIR is set; the sync just must not write there.
    local leaked=()
    for f in .claude/sessions/junk .claude/cache/junk; do
        _e2e_ssh "$FAKE_PROJECT_D" "test -e ~/$f" &>/dev/null && leaked+=("$f")
    done
    if (( ${#leaked[@]} == 0 )); then
        pass "runtime state (sessions, cache) not synced into guest"
    else
        fail "config sync excludes" "leaked into guest: ${leaked[*]}"
    fi
    local guest_cfg
    guest_cfg=$(_e2e_ssh "$FAKE_PROJECT_D" "cat ~/.claude/.claude.json" 2>/dev/null) || true
    if echo "$guest_cfg" | grep -q "hasCompletedOnboarding"; then
        pass "guest reads the synced config at ~/.claude/.claude.json"
    else
        fail "config-dir json content" "got: '$guest_cfg'"
    fi

    _e2e_cmd "$FAKE_PROJECT_D" stop &>/dev/null || true
    _e2e_cmd "$FAKE_PROJECT_D" destroy &>/dev/null || true
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
    if [[ "$content" == "hello from project A" ]]; then
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

# ── Phase 6: Rebase ─────────────────────────────────────────────────────────

phase_rebase() {
    echo ""
    echo "=== Phase 6: Rebase ==="
    _require_phase "rebase" || return

    local hash_a snap_a backup_a
    hash_a=$(echo -n "$FAKE_PROJECT_A" | sha256sum | cut -c1-12)
    snap_a="$CLAUDE_VM_DIR/snapshots/${hash_a}.qcow2"
    backup_a="$CLAUDE_VM_DIR/backups/${hash_a}"

    # Stop project A if running (project B may still be running from multi-instance)
    _e2e_cmd "$FAKE_PROJECT_A" stop &>/dev/null || true

    # Also stop project B if running
    _e2e_cmd "$FAKE_PROJECT_B" stop &>/dev/null || true

    # Write a sentinel value into ~/.claude/settings.json inside project A's VM
    # by re-launching, SSH-ing in, and modifying the file
    _e2e_launch "$FAKE_PROJECT_A"

    # Write sentinel to ~/.claude/settings.json
    _e2e_ssh "$FAKE_PROJECT_A" "mkdir -p ~/.claude && echo '{\"sentinel\":\"rebase-test-12345\"}' > ~/.claude/settings.json" 2>/dev/null || true

    # Runtime state that must NOT survive, transcript + glab auth that must
    # (transcripts live under the project's dir name since CLAUDE_CODE_PROJECT_DIR_NAME)
    _e2e_ssh "$FAKE_PROJECT_A" "mkdir -p ~/.claude/jobs ~/.claude/daemon ~/.claude/projects/project-a ~/.config/glab-cli \
        && echo job > ~/.claude/jobs/e2e-sentinel \
        && echo 99999 > ~/.claude/daemon/e2e-sentinel.lock \
        && echo transcript > ~/.claude/projects/project-a/e2e-sentinel.jsonl \
        && echo glab > ~/.config/glab-cli/e2e-sentinel" 2>/dev/null || true

    # Stop the VM before rebase
    _e2e_cmd "$FAKE_PROJECT_A" stop &>/dev/null || true

    # Record old base image mtime
    local old_base_mtime
    old_base_mtime=$(stat -c%Y "$CLAUDE_VM_DIR/base/base-debian-slim.qcow2" 2>/dev/null || echo 0)

    # Record old snapshot path
    local old_snap_path="$snap_a"
    local old_snap_exists=$([[ -f "$old_snap_path" ]] && echo 1 || echo 0)

    # Run rebase with --yes to skip confirmation. Rebase re-pulls the cloud
    # image and re-provisions the base, so on a cold network the total time
    # can rival the original build. Give it plenty.
    local rebase_output
    if rebase_output=$(timeout 1200 bash "$CLAUDE_VM" rebase --yes 2>&1); then
        pass "rebase command succeeded"
    else
        fail "rebase command" "exit code $?, output: $(echo "$rebase_output" | tail -5)"
        PHASE_OK=false
        return
    fi

    # Test: base image mtime is newer
    local new_base_mtime
    new_base_mtime=$(stat -c%Y "$CLAUDE_VM_DIR/base/base-debian-slim.qcow2" 2>/dev/null || echo 0)
    if (( new_base_mtime > old_base_mtime )); then
        pass "base image rebuilt (mtime newer)"
    else
        fail "base image rebuilt" "old=$old_base_mtime, new=$new_base_mtime"
    fi

    # Test: old snapshot is gone
    if [[ "$old_snap_exists" -eq 1 ]] && [[ ! -f "$old_snap_path" ]]; then
        pass "old snapshot removed after rebase"
    else
        fail "old snapshot removed" "exists=$([[ -f "$old_snap_path" ]] && echo y || echo n)"
    fi

    # Test: backup dir exists for the project
    if [[ -d "$backup_a" ]]; then
        pass "backup dir created during extraction"
    else
        fail "backup dir created" "not found: $backup_a"
    fi

    # Test: backup carries transcripts + glab-cli but no runtime state
    if [[ -f "$backup_a/.claude/projects/project-a/e2e-sentinel.jsonl" ]] \
       && [[ -f "$backup_a/.config/glab-cli/e2e-sentinel" ]]; then
        pass "backup contains transcripts and glab-cli config"
    else
        fail "backup payload" "transcript or glab-cli sentinel missing from $backup_a"
    fi
    if [[ ! -e "$backup_a/.claude/jobs" ]] && [[ ! -e "$backup_a/.claude/daemon" ]]; then
        pass "backup excludes ~/.claude runtime state (jobs, daemon)"
    else
        fail "backup excludes runtime state" "found: $(ls -d "$backup_a"/.claude/{jobs,daemon} 2>/dev/null | tr '\n' ' ')"
    fi

    # Test: relaunch creates fresh snapshot from new base
    _e2e_launch "$FAKE_PROJECT_A"

    if [[ -f "$snap_a" ]]; then
        pass "new snapshot created on relaunch after rebase"
    else
        fail "new snapshot created" "not found: $snap_a"
    fi

    # Test: sentinel value was restored (proves restore happened)
    local restored_settings
    restored_settings=$(_e2e_ssh "$FAKE_PROJECT_A" "cat ~/.claude/settings.json" 2>/dev/null) || true
    if echo "$restored_settings" | grep -q "rebase-test-12345"; then
        pass "VM state restored from backup (sentinel found)"
    else
        fail "VM state restored" "sentinel not found in settings.json, got: '$restored_settings'"
    fi

    # Test: runtime-state sentinels did not come back; transcript + glab did
    if _e2e_ssh "$FAKE_PROJECT_A" "test -f ~/.claude/projects/project-a/e2e-sentinel.jsonl && test -f ~/.config/glab-cli/e2e-sentinel" 2>/dev/null; then
        pass "transcript and glab-cli config restored after rebase"
    else
        fail "transcript/glab-cli restore" "sentinels missing in relaunched VM"
    fi
    if ! _e2e_ssh "$FAKE_PROJECT_A" "test -e ~/.claude/jobs/e2e-sentinel || test -e ~/.claude/daemon/e2e-sentinel.lock" 2>/dev/null; then
        pass "daemon/jobs runtime state not carried into the fresh VM"
    else
        fail "runtime state dropped" "jobs/daemon sentinel present after rebase"
    fi

    # Test: backup dir is gone after successful restore
    if [[ ! -d "$backup_a" ]]; then
        pass "backup dir consumed after restore"
    else
        fail "backup dir consumed" "still exists: $backup_a"
    fi

    # Clean up for next phases
    _e2e_cmd "$FAKE_PROJECT_A" stop &>/dev/null || true
}

phase_reset() {
    echo ""
    echo "=== Phase 7: Reset ==="
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
    echo "=== Phase 8: Destroy ==="
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

# ── Phase 9: Full flavor ────────────────────────────────────────────────────

phase_full_flavor() {
    echo ""
    echo "=== Phase 9: Full flavor (debian-full) ==="
    _require_phase "full flavor" || return

    local slim_base="$CLAUDE_VM_DIR/base/base-debian-slim.qcow2"
    local full_base="$CLAUDE_VM_DIR/base/base-debian-full.qcow2"

    # Test: building debian-full creates its own base image
    local output
    if output=$(timeout 600 bash "$CLAUDE_VM" build --flavor debian-full 2>&1); then
        if [[ -f "$full_base" ]] && qemu-img check "$full_base" &>/dev/null; then
            pass "debian-full build creates its own base image"
        else
            fail "debian-full build" "base image missing or corrupt"
            return
        fi
    else
        fail "debian-full build" "claude-vm build --flavor debian-full failed"
        echo "$output" | tail -20 | sed 's/^/    /'
        return
    fi

    # Test: both flavor bases coexist
    if [[ -f "$slim_base" && -f "$full_base" ]]; then
        pass "slim and full base images coexist"
    else
        fail "base coexistence" "slim=$([[ -f "$slim_base" ]] && echo y || echo n) full=$([[ -f "$full_base" ]] && echo y || echo n)"
    fi

    # Test: list shows both bases
    local list_output
    list_output=$(bash "$CLAUDE_VM" list 2>&1) || true
    if echo "$list_output" | grep -q "base-debian-slim.qcow2" && \
       echo "$list_output" | grep -q "base-debian-full.qcow2"; then
        pass "list shows both flavor bases"
    else
        fail "list shows bases" "$(echo "$list_output" | grep base || echo 'no base lines')"
    fi

    # Launch a project against the full flavor
    export FLAVOR=debian-full
    _e2e_launch "$FAKE_PROJECT_C"
    unset FLAVOR

    local hash_c snap_c
    hash_c=$(echo -n "$FAKE_PROJECT_C" | sha256sum | cut -c1-12)
    snap_c="$CLAUDE_VM_DIR/snapshots/${hash_c}.qcow2"

    # Test: snapshot backs onto the full base
    local backing
    backing=$(qemu-img info -U --output=json "$snap_c" 2>/dev/null | jq -r '.["backing-filename"] // empty' 2>/dev/null)
    if [[ "$(basename "$backing")" == "base-debian-full.qcow2" ]]; then
        pass "full-flavor snapshot backs onto base-debian-full.qcow2"
    else
        fail "full snapshot backing" "got: $backing"
    fi

    # Test: build tools present in the full image
    local missing_pkgs=()
    local pkg
    for pkg in build-essential cmake tmux strace wget glab; do
        if ! _e2e_ssh "$FAKE_PROJECT_C" "dpkg -s $pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done
    if (( ${#missing_pkgs[@]} == 0 )); then
        pass "full image includes build tools and utilities"
    else
        fail "full packages" "missing: ${missing_pkgs[*]}"
    fi

    # Test: gcc, tmux and glab run
    if _e2e_ssh "$FAKE_PROJECT_C" "gcc --version && tmux -V && glab --version" &>/dev/null; then
        pass "gcc, tmux and glab run in the full guest"
    else
        fail "gcc/tmux/glab run" "execution failed"
    fi

    _e2e_cmd "$FAKE_PROJECT_C" stop &>/dev/null || true
    FLAVOR=debian-full _e2e_cmd "$FAKE_PROJECT_C" destroy &>/dev/null || true
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    check_prerequisites
    setup_e2e
    trap cleanup_e2e EXIT INT TERM

    echo "=== claude-vm E2E tests ==="
    echo "E2E_DIR: $E2E_DIR"
    echo "CLAUDE_VM_DIR: $CLAUDE_VM_DIR"

    phase_build
    phase_launch
    phase_config_sync
    phase_multi_instance
    phase_stop
    phase_resume
    phase_rebase
    phase_reset
    phase_destroy
    phase_full_flavor

    echo ""
    echo "=== Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped, $TESTS_RUN total ==="

    (( TESTS_FAILED > 0 )) && exit 1
    exit 0
}

main "$@"
