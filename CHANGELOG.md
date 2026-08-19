# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Launch, stop, and rebase progress now renders as a single status line that redraws in place (spinner + current phase). A successful launch prints nothing and drops straight into Claude Code (the `Ready in Ns` summary is gone); stop and rebase end with a one-line confirmation. Non-interactive output (CI, pipes, `CLAUDE_VM_QUIET`) keeps the previous one-line-per-phase format, and failures still commit a `✗` line with the log tail. `CLAUDE_VM_FORCE_TTY=true` forces the interactive rendering without a tty (used by tests).
- `claude-vm stop --all` and `claude-vm rebase` stop running VMs concurrently instead of one at a time, showing a single `(k/N)` progress line. Per-VM shutdown output goes to `~/.claude-vm/run/<hash>/stop.log`.

### Fixed

- `ui_init` no longer clobbers a pre-existing EXIT trap, so an interrupted `rebase` releases its lock again.

### Removed

- Compilers and heavyweight tooling from the base image (all flavors): `build-essential`/`base-devel`/`gcc`+`gcc-c++`+`make`, `cmake`, `dnsutils`/`bind-tools`/`bind-utils`, `strace`, and `wget`. Together they accounted for roughly half of the provisioning time (~100MB of downloads, ~350MB installed) and pushed the base build well past the 120s target; the VM keeps NOPASSWD sudo, so Claude installs them on demand when a project actually compiles native extensions. Python's pip/venv stay.
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
