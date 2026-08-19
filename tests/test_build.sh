#!/usr/bin/env bash
# test_build.sh — Unit tests for build.sh host-prerequisite and image checks
#
# Tests:
# 1. check_build_prerequisites reports jq when it is missing
# 2. check_build_prerequisites passes when every tool is present
# 3. _verify_provisioned_size accepts a full-size image
# 4. _verify_provisioned_size rejects an undersized image
# 5. A missing jq is reported as such, not as "suspiciously small" (issue #7)
# 6. Non-numeric qemu-img output is reported as such, not as size 0

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TEST_SCRIPT_DIR")"

source "$REPO_DIR/lib/build.sh"

set +euo pipefail

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; (( TESTS_PASSED++ )); (( TESTS_RUN++ )); }
fail() { echo "  FAIL: $1"; (( TESTS_FAILED++ )); (( TESTS_RUN++ )); }

FAKE_BIN=""

# Build a PATH containing only stub tools, so tests are independent of what
# happens to be installed on the machine running them.
# Args: tool names to stub out
setup_fake_bin() {
    FAKE_BIN="$(mktemp -d)"
    local tool
    for tool in "$@"; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/$tool"
        chmod +x "$FAKE_BIN/$tool"
    done
}

teardown_fake_bin() {
    [[ -n "$FAKE_BIN" ]] && rm -rf "$FAKE_BIN"
    FAKE_BIN=""
}

# Stub qemu-img so `info --output=json` prints a chosen payload
# Args: $1 = JSON to emit
fake_qemu_img() {
    cat > "$FAKE_BIN/qemu-img" <<EOF
#!/usr/bin/env bash
cat <<'JSON'
$1
JSON
EOF
    chmod +x "$FAKE_BIN/qemu-img"
}

# ── Test 1: jq is a declared prerequisite ────────────────────────────────────
echo "--- Test 1: check_build_prerequisites reports missing jq ---"
setup_fake_bin qemu-system-x86_64 qemu-img curl genisoimage

output="$(PATH="$FAKE_BIN" check_build_prerequisites 2>&1)"
rc=$?

if (( rc != 0 )) && [[ "$output" == *jq* ]]; then
    pass "missing jq fails the prerequisite check and is named"
else
    fail "missing jq should fail the check (rc=$rc): $output"
fi

teardown_fake_bin

# ── Test 2: complete toolchain passes ────────────────────────────────────────
echo "--- Test 2: check_build_prerequisites passes with all tools ---"
setup_fake_bin qemu-system-x86_64 qemu-img curl genisoimage jq

output="$(PATH="$FAKE_BIN" check_build_prerequisites 2>&1)"
rc=$?

if (( rc == 0 )); then
    pass "complete toolchain satisfies the prerequisite check"
else
    fail "complete toolchain should pass (rc=$rc): $output"
fi

teardown_fake_bin

# ── Test 3: full-size image is accepted ──────────────────────────────────────
echo "--- Test 3: _verify_provisioned_size accepts a 1.5GB image ---"
if ! command -v jq &>/dev/null; then
    echo "  SKIP: jq not installed"
else
    setup_fake_bin
    fake_qemu_img '{"actual-size": 1610612736}'

    output="$(PATH="$FAKE_BIN:$PATH" bash -c '
        set -o pipefail
        source "'"$REPO_DIR"'/lib/build.sh"
        _verify_provisioned_size /tmp/fake.qcow2 /tmp/serial.log' 2>&1)"
    rc=$?

    if (( rc == 0 )); then
        pass "1.5GB image passes the size check"
    else
        fail "1.5GB image should pass (rc=$rc): $output"
    fi

    teardown_fake_bin
fi

# ── Test 4: undersized image is rejected ─────────────────────────────────────
echo "--- Test 4: _verify_provisioned_size rejects a 10MB image ---"
if ! command -v jq &>/dev/null; then
    echo "  SKIP: jq not installed"
else
    setup_fake_bin
    fake_qemu_img '{"actual-size": 10485760}'

    output="$(PATH="$FAKE_BIN:$PATH" bash -c '
        set -o pipefail
        source "'"$REPO_DIR"'/lib/build.sh"
        _verify_provisioned_size /tmp/fake.qcow2 /tmp/serial.log' 2>&1)"
    rc=$?

    if (( rc != 0 )) && [[ "$output" == *"suspiciously small"* ]]; then
        pass "10MB image is rejected as suspiciously small"
    else
        fail "10MB image should be rejected (rc=$rc): $output"
    fi

    teardown_fake_bin
fi

# ── Test 5: missing jq is not misreported as a small image (issue #7) ────────
echo "--- Test 5: missing jq is reported as a read failure, not a small image ---"
setup_fake_bin
fake_qemu_img '{"actual-size": 1610612736}'

# PATH holds only the stubs — no jq anywhere.
output="$(PATH="$FAKE_BIN" bash -c '
    set -o pipefail
    source "'"$REPO_DIR"'/lib/build.sh"
    _verify_provisioned_size /tmp/fake.qcow2 /tmp/serial.log' 2>&1)"
rc=$?

if (( rc != 0 )) && [[ "$output" != *"suspiciously small"* ]]; then
    pass "missing jq does not masquerade as a suspiciously small image"
else
    fail "missing jq should not report a small image (rc=$rc): $output"
fi

teardown_fake_bin

# ── Test 6: non-numeric size is reported as such ─────────────────────────────
echo "--- Test 6: unparseable qemu-img output is reported as unexpected ---"
if ! command -v jq &>/dev/null; then
    echo "  SKIP: jq not installed"
else
    setup_fake_bin
    fake_qemu_img '{"format": "qcow2"}'   # no actual-size key -> jq prints "null"

    output="$(PATH="$FAKE_BIN:$PATH" bash -c '
        set -o pipefail
        source "'"$REPO_DIR"'/lib/build.sh"
        _verify_provisioned_size /tmp/fake.qcow2 /tmp/serial.log' 2>&1)"
    rc=$?

    if (( rc != 0 )) && [[ "$output" == *"unexpected image size"* ]]; then
        pass "missing actual-size key reports an unexpected size"
    else
        fail "missing actual-size should report unexpected size (rc=$rc): $output"
    fi

    teardown_fake_bin
fi

# ── Test 7: checksum URL lookup resolves variant flavor names ────────────────
echo "--- Test 7: verify_cloud_image finds the checksum URL for variant flavors ---"
setup_fake_bin
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

# curl is stubbed to fail: reaching "Could not fetch checksum file" proves the
# distro-keyed URL lookup resolved for a <distro>-<variant> flavor name.
output="$(PATH="$FAKE_BIN:$PATH" bash -c '
    source "'"$REPO_DIR"'/lib/build.sh"
    FLAVOR=debian-slim
    verify_cloud_image /tmp/fake.qcow2' 2>&1)"
rc=$?

if (( rc == 0 )) && [[ "$output" != *"No upstream checksum URL"* ]] \
   && [[ "$output" == *"Could not fetch checksum file"* ]]; then
    pass "variant flavor resolves its distro's checksum URL"
else
    fail "variant flavor should resolve checksum URL (rc=$rc): $output"
fi

teardown_fake_bin

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
(( TESTS_FAILED > 0 )) && exit 1 || exit 0
