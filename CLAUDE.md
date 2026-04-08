# claude-vm

QEMU sandbox for Claude Code. Isolated VMs with virtiofs filesystem sharing
and QCOW2 linked snapshots for per-project isolation.

## Architecture

Host runs `claude-vm` which manages QEMU VMs with virtiofs mounts of `$PWD` → `/workspace`.

**Snapshot strategy:**
- Base image (`~/.claude-vm/base/base.qcow2`): golden image provisioned via cloud-init
- Linked snapshots (`~/.claude-vm/snapshots/<hash>.qcow2`): COW deltas per project (12-char SHA-256 of abs path)
- Sidecar metadata (`<hash>.project`): stores project dir path

**Launch flow:** check running → build base if missing → create snapshot if missing →
find SSH port → start virtiofsd → launch QEMU (daemonized) → wait SSH → verify virtiofs →
rsync config → exec into Claude Code

**Shutdown flow:** save VM state (QMP savevm) → QMP quit / HMP powerdown → SIGTERM/SIGKILL fallback →
stop virtiofsd → verify snapshot intact → clean runtime artifacts (never delete snapshot)

**Config sync (rsync over SSH):** `~/.claude/`, `~/.claude.json`, `~/.gitconfig`, `~/.config/gh/`
Include-list for `~/.claude/`: settings, credentials, plugins, skills, mcp.json, CLAUDE.md only.

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

## Conventions

- All scripts: `#!/usr/bin/env bash` + `set -euo pipefail`
- Functions: `snake_case`. Internal/private: `_` prefix (e.g. `_build_ssh_cmd`)
- Constants: `UPPER_SNAKE_CASE`. Local vars: `local` at top of function
- Quote all expansions: `"$var"`, `"${array[@]}"`
- Use `[[ ]]` for conditionals, `(( ))` for arithmetic
- User-facing output goes through `lib/ui.sh` (`ui_phase`, `ui_info`, `ui_warn`, `ui_error`)
- Never `echo` directly in launch/shutdown code paths
- Error messages to stderr (`>&2`). Technical details to log file, not terminal
- Snapshot file is **never** deleted during shutdown/error. Only `reset`/`destroy` remove snapshots
- When adding new features always write tests and update documentation files

**Adding a command:** `cmd_<name>` function in `claude-vm` → case in `main()` → usage line in `usage()`

**Adding a flavor:** entries in `FLAVOR_IMAGE_URL/NAME/PKG_FAMILY` arrays in `config.sh` →
cases in `_cloud_init_*` functions in `cloud-init.sh`

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
