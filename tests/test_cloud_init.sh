#!/usr/bin/env bash
# Tests for lib/cloud-init.sh — userdata generation across all flavors
# Run: bash tests/test_cloud_init.sh
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

ALL_FLAVORS=(debian-slim debian-full ubuntu-slim ubuntu-full
             archlinux-slim archlinux-full fedora-slim fedora-full)

# Generate userdata for a flavor in a fresh shell (so set -e applies and an
# unknown flavor aborts generation instead of emitting empty blocks).
# Usage: _generate FLAVOR OUTPUT_DIR
_generate() {
    local flavor="$1" out="$2"
    mkdir -p "$out"
    CLAUDE_VM_DIR="$TEST_DIR/vmdir" VM_USER="tester" FLAVOR="$flavor" bash -c "
        source '$PROJECT_DIR/lib/config.sh'
        source '$PROJECT_DIR/lib/cloud-init.sh'
        generate_cloud_init_userdata '$out'
    "
}

# Path of the generated user-data for a flavor
_userdata() { echo "$TEST_DIR/gen-$1/user-data"; }

# Package line present in the packages: list
_has_pkg() { grep -qE "^  - $2\$" "$(_userdata "$1")"; }

# ─── User cloud-init overlay helpers ─────────────────────────────────────────

OVERLAY_FILE="$TEST_DIR/vmdir/cloud-init.yaml"

# Generate userdata with an overlay in place.
# Usage: _generate_with_overlay FLAVOR OUTPUT_DIR OVERLAY_TEXT
_generate_with_overlay() {
    local flavor="$1" out="$2" overlay="$3"
    mkdir -p "$TEST_DIR/vmdir"
    printf '%s' "$overlay" > "$OVERLAY_FILE"
    _generate "$flavor" "$out"
}

_clear_overlay() { rm -f "$OVERLAY_FILE"; }
# Header lines of MIME part N of a generated user-data file
_part_headers() {
    local file="$1" n="$2"
    awk -v want="$n" '
        /^--claude-vm-boundary--$/ { inpart=0; next }
        /^--claude-vm-boundary$/ { count++; hdr=1; inpart=(count==want); next }
        inpart && hdr { if ($0 == "") { hdr=0; exit } print }
        inpart && !hdr { exit }
        inpart { print }
    ' "$file"
}

# Decoded body of MIME part N of a generated user-data file
_part_body() {
    local file="$1" n="$2"
    awk -v want="$n" '
        /^--claude-vm-boundary--$/ { inpart=0; next }
        /^--claude-vm-boundary$/ { count++; hdr=1; inpart=(count==want); next }
        inpart && hdr { if ($0 == "") hdr=0; next }
        inpart { print }
    ' "$file" | base64 -d
}

# Generation with an overlay must not leak into the shared flavor fixtures:
# each overlay case gets its own output directory.
OVERLAY_MERGE_TYPE="list(append)+dict(no_replace,recurse_list)+str()"

# Generate everything once up front. The flavor fixtures and the plain
# (no-overlay) baseline are generated with no overlay in place.
for _flavor in "${ALL_FLAVORS[@]}" debian; do
    if ! _generate "$_flavor" "$TEST_DIR/gen-$_flavor"; then
        echo "FATAL: userdata generation failed for flavor $_flavor" >&2
        exit 1
    fi
done
if ! _generate debian-slim "$TEST_DIR/gen-plain"; then
    echo "FATAL: plain userdata generation failed" >&2
    exit 1
fi

# ─── Tests ────────────────────────────────────────────────────────────────────

test_structure_all_flavors() {
    local flavor ud ok
    for flavor in "${ALL_FLAVORS[@]}"; do
        ud="$(_userdata "$flavor")"
        ok=true
        head -1 "$ud" | grep -q '^#cloud-config$' || { fail "$flavor structure" "missing #cloud-config header"; ok=false; }
        grep -q 'claude-vm-ready' "$ud"           || { fail "$flavor structure" "missing claude-vm-ready marker"; ok=false; }
        grep -q '^power_state:' "$ud"             || { fail "$flavor structure" "missing power_state:"; ok=false; }
        grep -q '^packages:' "$ud"                || { fail "$flavor structure" "missing packages: block"; ok=false; }
        $ok && pass "$flavor: header, ready marker, power_state, packages present"
    done
}

test_node_and_gh_from_distro_repos() {
    local flavor gh_pkg ok
    for flavor in "${ALL_FLAVORS[@]}"; do
        case "$flavor" in
            archlinux-*) gh_pkg="github-cli" ;;
            *)           gh_pkg="gh" ;;
        esac
        ok=true
        _has_pkg "$flavor" "nodejs"   || { fail "$flavor node" "nodejs not in packages"; ok=false; }
        _has_pkg "$flavor" "npm"      || { fail "$flavor node" "npm not in packages"; ok=false; }
        _has_pkg "$flavor" "$gh_pkg"  || { fail "$flavor gh" "$gh_pkg not in packages"; ok=false; }
        $ok && pass "$flavor: nodejs, npm, $gh_pkg installed via packages:"
    done
}

test_no_external_repos() {
    local flavor ud ok
    for flavor in "${ALL_FLAVORS[@]}"; do
        ud="$(_userdata "$flavor")"
        ok=true
        grep -q 'nodesource' "$ud"      && { fail "$flavor external repos" "references nodesource"; ok=false; }
        grep -q 'setup_22\.x' "$ud"     && { fail "$flavor external repos" "references setup_22.x"; ok=false; }
        grep -q 'cli\.github\.com' "$ud" && { fail "$flavor external repos" "references cli.github.com"; ok=false; }
        $ok && pass "$flavor: no NodeSource or cli.github.com repos"
    done
}

test_ssh_service_per_distro() {
    local flavor svc ok
    for flavor in "${ALL_FLAVORS[@]}"; do
        case "$flavor" in
            debian-*|ubuntu-*) svc="ssh" ;;
            *)                 svc="sshd" ;;
        esac
        ok=true
        grep -qE "^  - systemctl enable $svc\$" "$(_userdata "$flavor")" || { fail "$flavor ssh service" "expected 'systemctl enable $svc'"; ok=false; }
        $ok && pass "$flavor: ssh service is '$svc'"
    done
}

test_pkg_tuning_per_family() {
    local flavor ud ok
    for flavor in "${ALL_FLAVORS[@]}"; do
        ud="$(_userdata "$flavor")"
        ok=true
        case "$flavor" in
            debian-*|ubuntu-*)
                grep -q '/etc/dpkg/dpkg.cfg.d/claude-vm' "$ud"      || { fail "$flavor tuning" "missing dpkg tuning file"; ok=false; }
                grep -q 'force-unsafe-io' "$ud"                     || { fail "$flavor tuning" "missing force-unsafe-io"; ok=false; }
                grep -q '/etc/apt/apt.conf.d/99claude-vm' "$ud"     || { fail "$flavor tuning" "missing apt tuning file"; ok=false; }
                grep -q 'APT::Install-Recommends "false";' "$ud"    || { fail "$flavor tuning" "missing Install-Recommends false"; ok=false; }
                ;;
            fedora-*)
                grep -q '/etc/dnf/dnf.conf' "$ud"          || { fail "$flavor tuning" "missing dnf.conf tuning"; ok=false; }
                grep -q 'install_weak_deps=False' "$ud"    || { fail "$flavor tuning" "missing install_weak_deps"; ok=false; }
                grep -q 'tsflags=nodocs' "$ud"             || { fail "$flavor tuning" "missing tsflags=nodocs"; ok=false; }
                grep -q 'APT::' "$ud"                      && { fail "$flavor tuning" "apt tuning leaked into fedora"; ok=false; }
                ;;
            archlinux-*)
                grep -q 'dpkg.cfg.d' "$ud"              && { fail "$flavor tuning" "dpkg tuning leaked into arch"; ok=false; }
                grep -q 'install_weak_deps' "$ud"       && { fail "$flavor tuning" "dnf tuning leaked into arch"; ok=false; }
                ;;
        esac
        $ok && pass "$flavor: package manager tuning correct"
    done
}

test_deb_src_disabled_before_package_stage() {
    local flavor ok
    for flavor in "${ALL_FLAVORS[@]}"; do
        ok=true
        case "$flavor" in
            debian-*|ubuntu-*)
                grep -q "Types: deb deb-src" "$(_userdata "$flavor")" || { fail "$flavor bootcmd" "missing deb-src disable"; ok=false; }
                ;;
            *)
                grep -q "Types: deb deb-src" "$(_userdata "$flavor")" && { fail "$flavor bootcmd" "deb-src sed leaked into non-apt flavor"; ok=false; }
                ;;
        esac
        $ok && pass "$flavor: deb-src bootcmd $([[ "$flavor" == debian-* || "$flavor" == ubuntu-* ]] && echo present || echo absent)"
    done
}

test_installer_prefetch() {
    local flavor ud ok
    for flavor in "${ALL_FLAVORS[@]}"; do
        ud="$(_userdata "$flavor")"
        ok=true
        grep -q '^bootcmd:' "$ud" \
            || { fail "$flavor prefetch" "missing bootcmd section"; ok=false; }
        grep -q 'exec /usr/local/sbin/claude-vm-prefetch tester' "$ud" \
            || { fail "$flavor prefetch" "launcher missing or wrong user"; ok=false; }
        grep -q '  - path: /usr/local/sbin/claude-vm-prefetch' "$ud" \
            || { fail "$flavor prefetch" "prefetch script not in write_files"; ok=false; }
        grep -q 'claude-vm-prefetch-done' "$ud" \
            || { fail "$flavor prefetch" "runcmd does not wait for done marker"; ok=false; }
        grep -q 'test -f /run/claude-vm-prefetch-ok || sudo -u tester' "$ud" \
            || { fail "$flavor prefetch" "missing inline fallback installs"; ok=false; }
        grep -qF 'i=$((i+1))' "$ud" \
            || { fail "$flavor prefetch" "launcher loop counter was interpolated away"; ok=false; }
        $ok && pass "$flavor: installer prefetch launcher, script, and fallback present"
    done
}

test_tuning_precedes_packages_stage() {
    # write_files must carry the tuning (cloud-init runs write_files before
    # packages), i.e. the tuning path appears in the write_files block
    local ud="$(_userdata debian-slim)"
    local wf_line tuning_line
    wf_line=$(grep -n '^write_files:' "$ud" | cut -d: -f1)
    tuning_line=$(grep -n '/etc/dpkg/dpkg.cfg.d/claude-vm' "$ud" | head -1 | cut -d: -f1)
    if [[ -n "$wf_line" && -n "$tuning_line" ]] && (( tuning_line == wf_line + 1 )); then
        pass "tuning files are the first write_files entries"
    else
        fail "tuning placement" "write_files at line $wf_line, tuning at line $tuning_line"
    fi
}

test_slim_excludes_full_tools() {
    local flavor build_pkg ok
    for flavor in debian-slim ubuntu-slim archlinux-slim fedora-slim; do
        case "$flavor" in
            debian-*|ubuntu-*) build_pkg="build-essential" ;;
            archlinux-*)       build_pkg="base-devel" ;;
            fedora-*)          build_pkg="gcc" ;;
        esac
        ok=true
        _has_pkg "$flavor" "tmux"       && { fail "$flavor slim" "tmux present in slim"; ok=false; }
        _has_pkg "$flavor" "$build_pkg" && { fail "$flavor slim" "$build_pkg present in slim"; ok=false; }
        _has_pkg "$flavor" "cmake"      && { fail "$flavor slim" "cmake present in slim"; ok=false; }
        _has_pkg "$flavor" "wget"       && { fail "$flavor slim" "wget present in slim"; ok=false; }
        $ok && pass "$flavor: excludes tmux, $build_pkg, cmake, wget"
    done
}

test_full_includes_build_tools() {
    local flavor build_pkg ok
    for flavor in debian-full ubuntu-full archlinux-full fedora-full; do
        case "$flavor" in
            debian-*|ubuntu-*) build_pkg="build-essential" ;;
            archlinux-*)       build_pkg="base-devel" ;;
            fedora-*)          build_pkg="gcc" ;;
        esac
        ok=true
        _has_pkg "$flavor" "tmux"       || { fail "$flavor full" "tmux missing"; ok=false; }
        _has_pkg "$flavor" "$build_pkg" || { fail "$flavor full" "$build_pkg missing"; ok=false; }
        _has_pkg "$flavor" "cmake"      || { fail "$flavor full" "cmake missing"; ok=false; }
        _has_pkg "$flavor" "strace"     || { fail "$flavor full" "strace missing"; ok=false; }
        _has_pkg "$flavor" "wget"       || { fail "$flavor full" "wget missing"; ok=false; }
        $ok && pass "$flavor: includes tmux, $build_pkg, cmake, strace, wget"
    done
}

test_glab_full_only() {
    local flavor ok=true
    for flavor in debian-full ubuntu-full archlinux-full fedora-full; do
        _has_pkg "$flavor" "glab" || { fail "$flavor full" "glab missing"; ok=false; }
    done
    for flavor in debian-slim ubuntu-slim archlinux-slim fedora-slim; do
        _has_pkg "$flavor" "glab" && { fail "$flavor slim" "glab present in slim"; ok=false; }
    done
    $ok && pass "glab in every -full packages block, absent from -slim"
}

test_slim_core_set() {
    local flavor python_pkg ok
    for flavor in "${ALL_FLAVORS[@]}"; do
        case "$flavor" in
            archlinux-*) python_pkg="python" ;;
            *)           python_pkg="python3" ;;
        esac
        ok=true
        local pkg
        for pkg in git rsync curl ca-certificates jq ripgrep less zip unzip "$python_pkg"; do
            _has_pkg "$flavor" "$pkg" || { fail "$flavor core set" "$pkg missing"; ok=false; }
        done
        $ok && pass "$flavor: core tool set present"
    done
}

test_installers_still_present() {
    local flavor ud ok
    for flavor in "${ALL_FLAVORS[@]}"; do
        ud="$(_userdata "$flavor")"
        ok=true
        grep -q 'claude.ai/install.sh' "$ud" || { fail "$flavor installers" "Claude Code installer missing"; ok=false; }
        case "$flavor" in
            *-full)
                grep -q 'astral.sh/uv/install.sh' "$ud" || { fail "$flavor installers" "uv installer missing from full"; ok=false; }
                ;;
            *)
                grep -q 'astral.sh/uv/install.sh' "$ud" && { fail "$flavor installers" "uv installer present in slim"; ok=false; }
                ;;
        esac
        $ok && pass "$flavor: Claude Code installer present, uv $([[ "$flavor" == *-full ]] && echo present || echo absent)"
    done
}

test_bare_flavor_behaves_as_full() {
    local ud="$TEST_DIR/gen-debian/user-data"
    if grep -qE '^  - build-essential$' "$ud" && grep -qE '^  - tmux$' "$ud"; then
        pass "bare FLAVOR=debian generates the full package set"
    else
        fail "bare flavor alias" "debian userdata lacks full packages"
    fi
}

test_unknown_flavor_fails() {
    if _generate "bogus-flavor" "$TEST_DIR/gen-bogus" 2>/dev/null; then
        fail "unknown flavor" "generation succeeded for bogus-flavor"
    else
        pass "unknown flavor aborts generation"
    fi
}

test_package_update_enabled() {
    local flavor ok
    for flavor in "${ALL_FLAVORS[@]}"; do
        ok=true
        grep -q '^package_update: true' "$(_userdata "$flavor")" || { fail "$flavor package_update" "not enabled"; ok=false; }
        $ok || continue
    done
    $ok && pass "package_update: true in all flavors"
}

# ─── User cloud-init overlay ─────────────────────────────────────────────────

test_no_overlay_keeps_single_document() {
    local ud="$TEST_DIR/gen-plain/user-data"
    _clear_overlay
    _generate debian-slim "$TEST_DIR/gen-plain" || { fail "plain generation" "failed"; return; }

    local ok=true
    [[ "$(head -1 "$ud")" == "#cloud-config" ]] || { fail "plain head" "expected #cloud-config, got $(head -1 "$ud")"; ok=false; }
    grep -q 'MIME-Version' "$ud" && { fail "plain user-data" "unexpected MIME wrapper"; ok=false; }
    $ok && pass "no overlay: user-data stays a plain #cloud-config document"
}

test_overlay_is_mime_multipart() {
    _generate_with_overlay debian-slim "$TEST_DIR/gen-ovl" 'packages:
  - htop
' || { fail "overlay generation" "failed"; return; }

    local ud="$TEST_DIR/gen-ovl/user-data" ok=true
    [[ "$(head -1 "$ud")" == "MIME-Version: 1.0" ]] || { fail "mime version" "first line is $(head -1 "$ud")"; ok=false; }
    grep -q 'Content-Type: multipart/mixed; boundary="claude-vm-boundary"' "$ud" \
        || { fail "multipart header" "missing multipart content type"; ok=false; }
    [[ "$(grep -c '^--claude-vm-boundary$' "$ud")" == "2" ]] \
        || { fail "parts" "expected 2 parts, got $(grep -c '^--claude-vm-boundary$' "$ud")"; ok=false; }
    grep -q '^--claude-vm-boundary--$' "$ud" || { fail "closing boundary" "missing"; ok=false; }
    $ok && pass "overlay: user-data is a two-part MIME multipart document"
}

test_overlay_part_headers_carry_merge_type() {
    local ud="$TEST_DIR/gen-ovl/user-data" hdr ok=true
    hdr="$(_part_headers "$ud" 2)"

    echo "$hdr" | grep -q '^Content-Type: text/cloud-config; charset="utf-8"$' \
        || { fail "overlay content-type" "got: $hdr"; ok=false; }
    echo "$hdr" | grep -q '^Content-Transfer-Encoding: base64$' \
        || { fail "overlay transfer encoding" "base64 missing"; ok=false; }
    # Without an explicit merge type cloud-init REPLACES list values, which
    # would wipe the baked runcmd/packages entries.
    echo "$hdr" | grep -q "^Merge-Type: ${OVERLAY_MERGE_TYPE}$" \
        || { fail "merge type" "got: $(echo "$hdr" | grep Merge-Type)"; ok=false; }
    $ok && pass "overlay part declares base64 and list-append merge type"
}

test_overlay_payload_is_verbatim() {
    local overlay=$'packages:\n  - htop\n' ud="$TEST_DIR/gen-ovl/user-data" body
    body="$(_part_body "$ud" 2)"

    # The part payload is the overlay byte-for-byte. Injecting anything (a
    # merge_how: line, a rewritten marker) risks splitting the user's document
    # into two, which yaml.safe_load rejects wholesale.
    if [[ "$body"$'\n' == "$overlay" ]]; then
        pass "overlay payload is the source file verbatim"
    else
        fail "overlay payload" "body differs from the overlay file"
    fi
}

test_baked_part_matches_plain_generation() {
    local ud="$TEST_DIR/gen-ovl/user-data"
    _part_body "$ud" 1 > "$TEST_DIR/baked-decoded"
    # The wrapper must not alter the baked config at all — the base image still
    # gets exactly the provisioning a plain build produces.
    if cmp -s "$TEST_DIR/baked-decoded" "$TEST_DIR/gen-plain/user-data"; then
        pass "baked part decodes byte-identically to a plain generation"
    else
        fail "baked part" "decoded part differs from plain generation"
    fi
}

test_overlay_unicode_round_trips() {
    # Non-ASCII is why the parts are base64: cloud-init round-trips a part's
    # bytes through latin-1 and then the declared charset, so raw UTF-8 in a
    # plain part becomes unparseable surrogates and the part is dropped.
    local overlay=$'overlay_note: "caf\xc3\xa9 \xe2\x80\x94 ok"\n'
    _generate_with_overlay debian-slim "$TEST_DIR/gen-utf8" "$overlay" \
        || { fail "utf8 overlay generation" "failed"; return; }

    local body
    body="$(_part_body "$TEST_DIR/gen-utf8/user-data" 2)"
    if [[ "$body"$'\n' == "$overlay" ]]; then
        pass "non-ASCII overlay round-trips byte-exactly"
    else
        fail "utf8 overlay" "decoded body differs"
    fi
}

test_overlay_boundary_collision_is_harmless() {
    local overlay=$'overlay_note: "--claude-vm-boundary-- decoy"\n'
    _generate_with_overlay debian-slim "$TEST_DIR/gen-decoy" "$overlay" \
        || { fail "decoy overlay generation" "failed"; return; }

    local ud="$TEST_DIR/gen-decoy/user-data" body ok=true
    body="$(_part_body "$ud" 2)"
    [[ "$body"$'\n' == "$overlay" ]] \
        || { fail "decoy content" "decoy text was mangled"; ok=false; }
    [[ "$(grep -c '^--claude-vm-boundary$' "$ud")" == "2" ]] \
        || { fail "decoy part count" "extra boundary treated as structure"; ok=false; }
    $ok && pass "overlay text resembling the boundary cannot break the wrapper"
}

test_overlay_leading_document_marker_kept() {
    # A leading "---" is one document to yaml.safe_load, so it is shipped as-is
    # rather than edited.
    local overlay=$'---\noverlay_note: present\n'
    _generate_with_overlay debian-slim "$TEST_DIR/gen-marker" "$overlay" \
        || { fail "marker overlay generation" "failed"; return; }

    local body
    body="$(_part_body "$TEST_DIR/gen-marker/user-data" 2)"
    if [[ "$body"$'\n' == "$overlay" ]]; then
        pass "leading document marker is preserved and does not abort generation"
    else
        fail "marker overlay" "body differs from the overlay file"
    fi
}

test_overlay_marker_inside_block_scalar_is_not_structure() {
    # A "---" indented inside a block scalar is data (e.g. write_files writing a
    # YAML file into the guest), not a document separator. A line-based
    # multi-document check would reject this valid overlay outright.
    local overlay=$'write_files:\n  - path: /etc/example.yaml\n    content: |\n      ---\n      key: value\n'
    local err rc=0
    err="$(_generate_with_overlay debian-slim "$TEST_DIR/gen-scalar-marker" "$overlay" 2>&1)" || rc=$?

    local ok=true
    (( rc == 0 )) || { fail "block scalar marker" "generation failed: $err"; ok=false; }
    if (( rc == 0 )); then
        local body
        body="$(_part_body "$TEST_DIR/gen-scalar-marker/user-data" 2)"
        [[ "$body"$'\n' == "$overlay" ]] \
            || { fail "block scalar content" "body differs from the overlay file"; ok=false; }
    fi
    $ok && pass "indented '---' in a block scalar is accepted"
}

test_whitespace_only_overlay_is_ignored() {
    _generate_with_overlay debian-slim "$TEST_DIR/gen-blank" '

   
' || { fail "blank overlay generation" "failed"; return; }

    grep -q 'MIME-Version' "$TEST_DIR/gen-blank/user-data" \
        && fail "blank overlay" "wrapper emitted for a whitespace-only overlay" \
        || pass "whitespace-only overlay is ignored"
}

test_comment_only_overlay_is_ignored() {
    # This is the state an untouched scaffold leaves behind. Shipping it would
    # make cloud-init record a part error for a no-op overlay and stamp a
    # schema-error marker into the merged config, so comments do not count as
    # content.
    _generate_with_overlay debian-slim "$TEST_DIR/gen-comments" "# just a comment
# packages:
#   - htop
" || { fail "comment-only generation" "failed"; return; }

    if cmp -s "$TEST_DIR/gen-comments/user-data" "$TEST_DIR/gen-plain/user-data"; then
        pass "comments-only overlay is ignored (byte-identical to no overlay)"
    else
        fail "comment-only user-data" "differs from the plain generation"
    fi
}

test_multi_document_overlay_aborts_generation() {
    local err rc=0
    err="$(_generate_with_overlay debian-slim "$TEST_DIR/gen-multidoc" 'overlay_note: one
---
overlay_note: two
' 2>&1)" || rc=$?

    local ok=true
    (( rc != 0 )) || { fail "multidoc exit code" "generation succeeded"; ok=false; }
    # yaml.safe_load reports a second document as a stream error; that is the
    # same failure cloud-init would hit before silently dropping the part.
    grep -q "expected a single document" <<< "$err" \
        || { fail "multidoc message" "got: $err"; ok=false; }
    # A part cloud-init cannot parse is dropped silently, so the build must
    # refuse rather than report success with the overlay missing.
    $ok && pass "multi-document overlay aborts generation"
}

test_invalid_yaml_overlay_aborts_generation() {
    local err rc=0
    err="$(_generate_with_overlay debian-slim "$TEST_DIR/gen-badyaml" 'packages: [unclosed
' 2>&1)" || rc=$?

    local ok=true
    (( rc != 0 )) || { fail "invalid yaml exit code" "generation succeeded"; ok=false; }
    grep -q "while parsing a flow sequence" <<< "$err" \
        || { fail "invalid yaml message" "got: $err"; ok=false; }
    $ok && pass "invalid YAML overlay aborts generation"
}

test_non_mapping_overlay_aborts_generation() {
    local err rc=0
    err="$(_generate_with_overlay debian-slim "$TEST_DIR/gen-scalar" 'apt-get install -y htop
' 2>&1)" || rc=$?

    local ok=true
    (( rc != 0 )) || { fail "non-mapping exit code" "generation succeeded"; ok=false; }
    grep -q "must be a mapping" <<< "$err" || { fail "non-mapping message" "got: $err"; ok=false; }
    $ok && pass "non-mapping overlay (e.g. a bare command) aborts generation"
}

test_iso_embeds_generated_user_data() {
    # The guest reads user-data out of the cidata ISO, so the ISO must be built
    # from the generated file. The fake stands in for whichever tool
    # create_cloud_init_iso selects (it prefers genisoimage), so the assertion
    # does not depend on what is installed.
    local bin="$TEST_DIR/bin" out="$TEST_DIR/iso-gen" iso="$TEST_DIR/iso/ci.iso"
    mkdir -p "$bin" "$out" "$TEST_DIR/iso"
    local tool
    for tool in genisoimage mkisofs xorrisofs; do
        cat > "$bin/$tool" << 'EOF'
#!/usr/bin/env bash
out=""
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -output) out="$2"; shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
printf '%s\n' "${args[@]}" > "${out}.files"
: > "$out"
EOF
        chmod +x "$bin/$tool"
    done
    _clear_overlay

    local rc=0
    PATH="$bin:$PATH" CLAUDE_VM_DIR="$TEST_DIR/vmdir" VM_USER="tester" FLAVOR=debian-slim bash -c "
        source '$PROJECT_DIR/lib/config.sh'
        source '$PROJECT_DIR/lib/cloud-init.sh'
        create_cloud_init_iso '$out' '$iso'
    " || rc=$?

    local ok=true
    (( rc == 0 )) || { fail "iso creation" "failed with $rc"; ok=false; }
    [[ -f "$iso" ]] || { fail "iso file" "not created"; ok=false; }
    grep -qx "$out/user-data" "$iso.files" \
        || { fail "iso user-data" "generated user-data not passed to the ISO tool"; ok=false; }
    grep -qx "$out/meta-data" "$iso.files" || { fail "iso meta-data" "missing"; ok=false; }
    grep -qx "$out/network-config" "$iso.files" || { fail "iso network-config" "missing"; ok=false; }
    $ok && pass "ISO is built from the generated user-data/meta-data/network-config"
}

test_overlay_merge_type_is_additive_contract() {
    # Pins the merge CONTRACT claude-vm sends (the Merge-Type header) and the
    # integrity of the baked part. The merge behaviour itself is cloud-init's
    # (m_list/m_dict) and is not observable from these unit tests — it is
    # verified by booting a real base image with an overlay and inspecting the
    # guest's merged /var/lib/cloud/instance/cloud-config.txt.
    #
    # Why these ops: list(append) stops the overlay's first runcmd entry from
    # overwriting the baked first entry; dict(no_replace) keeps a baked scalar
    # over the overlay's; recurse_list appends list values nested in dicts
    # (users, write_files) rather than dropping the baked ones.
    _generate_with_overlay debian-slim "$TEST_DIR/gen-scalar-semantics" 'hostname: overlay-host
users:
  - name: extra
runcmd:
  - echo from-overlay
' || { fail "semantics generation" "failed"; return; }

    local ud="$TEST_DIR/gen-scalar-semantics/user-data" hdr ok=true
    hdr="$(_part_headers "$ud" 2)"

    echo "$hdr" | grep -q "^Merge-Type: ${OVERLAY_MERGE_TYPE}$" \
        || { fail "semantics merge type" "unexpected: $(echo "$hdr" | grep Merge-Type)"; ok=false; }
    case "$OVERLAY_MERGE_TYPE" in
        *list\(append\)*) ;;
        *) fail "semantics list append" "merge type lacks list(append)"; ok=false ;;
    esac
    case "$OVERLAY_MERGE_TYPE" in
        *dict\(no_replace*) ;;
        *) fail "semantics no_replace" "merge type lacks no_replace"; ok=false ;;
    esac
    case "$OVERLAY_MERGE_TYPE" in
        *recurse_list*) ;;
        *) fail "semantics recurse_list" "merge type lacks recurse_list"; ok=false ;;
    esac
    # The baked part must still carry the sandbox's own setup.
    _part_body "$ud" 1 > "$TEST_DIR/semantics-baked"
    grep -q "^power_state:" "$TEST_DIR/semantics-baked" \
        || { fail "semantics baked" "baked power_state missing from part 1"; ok=false; }
    grep -q "ssh_authorized_keys" "$TEST_DIR/semantics-baked" \
        || { fail "semantics baked key" "baked SSH key missing from part 1"; ok=false; }
    $ok && pass "overlay merge type keeps the additive contract and baked setup intact"
}

test_swapfile_removed() {
    local flavor ud ok
    for flavor in "${ALL_FLAVORS[@]}"; do
        ud="$(_userdata "$flavor")"
        ok=true
        grep -qF -- '- swapoff -a || true' "$ud" \
            || { fail "$flavor swap" "runcmd does not swapoff"; ok=false; }
        grep -qF -- "- sed -i '/swapfile/d' /etc/fstab" "$ud" \
            || { fail "$flavor swap" "fstab swapfile entry not removed"; ok=false; }
        # Images without /swap must not fail the line
        grep -qF -- '- rm -f /swap/swapfile; rmdir /swap 2>/dev/null || true' "$ud" \
            || { fail "$flavor swap" "swapfile removal missing or not failure-tolerant"; ok=false; }
        $ok && pass "$flavor: shipped swapfile is disabled and removed"
    done
}

# ─── Run ──────────────────────────────────────────────────────────────────────

run_test test_structure_all_flavors
run_test test_node_and_gh_from_distro_repos
run_test test_no_external_repos
run_test test_ssh_service_per_distro
run_test test_pkg_tuning_per_family
run_test test_deb_src_disabled_before_package_stage
run_test test_installer_prefetch
run_test test_swapfile_removed
run_test test_tuning_precedes_packages_stage
run_test test_slim_excludes_full_tools
run_test test_full_includes_build_tools
run_test test_glab_full_only
run_test test_slim_core_set
run_test test_installers_still_present
run_test test_bare_flavor_behaves_as_full
run_test test_unknown_flavor_fails
run_test test_package_update_enabled
run_test test_no_overlay_keeps_single_document
run_test test_overlay_is_mime_multipart
run_test test_overlay_part_headers_carry_merge_type
run_test test_overlay_payload_is_verbatim
run_test test_baked_part_matches_plain_generation
run_test test_overlay_unicode_round_trips
run_test test_overlay_boundary_collision_is_harmless
run_test test_overlay_leading_document_marker_kept
run_test test_overlay_marker_inside_block_scalar_is_not_structure
run_test test_comment_only_overlay_is_ignored
run_test test_whitespace_only_overlay_is_ignored
run_test test_multi_document_overlay_aborts_generation
run_test test_invalid_yaml_overlay_aborts_generation
run_test test_non_mapping_overlay_aborts_generation
run_test test_iso_embeds_generated_user_data
run_test test_overlay_merge_type_is_additive_contract

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_RUN} total"

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
echo "All tests passed."
