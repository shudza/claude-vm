#!/usr/bin/env bash
# test_image_checksum.sh — E2E test for cloud image hash verification
#
# Downloads real cloud images and verifies checksum against upstream.
# Requires: curl, sha256sum, sha512sum
# Run: bash tests/test_image_checksum.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Test framework ──────────────────────────────────────────────────────────

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() { (( ++TESTS_PASSED )); (( ++TESTS_RUN )); echo "  PASS: $1"; }
fail() { (( ++TESTS_FAILED )); (( ++TESTS_RUN )); echo "  FAIL: $1 — $2"; }
skip() { (( ++TESTS_SKIPPED )); (( ++TESTS_RUN )); echo "  SKIP: $1"; }

# ── Prerequisites ───────────────────────────────────────────────────────────

check_prerequisites() {
    for cmd in curl sha256sum sha512sum; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "SKIP: $cmd not found"
            exit 0
        fi
    done
}

# ── Setup / Teardown ───────────────────────────────────────────────────────

TMPDIR_TEST=""

setup() {
    TMPDIR_TEST="$(mktemp -d /tmp/claude-vm-checksum-test-XXXXXX)"
    export CLAUDE_VM_DIR="$TMPDIR_TEST/data"
    mkdir -p "$CLAUDE_VM_DIR/base" "$CLAUDE_VM_DIR/snapshots" "$CLAUDE_VM_DIR/cloud-init" "$CLAUDE_VM_DIR/run" "$CLAUDE_VM_DIR/keys"
}

cleanup() {
    rm -rf "$TMPDIR_TEST" 2>/dev/null || true
}

# ── Tests ───────────────────────────────────────────────────────────────────

# Source config to get flavor registry
source "$PROJECT_DIR/lib/config.sh"

test_verify_debian() {
    echo ""
    echo "=== Debian cloud image checksum ==="

    FLAVOR="debian"
    load_config

    local img_url="${FLAVOR_IMAGE_URL[debian]}"
    local img_name="${FLAVOR_IMAGE_NAME[debian]}"
    local img_path="$CLAUDE_VM_DIR/base/$img_name"
    local checksum_url="${FLAVOR_CHECKSUM_URL[debian]}"

    # Download just the first 1MB — enough to verify the checksum machinery works
    # For a real verification, we need the full file, so download it
    echo "  Downloading $img_name ..."
    if ! curl -fSL --progress-bar -o "$img_path" --retry 2 "$img_url"; then
        skip "Debian image download failed (network issue?)"
        return
    fi

    echo "  Fetching upstream checksums..."
    local checksums
    if ! checksums=$(curl -fsSL --retry 2 "$checksum_url" 2>/dev/null); then
        skip "Could not fetch Debian checksum file"
        return
    fi

    local expected_hash
    expected_hash=$(echo "$checksums" | grep -F "$img_name" | awk '{print $1}')
    if [[ -z "$expected_hash" ]]; then
        fail "Debian checksum lookup" "image not found in SHA512SUMS"
        return
    fi

    local actual_hash
    actual_hash=$(sha512sum "$img_path" | awk '{print $1}')

    if [[ "$actual_hash" == "$expected_hash" ]]; then
        pass "Debian image SHA512 matches upstream"
    else
        fail "Debian image SHA512" "hash mismatch"
    fi

    # Test: verify_cloud_image function works
    source "$PROJECT_DIR/lib/build.sh"
    if verify_cloud_image "$img_path" 2>&1 | grep -q "Checksum verified"; then
        pass "verify_cloud_image() succeeds for Debian"
    else
        fail "verify_cloud_image() for Debian" "function did not report success"
    fi

    # Test: tampered image is rejected
    echo "tampered" >> "$img_path"
    local verify_output
    if verify_output=$(verify_cloud_image "$img_path" 2>&1); then
        fail "tampered Debian image rejected" "verify_cloud_image returned success"
    else
        if echo "$verify_output" | grep -q "Checksum mismatch"; then
            pass "tampered Debian image correctly rejected"
        else
            fail "tampered Debian image rejected" "unexpected output: $verify_output"
        fi
    fi
}

test_verify_ubuntu() {
    echo ""
    echo "=== Ubuntu cloud image checksum ==="

    FLAVOR="ubuntu"
    load_config

    local img_url="${FLAVOR_IMAGE_URL[ubuntu]}"
    local img_name="${FLAVOR_IMAGE_NAME[ubuntu]}"
    local img_path="$CLAUDE_VM_DIR/base/$img_name"
    local checksum_url="${FLAVOR_CHECKSUM_URL[ubuntu]}"

    echo "  Downloading $img_name ..."
    if ! curl -fSL --progress-bar -o "$img_path" --retry 2 "$img_url"; then
        skip "Ubuntu image download failed (network issue?)"
        return
    fi

    echo "  Fetching upstream checksums..."
    local checksums
    if ! checksums=$(curl -fsSL --retry 2 "$checksum_url" 2>/dev/null); then
        skip "Could not fetch Ubuntu checksum file"
        return
    fi

    local expected_hash
    expected_hash=$(echo "$checksums" | grep -F "$img_name" | awk '{print $1}')
    if [[ -z "$expected_hash" ]]; then
        fail "Ubuntu checksum lookup" "image not found in SHA256SUMS"
        return
    fi

    local actual_hash
    actual_hash=$(sha256sum "$img_path" | awk '{print $1}')

    if [[ "$actual_hash" == "$expected_hash" ]]; then
        pass "Ubuntu image SHA256 matches upstream"
    else
        fail "Ubuntu image SHA256" "hash mismatch"
    fi

    # Test: verify_cloud_image function works
    source "$PROJECT_DIR/lib/build.sh"
    if verify_cloud_image "$img_path" 2>&1 | grep -q "Checksum verified"; then
        pass "verify_cloud_image() succeeds for Ubuntu"
    else
        fail "verify_cloud_image() for Ubuntu" "function did not report success"
    fi

    # Test: tampered image is rejected
    echo "tampered" >> "$img_path"
    local verify_output
    if verify_output=$(verify_cloud_image "$img_path" 2>&1); then
        fail "tampered Ubuntu image rejected" "verify_cloud_image returned success"
    else
        if echo "$verify_output" | grep -q "Checksum mismatch"; then
            pass "tampered Ubuntu image correctly rejected"
        else
            fail "tampered Ubuntu image rejected" "unexpected output: $verify_output"
        fi
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    check_prerequisites
    setup
    trap cleanup EXIT INT TERM

    echo "=== Cloud image checksum verification tests ==="

    test_verify_debian
    test_verify_ubuntu

    echo ""
    echo "=== Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped, $TESTS_RUN total ==="

    (( TESTS_FAILED > 0 )) && exit 1
    exit 0
}

main "$@"
