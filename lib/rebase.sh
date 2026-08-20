#!/usr/bin/env bash
# rebase.sh — Rebuild the base image and migrate per-VM state
#
# For each project snapshot: boot the VM headlessly (no virtiofs), rsync a
# narrow set of persistent paths out to ~/.claude-vm/backups/<hash>/, then
# destroy snapshots + base image and rebuild from the latest cloud image.
# On the next launch of each project, a fresh snapshot is created and the
# backup directory is rsynced back in.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/ui.sh"
source "$SCRIPT_DIR/shutdown.sh"
source "$SCRIPT_DIR/launch.sh"

# Guest paths copied during extraction and pushed back on restore.
# Trailing slash = directory, no slash = file.
_REBASE_GUEST_PATHS=(
    ".claude/"
    ".claude.json"
    ".gitconfig"
    ".config/gh/"
    ".config/glab-cli/"
)

# Runtime state under ~/.claude/ that must not be carried into a fresh VM:
# daemon locks/worker rosters with OS-reused PIDs break background agents,
# and caches/session scratch are worthless after a rebase. An exclude list
# (not an include list) so new upstream dirs are preserved by default.
# Kept: projects/ (transcripts), plans/, history.jsonl, all config.
_REBASE_CLAUDE_EXCLUDES=(
    "daemon/"
    "jobs/"
    "sessions/"
    "session-env/"
    "shell-snapshots/"
    "paste-cache/"
    "tasks/"
    "telemetry/"
    "cache/"
    "downloads/"
    "backups/"
    "file-history/"
    ".last-cleanup"
    ".last-update-result.json"
    "gh-pr-status-cache.json"
)

# Emit rsync --exclude args for a builtin guest path (only .claude/ has any).
# Args: $1 = entry from _REBASE_GUEST_PATHS
_rebase_excludes_for() {
    local path="$1" ex
    [[ "$path" == ".claude/" ]] || return 0
    for ex in "${_REBASE_CLAUDE_EXCLUDES[@]}"; do
        echo "--exclude=/$ex"
    done
}

# ── Concurrency lock ────────────────────────────────────────────────────────

# Acquire an exclusive lock so two rebase runs (or rebase + launch) can't
# corrupt each other's state. Held for the duration of cmd_rebase.
_rebase_lock_fd=""
_rebase_acquire_lock() {
    local lockfile="$CLAUDE_VM_DIR/rebase.lock"
    exec {_rebase_lock_fd}>"$lockfile"
    if ! flock -n "$_rebase_lock_fd"; then
        ui_warn "Another claude-vm process is running — abort rebase"
        return 1
    fi
}
_rebase_release_lock() {
    if [[ -n "${_rebase_lock_fd:-}" ]]; then
        flock -u "$_rebase_lock_fd" 2>/dev/null || true
        exec {_rebase_lock_fd}>&- 2>/dev/null || true
        _rebase_lock_fd=""
    fi
}

# ── Helpers ─────────────────────────────────────────────────────────────────

# Backup directory presence is the "pending restore" marker.
_has_pending_restore() {
    [[ -d "$(project_backup_dir "${1:-$PWD}")" ]]
}

# Echo project directory paths (one per line) for every snapshot that has a
# sidecar. Orphan snapshots (no sidecar) are skipped.
_list_projects_with_snapshots() {
    [[ -d "$SNAPSHOTS_DIR" ]] || return 0
    local snap hash sidecar
    for snap in "$SNAPSHOTS_DIR"/*.qcow2; do
        [[ -f "$snap" ]] || continue
        hash="$(basename "$snap" .qcow2)"
        sidecar="$SNAPSHOTS_DIR/${hash}.project"
        [[ -f "$sidecar" ]] || continue
        cat "$sidecar"
    done
}

# Run a command (typically rsync) and tolerate "nothing to transfer" exit
# codes that don't indicate a real failure:
#   rc=11 — error in file IO. Broader than 23/24, but tolerated because rsync
#           inside a freshly-booted Debian guest occasionally reports rc=11
#           when stat'ing files that exist but aren't yet fully visible
#           through the filesystem at the moment rsync polls them. This is a
#           transient that's safe to ignore during best-effort state
#           extraction where we'd rather skip a file than abort the rebase.
#   rc=23 — partial transfer (some sources missing)
#   rc=24 — source files vanished during the transfer
# Args: $1 = log file (stderr appended), $2... = command to run
# Returns: 0 on tolerated rc, 1 otherwise.
_safe_rsync() {
    local log_file="$1"; shift
    local rc=0
    "$@" 2>>"$log_file" || rc=$?
    (( rc == 0 || rc == 11 || rc == 23 || rc == 24 ))
}

# Echo normalized REBASE_BACKUP_PATHS entries, one per line.
# Normalization: split on commas, strip whitespace and trailing slashes,
# strip a leading ~/ (home-relative entries stay relative, absolute keep /).
_rebase_user_paths() {
    local IFS=','
    local entries entry
    read -ra entries <<< "${REBASE_BACKUP_PATHS:-}"
    for entry in "${entries[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -z "$entry" ]] && continue
        entry="${entry#\~/}"
        entry="${entry%/}"
        [[ -z "$entry" ]] && continue
        echo "$entry"
    done
}

# Map a normalized user path to its location inside the backup dir.
# Absolute paths go under the reserved _abs/ subtree so they can't collide
# with home-relative entries.
_backup_rel_path() {
    local upath="$1"
    if [[ "$upath" == /* ]]; then
        echo "_abs${upath}"
    else
        echo "$upath"
    fi
}

# Human-readable list of everything rebase preserves (builtins + user paths).
_rebase_preserved_desc() {
    local desc="" path upath
    for path in "${_REBASE_GUEST_PATHS[@]}"; do
        desc+="${desc:+, }~/$path"
    done
    while IFS= read -r upath; do
        if [[ "$upath" == /* ]]; then
            desc+="${desc:+, }$upath"
        else
            desc+="${desc:+, }~/$upath"
        fi
    done < <(_rebase_user_paths)
    desc+=" (excluding ~/.claude/ runtime state: daemon, jobs, sessions, caches)"
    echo "$desc"
}

# ── Extraction QEMU args ────────────────────────────────────────────────────

# Minimal QEMU arg set for extraction VMs — no virtiofs (workspace.mount uses
# nofail, so the guest boots cleanly without the device), no memfd/NUMA, no
# monitor/QMP (extraction shutdown is just SIGKILL since the snapshot is
# about to be deleted). 2G is enough to boot far enough for sshd + rsync.
# Args: $1=snap_path $2=run_dir $3=accel $4=ssh_port
# Sets: _qemu_args
_extraction_qemu_args() {
    local snap_path="$1"
    local run_dir="$2"
    local accel="$3"
    local ssh_port="$4"

    _qemu_args=(
        -name "claude-vm-extract-$(basename "$snap_path" .qcow2)"
        -machine "type=q35,accel=$accel"
        -cpu host
        -smp "$VM_CPUS"
        -m 2G
        -drive "file=$snap_path,format=qcow2,if=virtio,cache=writeback,discard=unmap,detect-zeroes=unmap"
        -netdev "user,id=net0,hostfwd=tcp::${ssh_port}-:22"
        -device "virtio-net-pci,netdev=net0"
        -display none
        -serial "file:$run_dir/serial.log"
        -pidfile "$run_dir/qemu.pid"
        -daemonize
    )
}

# ── Fast shutdown (no savevm, no ACPI) ──────────────────────────────────────

# SIGTERM → brief wait → SIGKILL. The snapshot is about to be destroyed, so
# there's no point asking the guest to flush cleanly: just kill the process.
# Args: $1 = run directory
_fast_shutdown() {
    local run_dir="$1"
    local pid_file="$run_dir/qemu.pid"

    [[ -f "$pid_file" ]] || return 0
    local qemu_pid
    qemu_pid=$(cat "$pid_file" 2>/dev/null) || return 0

    kill "$qemu_pid" 2>/dev/null || true
    local waited=0
    while kill -0 "$qemu_pid" 2>/dev/null && (( waited < 2 )); do
        sleep 1
        (( waited++ )) || true
    done
    if kill -0 "$qemu_pid" 2>/dev/null; then
        kill -9 "$qemu_pid" 2>/dev/null || true
    fi
}

# ── Extract / restore ───────────────────────────────────────────────────────

# Boot the VM headless, rsync state out, fast shutdown.
# On any failure: warn, drop the partial backup, return 1.
# Args: $1 = project directory
_extract_one_vm() {
    local project_dir="$1"
    local snap_path run_dir backup_dir ssh_port accel ssh_key log_file

    snap_path="$(project_snapshot_path "$project_dir")"
    run_dir="$(project_run_dir "$project_dir")"
    backup_dir="$(project_backup_dir "$project_dir")"
    ssh_key="$(_ssh_key_path)"
    log_file="$run_dir/rebase-extract.log"

    mkdir -p "$run_dir" "$backup_dir"
    # Clean stale runtime artifacts from a prior crashed launch/extraction
    rm -f "$run_dir/monitor.sock" "$run_dir/qemu.pid"

    ssh_port="$(find_available_port "$SSH_PORT_BASE")"
    echo "$ssh_port" > "$run_dir/ssh_port"
    accel="$(_detect_accel)"

    _extraction_qemu_args "$snap_path" "$run_dir" "$accel" "$ssh_port"

    if ! qemu-system-x86_64 "${_qemu_args[@]}" 2>>"$log_file"; then
        ui_warn "Could not start VM for extraction: $project_dir"
        _fast_shutdown "$run_dir"
        _cleanup_runtime "$run_dir"
        rm -rf "$backup_dir"
        return 1
    fi

    if ! wait_for_ssh "$ssh_port" 90 "$ssh_key" >>"$log_file" 2>&1; then
        ui_warn "SSH did not become available for extraction: $project_dir"
        _fast_shutdown "$run_dir"
        _cleanup_runtime "$run_dir"
        rm -rf "$backup_dir"
        return 1
    fi

    _build_ssh_cmd "$ssh_port"
    _build_rsync_cmd "$ssh_port"

    local rsync_fail=0 path dest
    for path in "${_REBASE_GUEST_PATHS[@]}"; do
        # Probe existence so a missing source doesn't even hit rsync
        if ! "${_ssh_cmd[@]}" "test -e ~/${path%/}" 2>/dev/null; then
            continue
        fi
        dest="$backup_dir/$path"
        if [[ "$path" == */ ]]; then
            mkdir -p "$dest"
        else
            mkdir -p "$(dirname "$dest")"
        fi
        local -a excludes=()
        mapfile -t excludes < <(_rebase_excludes_for "$path")
        _safe_rsync "$log_file" "${_rsync_cmd[@]}" "${excludes[@]}" \
            "$VM_USER@localhost:~/$path" "$dest" \
            || (( ++rsync_fail ))
    done

    # User-configured paths (REBASE_BACKUP_PATHS): synced as root with
    # perms/ownership preserved. Successfully extracted paths are recorded
    # in a manifest so restore doesn't depend on the live config value.
    _build_rsync_sudo_cmd "$ssh_port"
    local upath guest_path
    while IFS= read -r upath; do
        if [[ "$upath" == /* ]]; then
            guest_path="$upath"
        else
            guest_path="~/$upath"
        fi
        # sudo probe — root-only paths are invisible to a plain test
        if ! "${_ssh_cmd[@]}" "sudo test -e $guest_path" 2>/dev/null; then
            continue
        fi
        dest="$backup_dir/$(_backup_rel_path "$upath")"
        if "${_ssh_cmd[@]}" "sudo test -d $guest_path" 2>/dev/null; then
            mkdir -p "$dest"
            if ! _safe_rsync "$log_file" "${_rsync_sudo_cmd[@]}" \
                "$VM_USER@localhost:$guest_path/" "$dest/"; then
                (( ++rsync_fail ))
                continue
            fi
        else
            mkdir -p "$(dirname "$dest")"
            if ! _safe_rsync "$log_file" "${_rsync_sudo_cmd[@]}" \
                "$VM_USER@localhost:$guest_path" "$dest"; then
                (( ++rsync_fail ))
                continue
            fi
        fi
        echo "$upath" >> "$backup_dir/.rebase-paths"
    done < <(_rebase_user_paths)

    _fast_shutdown "$run_dir"
    _cleanup_runtime "$run_dir"

    # Backup with no actual payload (empty dirs and the manifest don't count)
    # → no-op restore later; drop it.
    if [[ -d "$backup_dir" ]] && \
       [[ -z "$(find "$backup_dir" ! -type d ! -name .rebase-paths -print -quit 2>/dev/null)" ]]; then
        rm -rf "$backup_dir"
    fi

    if (( rsync_fail > 0 )); then
        ui_warn "rsync failed on $rsync_fail item(s) for $project_dir (check $log_file)"
        return 1
    fi
    return 0
}

# Rsync backup data into a freshly booted VM. Runs after the host→guest sync
# in launch.sh so VM-side state (refreshed credentials) wins. Backup is
# removed on success (partial restore still clears the backup; the warning +
# log is the user's record).
# Args: $1 = project directory, $2 = ssh port
_restore_one_vm() {
    local project_dir="$1"
    local ssh_port="$2"
    local backup_dir restore_log
    backup_dir="$(project_backup_dir "$project_dir")"

    [[ -d "$backup_dir" ]] || return 0

    restore_log="$(project_run_dir "$project_dir")/restore.log"
    mkdir -p "$(project_run_dir "$project_dir")"
    : > "$restore_log"

    _build_ssh_cmd "$ssh_port"
    _build_rsync_cmd "$ssh_port"

    local path src
    for path in "${_REBASE_GUEST_PATHS[@]}"; do
        src="$backup_dir/$path"
        if [[ "$path" == */ ]]; then
            [[ -d "${src%/}" ]] || continue
            "${_ssh_cmd[@]}" "mkdir -p ~/${path%/}" 2>>"$restore_log" || true
            if ! _safe_rsync "$restore_log" "${_rsync_cmd[@]}" "$src" "$VM_USER@localhost:~/$path"; then
                ui_warn "restore: failed to sync $path (see $restore_log)"
            fi
        else
            [[ -f "$src" ]] || continue
            if ! _safe_rsync "$restore_log" "${_rsync_cmd[@]}" "$src" "$VM_USER@localhost:~/$path"; then
                ui_warn "restore: failed to sync $path (see $restore_log)"
            fi
        fi
    done

    # Migration: VMs from before CLAUDE_CONFIG_DIR was exported kept the live
    # global config at ~/.claude.json. Claude Code now reads it from
    # ~/.claude/.claude.json, so seed that path from the legacy file when the
    # backup doesn't already carry one (never clobber a config-dir copy).
    if [[ -f "$backup_dir/.claude.json" && ! -f "$backup_dir/.claude/.claude.json" ]]; then
        if ! _safe_rsync "$restore_log" "${_rsync_cmd[@]}" \
            "$backup_dir/.claude.json" "$VM_USER@localhost:~/.claude/.claude.json"; then
            ui_warn "restore: failed to migrate .claude.json to ~/.claude/ (see $restore_log)"
        fi
    fi

    # User-configured paths recorded at extraction time. Pushed as root with
    # perms/ownership preserved, as an overlay (no --delete) so files the
    # fresh image ships that aren't in the backup survive.
    if [[ -f "$backup_dir/.rebase-paths" ]]; then
        _build_rsync_sudo_cmd "$ssh_port"
        local upath guest_path
        while IFS= read -r upath; do
            [[ -z "$upath" ]] && continue
            if [[ "$upath" == /* ]]; then
                guest_path="$upath"
            else
                guest_path="~/$upath"
            fi
            src="$backup_dir/$(_backup_rel_path "$upath")"
            if [[ -d "$src" ]]; then
                "${_ssh_cmd[@]}" "sudo mkdir -p $guest_path" 2>>"$restore_log" || true
                if ! _safe_rsync "$restore_log" "${_rsync_sudo_cmd[@]}" "$src/" "$VM_USER@localhost:$guest_path/"; then
                    ui_warn "restore: failed to sync $upath (see $restore_log)"
                fi
            elif [[ -f "$src" ]]; then
                "${_ssh_cmd[@]}" "sudo mkdir -p $(dirname "$guest_path")" 2>>"$restore_log" || true
                if ! _safe_rsync "$restore_log" "${_rsync_sudo_cmd[@]}" "$src" "$VM_USER@localhost:$guest_path"; then
                    ui_warn "restore: failed to sync $upath (see $restore_log)"
                fi
            fi
        done < "$backup_dir/.rebase-paths"
    fi

    rm -rf "$backup_dir"
}

# ── Top-level command ───────────────────────────────────────────────────────

cmd_rebase() {
    local force=false yes_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            --yes|-y)   yes_flag=true; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: claude-vm rebase [--yes] [--force]

Rebuild the base image from the latest cloud image while preserving each
project VM's persistent state (~/.claude/, ~/.claude.json, ~/.gitconfig,
~/.config/gh/), plus any extra guest paths configured via:

  claude-vm config set REBASE_BACKUP_PATHS "/etc/ssh,~/.ssh"

Extra paths are synced with sudo rsync and keep permissions/ownership.
All other guest-side changes are discarded.

Options:
  --yes, -y    Skip the confirmation prompt
  --force, -f  Discard snapshots whose state cannot be extracted (data loss)
EOF
                return 0
                ;;
            *)
                ui_warn "Unknown option: $1"
                ui_info "Usage: claude-vm rebase [--force] [--yes]"
                return 1
                ;;
        esac
    done

    load_config
    ensure_dirs

    local _base_probe _have_base=false
    for _base_probe in "$BASE_IMAGES_DIR"/base*.qcow2; do
        [[ -f "$_base_probe" ]] && { _have_base=true; break; }
    done
    if [[ "$_have_base" != true ]]; then
        ui_warn "No base image found. Build one first: claude-vm build"
        return 1
    fi

    local projects=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && projects+=("$line")
    done < <(_list_projects_with_snapshots)

    if (( ${#projects[@]} == 0 )); then
        ui_info "No project snapshots found. Nothing to rebase."
        return 0
    fi

    ui_info ""
    ui_info "This will:"
    ui_info "  1. Extract per-VM state from ${#projects[@]} project(s)"
    ui_info "  2. Remove all snapshots and base images"
    ui_info "  3. Rebuild the $FLAVOR base image from the latest cloud image"
    ui_info "     (other flavors' bases are dropped and rebuilt on demand at launch)"
    ui_info "  4. Restore extracted state on next launch"
    ui_info ""
    ui_info "VM-side state preserved: $(_rebase_preserved_desc)"
    ui_info "Everything else in each VM will be lost."
    ui_info ""
    local proj
    for proj in "${projects[@]}"; do
        ui_info "  $proj"
    done
    ui_info ""

    if ! $yes_flag; then
        read -rp "Continue? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
            ui_info "Cancelled."
            return 0
        fi
    fi

    # Stop any running VMs first so they release their shared lock fds.
    # NOTE: there is a small race — another process can call `claude-vm launch`
    # between here and _rebase_acquire_lock below; that case is caught by the
    # acquire-lock failure path which warns and aborts.
    ui_init "$RUN_DIR/rebase.log"
    if [[ -d "$RUN_DIR" ]]; then
        local running_dirs=()
        local run_subdir pid_file pid failed_dir
        for run_subdir in "$RUN_DIR"/*/; do
            [[ -d "$run_subdir" ]] || continue
            pid_file="${run_subdir}qemu.pid"
            [[ -f "$pid_file" ]] || continue
            pid=$(cat "$pid_file" 2>/dev/null) || continue
            kill -0 "$pid" 2>/dev/null && running_dirs+=("$run_subdir")
        done
        if (( ${#running_dirs[@]} > 0 )); then
            [[ "$_UI_RICH" == "true" ]] || ui_info "Stopping ${#running_dirs[@]} running VM(s)..."
            if ! stop_vms_parallel "${running_dirs[@]}"; then
                for failed_dir in "${FAILED_RUN_DIRS[@]}"; do
                    ui_warn "Failed to stop VM $(basename "${failed_dir%/}") — see ${failed_dir%/}/stop.log"
                done
            fi
        fi
    fi

    if ! _rebase_acquire_lock; then
        return 1
    fi
    # Chain spinner cleanup that ui_init would otherwise own.
    trap '_rebase_release_lock; _ui_stop_spinner 2>/dev/null || true' EXIT INT TERM

    # ── Extraction phase ───────────────────────────────────────────────────
    local extracted=0 failed=0
    local failed_projects=()

    ui_info ""
    ui_info "Extraction phase — reading state from ${#projects[@]} project(s)..."

    for proj in "${projects[@]}"; do
        local run_dir
        run_dir="$(project_run_dir "$proj")"
        mkdir -p "$run_dir"
        ui_init "$run_dir/rebase-extract.log"

        if ui_phase "Extracting $(basename "$proj")" _extract_one_vm "$proj"; then
            (( ++extracted )) || true
        else
            (( ++failed )) || true
            failed_projects+=("$proj")
            $force && ui_warn "Extraction failed for $proj — dropping snapshot (--force)"
        fi
    done

    ui_info ""
    ui_info "Extracted: $extracted, Failed: $failed"

    if (( failed > 0 )) && ! $force; then
        ui_warn ""
        ui_warn "Extraction failed for ${#failed_projects[@]} project(s):"
        local fp
        for fp in "${failed_projects[@]}"; do
            ui_warn "  $fp"
        done
        ui_warn "Aborting — snapshots are intact."
        # Drop partial backups so a re-run starts fresh
        for proj in "${projects[@]}"; do
            rm -rf "$(project_backup_dir "$proj")"
        done
        ui_warn "Cleaned up partial backups. Fix the issue or use --force to drop broken VMs."
        return 1
    fi

    # ── Destruction + rebuild phase ────────────────────────────────────────
    # Build order: delete cached cloud image → build new base (the old base
    # is preserved on failure because build_base_image writes build-temp.qcow2
    # and only mv's it into place on success) → delete old snapshots only
    # after a successful build (they're unbootable against the new base).
    #
    # Only the configured FLAVOR's base is rebuilt. Snapshots are always
    # recreated from the current FLAVOR on next launch, so bases of other
    # flavors can never be used by a restored project — they are deleted
    # after the build succeeds and rebuilt on demand by a future launch that
    # selects that flavor. Legacy pre-flavor base.qcow2 is removed the same
    # way — rebase is the migration path off it.
    ui_info ""
    ui_info "Rebuilding base image ($FLAVOR)..."
    rm -f "$(cloud_image_path)"
    if ! build_base_image; then
        ui_warn ""
        ui_warn "Base image rebuild failed for '$FLAVOR'. Old snapshots are intact."
        ui_warn "Backups are intact in $BACKUPS_DIR/"
        ui_warn "Run 'claude-vm build' manually, then relaunch to trigger restore."
        return 1
    fi

    local base_file fname
    for base_file in "$BASE_IMAGES_DIR"/base*.qcow2; do
        [[ -f "$base_file" ]] || continue
        fname="$(basename "$base_file")"
        [[ "$fname" == "base-${FLAVOR}.qcow2" ]] && continue
        if [[ "$fname" == "base.qcow2" ]] || \
           { [[ "$fname" =~ ^base-(.+)\.qcow2$ ]] && is_valid_flavor "${BASH_REMATCH[1]}"; }; then
            rm -f "$base_file"
        fi
    done

    ui_info "Removing old snapshots..."
    if [[ -d "$SNAPSHOTS_DIR" ]]; then
        local f hash
        # qcow2 + ports are always wiped: snapshots are unbootable against
        # the new base, ports are transient.
        for f in "$SNAPSHOTS_DIR"/*.qcow2 "$SNAPSHOTS_DIR"/*.ports; do
            [[ -f "$f" ]] && rm -f "$f"
        done
        # .project sidecar survives only if the project has a backup waiting
        # — that's what lets `claude-vm list` surface the pending restore
        # before the user relaunches. Orphans (no backup) are swept.
        for f in "$SNAPSHOTS_DIR"/*.project; do
            [[ -f "$f" ]] || continue
            hash="${f##*/}"
            hash="${hash%.project}"
            [[ -d "$BACKUPS_DIR/$hash" ]] || rm -f "$f"
        done
    fi

    # ── Summary ────────────────────────────────────────────────────────────
    ui_info ""
    ui_done "Rebase complete"

    if (( extracted > 0 )); then
        ui_info "Projects with pending restore (next launch will restore state):"
        for proj in "${projects[@]}"; do
            if [[ -d "$(project_backup_dir "$proj")" ]]; then
                ui_info "  $proj"
            fi
        done
    fi
    if (( failed > 0 )); then
        ui_info ""
        ui_info "Projects with broken VMs (dropped via --force):"
        for fp in "${failed_projects[@]}"; do
            ui_info "  $fp"
        done
    fi
    ui_info ""
    ui_info "Base images:"
    for base_file in "$BASE_IMAGES_DIR"/base-*.qcow2; do
        [[ -f "$base_file" ]] || continue
        ui_info "  $base_file ($(du -h "$base_file" | cut -f1))"
    done
}
