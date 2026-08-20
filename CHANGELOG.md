# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] - 2026-08-19

### Fixed

- **Existing VMs no longer lose their config and conversation history after updating to 0.1.3.** v0.1.3 moved the guest's global config to `~/.claude/.claude.json` and transcripts to `~/.claude/projects/<project-name>`, but only handled new VMs and the rebase path — a pre-existing VM that was simply relaunched re-ran first-time onboarding and showed an empty conversation list (the old data was untouched at the old paths, just not read). Every connect now runs a one-time, guarded migration: `~/.claude.json` is copied to `~/.claude/.claude.json` if the latter doesn't exist, and `~/.claude/projects/-workspace` is renamed to the project's directory name. VMs that already re-ran onboarding keep their original file at `~/.claude.json`; restore it with `cp ~/.claude.json ~/.claude/.claude.json` inside the VM (while Claude Code isn't running).

## [0.1.3] - 2026-08-19

### Added

- Each VM's Claude Code transcripts now live under `~/.claude/projects/<project-name>` instead of every project sharing `-workspace`. `claude-vm` sets `CLAUDE_CODE_PROJECT_DIR_NAME` (plus `CLAUDE_CONFIG_DIR`, which the name requires) for both the Claude Code launch and `claude-vm ssh` shells; override them from `~/.env` inside the VM. The guest's global config json accordingly moves to `~/.claude/.claude.json` — synced there on new VMs and migrated automatically on the first launch after a rebase.
- User-scope `agents/`, `commands/`, `workflows/` and `keybindings.json` from `~/.claude/` are synced into new VMs alongside plugins and skills.
- GitLab support: `glab` ships in the full flavors, and `~/.config/glab-cli/` is synced into new VMs and preserved across `claude-vm rebase`, the same as `gh`.
- Every flavor now comes in two variants: **slim** (git, Node.js, Python, GitHub CLI, Claude Code) and **full** (slim plus compilers, tmux, vim, and debugging tools). The default is `debian-slim`. Bare names like `debian` still work and mean the full variant, so existing setups keep their tools.
- Each flavor gets its own base image, so you can use different flavors for different projects at the same time. Existing VMs keep working; `claude-vm rebase` moves them over to the new layout.

### Changed

- Base image builds are much faster. Everything installs from the distro's own repositories in one go (no more third-party Node.js/GitHub CLI repos), unused package extras like docs and man pages are skipped, and the Claude Code installer downloads while packages are still installing instead of after. A slim build typically finishes in about two minutes plus the one-time image download.
- Node.js now comes from the distro, so its version follows the distro (20.x on Debian, 18.x on Ubuntu, current on Arch/Fedora). Need a newer one? Install it inside the VM with sudo, as with any other tool.
- The fedora flavor moved from Fedora 41 (end-of-life, and shipping a broken Node.js) to Fedora 44.
- uv ships only in the full variants now; slim keeps Python with pip and venv.
- Launch, stop, and rebase show a single status line that updates in place instead of scrolling output. A successful launch drops straight into Claude Code. Scripts and CI still get plain one-line-per-step output.
- `claude-vm stop --all` and `claude-vm rebase` stop all running VMs at once instead of one at a time.
- The default CPU count is 4 (clamped to the host's core count) instead of 2. Claude Code's parallel subagents and workflows scale with the VM's cores, and at 2 they ran one at a time. An explicit `VM_CPUS` is left alone.
- `claude-vm rebase` no longer carries Claude Code runtime state (`daemon/`, `jobs/`, `sessions/`, caches and similar) into the rebuilt VM — stale daemon locks broke background agents after a rebase. Transcripts, plans, history and all settings are still preserved.

### Fixed

- The e2e test suites honor `TMPDIR` instead of hardcoding `/tmp`, so they can run on hosts where `/tmp` is a small tmpfs.
- Downloaded cloud images are checksum-verified again (verification was silently skipped for a while during development).
- Interrupting a rebase no longer leaves its lock behind.

### Removed

- Compilers and heavyweight tooling from the slim images — they now live in the full variants. Slim VMs keep passwordless sudo, so anything missing is one install away.
- The save-VM-state step of `claude-vm stop`. It never worked and only printed a spurious error on every stop.

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

[Unreleased]: https://github.com/shudza/claude-vm/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/shudza/claude-vm/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/shudza/claude-vm/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/shudza/claude-vm/compare/v0.1.1-alpha...v0.1.2
[0.1.1-alpha]: https://github.com/shudza/claude-vm/compare/v0.1.0-alpha...v0.1.1-alpha
[0.1.0-alpha]: https://github.com/shudza/claude-vm/releases/tag/v0.1.0-alpha
