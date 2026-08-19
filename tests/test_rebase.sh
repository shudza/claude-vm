#!/usr/bin/env bash
# test_rebase.sh — Unit tests for lib/rebase.sh
#
# Mocks the heavy bits (qemu, ssh, rsync, build_base_image) and exercises
# the orchestration in cmd_rebase plus the restore handoff used from
# launch.sh. No KVM or real VMs required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

set +euo pipefail

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() { echo "  PASS: $1"; (( TESTS_PASSED++ )); (( TESTS_RUN++ )); }
fail() { echo "  FAIL: $1 — $2"; (( TESTS_FAILED++ )); (( TESTS_RUN++ )); }
skip() { echo "  SKIP: $1"; (( TESTS_SKIPPED++ )); (( TESTS_RUN++ )); }

setup_test_env() {
    TEST_VM_DIR="$(mktemp -d)"
    export CLAUDE_VM_DIR="$TEST_VM_DIR"
    export CLAUDE_VM_CONFIG="$TEST_VM_DIR/config"
    export SSH_PORT_BASE=29022

    # Re-source so module-level path constants pick up CLAUDE_VM_DIR.
    # The lib files re-enable set -euo pipefail; undo for the harness.
    source "$PROJECT_DIR/lib/config.sh"
    source "$PROJECT_DIR/lib/ui.sh"
    source "$PROJECT_DIR/lib/shutdown.sh"
    source "$PROJECT_DIR/lib/launch.sh"
    source "$PROJECT_DIR/lib/rebase.sh"
    set +euo pipefail

    load_config
    ensure_dirs

    # The real base_image_exists shells out to `qemu-img check`, which rejects
    # the empty fake base images we create in tests. Treat existence as truth.
    base_image_exists() { [[ -f "$(base_image_path)" ]]; }
}

teardown_test_env() {
    rm -rf "$TEST_VM_DIR" 2>/dev/null
}

# Create a fake project snapshot with its sidecar
register_project() {
    local project_dir="$1"
    local hash
    hash="$(project_hash "$project_dir")"
    echo "fake qcow2" > "$SNAPSHOTS_DIR/${hash}.qcow2"
    echo "$project_dir" > "$SNAPSHOTS_DIR/${hash}.project"
}

# ── 1: project_backup_dir lands under BACKUPS_DIR/<hash> ────────────────────

test_project_backup_dir() {
    echo "--- Test 1: project_backup_dir path ---"
    setup_test_env

    local project_dir="/tmp/test-project-$$"
    local expected="$BACKUPS_DIR/$(project_hash "$project_dir")"
    local actual
    actual="$(project_backup_dir "$project_dir")"

    if [[ "$actual" == "$expected" ]]; then
        pass "project_backup_dir = BACKUPS_DIR/<hash>"
    else
        fail "project_backup_dir" "expected '$expected', got '$actual'"
    fi

    teardown_test_env
}

# ── 2: _has_pending_restore reflects backup dir presence ────────────────────

test_has_pending_restore() {
    echo "--- Test 2: _has_pending_restore reflects backup dir presence ---"
    setup_test_env

    local project="/tmp/proj-restore-$$"

    if _has_pending_restore "$project"; then
        fail "no backup yet" "_has_pending_restore returned true with no dir"
    else
        pass "no backup → false"
    fi

    mkdir -p "$(project_backup_dir "$project")"
    if _has_pending_restore "$project"; then
        pass "backup present → true"
    else
        fail "backup present" "_has_pending_restore returned false"
    fi

    teardown_test_env
}

# ── 3: _list_projects_with_snapshots enumerates registered projects ─────────

test_list_projects_with_snapshots() {
    echo "--- Test 3: _list_projects_with_snapshots ---"
    setup_test_env

    register_project "/tmp/proj-aaa-$$"
    register_project "/tmp/proj-bbb-$$"
    # Orphan snapshot (no sidecar) should be skipped
    echo "orphan" > "$SNAPSHOTS_DIR/orphan12345.qcow2"

    local output expected
    output="$(_list_projects_with_snapshots | sort)"
    expected="$(printf '%s\n%s' "/tmp/proj-aaa-$$" "/tmp/proj-bbb-$$" | sort)"

    if [[ "$output" == "$expected" ]]; then
        pass "enumeration returns only projects with a sidecar"
    else
        fail "enumeration output mismatch" "expected '$expected', got '$output'"
    fi

    teardown_test_env
}

# ── 4: _extraction_qemu_args — minimal, no virtiofs ─────────────────────────

test_extraction_qemu_args() {
    echo "--- Test 4: _extraction_qemu_args minimal, no virtiofs/memfd/numa ---"
    setup_test_env

    local snap_path="$SNAPSHOTS_DIR/dummy.qcow2"
    local run_dir="$RUN_DIR/dummy"
    mkdir -p "$run_dir"
    touch "$snap_path"

    _extraction_qemu_args "$snap_path" "$run_dir" "kvm" "10022"

    local has_virtiofs=false has_memfd=false has_numa=false
    local has_monitor=false has_qmp=false
    local arg
    for arg in "${_qemu_args[@]}"; do
        [[ "$arg" == *"vhost-user-fs"* ]]        && has_virtiofs=true
        [[ "$arg" == *"memory-backend-memfd"* ]] && has_memfd=true
        [[ "$arg" == *"numa"* ]]                 && has_numa=true
        [[ "$arg" == "-monitor" ]]               && has_monitor=true
        [[ "$arg" == "-qmp" ]]                   && has_qmp=true
    done

    if ! $has_virtiofs && ! $has_memfd && ! $has_numa && ! $has_monitor && ! $has_qmp; then
        pass "no virtiofs/memfd/numa/monitor/qmp in extraction args"
    else
        local reasons=""
        $has_virtiofs && reasons+="virtiofs "
        $has_memfd    && reasons+="memfd "
        $has_numa     && reasons+="numa "
        $has_monitor  && reasons+="monitor "
        $has_qmp      && reasons+="qmp "
        fail "_extraction_qemu_args" "should not contain: $reasons"
    fi

    teardown_test_env
}

# ── 5: _fast_shutdown kills the QEMU process ────────────────────────────────

test_fast_shutdown_kills() {
    echo "--- Test 5: _fast_shutdown kills QEMU process ---"
    setup_test_env

    local run_dir="$RUN_DIR/fshutdown"
    mkdir -p "$run_dir"

    sleep 300 &
    local fake_pid=$!
    echo "$fake_pid" > "$run_dir/qemu.pid"

    _fast_shutdown "$run_dir"

    if kill -0 "$fake_pid" 2>/dev/null; then
        fail "_fast_shutdown" "process $fake_pid still running"
        kill -9 "$fake_pid" 2>/dev/null
    else
        pass "_fast_shutdown killed the process"
    fi

    teardown_test_env
}

# ── 6: _fast_shutdown is a no-op when PID file is missing ───────────────────

test_fast_shutdown_no_pid() {
    echo "--- Test 6: _fast_shutdown — no PID file ---"
    setup_test_env

    local run_dir="$RUN_DIR/fshutdown-nopid"
    mkdir -p "$run_dir"

    _fast_shutdown "$run_dir"
    local rc=$?

    if (( rc == 0 )); then
        pass "_fast_shutdown returns 0 with no PID file"
    else
        fail "_fast_shutdown no pid" "returned $rc"
    fi

    teardown_test_env
}

# ── 7: _safe_rsync tolerates rc=11/23/24, fails on real errors ──────────────

test_safe_rsync_rc_tolerance() {
    echo "--- Test 7: _safe_rsync tolerates rc=11/23/24, fails otherwise ---"
    setup_test_env

    local log="$TEST_VM_DIR/safe-rsync.log"
    local fake_rc

    # Override the "command" we hand to _safe_rsync — it just exits $fake_rc
    _fake_cmd() { return "$fake_rc"; }

    local ok=true
    for fake_rc in 0 11 23 24; do
        if ! _safe_rsync "$log" _fake_cmd; then
            fail "_safe_rsync rc=$fake_rc" "should be tolerated"; ok=false
        fi
    done

    for fake_rc in 1 12 30; do
        if _safe_rsync "$log" _fake_cmd; then
            fail "_safe_rsync rc=$fake_rc" "should be reported as failure"; ok=false
        fi
    done

    $ok && pass "_safe_rsync tolerates {0,11,23,24}, fails on {1,12,30}"

    teardown_test_env
}

# ── 8: cmd_rebase reports nothing to do when no snapshots ──────────────────

test_rebase_no_snapshots() {
    echo "--- Test 8: cmd_rebase — no snapshots ---"
    setup_test_env

    : > "$(base_image_path)"  # base exists, no snapshots

    local output
    output=$(cmd_rebase --yes 2>&1) || true

    if echo "$output" | grep -qi "no project snapshots"; then
        pass "cmd_rebase reports nothing to rebase"
    else
        fail "cmd_rebase no snapshots" "expected 'no project snapshots', got: $output"
    fi

    teardown_test_env
}

# ── 9: cmd_rebase requires a base image ────────────────────────────────────

test_rebase_requires_base() {
    echo "--- Test 9: cmd_rebase requires a base image ---"
    setup_test_env

    rm -f "$(base_image_path)"

    local output
    output=$(cmd_rebase --yes 2>&1) || true

    if echo "$output" | grep -qi "no base image\|build one first"; then
        pass "cmd_rebase rejects when base image is missing"
    else
        fail "cmd_rebase requires base" "expected error about missing base image, got: $output"
    fi

    teardown_test_env
}

# ── 10: cmd_rebase rejects unknown flags ───────────────────────────────────

test_rebase_bad_flag() {
    echo "--- Test 10: cmd_rebase rejects unknown flags ---"
    setup_test_env

    local output
    output=$(cmd_rebase --bad-flag 2>&1) || true

    if echo "$output" | grep -qi "unknown option"; then
        pass "cmd_rebase rejects unknown flags"
    else
        fail "cmd_rebase bad flag" "expected 'Unknown option', got: $output"
    fi

    teardown_test_env
}

# ── 11: cmd_rebase extracts per-project state into BACKUPS_DIR/<hash>/ ─────

test_cmd_rebase_extracts_into_backup_dir() {
    echo "--- Test 11: cmd_rebase extracts into backup dir ---"
    setup_test_env

    local proj_a="/tmp/proj-extr-a-$$"
    local proj_b="/tmp/proj-extr-b-$$"
    register_project "$proj_a"
    register_project "$proj_b"
    : > "$(base_image_path)"

    # Mock the heavy ops
    _extract_one_vm() {
        local project_dir="$1"
        local bd
        bd="$(project_backup_dir "$project_dir")"
        mkdir -p "$bd/.claude" "$bd/.config/gh"
        echo "settings-$project_dir"   > "$bd/.claude/settings.json"
        echo "creds-$project_dir"      > "$bd/.claude/.credentials.json"
        echo "host gh"                 > "$bd/.config/gh/hosts.yml"
        echo "[user] email=test"       > "$bd/.gitconfig"
        return 0
    }
    build_base_image() { echo "new base" > "$(base_image_path)"; }

    cmd_rebase --yes >/dev/null 2>&1

    local bd_a bd_b
    bd_a="$(project_backup_dir "$proj_a")"
    bd_b="$(project_backup_dir "$proj_b")"

    local ok=true f
    for f in "$bd_a/.claude/settings.json" "$bd_a/.claude/.credentials.json" \
             "$bd_a/.config/gh/hosts.yml" "$bd_a/.gitconfig" \
             "$bd_b/.claude/settings.json" "$bd_b/.gitconfig"; do
        if [[ ! -f "$f" ]]; then
            fail "backup payload" "missing $f"; ok=false; break
        fi
    done

    $ok && pass "both projects' backup directories contain the expected payloads"

    teardown_test_env
}

# ── 11b: cmd_rebase stops running VMs in parallel before extracting ─────────

test_cmd_rebase_stops_running_vms() {
    echo "--- Test 11b: cmd_rebase stops running VMs in parallel ---"
    setup_test_env

    local proj_a="/tmp/proj-stop-a-$$"
    local proj_b="/tmp/proj-stop-b-$$"
    register_project "$proj_a"
    register_project "$proj_b"
    : > "$(base_image_path)"

    local run_a run_b
    run_a="$(project_run_dir "$proj_a")"
    run_b="$(project_run_dir "$proj_b")"
    mkdir -p "$run_a" "$run_b"

    sleep 300 &
    local pid_a=$!
    echo "$pid_a" > "$run_a/qemu.pid"
    sleep 300 &
    local pid_b=$!
    echo "$pid_b" > "$run_b/qemu.pid"

    _extract_one_vm() { return 0; }
    build_base_image() { echo "new base" > "$(base_image_path)"; }

    local output
    output=$(cmd_rebase --yes 2>&1)

    local ok=true
    if ! echo "$output" | grep -q "Stopping 2 running VM"; then
        fail "stop announcement" "expected 'Stopping 2 running VM(s)', got: $output"; ok=false
    fi
    if kill -0 "$pid_a" 2>/dev/null; then
        fail "VM A" "still running after rebase"; ok=false
    fi
    if kill -0 "$pid_b" 2>/dev/null; then
        fail "VM B" "still running after rebase"; ok=false
    fi
    $ok && pass "both running VMs stopped, single announcement line"

    kill "$pid_a" "$pid_b" 2>/dev/null
    wait "$pid_a" "$pid_b" 2>/dev/null
    teardown_test_env
}

# ── 12: cmd_rebase removes old snapshots + base and rebuilds ───────────────

test_cmd_rebase_destroys_and_rebuilds() {
    echo "--- Test 12: cmd_rebase clears snapshots + base and rebuilds ---"
    setup_test_env

    local proj="/tmp/proj-destroy-$$"
    register_project "$proj"
    : > "$(base_image_path)"

    local snap_path
    snap_path="$(project_snapshot_path "$proj")"

    _extract_one_vm() { return 0; }
    local _build_called=false
    build_base_image() {
        _build_called=true
        echo "new base" > "$(base_image_path)"
    }

    cmd_rebase --yes >/dev/null 2>&1

    local ok=true
    [[ -f "$snap_path" ]]                         && { fail "snapshot cleared" "still exists"; ok=false; }
    $_build_called                                || { fail "rebuild" "build_base_image not called"; ok=false; }
    [[ -f "$(base_image_path)" ]]                 || { fail "new base" "missing"; ok=false; }
    [[ -f "$SNAPSHOTS_DIR/$(project_hash "$proj").project" ]] \
                                                  && { fail "sidecar wiped" ".project still present after rebase"; ok=false; }

    $ok && pass "snapshots + sidecars removed, base rebuilt"

    teardown_test_env
}

# ── 12b: rebase preserves sidecars for pending restores, drops the rest ─────

test_cmd_rebase_sidecar_lifecycle() {
    echo "--- Test 12b: rebase keeps sidecars w/ pending restore, drops orphans ---"
    setup_test_env

    local proj_pending="/tmp/proj-pending-restore-$$"
    local proj_force="/tmp/proj-force-drop-$$"
    register_project "$proj_pending"
    register_project "$proj_force"
    : > "$(base_image_path)"

    # Orphan sidecars (older versions / interrupted destroys — no backup, no qcow2)
    echo "/tmp/gone-project-a" > "$SNAPSHOTS_DIR/aaaaaaaaaaaa.project"
    echo "8080,3000"           > "$SNAPSHOTS_DIR/aaaaaaaaaaaa.ports"
    echo "/tmp/gone-project-b" > "$SNAPSHOTS_DIR/bbbbbbbbbbbb.project"

    # Orphan 0-byte qcow2 — what the user saw as (unknown).
    : > "$SNAPSHOTS_DIR/cccccccccccc.qcow2"

    # proj_pending extracts successfully → backup written → sidecar kept
    # proj_force fails extraction → no backup → sidecar dropped
    _extract_one_vm() {
        if [[ "$1" == "$proj_force" ]]; then
            return 1
        fi
        local bd
        bd="$(project_backup_dir "$1")"
        mkdir -p "$bd/.claude"
        echo "data" > "$bd/.claude/settings.json"
        return 0
    }
    build_base_image() { echo "new base" > "$(base_image_path)"; }

    cmd_rebase --yes --force >/dev/null 2>&1

    local hp hf
    hp="$(project_hash "$proj_pending")"
    hf="$(project_hash "$proj_force")"

    local ok=true
    # Orphans wiped
    [[ -f "$SNAPSHOTS_DIR/aaaaaaaaaaaa.project" ]] && { fail "orphan .project a" "still present"; ok=false; }
    [[ -f "$SNAPSHOTS_DIR/aaaaaaaaaaaa.ports" ]]   && { fail "orphan .ports a"   "still present"; ok=false; }
    [[ -f "$SNAPSHOTS_DIR/bbbbbbbbbbbb.project" ]] && { fail "orphan .project b" "still present"; ok=false; }
    [[ -f "$SNAPSHOTS_DIR/cccccccccccc.qcow2" ]]   && { fail "empty qcow2"       "still present"; ok=false; }
    # qcow2 of registered projects always gone
    [[ -f "$SNAPSHOTS_DIR/${hp}.qcow2" ]]          && { fail "pending qcow2"     "still present"; ok=false; }
    [[ -f "$SNAPSHOTS_DIR/${hf}.qcow2" ]]          && { fail "force-drop qcow2"  "still present"; ok=false; }
    # Pending-restore sidecar preserved so `list` can show it before relaunch
    [[ -f "$SNAPSHOTS_DIR/${hp}.project" ]]        || { fail "pending sidecar"   "dropped despite backup"; ok=false; }
    # Force-dropped project has no backup → sidecar removed
    [[ -f "$SNAPSHOTS_DIR/${hf}.project" ]]        && { fail "force sidecar"     "kept without backup"; ok=false; }

    $ok && pass "sidecars: orphans wiped, pending kept, force-dropped wiped"

    teardown_test_env
}

# ── 13: extraction failure preserves snapshots (no --force) ─────────────────

test_cmd_rebase_aborts_on_failure() {
    echo "--- Test 13: extraction failure preserves snapshots ---"
    setup_test_env

    local proj_ok="/tmp/proj-ok-$$"
    local proj_bad="/tmp/proj-bad-$$"
    register_project "$proj_ok"
    register_project "$proj_bad"
    : > "$(base_image_path)"

    _extract_one_vm() {
        [[ "$1" == "$proj_bad" ]] && return 1
        return 0
    }
    local _build_called=false
    build_base_image() { _build_called=true; }

    local rc=0
    cmd_rebase --yes >/dev/null 2>&1 || rc=$?

    local ok=true
    (( rc != 0 ))                                       || { fail "exit code" "expected non-zero"; ok=false; }
    [[ -f "$(project_snapshot_path "$proj_ok")" ]]      || { fail "preserve ok"  "removed"; ok=false; }
    [[ -f "$(project_snapshot_path "$proj_bad")" ]]     || { fail "preserve bad" "removed"; ok=false; }
    [[ -f "$(base_image_path)" ]]                       || { fail "preserve base" "removed"; ok=false; }
    ! $_build_called                                    || { fail "no rebuild" "build_base_image was called"; ok=false; }

    $ok && pass "extraction failure: snapshots + base preserved, no rebuild"

    teardown_test_env
}

# ── 14: --force drops failed snapshots and rebuilds ─────────────────────────

test_cmd_rebase_force_drops_failed() {
    echo "--- Test 14: --force discards failed snapshots and rebuilds ---"
    setup_test_env

    local proj_ok="/tmp/proj-force-ok-$$"
    local proj_bad="/tmp/proj-force-bad-$$"
    register_project "$proj_ok"
    register_project "$proj_bad"
    : > "$(base_image_path)"

    _extract_one_vm() {
        if [[ "$1" == "$proj_bad" ]]; then
            return 1
        fi
        local bd
        bd="$(project_backup_dir "$1")"
        mkdir -p "$bd/.claude"
        echo "ok" > "$bd/.claude/settings.json"
        return 0
    }
    local _build_called=false
    build_base_image() {
        _build_called=true
        echo "new base" > "$(base_image_path)"
    }

    cmd_rebase --yes --force >/dev/null 2>&1

    local ok=true
    [[ -f "$(project_snapshot_path "$proj_ok")" ]]   && { fail "ok snapshot dropped"  "still present"; ok=false; }
    [[ -f "$(project_snapshot_path "$proj_bad")" ]]  && { fail "bad snapshot dropped" "still present"; ok=false; }
    $_build_called                                   || { fail "force rebuilds" "build_base_image not called"; ok=false; }
    [[ -d "$(project_backup_dir "$proj_ok")" ]]      || { fail "ok backup persists" "missing"; ok=false; }

    $ok && pass "--force: snapshots dropped, base rebuilt, ok-project backup kept"

    teardown_test_env
}

# ── 15: _restore_one_vm consumes backup dir + no-op when absent ─────────────

test_restore_consumes_backup() {
    echo "--- Test 15: _restore_one_vm consumes backup; no-op when absent ---"
    setup_test_env

    local project="/tmp/proj-restore-consume-$$"
    local bd
    bd="$(project_backup_dir "$project")"

    # Stub out the ssh/rsync helpers so _restore_one_vm doesn't shell out
    _build_ssh_cmd()   { _ssh_cmd=(true); }
    _build_rsync_cmd() { _rsync_cmd=(true); }
    _build_rsync_sudo_cmd() { _rsync_sudo_cmd=(true); }

    # A: no backup directory → no-op, returns 0
    if _restore_one_vm "$project" 10022; then
        pass "no backup → no-op returns 0"
    else
        fail "no-op return" "non-zero exit"
    fi

    # B: backup present → contents consumed (dir removed) after restore
    mkdir -p "$bd/.claude"
    echo "data" > "$bd/.claude/settings.json"
    echo "data" > "$bd/.gitconfig"

    _restore_one_vm "$project" 10022 >/dev/null 2>&1

    if [[ ! -d "$bd" ]]; then
        pass "backup dir removed after restore"
    else
        fail "backup consumed" "directory still present at $bd"
    fi

    teardown_test_env
}

# ── 16: _rebase_user_paths normalizes REBASE_BACKUP_PATHS entries ───────────

test_rebase_user_paths_normalization() {
    echo "--- Test 16: _rebase_user_paths normalization ---"
    setup_test_env

    REBASE_BACKUP_PATHS="~/.ssh, /etc/,foo/, ,"
    local output expected
    output="$(_rebase_user_paths)"
    expected="$(printf '%s\n%s\n%s' ".ssh" "/etc" "foo")"

    if [[ "$output" == "$expected" ]]; then
        pass "entries trimmed, ~/ and trailing slashes stripped, empties skipped"
    else
        fail "_rebase_user_paths" "expected '$expected', got '$output'"
    fi

    REBASE_BACKUP_PATHS=""
    output="$(_rebase_user_paths)"
    if [[ -z "$output" ]]; then
        pass "empty config → no output"
    else
        fail "_rebase_user_paths empty" "got '$output'"
    fi

    teardown_test_env
}

# ── 17: _backup_rel_path maps absolute paths under _abs/ ────────────────────

test_backup_rel_path() {
    echo "--- Test 17: _backup_rel_path layout ---"
    setup_test_env

    local ok=true
    [[ "$(_backup_rel_path "/etc")" == "_abs/etc" ]]             || { fail "_backup_rel_path /etc" "got $(_backup_rel_path "/etc")"; ok=false; }
    [[ "$(_backup_rel_path "/etc/hosts")" == "_abs/etc/hosts" ]] || { fail "_backup_rel_path /etc/hosts" "got $(_backup_rel_path "/etc/hosts")"; ok=false; }
    [[ "$(_backup_rel_path ".ssh")" == ".ssh" ]]                 || { fail "_backup_rel_path .ssh" "got $(_backup_rel_path ".ssh")"; ok=false; }

    $ok && pass "absolute → _abs/<path>, home-relative unchanged"

    teardown_test_env
}

# ── 18: _build_rsync_sudo_cmd runs as root and preserves perms ───────────────

test_build_rsync_sudo_cmd() {
    echo "--- Test 18: _build_rsync_sudo_cmd flags ---"
    setup_test_env

    _build_rsync_sudo_cmd 10022

    local has_sudo=false has_fake_super=false strips_perms=false arg
    for arg in "${_rsync_sudo_cmd[@]}"; do
        [[ "$arg" == "--rsync-path=sudo rsync" ]] && has_sudo=true
        [[ "$arg" == "--fake-super" ]]            && has_fake_super=true
        [[ "$arg" == "--no-perms" || "$arg" == "--no-owner" || "$arg" == "--no-group" ]] && strips_perms=true
    done

    if $has_sudo && $has_fake_super && ! $strips_perms; then
        pass "sudo rsync-path + --fake-super, no perms-stripping flags"
    else
        fail "_build_rsync_sudo_cmd" "sudo=$has_sudo fake_super=$has_fake_super strips_perms=$strips_perms"
    fi

    teardown_test_env
}

# ── 19: _rebase_preserved_desc lists builtins + user paths ──────────────────

test_rebase_preserved_desc() {
    echo "--- Test 19: _rebase_preserved_desc ---"
    setup_test_env

    REBASE_BACKUP_PATHS="/etc/ssh,~/.ssh"
    local desc
    desc="$(_rebase_preserved_desc)"

    if [[ "$desc" == *"~/.claude/"* && "$desc" == *"~/.gitconfig"* \
          && "$desc" == *"/etc/ssh"* && "$desc" == *"~/.ssh"* ]]; then
        pass "description includes builtins and user paths"
    else
        fail "_rebase_preserved_desc" "got '$desc'"
    fi

    teardown_test_env
}

# ── 20: _restore_one_vm pushes manifest paths via sudo rsync ────────────────

test_restore_manifest_paths() {
    echo "--- Test 20: manifest restore uses sudo rsync + correct destinations ---"
    setup_test_env

    local project="/tmp/proj-manifest-restore-$$"
    local bd cap sshcap
    bd="$(project_backup_dir "$project")"
    cap="$TEST_VM_DIR/rsync-capture"
    sshcap="$TEST_VM_DIR/ssh-capture"
    : > "$cap"; : > "$sshcap"

    mkdir -p "$bd/.ssh" "$bd/_abs/etc"
    echo "key"   > "$bd/.ssh/id_ed25519"
    echo "hosts" > "$bd/_abs/etc/hosts"
    printf '%s\n%s\n' ".ssh" "/etc/hosts" > "$bd/.rebase-paths"

    fake_ssh()        { echo "$*" >> "$sshcap"; return 0; }
    fake_rsync()      { echo "plain $*" >> "$cap"; return 0; }
    fake_rsync_sudo() { echo "sudo $*"  >> "$cap"; return 0; }
    _build_ssh_cmd()        { _ssh_cmd=(fake_ssh); }
    _build_rsync_cmd()      { _rsync_cmd=(fake_rsync); }
    _build_rsync_sudo_cmd() { _rsync_sudo_cmd=(fake_rsync_sudo); }

    _restore_one_vm "$project" 10022 >/dev/null 2>&1

    local ok=true
    grep -q "sudo $bd/.ssh/ $VM_USER@localhost:~/.ssh/" "$cap" \
        || { fail "dir restore" "no sudo rsync push of .ssh/ ($(cat "$cap"))"; ok=false; }
    grep -q "sudo $bd/_abs/etc/hosts $VM_USER@localhost:/etc/hosts" "$cap" \
        || { fail "file restore" "no sudo rsync push of /etc/hosts ($(cat "$cap"))"; ok=false; }
    grep -q "sudo mkdir -p ~/.ssh" "$sshcap" \
        || { fail "dir mkdir" "no sudo mkdir -p ~/.ssh"; ok=false; }
    grep -q "sudo mkdir -p /etc" "$sshcap" \
        || { fail "file mkdir" "no sudo mkdir -p /etc"; ok=false; }
    grep -q "^plain .*_abs" "$cap" \
        && { fail "sudo separation" "user path went through the unprivileged rsync"; ok=false; }
    [[ -d "$bd" ]] \
        && { fail "backup consumed" "directory still present"; ok=false; }

    $ok && pass "manifest paths pushed via sudo rsync to ~/.ssh and /etc/hosts, backup consumed"

    teardown_test_env
}

# ── 21: extraction records manifest and drops bare-manifest backups ─────────

test_extract_user_paths_manifest() {
    echo "--- Test 21: extraction manifest + empty-backup cleanup ---"
    setup_test_env

    local project="/tmp/proj-extract-manifest-$$"
    register_project "$project"
    local bd
    bd="$(project_backup_dir "$project")"

    # Stub everything around the copy loops so the real _extract_one_vm runs
    qemu-system-x86_64() { return 0; }
    wait_for_ssh()       { return 0; }
    _detect_accel()      { echo "tcg"; }
    find_available_port() { echo 29022; }
    _fast_shutdown()     { return 0; }
    _cleanup_runtime()   { return 0; }

    # Guest state: /etc exists (dir), ~/.ssh missing; builtins missing
    fake_ssh() {
        case "${*: -1}" in
            "sudo test -e /etc"|"sudo test -d /etc") return 0 ;;
            *) return 1 ;;
        esac
    }
    fake_rsync_sudo() { echo "payload" > "${@: -1}/passwd"; return 0; }
    _build_ssh_cmd()        { _ssh_cmd=(fake_ssh); }
    _build_rsync_cmd()      { _rsync_cmd=(true); }
    _build_rsync_sudo_cmd() { _rsync_sudo_cmd=(fake_rsync_sudo); }

    REBASE_BACKUP_PATHS="/etc,~/.ssh"
    _extract_one_vm "$project" >/dev/null 2>&1

    local ok=true
    [[ -f "$bd/_abs/etc/passwd" ]] \
        || { fail "extract payload" "missing $bd/_abs/etc/passwd"; ok=false; }
    [[ -f "$bd/.rebase-paths" ]] \
        || { fail "manifest written" "missing .rebase-paths"; ok=false; }
    if [[ -f "$bd/.rebase-paths" ]]; then
        grep -qx "/etc" "$bd/.rebase-paths"  || { fail "manifest content" "/etc not recorded"; ok=false; }
        grep -qx ".ssh" "$bd/.rebase-paths"  && { fail "manifest content" "missing .ssh was recorded"; ok=false; }
    fi
    $ok && pass "existing path extracted + recorded, missing path skipped"

    # Bare-manifest backup (file entry whose rsync transferred nothing) → dropped
    rm -rf "$bd"
    fake_ssh() {
        case "${*: -1}" in
            "sudo test -e /etc/nosuch") return 0 ;;
            *) return 1 ;;
        esac
    }
    fake_rsync_sudo() { return 24; }  # tolerated rc, nothing written

    REBASE_BACKUP_PATHS="/etc/nosuch"
    _extract_one_vm "$project" >/dev/null 2>&1

    if [[ ! -d "$bd" ]]; then
        pass "backup containing only the manifest is dropped"
    else
        fail "bare-manifest cleanup" "backup dir still present: $(ls -A "$bd")"
    fi

    teardown_test_env
}

# ── Run all tests ───────────────────────────────────────────────────────────

echo "=== claude-vm rebase tests ==="
echo ""

test_project_backup_dir
test_has_pending_restore
test_list_projects_with_snapshots
test_extraction_qemu_args
test_fast_shutdown_kills
test_fast_shutdown_no_pid
test_safe_rsync_rc_tolerance
test_rebase_no_snapshots
test_rebase_requires_base
test_rebase_bad_flag
test_cmd_rebase_extracts_into_backup_dir
test_cmd_rebase_stops_running_vms
test_cmd_rebase_destroys_and_rebuilds
test_cmd_rebase_sidecar_lifecycle
test_cmd_rebase_aborts_on_failure
test_cmd_rebase_force_drops_failed
test_restore_consumes_backup
test_rebase_user_paths_normalization
test_backup_rel_path
test_build_rsync_sudo_cmd
test_rebase_preserved_desc
test_restore_manifest_paths
test_extract_user_paths_manifest

echo ""
echo "=== Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped, $TESTS_RUN total ==="

(( TESTS_FAILED > 0 )) && exit 1
exit 0
