#!/usr/bin/env bash
# Tests for lib/herdr.sh — VM names, the claude-vm-* ssh aliases, the
# ~/.ssh/config include, setup-herdr and the herdr start/stop/remove hooks —
# plus the pinned host key and guest env file they rely on.
# herdr, ssh and socat are PATH shims; no VM or real herdr is needed.
# Run: bash tests/test_herdr.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  ✓ $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  ✗ $1: $2"; }

# ─── Setup ────────────────────────────────────────────────────────────────────

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export CLAUDE_VM_DIR="$TEST_DIR/vm data"
export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"
export VM_USER="testuser"
export HOME="$TEST_DIR/home"
mkdir -p "$HOME" "$CLAUDE_VM_DIR/keys"
: > "$CLAUDE_VM_CONFIG"
ssh-keygen -t ed25519 -f "$CLAUDE_VM_DIR/keys/id_ed25519" -N "" -q

source "$PROJECT_DIR/lib/config.sh"
source "$PROJECT_DIR/lib/launch.sh"
CLAUDE_VM_BIN="/opt/claude vm/claude-vm"
load_config
ensure_dirs

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"
export FAKE_LOG="$TEST_DIR/calls.log"
export HERDR_CATALOG="$TEST_DIR/herdr-catalog"
export SSH_RESOLVES=true SSH_HOSTKEY_EXIT=0 HERDR_ADD_EXIT=0 SSH_PIN_FIXES=false SSH_PROBE_EXIT=0

# herdr: a tab-separated catalog (id label target session state)
cat > "$FAKE_BIN/herdr" << 'EOF'
#!/usr/bin/env bash
echo "herdr $*" >> "$FAKE_LOG"
[[ "$1" == machine ]] || exit 2
touch "$HERDR_CATALOG"
case "$2" in
    list) cat "$HERDR_CATALOG" ;;
    add)
        [[ "${HERDR_ADD_EXIT:-0}" == 0 ]] || exit "$HERDR_ADD_EXIT"
        printf 'id%s\t%s\t%s\tdefault\tenabled\n' "$(wc -l < "$HERDR_CATALOG")" "$3" "$3" >> "$HERDR_CATALOG"
        ;;
    enable|disable)
        state="${2}d"
        awk -F'\t' -v OFS='\t' -v id="$3" -v s="$state" '$1 == id { $5 = s } { print }' \
            "$HERDR_CATALOG" > "$HERDR_CATALOG.tmp" && mv "$HERDR_CATALOG.tmp" "$HERDR_CATALOG"
        ;;
    remove)
        awk -F'\t' -v id="$3" '$1 != id' "$HERDR_CATALOG" > "$HERDR_CATALOG.tmp"
        mv "$HERDR_CATALOG.tmp" "$HERDR_CATALOG"
        ;;
esac
EOF

# ssh: -G answers config queries; "sudo sh -s" is the host key install
# (script captured; with SSH_PIN_FIXES=true later checks pass); anything
# else is the host key check, or the env-file write during config sync
cat > "$FAKE_BIN/ssh" << 'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$FAKE_LOG"
for a in "$@"; do
    if [[ "$a" == -G ]]; then
        [[ "$SSH_RESOLVES" == true ]] && echo "proxycommand env CLAUDE_VM_DIR=/x /usr/bin/claude-vm proxy %n"
        exit 0
    fi
    if [[ "$a" == "cat > ~/.claude-vm-env" ]]; then
        cat > "$FAKE_LOG.env"
        exit 0
    fi
    if [[ "$a" == "grep -qxF "* ]]; then
        # strict probe: refused (255) until the key is pinned, then reports
        # the guest env state
        [[ -f "$FAKE_LOG.pinned" || "${SSH_HOSTKEY_EXIT:-0}" == 0 ]] || exit "$SSH_HOSTKEY_EXIT"
        exit "${SSH_PROBE_EXIT:-0}"
    fi
    if [[ "$a" == "sh -s" ]]; then
        cat > "$FAKE_LOG.upgrade"
        exit 0
    fi
    if [[ "$a" == "sudo sh -s" ]]; then
        cat > "$FAKE_LOG.pin"
        [[ "${SSH_PIN_FIXES:-}" == true ]] && touch "$FAKE_LOG.pinned"
        exit 0
    fi
done
[[ -f "$FAKE_LOG.pinned" ]] && exit 0
exit "${SSH_HOSTKEY_EXIT:-0}"
EOF

# The pin retry loop sleeps between checks; tests needn't wait
printf '#!/bin/sh\n' > "$FAKE_BIN/sleep"

cat > "$FAKE_BIN/socat" << 'EOF'
#!/usr/bin/env bash
echo "socat $*" >> "$FAKE_LOG"
EOF
chmod +x "$FAKE_BIN"/*

reset_state() {
    rm -f "$FAKE_LOG" "$FAKE_LOG.env" "$FAKE_LOG.pin" "$FAKE_LOG.pinned" "$FAKE_LOG.upgrade" "$HERDR_CATALOG" "$SNAPSHOTS_DIR"/*.name \
        "$(vm_ssh_config_path)" "$HOME/.ssh/config" "$HOME/.ssh/config.claude-vm.bak"
    rm -rf "${RUN_DIR:?}"/*
    SSH_RESOLVES=true SSH_HOSTKEY_EXIT=0 HERDR_ADD_EXIT=0 SSH_PIN_FIXES=false SSH_PROBE_EXIT=0
}

# Mark a project's VM as running on a port (qemu.pid = this shell)
fake_running() {
    local dir="$1" port="$2" run_dir
    run_dir="$(project_run_dir "$dir")"
    mkdir -p "$run_dir"
    echo "$$" > "$run_dir/qemu.pid"
    echo "$port" > "$run_dir/ssh_port"
    echo "$dir" > "$SNAPSHOTS_DIR/$(project_hash "$dir").project"
}

# What setup-herdr leaves behind: the alias config plus the include
fake_setup() {
    write_vm_ssh_config
    _add_user_ssh_include
}

logged() { grep -qF -- "$1" "$FAKE_LOG" 2>/dev/null; }

echo "=== herdr / ssh alias tests ==="
echo ""

# ─── Names ────────────────────────────────────────────────────────────────────

test_sanitize() {
    local got
    got="$(_sanitize_vm_name "/x/My Project.v2")"
    [[ "$got" == "my-project-v2" ]] && pass "sanitize: lowercase, punctuation to single dashes" \
        || fail "sanitize: punctuation" "got $got"
    got="$(_sanitize_vm_name "/x/a-very-long-project-name-indeed")"
    [[ "$got" == "a-very-long-proj" ]] && pass "sanitize: capped at 16 chars" \
        || fail "sanitize: cap" "got $got"
    got="$(_sanitize_vm_name "/x/abcdefghijklmno-pq")"
    [[ "$got" == "abcdefghijklmno" ]] && pass "sanitize: no trailing dash after the cap" \
        || fail "sanitize: trailing dash" "got $got"
    got="$(_sanitize_vm_name "/x/__")"
    [[ "$got" == "vm" ]] && pass "sanitize: nothing usable falls back to 'vm'" \
        || fail "sanitize: fallback" "got $got"
}

test_names_persist_and_dedupe() {
    reset_state
    local a b c
    a="$(project_vm_name /work/api)"
    b="$(project_vm_name /oss/api)"
    c="$(project_vm_name /work/api)"
    if [[ "$a" == api && "$b" == api-2 && "$c" == api ]]; then
        pass "names: same basename gets -2; a project keeps its name"
    else
        fail "names: dedupe" "a=$a b=$b c=$c"
    fi
    a="$(project_vm_name /one/sixteen-chars-xx)"
    b="$(project_vm_name /two/sixteen-chars-xx)"
    if [[ "$a" == sixteen-chars-xx && "$b" == sixteen-chars-2 ]]; then
        pass "names: suffix stays within 16 chars"
    else
        fail "names: suffix cap" "a=$a b=$b"
    fi
    [[ "$(vm_hash_for_name api-2)" == "$(project_hash /oss/api)" ]] \
        && pass "names: vm_hash_for_name maps a name back to its project" \
        || fail "names: lookup" "got $(vm_hash_for_name api-2)"
}

# ─── Host key, ssh config, cloud-init ─────────────────────────────────────────

test_host_key_pinned() {
    ensure_vm_host_key
    local first second
    first="$(cat "$(vm_known_hosts_path)")"
    ensure_vm_host_key
    second="$(cat "$(vm_known_hosts_path)")"
    if [[ "$first" == "claude-vm ssh-ed25519 "* && "$first" == "$second" ]]; then
        pass "host key: known_hosts pins it under the claude-vm alias; stable across calls"
    else
        fail "host key" "first=$first second=$second"
    fi
}

test_ssh_config_contents() {
    write_vm_ssh_config
    local cfg
    cfg="$(cat "$(vm_ssh_config_path)")"
    local ok=true
    [[ "$cfg" == *"Host claude-vm-*"* ]] || ok=false
    [[ "$cfg" == *"User testuser"* ]] || ok=false
    [[ "$cfg" == *"HostKeyAlias claude-vm"* ]] || ok=false
    [[ "$cfg" == *"IdentityFile \"$CLAUDE_VM_DIR/keys/id_ed25519\""* ]] || ok=false
    [[ "$cfg" == *"ProxyCommand env CLAUDE_VM_DIR=$TEST_DIR/vm\\ data /opt/claude\\ vm/claude-vm proxy %n"* ]] || ok=false
    $ok && pass "ssh config: one Host block, pinned key, quoted ProxyCommand" \
        || fail "ssh config" "$cfg"
}

test_cloud_init_bakes_host_key_and_env() {
    local out="$TEST_DIR/ci"
    mkdir -p "$out"
    FLAVOR=debian-slim generate_cloud_init_userdata "$out" >/dev/null
    local ud
    ud="$(cat "$out/user-data")"
    if [[ "$ud" == *"ed25519_private: |"*"    -----BEGIN OPENSSH PRIVATE KEY-----"* \
          && "$ud" == *"ed25519_public: $(cat "$(vm_host_key_path).pub")"* ]]; then
        pass "cloud-init: ssh_keys carries the pinned host key"
    else
        fail "cloud-init: ssh_keys" "missing or misindented"
    fi
    if [[ "$ud" == *'[ -f "$HOME/.claude-vm-env" ] && . "$HOME/.claude-vm-env"'* ]]; then
        pass "cloud-init: guest .bashrc sources ~/.claude-vm-env"
    else
        fail "cloud-init: bashrc" "no source line"
    fi
    # Claude Code sources ~/.bashrc per Bash call; a cd there undoes its cwd
    if [[ "$ud" != *'cd /workspace'* ]]; then
        pass "cloud-init: guest .bashrc does not cd"
    else
        fail "cloud-init: bashrc" "still cds to /workspace"
    fi
}

test_sync_writes_env_file() {
    reset_state
    sync_claude_config_to_vm 12345 "/work/My App" >/dev/null 2>&1 || true
    local env
    env="$(cat "$FAKE_LOG.env" 2>/dev/null)"
    if [[ "$env" == *'export CLAUDE_CONFIG_DIR="$HOME/.claude"'* \
          && "$env" == *'export CLAUDE_CODE_PROJECT_DIR_NAME="MyApp"'* ]]; then
        pass "config sync: writes ~/.claude-vm-env with the project's transcript name"
    else
        fail "config sync: env file" "got: $env"
    fi
}

# ─── ~/.ssh/config include ────────────────────────────────────────────────────

test_include_new_config() {
    reset_state
    rm -rf "$HOME/.ssh"
    _add_user_ssh_include
    local cfg="$HOME/.ssh/config"
    if [[ "$(head -2 "$cfg" | tail -1)" == "$(_herdr_include_line)" \
          && "$(stat -c %a "$cfg")" == 600 && "$(stat -c %a "$HOME/.ssh")" == 700 ]]; then
        pass "include: creates ~/.ssh/config (600) with the Include"
    else
        fail "include: new config" "$(cat "$cfg"; stat -c %a "$cfg")"
    fi
}

test_include_existing_roundtrip() {
    reset_state
    mkdir -p "$HOME/.ssh"
    local orig=$'Host *\n  User bob\n'
    printf '%s' "$orig" > "$HOME/.ssh/config"
    _add_user_ssh_include
    local first_lines
    first_lines="$(head -2 "$HOME/.ssh/config")"
    if [[ "$first_lines" == "$HERDR_INCLUDE_MARKER"$'\n'"$(_herdr_include_line)" \
          && "$(tail -2 "$HOME/.ssh/config")" == "${orig%$'\n'}" \
          && "$(cat "$HOME/.ssh/config.claude-vm.bak")" == "${orig%$'\n'}" ]]; then
        pass "include: prepended before existing Host blocks; backup kept"
    else
        fail "include: prepend" "$(cat "$HOME/.ssh/config")"
    fi
    _user_ssh_config_has_include && pass "include: detected once present" \
        || fail "include: detection" "not detected"
    _remove_user_ssh_include
    if [[ "$(cat "$HOME/.ssh/config")" == "${orig%$'\n'}" ]]; then
        pass "include: removal restores the original config"
    else
        fail "include: removal" "$(cat "$HOME/.ssh/config")"
    fi
}

test_include_keeps_symlink() {
    reset_state
    mkdir -p "$HOME/.ssh" "$HOME/dotfiles"
    echo "Host x" > "$HOME/dotfiles/ssh_config"
    ln -s "$HOME/dotfiles/ssh_config" "$HOME/.ssh/config"
    _add_user_ssh_include
    if [[ -L "$HOME/.ssh/config" ]] && grep -qxF "$(_herdr_include_line)" "$HOME/dotfiles/ssh_config"; then
        pass "include: writes through a symlinked ~/.ssh/config"
    else
        fail "include: symlink" "symlink replaced or target unchanged"
    fi
    rm -f "$HOME/.ssh/config" "$HOME/dotfiles/ssh_config"
}

# ─── setup-herdr ──────────────────────────────────────────────────────────────

test_setup_declined() {
    reset_state
    local out
    out="$(echo n | setup_herdr 2>&1)"
    if [[ ! -f "$HOME/.ssh/config" && -f "$(vm_ssh_config_path)" && "$out" == *"Not changed"* ]]; then
        pass "setup-herdr: answering no leaves ~/.ssh/config alone"
    else
        fail "setup-herdr: decline" "$out"
    fi
}

test_setup_yes_registers_running() {
    reset_state
    fake_running /work/web 10050
    local out
    out="$(setup_herdr --yes 2>&1)"
    if _user_ssh_config_has_include && logged "herdr machine add claude-vm-web" \
        && [[ "$out" == *"Running VMs:"*"claude-vm-web  /work/web"* ]]; then
        pass "setup-herdr --yes: adds the include and registers running VMs"
    else
        fail "setup-herdr --yes" "$out"
    fi
    out="$(setup_herdr --yes 2>&1)"
    if [[ "$out" == *"already includes"* && "$(grep -c "$(_herdr_include_line)" "$HOME/.ssh/config")" == 1 ]]; then
        pass "setup-herdr: idempotent"
    else
        fail "setup-herdr: rerun" "$out"
    fi
}

test_setup_remove() {
    reset_state
    setup_herdr --yes >/dev/null 2>&1
    printf 'idX\tmine\tworkbox\tdefault\tenabled\nidY\tclaude-vm-a\tclaude-vm-a\tdefault\tenabled\n' > "$HERDR_CATALOG"
    setup_herdr --remove >/dev/null 2>&1
    if ! _user_ssh_config_has_include && [[ ! -f "$(vm_ssh_config_path)" ]] \
        && logged "herdr machine remove idY" && ! logged "herdr machine remove idX"; then
        pass "setup-herdr --remove: drops include, config and only claude-vm machines"
    else
        fail "setup-herdr --remove" "$(cat "$FAKE_LOG" 2>/dev/null)"
    fi
}

# ─── Start / stop / remove hooks ──────────────────────────────────────────────

test_start_hook_inactive_without_setup() {
    reset_state
    herdr_vm_started /work/web 10050 2>/dev/null
    if [[ ! -s "$FAKE_LOG" && ! -f "$SNAPSHOTS_DIR/$(project_hash /work/web).name" ]]; then
        pass "start hook: no-op until setup-herdr"
    else
        fail "start hook: inactive" "$(cat "$FAKE_LOG")"
    fi
}

test_start_hook_warns_unresolved() {
    reset_state
    fake_setup
    SSH_RESOLVES=false
    local out
    out="$(herdr_vm_started /work/web 10050 2>&1)"
    if [[ "$out" == *"does not include"* ]] && ! logged "herdr machine add"; then
        pass "start hook: warns when ~/.ssh/config doesn't resolve the alias"
    else
        fail "start hook: unresolved" "$out"
    fi
}

test_start_hook_pins_old_base() {
    reset_state
    fake_setup
    SSH_HOSTKEY_EXIT=255 SSH_PIN_FIXES=true
    local out
    out="$(herdr_vm_started /work/web 10050 2>&1)"
    if [[ -s "$FAKE_LOG.pin" && -s "$FAKE_LOG.upgrade" && "$out" != *"rebase"* ]] \
        && logged "herdr machine add claude-vm-web"; then
        pass "start hook: older VM gets the host key and env upgrade, then registers"
    else
        fail "start hook: pin old base" "$out"
    fi
}

# A VM pinned before the env upgrade existed: key fine, env missing
test_pinned_vm_without_env_gets_upgrade() {
    reset_state
    fake_setup
    SSH_PROBE_EXIT=1
    local out
    out="$(herdr_vm_started /work/web 10050 2>&1)"
    if [[ -s "$FAKE_LOG.upgrade" && ! -e "$FAKE_LOG.pin" && "$out" != *"rebase"* ]] \
        && logged "herdr machine add claude-vm-web"; then
        pass "start hook: already-pinned VM missing the env gets only the env upgrade"
    else
        fail "start hook: env-only upgrade" "upgrade=$([[ -s "$FAKE_LOG.upgrade" ]] && echo y) pin=$([[ -e "$FAKE_LOG.pin" ]] && echo y) out=$out"
    fi
}

test_pinned_vm_skips_upgrades() {
    reset_state
    fake_setup
    herdr_vm_started /work/web 10050 2>/dev/null
    if [[ ! -e "$FAKE_LOG.pin" && ! -e "$FAKE_LOG.upgrade" ]]; then
        pass "start hook: a VM already on the pinned key is left untouched"
    else
        fail "start hook: pinned VM" "pin or upgrade ran"
    fi
}

# Run the captured env upgrade for real in a scratch guest home
test_env_upgrade_script() {
    reset_state
    _upgrade_guest_env 10050 "/work/My App" >/dev/null 2>&1
    local home="$TEST_DIR/guest-home"
    rm -rf "$home"; mkdir -p "$home"
    # An older base's .bashrc: PATH line plus the cd block that must go
    printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' \
        'if [ -d /workspace ]; then' '  cd /workspace 2>/dev/null' 'fi' > "$home/.bashrc"
    mkdir -p "$home/elsewhere"
    HOME="$home" sh -s < "$FAKE_LOG.upgrade"
    HOME="$home" sh -s < "$FAKE_LOG.upgrade"
    local got
    got="$(cd "$home/elsewhere" && HOME="$home" bash -c '. "$HOME/.bashrc"; echo "$CLAUDE_CODE_PROJECT_DIR_NAME:$CLAUDE_CONFIG_DIR:$PWD"')"
    if [[ "$(grep -cxF "$GUEST_ENV_SOURCE_LINE" "$home/.bashrc")" == 1 \
          && "$(head -1 "$home/.bashrc")" == 'export PATH="$HOME/.local/bin:$PATH"' \
          && "$got" == "MyApp:$home/.claude:"* ]]; then
        pass "env upgrade: appends the .bashrc line once and writes ~/.claude-vm-env"
    else
        fail "env upgrade" "got=$got bashrc=$(cat "$home/.bashrc")"
    fi
    if ! grep -q 'cd /workspace' "$home/.bashrc" && [[ "$got" == *":$home/elsewhere" ]]; then
        pass "env upgrade: strips the old cd block, so sourcing .bashrc keeps the cwd"
    else
        fail "env upgrade: cd block" "got=$got bashrc=$(cat "$home/.bashrc")"
    fi
    echo 'export CLAUDE_CODE_PROJECT_DIR_NAME="stale"' > "$home/.claude-vm-env"
    HOME="$home" sh -s < "$FAKE_LOG.upgrade"
    if cmp -s <(_guest_env_file "/work/My App") "$home/.claude-vm-env"; then
        pass "env upgrade: a stale ~/.claude-vm-env is rewritten"
    else
        fail "env upgrade: stale file" "$(cat "$home/.claude-vm-env")"
    fi
}

test_start_hook_warns_when_pin_fails() {
    reset_state
    fake_setup
    SSH_HOSTKEY_EXIT=255
    local out
    out="$(herdr_vm_started /work/web 10050 2>&1)"
    if [[ -s "$FAKE_LOG.pin" && "$out" == *"claude-vm rebase"* ]] && ! logged "herdr machine add"; then
        pass "start hook: a key that still doesn't match asks for a rebase instead of registering"
    else
        fail "start hook: pin failure" "$out"
    fi
}

# Run the captured install script for real against a scratch /etc/ssh
# (no sudo, systemctl stubbed): it must write the pinned key in place
test_pin_script_installs_key() {
    reset_state
    _pin_vm_host_key 10050 >/dev/null 2>&1
    local etc="$TEST_DIR/etc-ssh" stub="$TEST_DIR/stub-bin"
    mkdir -p "$etc" "$stub"
    printf 'old\n' > "$etc/ssh_host_ed25519_key"
    chmod 640 "$etc/ssh_host_ed25519_key"
    printf '#!/bin/sh\necho "systemctl $*" >> "%s"\n' "$FAKE_LOG" > "$stub/systemctl"
    chmod +x "$stub/systemctl"
    local rc=0
    sed "s|/etc/ssh|$etc|" "$FAKE_LOG.pin" | PATH="$stub:$PATH" sh -s >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )) \
        && cmp -s "$etc/ssh_host_ed25519_key" "$(vm_host_key_path)" \
        && cmp -s "$etc/ssh_host_ed25519_key.pub" "$(vm_host_key_path).pub" \
        && [[ "$(stat -c %a "$etc/ssh_host_ed25519_key")" == 640 ]] \
        && logged "systemctl reload ssh"; then
        pass "pin script: writes key + pub in place (mode kept) and reloads sshd"
    else
        fail "pin script" "rc=$rc mode=$(stat -c %a "$etc/ssh_host_ed25519_key")"
    fi
}

test_start_hook_add_enable() {
    reset_state
    fake_setup
    herdr_vm_started /work/web 10050 2>/dev/null
    logged "herdr machine add claude-vm-web" && pass "start hook: registers a new VM" \
        || fail "start hook: add" "$(cat "$FAKE_LOG")"
    rm -f "$FAKE_LOG"
    herdr_vm_started /work/web 10050 2>/dev/null
    ! logged "herdr machine add" && ! logged "herdr machine enable" \
        && pass "start hook: an enabled machine is left alone" \
        || fail "start hook: rerun" "$(cat "$FAKE_LOG")"
    herdr machine disable id0
    rm -f "$FAKE_LOG"
    herdr_vm_started /work/web 10050 2>/dev/null
    logged "herdr machine enable id0" && pass "start hook: re-enables a disabled machine" \
        || fail "start hook: enable" "$(cat "$FAKE_LOG")"
}

test_host_key_check_quotes_known_hosts() {
    reset_state
    vm_host_key_pinned 10050 || true
    # The VM dir has a space; UserKnownHostsFile splits unquoted values
    if logged "UserKnownHostsFile=\"$CLAUDE_VM_DIR/known_hosts\"" && logged "StrictHostKeyChecking=yes"; then
        pass "host key check: strict, with the known_hosts path quoted"
    else
        fail "host key check: quoting" "$(cat "$FAKE_LOG")"
    fi
}

test_start_hook_add_failure_is_soft() {
    reset_state
    fake_setup
    HERDR_ADD_EXIT=1
    local out rc=0
    out="$(herdr_vm_started /work/web 10050 2>&1)" || rc=$?
    if (( rc == 0 )) && [[ "$out" == *"installed in the guest"* ]]; then
        pass "start hook: failed registration warns, never fails the launch"
    else
        fail "start hook: add failure" "rc=$rc out=$out"
    fi
}

test_stop_and_remove_hooks() {
    reset_state
    fake_setup
    herdr_vm_started /work/web 10050 2>/dev/null
    local hash
    hash="$(project_hash /work/web)"
    herdr_vm_stopped "$hash"
    logged "herdr machine disable id0" && pass "stop hook: disables the machine" \
        || fail "stop hook" "$(cat "$FAKE_LOG")"
    herdr_vm_removed "$hash"
    if logged "herdr machine remove id0" && [[ ! -f "$SNAPSHOTS_DIR/${hash}.name" ]]; then
        pass "remove hook: removes the machine and releases the name"
    else
        fail "remove hook" "$(cat "$FAKE_LOG")"
    fi
}

test_parallel_stop_defers_herdr() {
    reset_state
    local d1="$RUN_DIR/aaa/" d2="$RUN_DIR/bbb/"
    mkdir -p "$d1" "$d2"
    (
        stop_vm_by_run_dir() { echo "${_HERDR_DEFER_STOP:-}" > "${1%/}/defer"; }
        herdr_vm_stopped() { echo "$1" >> "$TEST_DIR/stopped"; }
        stop_vms_parallel "$d1" "$d2" >/dev/null 2>&1
    )
    if [[ "$(cat "$d1/defer")" == true && "$(sort "$TEST_DIR/stopped" | tr '\n' ' ')" == "aaa bbb " ]]; then
        pass "stop --all: herdr disables run once per VM after the parallel stop"
    else
        fail "stop --all" "defer=$(cat "$d1/defer" 2>/dev/null) stopped=$(cat "$TEST_DIR/stopped" 2>/dev/null)"
    fi
}

# ─── Proxy ────────────────────────────────────────────────────────────────────

test_proxy() {
    reset_state
    local out rc=0
    out="$(vm_proxy claude-vm-nope 2>&1)" || rc=$?
    (( rc != 0 )) && [[ "$out" == *"no VM named 'nope'"* ]] \
        && pass "proxy: unknown name fails clearly" || fail "proxy: unknown" "$out"

    project_vm_name /work/web >/dev/null
    echo /work/web > "$SNAPSHOTS_DIR/$(project_hash /work/web).project"
    rc=0
    out="$(vm_proxy claude-vm-web 2>&1)" || rc=$?
    (( rc != 0 )) && [[ "$out" == *"not running"*"claude-vm start /work/web"* ]] \
        && pass "proxy: stopped VM names the start command" || fail "proxy: stopped" "$out"

    fake_running /work/web 10077
    ( vm_proxy claude-vm-web ) </dev/null >/dev/null 2>&1 || true
    logged "socat - TCP:127.0.0.1:10077" && pass "proxy: connects to the VM's current port" \
        || fail "proxy: running" "$(cat "$FAKE_LOG" 2>/dev/null)"
}

test_sanitize
test_names_persist_and_dedupe
test_host_key_pinned
test_ssh_config_contents
test_cloud_init_bakes_host_key_and_env
test_sync_writes_env_file
test_include_new_config
test_include_existing_roundtrip
test_include_keeps_symlink
test_setup_declined
test_setup_yes_registers_running
test_setup_remove
test_start_hook_inactive_without_setup
test_start_hook_warns_unresolved
test_start_hook_pins_old_base
test_pinned_vm_without_env_gets_upgrade
test_pinned_vm_skips_upgrades
test_env_upgrade_script
test_start_hook_warns_when_pin_fails
test_pin_script_installs_key
test_start_hook_add_enable
test_host_key_check_quotes_known_hosts
test_start_hook_add_failure_is_soft
test_stop_and_remove_hooks
test_parallel_stop_defers_herdr
test_proxy

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
if (( TESTS_FAILED > 0 )); then
    exit 1
fi
echo "All tests passed."
