# claude-vm

QEMU sandbox for Claude Code. Isolated VMs with virtiofs filesystem sharing
and QCOW2 linked snapshots for per-project isolation.

## Architecture

Host runs `claude-vm` which manages QEMU VMs with virtiofs mounts of `$PWD` → `/workspace`.

**Snapshot strategy:**
- Base images (`~/.claude-vm/base/base-<flavor>.qcow2`): golden images provisioned via cloud-init, one per flavor (`<distro>-{slim,full}`; bare distro names alias to full). Legacy `base.qcow2` backings still verify; `rebase` migrates them
- Linked snapshots (`~/.claude-vm/snapshots/<hash>.qcow2`): COW deltas per project (12-char SHA-256 of abs path); the embedded backing reference records the flavor
- Sidecar metadata (`<hash>.project`): stores project dir path

**Launch flow:** check running → build base if missing → create snapshot if missing →
find SSH port → start virtiofsd → launch QEMU (daemonized) → wait SSH → verify virtiofs →
rsync config → exec into Claude Code

**Shutdown flow:** HMP powerdown → SIGTERM/SIGKILL fallback →
stop virtiofsd → verify snapshot intact → clean runtime artifacts (never delete snapshot)
`stop --all` and `rebase` stop VMs concurrently via `stop_vms_parallel` (per-VM logs in `run/<hash>/stop.log`)
`rebase` extracts `_REBASE_GUEST_PATHS` but excludes `~/.claude/` runtime state (`_REBASE_CLAUDE_EXCLUDES`:
daemon, jobs, sessions, caches…) so stale daemon locks never reach a fresh VM; transcripts/plans/config are kept

**Config sync (rsync over SSH):** `~/.claude/`, `~/.claude.json` (→ guest `~/.claude/.claude.json`),
`~/.gitconfig`, `~/.config/gh/`, `~/.config/glab-cli/`
Include-list for `~/.claude/`: settings, credentials, plugins, skills, agents, commands, workflows,
keybindings.json, mcp.json, CLAUDE.md only — never runtime state.
`connect_vm`/`connect_vm_shell` export `CLAUDE_CONFIG_DIR=~/.claude` +
`CLAUDE_CODE_PROJECT_DIR_NAME=<sanitized basename>` so guest transcripts land in
`~/.claude/projects/<name>` instead of `-workspace` (the name is only honored with a config
dir set; with it set, Claude Code reads the global json from `$CLAUDE_CONFIG_DIR/.claude.json`).
Pre-0.1.3 VMs are migrated by guarded commands in the connect prefix (cp json, mv -workspace).
MCP servers live in `~/.claude.json` (not `~/.claude/`): only user-scoped (`mcpServers`)
carry over; local-scoped (`projects["<host-path>"]`) don't — the VM mounts at `/workspace`.

## Module Map

| File | Responsibility |
|-|-|
| `claude-vm` | CLI entry point, command dispatch |
| `lib/config.sh` | Config loading, defaults, flavor registry, path helpers |
| `lib/build.sh` | Base image download, cloud-init provisioning, prereq checks |
| `lib/cloud-init.sh` | Cloud-init ISO generation, flavor-specific packages/runcmd |
| `lib/launch.sh` | VM launch, SSH connection, virtiofsd start, config sync |
| `lib/shutdown.sh` | Graceful shutdown, state save, cleanup |
| `lib/snapshot.sh` | Linked snapshot creation, backing chain verification, deletion |
| `lib/virtiofs.sh` | virtiofsd binary detection, guest mount management |
| `lib/ui.sh` | Spinner, phase execution with log capture, status messages |
| `lib/rebase.sh` | Base image rebuild with per-VM state migration |

## Conventions

- All scripts: `#!/usr/bin/env bash` + `set -euo pipefail`
- Functions: `snake_case`. Internal/private: `_` prefix (e.g. `_build_ssh_cmd`)
- Constants: `UPPER_SNAKE_CASE`. Local vars: `local` at top of function
- Quote all expansions: `"$var"`, `"${array[@]}"`
- Use `[[ ]]` for conditionals, `(( ))` for arithmetic
- User-facing output goes through `lib/ui.sh` (`ui_phase`, `ui_info`, `ui_warn`, `ui_done`, `ui_progress`)
- Interactive terminals get a single redrawing status line; non-tty/quiet gets one line per phase
- Never `echo` directly in launch/shutdown code paths
- Error messages to stderr (`>&2`). Technical details to log file, not terminal
- Snapshot file is **never** deleted during shutdown/error. Only `reset`/`destroy` remove snapshots
- When adding new features always write tests and update documentation files

**Adding a command:** `cmd_<name>` function in `claude-vm` → case in `main()` → usage line in `usage()`

**Adding a flavor:** entries in `FLAVOR_IMAGE_URL/NAME/CHECKSUM_URL/CHECKSUM_TYPE` arrays
in `config.sh` (keyed by distro; slim/full share the image) → distro cases in
`_cloud_init_*` functions in `cloud-init.sh` (slim package set + full extras)

**Adding a config key:** `DEFAULT_*` constant in `config.sh` → handle in `load_config` →
validate in `set_config_value` → add to `get` case in `claude-vm`

## Testing

```bash
make test          # all (unit + e2e)
make test-unit     # no QEMU/KVM needed
make test-e2e      # requires KVM + nested virt
```

Unit tests mock QEMU/virtiofsd with fake processes. E2E tests run real VMs.
Tests create temp dirs and clean up. Pattern: setup → action → assert → teardown.
E2E suites honor `TMPDIR` (default `/tmp`); the main suite needs ~5 GB for two base
images plus snapshots, so point `TMPDIR` at a real disk when `/tmp` is a small tmpfs.
