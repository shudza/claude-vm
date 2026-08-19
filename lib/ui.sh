#!/usr/bin/env bash
# ui.sh — Clean console output for claude-vm
#
# Provides a single status line that redraws in place with a spinner,
# hiding technical output behind it. All stdout/stderr from wrapped
# commands goes to a log file.
#
# Rendering modes (decided once in ui_init):
#   rich    — interactive terminal: one transient line redraws per phase;
#             successful phases leave no output behind
#   plain   — non-tty / CLAUDE_VM_QUIET: one permanent line per phase (✓/✗)
#   verbose — CLAUDE_VM_VERBOSE: phase headers plus full command output
# On failure: a ✗ line is committed in every mode, with log path and tail.
#
# Usage:
#   ui_init "/path/to/logfile"
#   ui_phase "Starting VM" start_vm_function arg1 arg2
#   ui_phase "Waiting for SSH" wait_for_ssh 10022 60
#   ui_done "VM ready"

set -euo pipefail

# ── State ────────────────────────────────────────────────────────────────────

_UI_LOG=""
_UI_SPINNER_PID=""
_UI_SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
_UI_QUIET="${CLAUDE_VM_QUIET:-false}"
_UI_VERBOSE="${CLAUDE_VM_VERBOSE:-false}"
_UI_RICH=false
_UI_PROGRESS_I=0

# ── Init / Teardown ─────────────────────────────────────────────────────────

# Initialize the UI with a log file path
# Args: $1 = log file path
ui_init() {
    _UI_LOG="$1"
    mkdir -p "$(dirname "$_UI_LOG")"
    : > "$_UI_LOG"  # truncate

    _UI_RICH=false
    if [[ "$_UI_QUIET" != "true" && "$_UI_VERBOSE" != "true" ]]; then
        # UI output goes to stderr, so the tty check is on fd 2;
        # CLAUDE_VM_FORCE_TTY lets tests exercise rich mode without a tty
        if [[ -t 2 || "${CLAUDE_VM_FORCE_TTY:-}" == "true" ]]; then
            _UI_RICH=true
        fi
    fi

    # Clean up spinner on exit/interrupt — but only when the caller doesn't
    # already own the EXIT trap (rebase chains _ui_stop_spinner into its
    # lock-release trap, which must not be clobbered)
    if [[ -z "$(trap -p EXIT)" ]]; then
        trap '_ui_stop_spinner' EXIT INT TERM
    fi
}

# ── Spinner ──────────────────────────────────────────────────────────────────

_ui_start_spinner() {
    local msg="$1"

    if [[ "${_UI_RICH:-false}" != "true" ]]; then
        return
    fi

    (
        local i=0
        local n=${#_UI_SPINNER_FRAMES[@]}
        while true; do
            printf '\r\033[K  %s %s' "${_UI_SPINNER_FRAMES[$((i % n))]}" "$msg" >&2
            sleep 0.08
            (( i++ )) || true
        done
    ) &
    _UI_SPINNER_PID=$!
    disown "$_UI_SPINNER_PID" 2>/dev/null || true
}

_ui_stop_spinner() {
    if [[ -n "${_UI_SPINNER_PID:-}" ]]; then
        kill "$_UI_SPINNER_PID" 2>/dev/null || true
        wait "$_UI_SPINNER_PID" 2>/dev/null || true
        _UI_SPINNER_PID=""
        # Clear the spinner line
        if [[ "${_UI_RICH:-false}" == "true" ]]; then
            printf '\r\033[K' >&2
        fi
    fi
}

# ── Phase execution ──────────────────────────────────────────────────────────

# Run a command with a spinner, capturing all output to log
# Args: $1 = display message, $2... = command and args
# Returns: exit code of the command
ui_phase() {
    local msg="$1"
    shift

    if [[ "$_UI_VERBOSE" == "true" ]]; then
        # Verbose mode: no spinner, show everything
        echo ":: $msg" >&2
        "$@" 2>&1 | tee -a "$_UI_LOG"
        return "${PIPESTATUS[0]}"
    fi

    _ui_start_spinner "$msg"

    local rc=0
    "$@" >> "$_UI_LOG" 2>&1 || rc=$?

    _ui_stop_spinner

    if (( rc == 0 )); then
        # Rich mode: success leaves nothing behind — the next phase (or
        # ui_done) redraws in place of the cleared spinner line
        if [[ "$_UI_RICH" != "true" ]]; then
            printf '  \033[32m✓\033[0m %s\n' "$msg" >&2
        fi
    else
        printf '  \033[31m✗\033[0m %s\n' "$msg" >&2
        _ui_show_error "$rc"
    fi

    return "$rc"
}

# ── Progress line (parent-driven, for parallel waits) ───────────────────────

# Redraw a transient progress line. Call repeatedly while polling.
# Must not be used while a ui_phase spinner is running.
# Args: $1 = display message
ui_progress() {
    local msg="$1"
    if [[ "$_UI_RICH" != "true" ]]; then
        return 0
    fi
    local n=${#_UI_SPINNER_FRAMES[@]}
    printf '\r\033[K  %s %s' "${_UI_SPINNER_FRAMES[$((_UI_PROGRESS_I % n))]}" "$msg" >&2
    (( _UI_PROGRESS_I++ )) || true
}

# Clear the transient progress line
ui_progress_clear() {
    if [[ "$_UI_RICH" == "true" ]]; then
        printf '\r\033[K' >&2
    fi
}

# ── Status messages ──────────────────────────────────────────────────────────

# Print a success summary line
ui_done() {
    local msg="$1"
    if [[ "$_UI_RICH" == "true" ]]; then
        printf '  \033[32m%s\033[0m\n' "$msg" >&2
    else
        printf '\n  \033[32m%s\033[0m\n\n' "$msg" >&2
    fi
}

# Print an info line (not a phase, just context)
ui_info() {
    local msg="$1"
    printf '  %s\n' "$msg" >&2
}

# Print a warning
ui_warn() {
    local msg="$1"
    printf '  \033[33m⚠ %s\033[0m\n' "$msg" >&2
}

# ── Internal ─────────────────────────────────────────────────────────────────

_ui_show_error() {
    local rc="$1"
    if [[ -n "$_UI_LOG" && -f "$_UI_LOG" ]]; then
        printf '\n  \033[2mLog: %s\033[0m\n' "$_UI_LOG" >&2
        # Show last few non-empty lines from log
        local tail_lines
        tail_lines=$(grep -v '^$' "$_UI_LOG" | tail -5)
        if [[ -n "$tail_lines" ]]; then
            printf '  \033[2m' >&2
            echo "$tail_lines" | sed 's/^/  | /' >&2
            printf '\033[0m\n' >&2
        fi
    fi
}
