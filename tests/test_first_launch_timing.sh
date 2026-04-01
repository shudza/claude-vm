#!/usr/bin/env bash
# Test: First launch (base image build + first snapshot) completes within 2 minutes
# AC 1 verification test
#
# This test validates:
# 1. Prerequisites are checked
# 2. Cloud image download works (or is cached)
# 3. Base image build with cloud-init provisioning
# 4. Project snapshot creation via linked QCOW2
# 5. Total time < 120 seconds (excluding initial cloud image download)
#
# Usage: ./tests/test_first_launch_timing.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }
info() { echo -e "${YELLOW}INFO${NC}: $1"; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Use a test-specific data directory to avoid interfering with real data
export CLAUDE_VM_DIR="${TMPDIR:-/tmp}/claude-vm-test-$$"
trap 'rm -rf "$CLAUDE_VM_DIR"' EXIT

source "$LIB_DIR/config.sh"
source "$LIB_DIR/build.sh"

echo "=== AC 1: First launch timing test ==="
echo "Test data dir: $CLAUDE_VM_DIR"
echo ""

# Test 1: Prerequisites check
echo "--- Test 1: Prerequisites ---"
load_config
ensure_dirs

HAS_QEMU=true
if check_build_prerequisites 2>/dev/null; then
    pass "Prerequisites check passed"
else
    info "QEMU not installed — will run unit tests only"
    HAS_QEMU=false
fi

# Test 2: Directory structure creation
echo ""
echo "--- Test 2: Directory structure ---"
[[ -d "$BASE_IMAGES_DIR" ]] || fail "BASE_IMAGES_DIR not created"
[[ -d "$SNAPSHOTS_DIR" ]] || fail "SNAPSHOTS_DIR not created"
[[ -d "$CLOUD_INIT_DIR" ]] || fail "CLOUD_INIT_DIR not created"
[[ -d "$RUN_DIR" ]] || fail "RUN_DIR not created"
pass "All directories created"

# Test 3: Cloud-init generation
echo ""
echo "--- Test 3: Cloud-init config generation ---"
source "$LIB_DIR/cloud-init.sh"

# Always test config file generation (doesn't need ISO tools)
generate_cloud_init_userdata "$CLOUD_INIT_DIR"
generate_cloud_init_metadata "$CLOUD_INIT_DIR"
generate_cloud_init_network "$CLOUD_INIT_DIR"

[[ -f "$CLOUD_INIT_DIR/user-data" ]] || fail "user-data not generated"
[[ -f "$CLOUD_INIT_DIR/meta-data" ]] || fail "meta-data not generated"
[[ -f "$CLOUD_INIT_DIR/network-config" ]] || fail "network-config not generated"
grep -q "claude" "$CLOUD_INIT_DIR/user-data" || fail "user-data missing Claude Code install"
grep -q "openssh-server" "$CLOUD_INIT_DIR/user-data" || fail "user-data missing openssh-server"
grep -q "virtiofs" "$CLOUD_INIT_DIR/user-data" || fail "user-data missing virtiofs config"
grep -q "power_state" "$CLOUD_INIT_DIR/user-data" || fail "user-data missing power_state (auto-poweroff)"
grep -q "claude-vm-ready" "$CLOUD_INIT_DIR/user-data" || fail "user-data missing ready signal"
pass "Cloud-init config files verified"

# Test ISO creation if tools available
ci_iso="$CLOUD_INIT_DIR/cloud-init.iso"
if create_cloud_init_iso "$CLOUD_INIT_DIR" "$ci_iso" 2>/dev/null; then
    [[ -f "$ci_iso" ]] || fail "Cloud-init ISO not created"
    [[ -s "$ci_iso" ]] || fail "Cloud-init ISO is empty"
    pass "Cloud-init ISO created ($(du -h "$ci_iso" | cut -f1))"
else
    info "ISO creation tools not available — skipping ISO test"
fi

# Test 4: Project hash generation
echo ""
echo "--- Test 4: Project hashing ---"
hash1=$(project_hash "/home/user/project-a")
hash2=$(project_hash "/home/user/project-b")
hash3=$(project_hash "/home/user/project-a")
[[ "$hash1" != "$hash2" ]] || fail "Different projects got same hash"
[[ "$hash1" == "$hash3" ]] || fail "Same project got different hash"
[[ ${#hash1} -eq 12 ]] || fail "Hash is not 12 characters"
pass "Project hashing is deterministic and unique"

# Test 5: Snapshot path generation
echo ""
echo "--- Test 5: Snapshot paths ---"
snap_path=$(project_snapshot_path "/home/user/my-project")
[[ "$snap_path" == "$SNAPSHOTS_DIR/"*.qcow2 ]] || fail "Snapshot path format wrong: $snap_path"
pass "Snapshot path generation correct"

if $DRY_RUN || ! $HAS_QEMU; then
    echo ""
    if $DRY_RUN; then
        info "Dry run mode — skipping actual image build"
    else
        info "QEMU not available — skipping image build tests"
    fi
    echo ""
    echo "=== Unit tests passed ==="
    exit 0
fi

# Test 6: Full build timing (requires QEMU + network + KVM)
echo ""
echo "--- Test 6: Full base image build timing ---"

# Check KVM availability
if [[ ! -r /dev/kvm ]]; then
    info "KVM not available — skipping full build test"
    info "Build would be too slow without KVM to meaningfully test timing"
    echo ""
    echo "=== Tests complete (KVM-dependent tests skipped) ==="
    exit 0
fi

# If cloud image is not cached, download it first (don't count download time)
cloud_img="$(cloud_image_path)"
if [[ ! -f "$cloud_img" ]]; then
    info "Downloading cloud image first (not counted in build time)..."
    download_cloud_image
fi

# Now time the actual build
info "Starting timed base image build..."
build_start=$(date +%s)

build_base_image

build_end=$(date +%s)
build_time=$(( build_end - build_start ))

if (( build_time <= 120 )); then
    pass "Base image built in ${build_time}s (target: <120s)"
else
    fail "Base image build took ${build_time}s (target: <120s)"
fi

# Test 7: Verify base image was created
echo ""
echo "--- Test 7: Base image verification ---"
base_img="$(base_image_path)"
[[ -f "$base_img" ]] || fail "Base image file not created"

# Check it's a valid qcow2
img_format=$(qemu-img info --output=json "$base_img" | jq -r '.format')
[[ "$img_format" == "qcow2" ]] || fail "Base image is not qcow2 format (got: $img_format)"
pass "Base image is valid qcow2"

# Test 8: Linked snapshot creation timing
echo ""
echo "--- Test 8: Linked snapshot creation ---"
snap_start=$(date +%s)

create_project_snapshot "/tmp/test-project"

snap_end=$(date +%s)
snap_time=$(( snap_end - snap_start ))

snap_path=$(project_snapshot_path "/tmp/test-project")
[[ -f "$snap_path" ]] || fail "Project snapshot not created"

# Verify it's backed by the base image
backing=$(qemu-img info --output=json "$snap_path" | jq -r '.["full-backing-filename"] // .["backing-filename"]')
[[ "$backing" == "$base_img" ]] || fail "Snapshot not backed by base image (backing: $backing)"
pass "Linked snapshot created in ${snap_time}s, backed by base image"

# Test 9: Total first-launch time
echo ""
echo "--- Test 9: Total first-launch time ---"
total_time=$(( build_time + snap_time ))
if (( total_time <= 120 )); then
    pass "Total first launch: ${total_time}s (build: ${build_time}s + snapshot: ${snap_time}s) — under 2 min target"
else
    fail "Total first launch: ${total_time}s — exceeds 2 min target"
fi

echo ""
echo "=== All AC 1 tests passed ==="
