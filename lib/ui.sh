#!/usr/bin/env bash
# ui.sh — Clean console output for claude-vm
#
# Provides a spinner that hides technical output behind a single status line.
# All stdout/stderr from wrapped commands goes to a log file.
# On success: spinner completes with ✓
# On failure: spinner shows ✗, prints log path, and tails recent errors
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

# ── Init / Teardown ─────────────────────────────────────────────────────────

# Initialize the UI with a log file path
# Args: $1 = log file path
ui_init() {
    _UI_LOG="$1"
    mkdir -p "$(dirname "$_UI_LOG")"
    : > "$_UI_LOG"  # truncate

    # Clean up spinner on exit/interrupt
    trap '_ui_stop_spinner' EXIT INT TERM
}

# ── Spinner ──────────────────────────────────────────────────────────────────

_ui_start_spinner() {
    local msg="$1"

    # Don't spin if not a terminal or in quiet mode
    if [[ ! -t 1 ]] || [[ "$_UI_QUIET" == "true" ]]; then
        return
    fi

    (
        local i=0
        local n=${#_UI_SPINNER_FRAMES[@]}
        while true; do
            printf '\r  %s %s' "${_UI_SPINNER_FRAMES[$((i % n))]}" "$msg" >&2
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
        if [[ -t 1 ]]; then
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
        printf '  \033[32m✓\033[0m %s\n' "$msg" >&2
    else
        printf '  \033[31m✗\033[0m %s\n' "$msg" >&2
        _ui_show_error "$rc"
    fi

    return "$rc"
}

# ── Status messages ──────────────────────────────────────────────────────────

# Print a success summary line
ui_done() {
    local msg="$1"
    printf '\n  \033[32m%s\033[0m\n\n' "$msg" >&2
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

# Print an error with log tail
ui_error() {
    local msg="$1"
    printf '  \033[31m✗ %s\033[0m\n' "$msg" >&2
    _ui_show_error 1
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
