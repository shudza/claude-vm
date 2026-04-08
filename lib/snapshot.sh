#!/usr/bin/env bash
# snapshot.sh — Per-project QCOW2 linked snapshot management
#
# Each project directory gets its own QCOW2 snapshot backed by a shared base
# image. Snapshots use copy-on-write (COW), so only the delta from the base
# image consumes disk space.
#
# Backing chain: base.qcow2 ← <project-hash>.qcow2
#
# Functions:
#   create_project_snapshot  — Create a linked snapshot for a project
#   verify_snapshot          — Verify snapshot integrity and backing chain
#   delete_snapshot          — Remove a project snapshot

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Create a QCOW2 linked snapshot for a project directory
# The snapshot is backed by the shared base image (copy-on-write).
# Args: $1 = project directory (defaults to $PWD)
# Returns: 0 on success, 1 on error
create_project_snapshot() {
    local project_dir="${1:-$PWD}"
    local snap_path base_img

    load_config
    ensure_dirs

    base_img="$(base_image_path)"
    snap_path="$(project_snapshot_path "$project_dir")"

    if [[ ! -f "$base_img" ]]; then
        echo "ERROR: Base image not found at $base_img" >&2
        echo "Run 'claude-vm build' first." >&2
        return 1
    fi

    if [[ -f "$snap_path" ]]; then
        echo "  Snapshot already exists: $snap_path"
        return 0
    fi

    # Verify base image is healthy before creating a snapshot
    if ! qemu-img check "$base_img" &>/dev/null; then
        echo "ERROR: Base image is corrupt or unreadable: $base_img" >&2
        echo "Run 'claude-vm build --force' to rebuild." >&2
        return 1
    fi

    local hash
    hash="$(project_hash "$project_dir")"

    echo "  Creating linked snapshot for project..."
    echo "  Project: $project_dir"
    echo "  Hash: $hash"
    echo "  Base: $base_img"
    echo "  Snapshot: $snap_path"

    # Create QCOW2 image backed by the base image (copy-on-write)
    # -b sets the backing file, -F specifies the backing file format
    if ! qemu-img create -f qcow2 -b "$base_img" -F qcow2 "$snap_path"; then
        echo "ERROR: Failed to create linked snapshot" >&2
        rm -f "$snap_path"
        return 1
    fi

    # Store project directory path as sidecar metadata (for cmd_list)
    echo "$project_dir" > "$SNAPSHOTS_DIR/${hash}.project"

    echo "  Snapshot created ($(du -h "$snap_path" | cut -f1) initial — grows on write)"
    return 0
}

# Verify a project snapshot's integrity and backing chain
# Checks: file exists, qcow2 format valid, backing file resolves to base image
# Args: $1 = project directory (defaults to $PWD)
# Returns: 0 if valid, 1 if invalid
verify_snapshot() {
    local project_dir="${1:-$PWD}"
    local snap_path base_img

    load_config

    snap_path="$(project_snapshot_path "$project_dir")"
    base_img="$(base_image_path)"

    if [[ ! -f "$snap_path" ]]; then
        echo "ERROR: Snapshot not found: $snap_path" >&2
        return 1
    fi

    # Check qcow2 integrity
    if ! qemu-img check "$snap_path" &>/dev/null; then
        echo "ERROR: Snapshot is corrupt: $snap_path" >&2
        return 1
    fi

    # Verify backing file points to the expected base image
    local actual_backing
    actual_backing="$(qemu-img info --output=json "$snap_path" | \
        jq -r '.["backing-filename"] // empty' 2>/dev/null || true)"

    if [[ -z "$actual_backing" ]]; then
        echo "ERROR: Snapshot has no backing file (not a linked snapshot): $snap_path" >&2
        return 1
    fi

    # Resolve to absolute paths for comparison
    local resolved_backing resolved_base
    resolved_backing="$(realpath -m "$actual_backing" 2>/dev/null || echo "$actual_backing")"
    resolved_base="$(realpath -m "$base_img" 2>/dev/null || echo "$base_img")"

    if [[ "$resolved_backing" != "$resolved_base" ]]; then
        echo "WARNING: Snapshot backing file mismatch" >&2
        echo "  Expected: $resolved_base" >&2
        echo "  Actual: $resolved_backing" >&2
        return 1
    fi

    # Verify the backing file itself exists
    if [[ ! -f "$resolved_base" ]]; then
        echo "ERROR: Backing file (base image) is missing: $resolved_base" >&2
        echo "This snapshot is orphaned. Reset with 'claude-vm reset'." >&2
        return 1
    fi

    echo "  Snapshot verified: $snap_path"
    echo "  Backing: $resolved_base"
    return 0
}

# Delete a project's snapshot
# Args: $1 = project directory (defaults to $PWD)
delete_snapshot() {
    local project_dir="${1:-$PWD}"
    local snap_path

    load_config

    snap_path="$(project_snapshot_path "$project_dir")"

    if [[ ! -f "$snap_path" ]]; then
        echo "No snapshot for project: $project_dir"
        return 0
    fi

    local hash
    hash="$(project_hash "$project_dir")"
    rm -f "$snap_path" "$SNAPSHOTS_DIR/${hash}.project" "$SNAPSHOTS_DIR/${hash}.ports"
    echo "Snapshot deleted: $snap_path"
}

