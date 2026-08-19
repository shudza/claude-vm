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

# Generate everything once up front
for _flavor in "${ALL_FLAVORS[@]}" debian; do
    if ! _generate "$_flavor" "$TEST_DIR/gen-$_flavor"; then
        echo "FATAL: userdata generation failed for flavor $_flavor" >&2
        exit 1
    fi
done

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
                grep -q 'DPkg::Lock::Timeout' "$ud"                 || { fail "$flavor tuning" "missing dpkg lock timeout"; ok=false; }
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
        grep -q 'claude-vm-prefetch --kill' "$ud" \
            || { fail "$flavor prefetch" "runcmd wait timeout does not kill the prefetch"; ok=false; }
        grep -q 'claude-vm-prefetch.pid' "$ud" \
            || { fail "$flavor prefetch" "prefetch does not record its pid"; ok=false; }
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
        grep -q 'astral.sh/uv/install.sh' "$ud"    || { fail "$flavor installers" "uv installer missing"; ok=false; }
        grep -q 'claude.ai/install.sh' "$ud"       || { fail "$flavor installers" "Claude Code installer missing"; ok=false; }
        $ok && pass "$flavor: uv and Claude Code installers present"
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

# ─── Run ──────────────────────────────────────────────────────────────────────

echo "=== claude-vm cloud-init tests ==="
echo ""

run_test test_structure_all_flavors
run_test test_node_and_gh_from_distro_repos
run_test test_no_external_repos
run_test test_ssh_service_per_distro
run_test test_pkg_tuning_per_family
run_test test_deb_src_disabled_before_package_stage
run_test test_installer_prefetch
run_test test_tuning_precedes_packages_stage
run_test test_slim_excludes_full_tools
run_test test_full_includes_build_tools
run_test test_slim_core_set
run_test test_installers_still_present
run_test test_bare_flavor_behaves_as_full
run_test test_unknown_flavor_fails
run_test test_package_update_enabled

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_RUN} total"

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
echo "All tests passed."
