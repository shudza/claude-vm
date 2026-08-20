#!/usr/bin/env bash
# test_launch.sh — Unit tests for launch.sh helpers
#
# Tests:
# 1. sync_claude_config_to_vm is called on first VM creation (new snapshot)
# 2. sync_claude_config_to_vm is skipped on subsequent launches (existing snapshot)
# 3. _pid_alive tracks process liveness (including unreaped children)
# 4. _check_virtiofsd_idmap requires newuidmap/newgidmap when unprivileged
# 5. start_virtiofsd fails when virtiofsd dies after binding its socket
# 8. _guest_project_dir_name derives a sanitized name from the project basename
# 9. connect_vm / connect_vm_shell export CLAUDE_CODE_PROJECT_DIR_NAME
# 9b. the connect command migrates pre-CLAUDE_CONFIG_DIR VM state (config json + -workspace)
# 10. sync_claude_config_to_vm includes agents/commands/workflows/keybindings
# 11. sync_claude_config_to_vm syncs ~/.config/glab-cli/
# 12. host ~/.claude.json syncs to ~/.claude/.claude.json (CLAUDE_CONFIG_DIR location)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$PROJECT_DIR"

source "$PROJECT_DIR/lib/config.sh"
source "$PROJECT_DIR/lib/launch.sh"

set +euo pipefail

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; (( TESTS_PASSED++ )); (( TESTS_RUN++ )); }
fail() { echo "  FAIL: $1"; (( TESTS_FAILED++ )); (( TESTS_RUN++ )); }

setup_test_env() {
    TEST_VM_DIR="$(mktemp -d)"
    export CLAUDE_VM_DIR="$TEST_VM_DIR"
    export CLAUDE_VM_CONFIG="$TEST_VM_DIR/config"
    load_config
    ensure_dirs
}

teardown_test_env() {
    rm -rf "$TEST_VM_DIR" 2>/dev/null
}

# ── Test: is_new_vm is true when snapshot does not exist ─────────────────────
echo "--- Test 1: is_new_vm=true when snapshot absent ---"
setup_test_env

PROJECT_DIR_TEST="$(mktemp -d)"
snap_path="$(project_snapshot_path "$PROJECT_DIR_TEST")"

is_new_vm=false
[[ ! -f "$snap_path" ]] && is_new_vm=true

if [[ "$is_new_vm" == true ]]; then
    pass "is_new_vm set to true when snapshot absent"
else
    fail "is_new_vm should be true when snapshot absent"
fi

rm -rf "$PROJECT_DIR_TEST"
teardown_test_env

# ── Test: is_new_vm is false when snapshot already exists ────────────────────
echo "--- Test 2: is_new_vm=false when snapshot present ---"
setup_test_env

PROJECT_DIR_TEST="$(mktemp -d)"
snap_path="$(project_snapshot_path "$PROJECT_DIR_TEST")"
mkdir -p "$(dirname "$snap_path")"
touch "$snap_path"

is_new_vm=false
[[ ! -f "$snap_path" ]] && is_new_vm=true

if [[ "$is_new_vm" == false ]]; then
    pass "is_new_vm stays false when snapshot present"
else
    fail "is_new_vm should be false when snapshot present"
fi

rm -rf "$PROJECT_DIR_TEST"
teardown_test_env

# ── Test: _pid_alive reports a running process as alive ──────────────────────
echo "--- Test 3: _pid_alive on a running process ---"

sleep 30 &
live_pid=$!

if _pid_alive "$live_pid"; then
    pass "_pid_alive true for a running process"
else
    fail "_pid_alive should be true for a running process"
fi

kill "$live_pid" 2>/dev/null

# ── Test: _pid_alive reports an exited child as dead ─────────────────────────
# The child is deliberately left unreaped — `kill -0` succeeds on a zombie, so
# liveness is read from /proc instead.
echo "--- Test 4: _pid_alive on an exited (unreaped) child ---"

bash -c 'exit 1' &
dead_pid=$!
sleep 0.3

if _pid_alive "$dead_pid"; then
    fail "_pid_alive should be false for an exited child"
else
    pass "_pid_alive false for an exited child"
fi

wait "$dead_pid" 2>/dev/null

# ── Test: virtiofsd id-mapping helpers are required (issue #7) ───────────────
echo "--- Test 5: _check_virtiofsd_idmap requires newuidmap/newgidmap ---"

FAKE_BIN="$(mktemp -d)"

output="$(PATH="$FAKE_BIN" _check_virtiofsd_idmap /usr/libexec/virtiofsd 2>&1)"
rc=$?

if (( EUID == 0 )); then
    echo "  SKIP: running as root (the helpers are only needed unprivileged)"
elif (( rc != 0 )) && [[ "$output" == *uidmap* ]]; then
    pass "missing newuidmap/newgidmap fails with an install hint"
else
    fail "missing newuidmap/newgidmap should fail (rc=$rc): $output"
fi

# Present in PATH -> check passes
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/newuidmap"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/newgidmap"
chmod +x "$FAKE_BIN/newuidmap" "$FAKE_BIN/newgidmap"

if PATH="$FAKE_BIN" _check_virtiofsd_idmap /usr/libexec/virtiofsd 2>/dev/null; then
    pass "newuidmap/newgidmap present satisfies the check"
else
    fail "newuidmap/newgidmap present should satisfy the check"
fi

# The legacy C daemon doesn't use the helpers — don't demand them
rm -f "$FAKE_BIN/newuidmap" "$FAKE_BIN/newgidmap"

if PATH="$FAKE_BIN" _check_virtiofsd_idmap /usr/lib/qemu/virtiofsd 2>/dev/null; then
    pass "legacy qemu virtiofsd skips the id-map check"
else
    fail "legacy qemu virtiofsd should skip the id-map check"
fi

rm -rf "$FAKE_BIN"

# ── Test: start_virtiofsd rejects a daemon that dies after binding ───────────
# Regression for issue #7: virtiofsd binds the socket, then dies during sandbox
# setup (e.g. no newuidmap). The socket file survives, so an existence-only
# check passed and the failure surfaced later as a QEMU "Connection refused".
echo "--- Test 6: start_virtiofsd detects a daemon that dies after binding ---"

if ! command -v python3 &>/dev/null; then
    echo "  SKIP: python3 needed to create a unix socket"
else
    setup_test_env
    FAKE_BIN="$(mktemp -d)"
    VFS_PROJECT="$(mktemp -d)"
    VFS_RUN="$TEST_VM_DIR/run/fake"
    mkdir -p "$VFS_RUN"

    # Stub the id-map helpers so this test exercises liveness, not test 5
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/newuidmap"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/newgidmap"
    chmod +x "$FAKE_BIN/newuidmap" "$FAKE_BIN/newgidmap"

    # Fake virtiofsd: bind the socket, leave the file behind, then die
    cat > "$FAKE_BIN/virtiofsd" <<'FAKE'
#!/usr/bin/env bash
sock=""
for arg in "$@"; do
    case "$arg" in --socket-path=*) sock="${arg#--socket-path=}" ;; esac
done
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)' "$sock"
echo "fake virtiofsd: simulated crash during sandbox setup" >&2
exit 1
FAKE
    chmod +x "$FAKE_BIN/virtiofsd"

    output="$(PATH="$FAKE_BIN:$PATH" start_virtiofsd "$VFS_PROJECT" "$VFS_RUN/virtiofs.sock" "$VFS_RUN" 2>&1)"
    rc=$?

    if (( rc != 0 )); then
        pass "start_virtiofsd fails when the daemon dies after binding"
    else
        fail "start_virtiofsd should fail when the daemon dies (rc=$rc): $output"
    fi

    if [[ "$output" == *"simulated crash"* ]]; then
        pass "start_virtiofsd surfaces the virtiofsd log on failure"
    else
        fail "start_virtiofsd should surface the virtiofsd log: $output"
    fi

    # ── A daemon that stays up is accepted ──────────────────────────────────
    echo "--- Test 7: start_virtiofsd accepts a live daemon ---"
    cat > "$FAKE_BIN/virtiofsd" <<'FAKE'
#!/usr/bin/env bash
sock=""
for arg in "$@"; do
    case "$arg" in --socket-path=*) sock="${arg#--socket-path=}" ;; esac
done
exec python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(30)' "$sock"
FAKE
    chmod +x "$FAKE_BIN/virtiofsd"

    rm -f "$VFS_RUN/virtiofs.sock"
    output="$(PATH="$FAKE_BIN:$PATH" start_virtiofsd "$VFS_PROJECT" "$VFS_RUN/virtiofs.sock" "$VFS_RUN" 2>&1)"
    rc=$?

    if (( rc == 0 )); then
        pass "start_virtiofsd succeeds when the daemon stays alive"
    else
        fail "start_virtiofsd should succeed with a live daemon (rc=$rc): $output"
    fi

    [[ -f "$VFS_RUN/virtiofsd.pid" ]] && kill "$(cat "$VFS_RUN/virtiofsd.pid")" 2>/dev/null
    rm -rf "$FAKE_BIN" "$VFS_PROJECT"
    teardown_test_env
fi

# ── Test: guest project dir name derivation ──────────────────────────────────
echo "--- Test 8: _guest_project_dir_name sanitizes the basename ---"
setup_test_env

NAME_ROOT="$(mktemp -d)"
mkdir -p "$NAME_ROOT/my-proj" "$NAME_ROOT/we ird (x)" "$NAME_ROOT/my.app" "$NAME_ROOT/@@@" "$NAME_ROOT/AUX"

if [[ "$(_guest_project_dir_name "$NAME_ROOT/my-proj")" == "my-proj" ]]; then
    pass "plain basename is kept"
else
    fail "plain basename should be kept: $(_guest_project_dir_name "$NAME_ROOT/my-proj")"
fi
if [[ "$(_guest_project_dir_name "$NAME_ROOT/we ird (x)")" == "weirdx" ]]; then
    pass "unsafe characters are stripped"
else
    fail "unsafe characters should be stripped: $(_guest_project_dir_name "$NAME_ROOT/we ird (x)")"
fi
# Claude Code validates against ^[A-Za-z0-9_-]{1,64}$ — dots are rejected
if [[ "$(_guest_project_dir_name "$NAME_ROOT/my.app")" == "myapp" ]]; then
    pass "dots are stripped (upstream charset has no dot)"
else
    fail "dots should be stripped: $(_guest_project_dir_name "$NAME_ROOT/my.app")"
fi
if [[ "$(_guest_project_dir_name "$NAME_ROOT/@@@")" == "workspace" ]]; then
    pass "empty result falls back to 'workspace'"
else
    fail "empty result should fall back to workspace: $(_guest_project_dir_name "$NAME_ROOT/@@@")"
fi
if [[ "$(_guest_project_dir_name "$NAME_ROOT/AUX")" == "workspace" ]]; then
    pass "Windows reserved device names fall back to 'workspace'"
else
    fail "reserved names should fall back: $(_guest_project_dir_name "$NAME_ROOT/AUX")"
fi
long_dir="$NAME_ROOT/$(printf 'a%.0s' {1..80})"
mkdir -p "$long_dir"
long_name="$(_guest_project_dir_name "$long_dir")"
if (( ${#long_name} == 64 )); then
    pass "names are truncated to 64 chars (upstream max)"
else
    fail "name should be 64 chars, got ${#long_name}"
fi

rm -rf "$NAME_ROOT"
teardown_test_env

# ── Test: connect_vm / connect_vm_shell export the project dir name ──────────
echo "--- Test 9: connect helpers export CLAUDE_CODE_PROJECT_DIR_NAME ---"
setup_test_env

FAKE_BIN="$(mktemp -d)"
cat > "$FAKE_BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@"
FAKE
chmod +x "$FAKE_BIN/ssh"
CONN_PROJECT="$(mktemp -d)/sample-app"
mkdir -p "$CONN_PROJECT"

output="$(PATH="$FAKE_BIN:$PATH" connect_vm 12345 "$CONN_PROJECT" --resume 2>&1)"
if [[ "$output" == *'export CLAUDE_CODE_PROJECT_DIR_NAME="sample-app";'* ]]; then
    pass "connect_vm exports CLAUDE_CODE_PROJECT_DIR_NAME=sample-app"
else
    fail "connect_vm should export the project dir name: $output"
fi
# Claude Code only honors the name when CLAUDE_CONFIG_DIR is set
if [[ "$output" == *'export CLAUDE_CONFIG_DIR="$HOME/.claude"; export CLAUDE_CODE_PROJECT_DIR_NAME'* ]]; then
    pass "connect_vm exports CLAUDE_CONFIG_DIR (required for the name to be honored)"
else
    fail "connect_vm should export CLAUDE_CONFIG_DIR: $output"
fi
if [[ "$output" == *'exec claude --dangerously-skip-permissions --resume'* ]]; then
    pass "connect_vm still launches claude with CLAUDE_ARGS + extras"
else
    fail "connect_vm should launch claude with args: $output"
fi
if [[ "$output" == *'CLAUDE_CODE_PROJECT_DIR_NAME="sample-app"; cd /workspace 2>/dev/null; [ -f ~/.env ] && . ~/.env;'* ]]; then
    pass "export precedes ~/.env so the user can override it"
else
    fail "export should come before ~/.env: $output"
fi

output="$(PATH="$FAKE_BIN:$PATH" connect_vm_shell 12345 "$CONN_PROJECT" 2>&1)"
if [[ "$output" == *'export CLAUDE_CODE_PROJECT_DIR_NAME="sample-app";'* ]] && [[ "$output" == *'-l'* ]]; then
    pass "connect_vm_shell exports the name and execs a login shell"
else
    fail "connect_vm_shell should export the name and exec a login shell: $output"
fi

# ── Test: connect migrates pre-CLAUDE_CONFIG_DIR VMs ─────────────────────────
echo "--- Test 9b: connect command migrates legacy VM state ---"
if [[ "$output" == *'cp "$HOME/.claude.json" "$HOME/.claude/.claude.json"'* ]] \
   && [[ "$output" == *'mv "$HOME/.claude/projects/-workspace" "$HOME/.claude/projects/$CLAUDE_CODE_PROJECT_DIR_NAME"'* ]]; then
    pass "connect command carries the config-json and transcript migrations"
else
    fail "connect command should carry the migrations: $output"
fi
if [[ "$output" == *'. ~/.env; { [ -f "$HOME/.claude.json" ]'* ]]; then
    pass "migration runs after ~/.env so a user override of the name is respected"
else
    fail "migration should run after ~/.env: $output"
fi
mig_cmd="${output##*'. ~/.env; '}"
mig_cmd="${mig_cmd% exec*}"
MIG_HOME="$(mktemp -d)"
mkdir -p "$MIG_HOME/.claude/projects/-workspace"
echo '{"orig":1}' > "$MIG_HOME/.claude.json"
echo conv > "$MIG_HOME/.claude/projects/-workspace/c.jsonl"
HOME="$MIG_HOME" CLAUDE_CODE_PROJECT_DIR_NAME="sample-app" bash -c "$mig_cmd"
if [[ "$(cat "$MIG_HOME/.claude/.claude.json" 2>/dev/null)" == '{"orig":1}' ]] \
   && [[ -f "$MIG_HOME/.claude/projects/sample-app/c.jsonl" ]] \
   && [[ ! -e "$MIG_HOME/.claude/projects/-workspace" ]]; then
    pass "legacy VM state migrates: config json copied, -workspace renamed"
else
    fail "legacy migration should copy the json and rename -workspace: $(find "$MIG_HOME" -mindepth 1 2>/dev/null | tr '\n' ' ')"
fi
echo '{"newer":1}' > "$MIG_HOME/.claude/.claude.json"
HOME="$MIG_HOME" CLAUDE_CODE_PROJECT_DIR_NAME="sample-app" bash -c "$mig_cmd"
if [[ "$(cat "$MIG_HOME/.claude/.claude.json")" == '{"newer":1}' ]]; then
    pass "an existing ~/.claude/.claude.json is never clobbered"
else
    fail "migration must not clobber an existing config-dir json"
fi

# Wizard-window VM: a session between 0.1.3 and 0.1.4 created projects/<name>,
# stranding history in -workspace — entries must merge without overwriting
mkdir -p "$MIG_HOME/.claude/projects/-workspace/memory"
echo hist > "$MIG_HOME/.claude/projects/-workspace/hist.jsonl"
echo mem  > "$MIG_HOME/.claude/projects/-workspace/memory/MEMORY.md"
echo wiz  > "$MIG_HOME/.claude/projects/sample-app/wiz.jsonl"
echo keep > "$MIG_HOME/.claude/projects/-workspace/wiz.jsonl"
HOME="$MIG_HOME" CLAUDE_CODE_PROJECT_DIR_NAME="sample-app" bash -c "$mig_cmd"
if [[ -f "$MIG_HOME/.claude/projects/sample-app/hist.jsonl" ]] \
   && [[ -f "$MIG_HOME/.claude/projects/sample-app/memory/MEMORY.md" ]] \
   && [[ "$(cat "$MIG_HOME/.claude/projects/sample-app/wiz.jsonl")" == wiz ]]; then
    pass "both-dirs case merges -workspace into projects/<name> without overwriting"
else
    fail "merge migration failed: $(find "$MIG_HOME/.claude/projects" 2>/dev/null | tr '\n' ' ')"
fi
if [[ "$(cat "$MIG_HOME/.claude/projects/-workspace/wiz.jsonl" 2>/dev/null)" == keep ]]; then
    pass "colliding entries are left behind in -workspace, never clobbered"
else
    fail "collision handling: -workspace/wiz.jsonl should survive with original content"
fi
rm -rf "$MIG_HOME"

rm -rf "$FAKE_BIN" "$(dirname "$CONN_PROJECT")"
teardown_test_env

# ── Test: sync include-list carries user-scope customizations ────────────────
echo "--- Test 10: sync_claude_config_to_vm include-list ---"
setup_test_env

FAKE_BIN="$(mktemp -d)"
FAKE_HOME="$(mktemp -d)"
SYNC_LOG="$FAKE_BIN/calls.log"
cat > "$FAKE_BIN/rsync" <<FAKE
#!/usr/bin/env bash
echo "rsync \$*" >> "$SYNC_LOG"
FAKE
cat > "$FAKE_BIN/ssh" <<FAKE
#!/usr/bin/env bash
echo "ssh \$*" >> "$SYNC_LOG"
FAKE
chmod +x "$FAKE_BIN/rsync" "$FAKE_BIN/ssh"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.config/glab-cli" "$FAKE_HOME/.config/gh"
echo '{"theme":"dark"}' > "$FAKE_HOME/.claude.json"

HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" sync_claude_config_to_vm 12345 >/dev/null 2>&1

claude_sync_line="$(grep -- "--include=settings.json" "$SYNC_LOG" | head -1)"
missing_includes=()
for inc in "agents/***" "commands/***" "workflows/***" "keybindings.json" "plugins/***" "skills/***"; do
    [[ "$claude_sync_line" == *"--include=$inc "* ]] || missing_includes+=("$inc")
done
if (( ${#missing_includes[@]} == 0 )); then
    pass "~/.claude sync includes agents, commands, workflows, keybindings"
else
    fail "~/.claude sync missing includes: ${missing_includes[*]} — $claude_sync_line"
fi
if [[ "$claude_sync_line" == *"--exclude=* "* ]]; then
    pass "~/.claude sync still ends with a catch-all exclude"
else
    fail "~/.claude sync should keep --exclude='*': $claude_sync_line"
fi

# ── Test: glab-cli config is synced like gh ──────────────────────────────────
echo "--- Test 11: sync_claude_config_to_vm syncs ~/.config/glab-cli/ ---"
if grep -q "ssh .*mkdir -p ~/.config/glab-cli" "$SYNC_LOG" && \
   grep -q "rsync .*$FAKE_HOME/.config/glab-cli/ .*@localhost:~/.config/glab-cli/" "$SYNC_LOG"; then
    pass "glab-cli config dir is rsynced into the guest"
else
    fail "glab-cli config should be rsynced: $(cat "$SYNC_LOG")"
fi
if grep -q "rsync .*$FAKE_HOME/.config/gh/ .*@localhost:~/.config/gh/" "$SYNC_LOG"; then
    pass "gh config sync unchanged"
else
    fail "gh config sync should still run: $(cat "$SYNC_LOG")"
fi

# ── Test: ~/.claude.json lands at the CLAUDE_CONFIG_DIR location ─────────────
echo "--- Test 12: host ~/.claude.json syncs to guest ~/.claude/.claude.json ---"
if grep -q "rsync .*$FAKE_HOME/.claude.json .*@localhost:~/.claude/.claude.json" "$SYNC_LOG"; then
    pass "config json targets ~/.claude/.claude.json (read via CLAUDE_CONFIG_DIR)"
else
    fail "config json should target ~/.claude/.claude.json: $(grep claude.json "$SYNC_LOG")"
fi
if grep -q "@localhost:~/.claude.json" "$SYNC_LOG"; then
    fail "config json must not target the legacy ~/.claude.json path: $(grep claude.json "$SYNC_LOG")"
else
    pass "legacy ~/.claude.json guest path no longer written"
fi

rm -rf "$FAKE_BIN" "$FAKE_HOME"
teardown_test_env

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
(( TESTS_FAILED > 0 )) && exit 1 || exit 0
