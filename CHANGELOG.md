# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Slim/full flavor split: every distro now comes as `<distro>-slim` (git, zip/unzip, Node.js + npm, Python, gh, Claude Code, and core infra) and `<distro>-full` (slim plus build tools, tmux, vim, and debug utilities), for 8 flavors total. The default is `debian-slim`; bare distro names (`debian`, `ubuntu`, ...) alias to the `-full` variant so existing configs keep their tool set.
- Per-flavor base images: bases are now stored as `~/.claude-vm/base/base-<flavor>.qcow2`, so multiple flavors coexist and different projects can run different flavors side by side. `claude-vm list` and `status` show all built bases. Snapshots from before the split (backed by the old `base.qcow2`) keep launching unchanged; `claude-vm rebase` rebuilds every flavor in use and migrates legacy snapshots to flavor-keyed bases.

### Changed

- Base provisioning now installs everything — including `nodejs`, `npm`, and `gh`/`github-cli` — from the distro's own repositories in the single cloud-init package transaction. The NodeSource and cli.github.com apt repositories are gone, which removes two full apt index refreshes and their setup scripts from the build. Consequence: Node.js follows the distro version (20.x on Debian 13, 18.x on Ubuntu 24.04, current on Arch/Fedora) instead of always 22.x; newer Node can still be installed at runtime via sudo (NodeSource/nvm).
- The fedora flavor now tracks Fedora 44 Cloud Base (was Fedora 41, EOL since May 2025). This is also a correctness fix: F41's final `nodejs` build (22.21.1) links the sqlite session API that no F41 `sqlite-libs` build ships, so `node` failed to start with `symbol lookup error: undefined symbol: sqlite3session_attach` — within F44, nodejs and sqlite are built consistently.
- Package-manager tuning is written before the package transaction runs: apt/dpkg skip man pages, docs, recommends, suggests, and translations and use `force-unsafe-io` (debian/ubuntu); dnf sets `install_weak_deps=False` and `tsflags=nodocs` (fedora). A `bootcmd` additionally disables `deb-src` in the Debian cloud image's deb822 sources before the index refresh — measured to cut the `apt update` fetch from 21.6MB/33s to 10.5MB/2s. This trims both provisioning time and base image size. The exclusions persist into project VMs; delete `/etc/dpkg/dpkg.cfg.d/claude-vm` (or `/etc/apt/apt.conf.d/99claude-vm`) in the guest to get docs back for later installs.
- The Claude Code installer (plus uv on full flavors) now downloads in parallel with the package phase: a `bootcmd`-launched prefetch script runs the installers as soon as the network and user exist, and `runcmd` waits on a completion marker, falling back to inline installs if the prefetch didn't finish (the installers are idempotent, plain downloads into `~/.local` that never touch the package manager). This hides the installers' ~60-70s behind the package download instead of adding it after.
- uv now ships only in the `*-full` flavors; slim keeps Python with pip and venv.
- The base-build time target is now <210s (was <120s), in both the post-build warning and the first-launch timing e2e. Measured slim builds land at 140-165s across machines with the remaining time almost entirely network-bound (~70MB of packages plus the Claude Code installer's ~60-70s), so the old target failed on every machine regardless of the provisioning optimizations.
- Launch, stop, and rebase progress now renders as a single status line that redraws in place (spinner + current phase). A successful launch prints nothing and drops straight into Claude Code (the `Ready in Ns` summary is gone); stop and rebase end with a one-line confirmation. Non-interactive output (CI, pipes, `CLAUDE_VM_QUIET`) keeps the previous one-line-per-phase format, and failures still commit a `✗` line with the log tail. `CLAUDE_VM_FORCE_TTY=true` forces the interactive rendering without a tty (used by tests).
- `claude-vm stop --all` and `claude-vm rebase` stop running VMs concurrently instead of one at a time, showing a single `(k/N)` progress line. Per-VM shutdown output goes to `~/.claude-vm/run/<hash>/stop.log`.

### Fixed

- Cloud image checksum verification was silently skipped for every flavor after the slim/full split: `verify_cloud_image` looked up the checksum arrays with the full flavor name (`debian-slim`) while the arrays are keyed by distro. It now resolves through `flavor_distro`, and a unit test pins the lookup.
- `ui_init` no longer clobbers a pre-existing EXIT trap, so an interrupted `rebase` releases its lock again.

### Removed

- Compilers and heavyweight tooling from the *slim* base images: `build-essential`/`base-devel`/`gcc`+`gcc-c++`+`make`, `cmake`, `dnsutils`/`bind-tools`/`bind-utils`, `strace`, `wget`, tmux, vim, and the other extra utilities now live only in the `*-full` flavors. They accounted for roughly half of the provisioning time (~100MB of downloads, ~350MB installed) and pushed the slim build well past the 120s target; slim VMs keep NOPASSWD sudo, so anything missing installs on demand. Python's pip/venv stay in slim.
- The save-VM-state step of `claude-vm stop`. It could never succeed — QEMU was launched without the QMP socket it required — and only produced a spurious `✗ Saving VM state` error on every stop. There was also no `-loadvm` counterpart, so no state was ever resumed.

## [0.1.2] - 2026-07-25

### Added

- `jq` is now checked by `check_build_prerequisites` and listed in the README requirements. It has always been required (it parses `qemu-img info --output=json`), but a host without it only found out at the end of a base build. ([#7](https://github.com/shudza/claude-vm/issues/7))
- `newuidmap`/`newgidmap` are checked before virtiofsd is started, and listed in the README requirements. Rust virtiofsd shells out to them for its unprivileged user namespace; on Debian/Ubuntu they ship in the separate `uidmap` package, which is not installed by default. ([#7](https://github.com/shudza/claude-vm/issues/7))
- `REBASE_BACKUP_PATHS` config key: comma-separated list of extra guest paths (absolute like `/etc/ssh` or home-relative like `~/.ssh`) that `claude-vm rebase` backs up and restores on next launch, alongside the built-in set. Unlike the built-ins, these are synced as root (`sudo rsync`) with permissions and ownership preserved (`--fake-super` on the host side). Extracted paths are recorded in a `.rebase-paths` manifest inside the backup so a config edit between rebase and relaunch can't misroute the restore; restore is an overlay (no `--delete`).

### Fixed

- `start_virtiofsd` verifies that the daemon is still running instead of only checking that the socket file exists. virtiofsd binds its socket before finishing sandbox setup, so a daemon that died afterwards left the socket behind, passed the check, and surfaced as an unrelated-looking QEMU error (`Failed to connect to '…/virtiofs.sock': Connection refused`). Failures now report the tail of `virtiofsd.log`. ([#7](https://github.com/shudza/claude-vm/issues/7))
- A failure to read the provisioned image size is no longer reported as `provisioned image is suspiciously small (0MB)`. `qemu-img info | jq` errors were swallowed and collapsed into a size of 0, which pointed at a provisioning bug that didn't exist. ([#7](https://github.com/shudza/claude-vm/issues/7))

## [0.1.1-alpha] - 2026-05-22

### Added

- `claude-vm list` shows projects with a pending restore (post-rebase, before relaunch) as `[pending restore]`. Previously these projects were invisible until their first `launch` recreated a snapshot.

### Fixed

- `claude-vm rebase` cleans `.ports` sidecars and orphan `.project` sidecars during its destruction phase. `.project` sidecars for projects with a backup are preserved so `list` can surface pending restores; orphans (no backup, no qcow2) accumulated in `~/.claude-vm/snapshots/` indefinitely before and are now swept.
- `claude-vm list` skips 0-byte `.qcow2` placeholders. Interrupted snapshot creation (SIGINT/SIGTERM during `qemu-img create`) could leave an empty file behind that surfaced as a confusing `(unknown) … [stopped]` row.
- `create_project_snapshot` traps `INT`/`TERM` and removes the partial `.qcow2` (and the sidecar it would have written) before exiting. Closes the upstream of the 0-byte qcow2 files that the `list` filter now hides.

## [0.1.0-alpha] - 2026-05-20

### Added

- `claude-vm rebase` command: refreshes the shared base image (Claude Code, OS packages, kernel) while preserving each project VM's persistent state by extracting `~/.claude/`, `~/.claude.json`, `~/.gitconfig`, and `~/.config/gh/` to a per-project backup directory, rebuilding the base from upstream, and lazy-restoring the extracted state on the project's next launch.

[Unreleased]: https://github.com/shudza/claude-vm/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/shudza/claude-vm/compare/v0.1.1-alpha...v0.1.2
[0.1.1-alpha]: https://github.com/shudza/claude-vm/compare/v0.1.0-alpha...v0.1.1-alpha
[0.1.0-alpha]: https://github.com/shudza/claude-vm/releases/tag/v0.1.0-alpha
