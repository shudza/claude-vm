# macOS Support for claude-vm

**Based on commit:** `654cdda` (cc: e2e tests) — `654cdda0075c22c0985e9659a22be25842fb9ff7`

## Context

claude-vm is a Linux-only (KVM + virtiofs) QEMU sandbox. The user wants to understand
the scope of adding macOS support. The main blockers are: virtiofs doesn't work with
QEMU on macOS, KVM doesn't exist on macOS (HVF instead), GNU coreutils differ from
BSD, and Apple Silicon Macs need aarch64 images.

The approach: a **platform abstraction layer** that detects the host OS/arch once at
startup and gates all platform-specific behavior behind it. Linux paths stay untouched.
macOS uses QEMU+HVF with **9P** filesystem sharing (built into QEMU, no daemon needed).

## Scope Summary

| Area | Linux (unchanged) | macOS (new) |
|-|-|-|
| Acceleration | KVM | HVF (or TCG fallback) |
| FS sharing | virtiofs (virtiofsd + memfd) | 9P (virtio-9p, no daemon) |
| QEMU binary | qemu-system-x86_64 | qemu-system-aarch64 (ARM) or x86_64 (Intel) |
| Machine type | q35 | virt (ARM) or q35 (Intel) |
| Cloud images | amd64 | arm64 (ARM) or amd64 (Intel) |
| Coreutils | GNU (stat -c, sed -i, ss, sha256sum, numfmt) | BSD wrappers |

## New Files

### 1. `lib/platform.sh` — Platform detection + portable wrappers

Runs once at startup. Exports globals and defines wrapper functions.

**Globals:**
- `HOST_OS` — "linux" or "darwin"
- `HOST_ARCH` — "x86_64" or "aarch64" (darwin arm64 mapped to aarch64)
- `QEMU_BIN` — "qemu-system-x86_64" or "qemu-system-aarch64"
- `QEMU_ACCEL` — "kvm", "hvf", or "tcg"
- `QEMU_MACHINE` — "type=q35" or "type=virt"
- `FS_SHARING` — "virtiofs" or "9p"

**Wrapper functions:**
- `_stat_size "$file"` — `stat -c%s` (Linux) vs `stat -f%z` (macOS)
- `_stat_owner "$file"` — `stat -c '%U'` vs `stat -f '%Su'`
- `_sha256 "$string"` — `sha256sum` vs `shasum -a 256`
- `_numfmt_iec "$bytes"` — `numfmt --to=iec` vs pure-bash fallback
- `_sed_i "$expr" "$file"` — `sed -i "$expr"` vs `sed -i '' "$expr"`
- `_check_port_free "$port"` — `ss -tlnp | grep ":$port "` vs `lsof -iTCP:$port -sTCP:LISTEN`

**Detection logic:**
```
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')  # "linux" or "darwin"
HOST_ARCH=$(uname -m)  # x86_64 or arm64
[[ "$HOST_ARCH" == "arm64" ]] && HOST_ARCH="aarch64"

# Acceleration
if [[ "$HOST_OS" == "linux" && -r /dev/kvm && -w /dev/kvm ]]; then
    QEMU_ACCEL="kvm"
elif [[ "$HOST_OS" == "darwin" ]] && sysctl -n kern.hv_support 2>/dev/null | grep -q 1; then
    QEMU_ACCEL="hvf"
else
    QEMU_ACCEL="tcg"
fi
```

### 2. `lib/fs-share.sh` — Filesystem sharing abstraction

Wraps virtiofs (Linux) and 9P (macOS) behind a common interface:

- `fs_share_start_daemon "$project_dir" "$sock_path" "$run_dir"`
  - Linux: calls existing `start_virtiofsd` from launch.sh
  - macOS: no-op (9P needs no host daemon)

- `fs_share_stop_daemon "$run_dir"`
  - Linux: kills virtiofsd
  - macOS: no-op

- `fs_share_qemu_args "$project_dir" "$sock_path" "$ram"`
  - Linux: returns memfd + chardev + vhost-user-fs-pci args
  - macOS: returns `-virtfs local,path=$project_dir,mount_tag=workspace,security_model=mapped-xattr,id=fs0`

- `fs_share_ensure_mounted "$ssh_port" "$ssh_key" "$user"`
  - Linux: `mount -t virtiofs workspace /workspace`
  - macOS: `mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 workspace /workspace`

## Modifications to Existing Files

### `claude-vm` (entry point)
- Source `lib/platform.sh` at line 22 (before other sources)
- No other changes

### `lib/config.sh`
- **Line 21-34 (flavor registry):** Add aarch64 image URLs:
  ```
  [debian]="...amd64.qcow2"       → kept, selected when HOST_ARCH=x86_64
  [debian-arm64]="...arm64.qcow2" → new, selected when HOST_ARCH=aarch64
  ```
  Or better: dynamic selection in `load_config` based on `HOST_ARCH`
- **Line 173:** `sed -i` → `_sed_i`
- **Line 189:** `sha256sum` → `_sha256`

### `lib/build.sh`
- **Line 98:** `qemu-system-x86_64` in prereq check → `$QEMU_BIN`
- **Lines 117-120:** `/dev/kvm` check → use `$QEMU_ACCEL`
- **Lines 126-130:** Add brew install instructions for macOS
- **Lines 145-148:** KVM fallback → use `$QEMU_ACCEL`
- **Line 159-161:** Replace hardcoded QEMU args:
  - `qemu-system-x86_64` → `$QEMU_BIN`
  - `accel=$accel` → `accel=$QEMU_ACCEL`
  - `-machine "type=q35,..."` → `-machine "$QEMU_MACHINE,accel=$QEMU_ACCEL"`
  - `-cpu host` stays (works with both KVM and HVF)
  - Remove `memory-backend-memfd` from build (not needed — no virtiofs during provisioning)

### `lib/launch.sh`
- **Lines 133-136 (`find_available_port`):** `ss -tlnp` → `_check_port_free`
- **Lines 239-243 (accel check):** Replace with `$QEMU_ACCEL` from platform.sh
- **Lines 247-249 (virtiofsd start):** Replace with `fs_share_start_daemon`
- **Lines 252-273 (`_launch_qemu`):** Rebuild QEMU args using platform globals:
  - `$QEMU_BIN` instead of `qemu-system-x86_64`
  - `$QEMU_MACHINE,accel=$QEMU_ACCEL`
  - Call `fs_share_qemu_args` for fs-sharing args (replaces memfd + chardev + vhost-user-fs-pci block)
  - Keep drive, network, serial, monitor, pidfile, daemonize args as-is
- **Line 282 (virtiofs mount):** Replace with `fs_share_ensure_mounted`

### `lib/shutdown.sh`
- **Line 175, 342:** `stat -c%s` → `_stat_size`
- **Line 348:** `numfmt --to=iec` → `_numfmt_iec`

### `lib/virtiofs.sh`
- No changes. Becomes Linux-only, called indirectly via `fs-share.sh`

### `lib/cloud-init.sh`
- **Lines 84-101 (workspace.mount systemd unit):** Conditionally generate:
  - `Type=virtiofs` when `FS_SHARING=virtiofs`
  - `Type=9p` + `Options=trans=virtio,version=9p2000.L,msize=104857600,nofail` when `FS_SHARING=9p`
- **Line 121 (fstab entry):** Same conditional for fstab fallback
- **Lines 83-85 (modules-load.d):** Load `9p` + `9pnet_virtio` modules when `FS_SHARING=9p`

### `lib/qemu-opts.sh`
- **Line 33:** `qemu-system-x86_64` → `$QEMU_BIN`
- **Line 34:** `-enable-kvm` → `-accel $QEMU_ACCEL`
- **Lines 41-42:** memfd block → conditional on `FS_SHARING=virtiofs`
- **Lines 98-104 (`build_virtiofs_qemu_args`):** Rename or make conditional, delegate to `fs-share.sh`

### `Makefile`
- **Line 13:** `sed -i` → portable form (use temp file: `sed '...' file > file.tmp && mv file.tmp file`)

## Implementation Order

1. `lib/platform.sh` (new) — purely additive, no existing code touched
2. `lib/fs-share.sh` (new) — purely additive
3. `claude-vm` — add `source "$LIB_DIR/platform.sh"` early
4. `lib/config.sh` — arm64 images + portable wrappers
5. `lib/build.sh` — QEMU binary/accel/machine + brew prereqs
6. `lib/launch.sh` — use platform globals + fs-share abstraction
7. `lib/cloud-init.sh` — 9P mount config
8. `lib/shutdown.sh`, `lib/qemu-opts.sh` — portable wrappers
9. `Makefile` — portable sed

## Verification

**Linux (no regression):**
- `make test-unit` — all existing tests pass
- `FS_SHARING=9p make test-unit` — 9P path can be smoke-tested on Linux too (QEMU supports 9P on Linux)
- `make test-e2e` — full lifecycle unchanged

**macOS:**
- New `tests/test_platform.sh` — validates detection outputs correct values per host
- Manual: `brew install qemu` → `claude-vm build` → `claude-vm` on macOS
- CI: add `macos-14` (Apple Silicon) runner to GitHub Actions matrix

**9P performance sanity:**
- `dd if=/dev/zero of=/workspace/test bs=1M count=100` inside guest
- Compare virtiofs vs 9P throughput (expect 9P ~50-70% of virtiofs for metadata ops)

## Risks / Notes

- **9P performance:** Notably slower than virtiofs for metadata-heavy workloads (npm install, git status on large repos). Acceptable for macOS where virtiofs isn't an option. Can document as known limitation.
- **ARM cloud images:** Debian/Ubuntu provide arm64 cloud images but they're less tested. May need flavor-specific quirks.
- **QEMU on macOS:** `brew install qemu` works but QEMU+HVF is less battle-tested than KVM. TCG fallback is very slow.
- **No virtiofsd on macOS:** The `virtiofs.sh` verify functions (read/write round-trip) need 9P equivalents in `fs-share.sh`.
