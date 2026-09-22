#!/usr/bin/env bash
# Tests for the claude-vm cp command and its launch.sh helpers
# (copy_to_vm, _build_scp_cmd, _resolve_guest_path)
# Run: bash tests/test_cp.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  ✓ $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  ✗ $1: $2"; }

run_test() { "$@"; }

# ─── Setup ────────────────────────────────────────────────────────────────────

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

source "$PROJECT_DIR/lib/config.sh"
source "$PROJECT_DIR/lib/launch.sh"

# Extract cmd_cp from the CLI entry point (same approach as test_show.sh)
eval "$(sed -n '/^cmd_cp()/,/^}/p' "$PROJECT_DIR/claude-vm")"

# PATH shim for scp: records its argv and exits with $SCP_EXIT
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"
SCP_ARGS_FILE="$TEST_DIR/scp-args"
SCP_EXIT=0
export SCP_ARGS_FILE SCP_EXIT
cat > "$FAKE_BIN/scp" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SCP_ARGS_FILE"
exit "${SCP_EXIT:-0}"
EOF
chmod +x "$FAKE_BIN/scp"

# Scratch install state: VM dir with an ssh key present (so -i must appear)
export CLAUDE_VM_DIR="$TEST_DIR/vm"
export CLAUDE_VM_CONFIG="$CLAUDE_VM_DIR/config"
mkdir -p "$CLAUDE_VM_DIR/keys"
: > "$CLAUDE_VM_CONFIG"
export VM_USER="testuser"
touch "$CLAUDE_VM_DIR/keys/id_ed25519"

# Mock VM state
VM_RUNNING=true
is_vm_running() { $VM_RUNNING; }
get_project_ssh_port() { echo "10055"; }

# Workdir standing in for the project (cp always targets $PWD's VM)
WORK_DIR="$TEST_DIR/project"
mkdir -p "$WORK_DIR"

# Run cmd_cp from WORK_DIR, capturing stdout+stderr. Sets RC and OUTPUT.
run_cp() {
    set +e
    ( cd "$WORK_DIR" && cmd_cp "$@" ) >"$TEST_DIR/out" 2>&1
    RC=$?
    set -e
    OUTPUT="$(cat "$TEST_DIR/out")"
}

# True when one line of the recorded scp argv equals $1
scp_arg_is() { grep -qxF -e "$1" -- "$SCP_ARGS_FILE"; }

# True when the recorded argv contains $1 (an option flag) immediately
# followed by $2 (its value): scp passes e.g. -o and the option string as
# separate argv entries.
scp_opt_is() {
    local flag="$1" value="$2"
    grep -qxF -e "$flag" -- "$SCP_ARGS_FILE" \
        && awk -v f="$flag" -v v="$value" '
            $0 == f { seen = 1; next }
            seen && $0 == v { found = 1; exit }
            END { exit !found }
        ' "$SCP_ARGS_FILE"
}

reset_scp_args() { rm -f "$SCP_ARGS_FILE"; }

# ─── _resolve_guest_path ──────────────────────────────────────────────────────

test_resolve_dot() {
    if [[ "$(_resolve_guest_path ".")" == "/workspace" ]]; then
        pass "_resolve_guest_path: '.' -> /workspace"
    else
        fail "_resolve_guest_path: '.'" "got: $(_resolve_guest_path '.')"
    fi
}

test_resolve_dot_slash() {
    if [[ "$(_resolve_guest_path "./")" == "/workspace" ]]; then
        pass "_resolve_guest_path: './' -> /workspace"
    else
        fail "_resolve_guest_path: './'" "got: $(_resolve_guest_path './')"
    fi
}

test_resolve_relative() {
    local got
    got="$(_resolve_guest_path "a/b")"
    if [[ "$got" == "/workspace/a/b" ]]; then
        pass "_resolve_guest_path: relative path -> /workspace/<path>"
    else
        fail "_resolve_guest_path: relative path" "got: $got"
    fi
}

test_resolve_dot_relative() {
    local got
    got="$(_resolve_guest_path "./a/b")"
    if [[ "$got" == "/workspace/a/b" ]]; then
        pass "_resolve_guest_path: './a/b' -> /workspace/a/b"
    else
        fail "_resolve_guest_path: './a/b'" "got: $got"
    fi
}

test_resolve_parent() {
    local got
    got="$(_resolve_guest_path "../x")"
    if [[ "$got" == "/workspace/../x" ]]; then
        pass "_resolve_guest_path: relative parent not normalized"
    else
        fail "_resolve_guest_path: '../x'" "got: $got"
    fi
}

test_resolve_absolute() {
    local got
    got="$(_resolve_guest_path "/tmp/x")"
    if [[ "$got" == "/tmp/x" ]]; then
        pass "_resolve_guest_path: absolute path passes through"
    else
        fail "_resolve_guest_path: absolute path" "got: $got"
    fi
}

test_resolve_tilde() {
    local got
    got="$(_resolve_guest_path "~")"
    if [[ "$got" == "/home/$VM_USER" ]]; then
        pass "_resolve_guest_path: '~' -> guest user home"
    else
        fail "_resolve_guest_path: '~'" "got: $got"
    fi
}

test_resolve_tilde_subpath() {
    local got
    got="$(_resolve_guest_path "~/x")"
    if [[ "$got" == "/home/$VM_USER/x" ]]; then
        pass "_resolve_guest_path: '~/x' -> guest user home/x"
    else
        fail "_resolve_guest_path: '~/x'" "got: $got"
    fi
}

test_resolve_empty_fails() {
    if _resolve_guest_path "" >/dev/null 2>&1; then
        fail "_resolve_guest_path: empty string should fail" "it succeeded"
    else
        pass "_resolve_guest_path: empty string fails"
    fi
}

# ─── cmd_cp argument validation ───────────────────────────────────────────────

test_cp_needs_two_args_zero() {
    run_cp
    if (( RC != 0 )) && [[ "$OUTPUT" == *"Usage: claude-vm cp SRC DST"* ]]; then
        pass "cp with no args: usage error"
    else
        fail "cp with no args" "rc=$RC output=$OUTPUT"
    fi
}

test_cp_needs_two_args_one() {
    run_cp only-one
    if (( RC != 0 )) && [[ "$OUTPUT" == *"Usage: claude-vm cp SRC DST"* ]]; then
        pass "cp with one arg: usage error"
    else
        fail "cp with one arg" "rc=$RC output=$OUTPUT"
    fi
}

test_cp_needs_two_args_three() {
    run_cp a b c
    if (( RC != 0 )) && [[ "$OUTPUT" == *"Usage: claude-vm cp SRC DST"* ]]; then
        pass "cp with three args: usage error"
    else
        fail "cp with three args" "rc=$RC output=$OUTPUT"
    fi
}

test_cp_unknown_option() {
    run_cp -x a b
    if (( RC != 0 )) && [[ "$OUTPUT" == *"Unknown option: -x"* ]]; then
        pass "cp with unknown option: rejected"
    else
        fail "cp with unknown option" "rc=$RC output=$OUTPUT"
    fi
}

test_cp_help() {
    run_cp --help
    if (( RC == 0 )) && [[ "$OUTPUT" == *"Usage: claude-vm cp SRC DST"* ]] \
        && [[ "$OUTPUT" == *"always"* ]]; then
        pass "cp --help: usage text, exit 0"
    else
        fail "cp --help" "rc=$RC output=$OUTPUT"
    fi
}

test_cp_requires_running_vm() {
    VM_RUNNING=false
    run_cp a b
    VM_RUNNING=true
    if (( RC != 0 )) && [[ "$OUTPUT" == *"No VM running"* ]]; then
        pass "cp with no running VM: rejected"
    else
        fail "cp with no running VM" "rc=$RC output=$OUTPUT"
    fi
}

test_cp_missing_source() {
    reset_scp_args
    run_cp no-such-file .
    if (( RC != 0 )) && [[ "$OUTPUT" == *"Source not found: no-such-file"* ]] \
        && [[ ! -f "$SCP_ARGS_FILE" ]]; then
        pass "cp with missing source: rejected before scp"
    else
        fail "cp with missing source" "rc=$RC output=$OUTPUT"
    fi
}

test_cp_empty_destination() {
    touch "$WORK_DIR/notes.md"
    run_cp notes.md ""
    if (( RC != 0 )) && [[ "$OUTPUT" == *"Invalid destination path"* ]]; then
        pass "cp with empty destination: rejected"
    else
        fail "cp with empty destination" "rc=$RC output=$OUTPUT"
    fi
}

# ─── scp invocation ───────────────────────────────────────────────────────────

test_cp_invokes_scp_recursive() {
    touch "$WORK_DIR/notes.md"
    reset_scp_args
    run_cp notes.md .
    if (( RC == 0 )) && scp_arg_is "-r"; then
        pass "cp passes -r even for a single file"
    else
        fail "cp -r for a file" "rc=$RC"
    fi
}

test_cp_scp_argv() {
    touch "$WORK_DIR/notes.md"
    reset_scp_args
    run_cp notes.md .
    local ok=true
    scp_opt_is "-i" "$CLAUDE_VM_DIR/keys/id_ed25519" || ok=false
    scp_opt_is "-o" "StrictHostKeyChecking=no" || ok=false
    scp_opt_is "-o" "UserKnownHostsFile=/dev/null" || ok=false
    scp_opt_is "-o" "LogLevel=ERROR" || ok=false
    scp_opt_is "-P" "10055" || ok=false
    scp_arg_is "notes.md" || ok=false
    scp_arg_is "testuser@localhost:/workspace" || ok=false
    if $ok; then
        pass "cp scp argv: -i key, ssh options, -P port, user@localhost:/workspace"
    else
        fail "cp scp argv" "$(tr '\n' ' ' < "$SCP_ARGS_FILE")"
    fi
}

test_cp_scp_argv_without_key() {
    mv "$CLAUDE_VM_DIR/keys/id_ed25519" "$CLAUDE_VM_DIR/keys/id_ed25519.bak"
    touch "$WORK_DIR/notes.md"
    reset_scp_args
    run_cp notes.md .
    local rc=$RC
    mv "$CLAUDE_VM_DIR/keys/id_ed25519.bak" "$CLAUDE_VM_DIR/keys/id_ed25519"
    if (( rc == 0 )) && ! scp_arg_is "-i $CLAUDE_VM_DIR/keys/id_ed25519"; then
        pass "scp argv omits -i when no key file exists"
    else
        fail "scp argv without key" "rc=$rc"
    fi
}

test_cp_dot_destination() {
    touch "$WORK_DIR/notes.md"
    reset_scp_args
    run_cp notes.md .
    if (( RC == 0 )) && scp_arg_is "testuser@localhost:/workspace"; then
        pass "cp destination '.' -> /workspace"
    else
        fail "cp destination '.'" "rc=$RC"
    fi
}

test_cp_relative_destination() {
    touch "$WORK_DIR/notes.md"
    reset_scp_args
    run_cp notes.md sub/dir
    if (( RC == 0 )) && scp_arg_is "testuser@localhost:/workspace/sub/dir"; then
        pass "cp relative destination -> /workspace/<path>"
    else
        fail "cp relative destination" "rc=$RC"
    fi
}

test_cp_absolute_destination() {
    touch "$WORK_DIR/notes.md"
    reset_scp_args
    run_cp notes.md /tmp/hosts
    if (( RC == 0 )) && scp_arg_is "testuser@localhost:/tmp/hosts"; then
        pass "cp absolute destination passes through"
    else
        fail "cp absolute destination" "rc=$RC"
    fi
}

test_cp_tilde_destination() {
    touch "$WORK_DIR/notes.md"
    reset_scp_args
    run_cp notes.md "~/secrets"
    if (( RC == 0 )) && scp_arg_is "testuser@localhost:/home/testuser/secrets"; then
        pass "cp '~/' destination -> guest user home"
    else
        fail "cp '~/..' destination" "rc=$RC"
    fi
}

test_cp_directory_source() {
    mkdir -p "$WORK_DIR/src"
    touch "$WORK_DIR/src/f.txt"
    reset_scp_args
    run_cp src vendor
    if (( RC == 0 )) && scp_arg_is "src" && scp_arg_is "testuser@localhost:/workspace/vendor" \
        && scp_arg_is "-r"; then
        pass "cp directory source: -r with guest destination"
    else
        fail "cp directory source" "rc=$RC"
    fi
}

test_cp_leading_dash_source() {
    touch "$WORK_DIR/-dash.txt"
    reset_scp_args
    run_cp -- -dash.txt .
    if (( RC == 0 )) && scp_arg_is "./-dash.txt" && scp_arg_is "testuser@localhost:/workspace"; then
        pass "cp '-- -dash.txt': source prefixed with ./"
    else
        fail "cp leading-dash source" "rc=$RC"
    fi
}

test_cp_propagates_scp_failure() {
    touch "$WORK_DIR/notes.md"
    reset_scp_args
    SCP_EXIT=7
    run_cp notes.md .
    local rc=$RC
    SCP_EXIT=0
    if (( rc == 7 )) && [[ "$OUTPUT" != *"Copied to"* ]]; then
        pass "cp propagates scp exit code and skips success line"
    else
        fail "cp scp failure propagation" "rc=$rc output=$OUTPUT"
    fi
}

test_cp_success_messages() {
    touch "$WORK_DIR/notes.md"
    reset_scp_args
    run_cp notes.md .
    if [[ "$OUTPUT" == *"Copying notes.md -> testuser@localhost:/workspace"* ]] \
        && [[ "$OUTPUT" == *"Copied to /workspace"* ]]; then
        pass "cp prints destination before and success line after"
    else
        fail "cp success messages" "output=$OUTPUT"
    fi
}

# ─── Run ──────────────────────────────────────────────────────────────────────

echo "=== claude-vm cp tests ==="
echo ""

run_test test_resolve_dot
run_test test_resolve_dot_slash
run_test test_resolve_relative
run_test test_resolve_dot_relative
run_test test_resolve_parent
run_test test_resolve_absolute
run_test test_resolve_tilde
run_test test_resolve_tilde_subpath
run_test test_resolve_empty_fails
run_test test_cp_needs_two_args_zero
run_test test_cp_needs_two_args_one
run_test test_cp_needs_two_args_three
run_test test_cp_unknown_option
run_test test_cp_help
run_test test_cp_requires_running_vm
run_test test_cp_missing_source
run_test test_cp_empty_destination
run_test test_cp_invokes_scp_recursive
run_test test_cp_scp_argv
run_test test_cp_scp_argv_without_key
run_test test_cp_dot_destination
run_test test_cp_relative_destination
run_test test_cp_absolute_destination
run_test test_cp_tilde_destination
run_test test_cp_directory_source
run_test test_cp_leading_dash_source
run_test test_cp_propagates_scp_failure
run_test test_cp_success_messages

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_RUN} total"

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
echo "All tests passed."
