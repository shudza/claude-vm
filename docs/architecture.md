# Architecture

## Overview

claude-vm wraps QEMU to provide instant, isolated sandbox environments for Claude Code. Each project directory gets its own copy-on-write VM snapshot backed by a shared base image.

```
Host (Linux)
  $ claude-vm
  |
  +-- virtiofsd            Shares $PWD into guest as /workspace
  +-- QEMU (KVM)           Runs linked snapshot of base image
  |     +-- SSH (port-forwarded)
  |     +-- virtiofs mount (/workspace)
  |     +-- Claude Code (--dangerously-skip-permissions)
  |
  +-- rsync over SSH       Syncs ~/.claude/, ~/.gitconfig, ~/.config/gh/, ~/.config/glab-cli/
```

## Snapshot Strategy

**Base images** (`~/.claude-vm/base/base-<flavor>.qcow2`): Golden images with OS + Claude Code + dev tools, one per flavor (e.g. `base-debian-slim.qcow2`, `base-fedora-full.qcow2`), so multiple flavors coexist. Built once via cloud-init provisioning, updated occasionally with `claude-vm build --force` or `claude-vm rebase`. Installs from before the slim/full split used a single `base.qcow2`; snapshots backed by it keep working, and `claude-vm rebase` migrates them to flavor-keyed bases.

**Linked snapshots** (`~/.claude-vm/snapshots/<hash>.qcow2`): QCOW2 files backed by a base image. Copy-on-write means only the delta from base consumes disk. Each project directory gets its own snapshot identified by a 12-char SHA-256 hash of the absolute path; the snapshot's embedded backing reference records which flavor's base it was created from.

**Sidecar metadata** (`~/.claude-vm/snapshots/<hash>.project`): Stores the project directory path so `claude-vm list` can display human-readable names.

```
base-debian-slim.qcow2 (golden image, ~1GB)
  <- project-abc123.qcow2 (COW delta, starts at ~200KB)
  <- project-def456.qcow2 (COW delta)
base-debian-full.qcow2 (golden image, ~1.5GB)
  <- project-789abc.qcow2 (COW delta)
```

## Launch Flow

1. Check if VM is already running for this project -- if so, attach a new Claude Code instance via SSH
2. Build base image if missing (download cloud image + cloud-init provisioning)
3. Create linked snapshot if missing (qemu-img create with backing file)
4. Find available SSH port starting from `SSH_PORT_BASE`
5. Start virtiofsd daemon sharing the project directory
6. Launch QEMU (daemonized) with KVM acceleration, virtiofs, and SSH port forwarding
7. Wait for SSH to become available (polls up to 60s)
8. Verify virtiofs mount in guest (mount test + read/write verification)
9. Sync host config into guest via rsync (~/.claude/, ~/.gitconfig, ~/.config/gh/, ~/.config/glab-cli/)
10. `exec` into SSH session running Claude Code, with `CLAUDE_CODE_PROJECT_DIR_NAME` set to the sanitized project basename so the guest's transcript dir is `~/.claude/projects/<name>` rather than `-workspace` (`claude-vm ssh` shells get the same export)

All output goes to `~/.claude-vm/run/<hash>/launch.log`. In an interactive terminal
the user sees a single status line that redraws in place per phase (spinner + phase
text); successful phases leave no output behind, and a successful launch prints
nothing before dropping into Claude Code.
When output is not a terminal (CI, pipes) or `CLAUDE_VM_QUIET=true`, each phase
prints one permanent `✓`/`✗` line instead. Failed phases always commit a `✗` line
with the log path and a tail of recent errors.

## Shutdown Flow

1. Send HMP `system_powerdown` (ACPI shutdown)
2. Wait up to 15s for graceful exit
3. SIGTERM then SIGKILL if still alive
4. Stop virtiofsd
5. Verify snapshot file integrity (exists, non-empty)
6. Clean up runtime artifacts (PID files, sockets) -- snapshot is **never** deleted

`stop --all` and `rebase` stop all running VMs concurrently, showing a single
`(k/N)` progress line; per-VM output goes to `~/.claude-vm/run/<hash>/stop.log`.

## Build/Provisioning Flow

1. Download cloud image (Debian 13, Ubuntu 24.04, Arch, or Fedora 44 depending on flavor)
2. Convert to QCOW2 and resize to 20GB
3. Generate cloud-init ISO with user-data, meta-data, and network-config
4. Boot VM with cloud-init attached (headless, auto-poweroff when done)
5. Cloud-init provisions: user account, SSH, the flavor's package set (nodejs/npm/gh from the distro repos in a single package transaction), uv, Claude Code, virtiofs mounts
6. Move provisioned image to its flavor-keyed base location (`base-<flavor>.qcow2`)

## Rebase Flow

`claude-vm rebase` rebuilds the base image from the latest cloud image while preserving per-VM state:

1. **Extract:** For each project, boot the VM headless (no virtiofs — `workspace.mount` uses `nofail`), rsync persistent state (`~/.claude/`, `~/.claude.json`, `~/.gitconfig`, `~/.config/gh/`, `~/.config/glab-cli/`) to `~/.claude-vm/backups/<hash>/`, fast shutdown. Runtime state under `~/.claude/` is excluded (`daemon/`, `jobs/`, `sessions/`, `session-env/`, `shell-snapshots/`, `paste-cache/`, `tasks/`, `telemetry/`, `cache/`, `downloads/`, `backups/`, `file-history/` and a few cache files) so stale daemon locks and worker rosters never reach the fresh VM; transcripts (`projects/`), `plans/`, `history.jsonl` and all config are kept. Paths from `REBASE_BACKUP_PATHS` are copied in a second pass as root (`--rsync-path="sudo rsync"`) with perms/ownership preserved via `--fake-super` xattrs, and recorded in a `.rebase-paths` manifest inside the backup
2. **Destroy:** Remove all `<hash>.qcow2` snapshots (preserve `.project` and `.ports` sidecars), remove old base image and cached cloud image
3. **Rebuild:** `build_base_image()` downloads the latest cloud image and provisions from scratch — only for the configured `FLAVOR`. Snapshots are always recreated from the current flavor on the next launch, so other flavors' bases are deleted rather than rebuilt; a launch that selects one later rebuilds it on demand
4. **Restore (lazy):** On next `launch_vm()`, if `~/.claude-vm/backups/<hash>/` exists, rsync its contents into the freshly created VM, then remove the backup directory. Manifest paths are pushed as root with perms/ownership restored, as an overlay (no `--delete`) so files the fresh image ships survive

The backup directory itself is the "pending restore" marker — no separate state file needed.

## Filesystem Sharing (virtiofs)

Host runs `virtiofsd` pointing at the project directory. QEMU connects via a Unix socket with `vhost-user-fs-pci`. The guest mounts it at `/workspace` via a systemd mount unit.

Requires `memory-backend-memfd` with `share=on` for DAX support.

## Multi-Instance Support

Multiple `claude-vm` invocations in the same directory each get their own SSH session and Claude Code process. The guest sshd is configured with `MaxSessions 64`. No locking or coordination -- each instance is independent.

## Config Sync (rsync)

On each launch, rsync transfers host config into the guest:

| Source | Destination | Purpose |
|-|-|-|
| `~/.claude/` | `~/.claude/` | Claude Code settings, credentials, plugins, skills, agents, commands, workflows, keybindings |
| `~/.claude.json` | `~/.claude/.claude.json` | Theme, onboarding state, user-scope MCP servers (Claude Code reads it from `$CLAUDE_CONFIG_DIR` in the guest) |
| `~/.gitconfig` | `~/.gitconfig` | Git identity and preferences |
| `~/.config/gh/` | `~/.config/gh/` | GitHub CLI auth tokens |
| `~/.config/glab-cli/` | `~/.config/glab-cli/` | GitLab CLI auth tokens (`glab` itself ships in `-full` flavors) |

The `~/.claude/` sync is an include-list (`settings.json`, credentials, `plugins/`, `skills/`, `agents/`, `commands/`, `workflows/`, `keybindings.json`, `mcp.json`, `CLAUDE.md`, `statusline-command.sh`); everything else -- sessions, cache, daemon state, tasks, history, backups -- stays on the host.

Rsync is incremental -- after the first launch, only changed files transfer.

### MCP servers

MCP server definitions are *not* stored under `~/.claude/` -- they live in `~/.claude.json`:

| MCP scope | Stored in | Carries into VM? |
|-|-|-|
| User (`claude mcp add -s user`) | `~/.claude.json` -> top-level `mcpServers` | Yes -- the whole file syncs |
| Local (`claude mcp add`, default) | `~/.claude.json` -> `projects["<host-path>"].mcpServers` | No -- keyed by the host path; the VM mounts the project at `/workspace` |
| Project (`.mcp.json` in repo) | repo `.mcp.json` (shared via virtiofs) + approval state in `~/.claude.json` | Definition yes; approval state is host-path-keyed, so re-approve in the VM |

Only **user-scoped** MCP servers carry over automatically. For a server you want in the VM, either add it user-scoped (`claude mcp add -s user ...`) on the host, or re-add it with `claude mcp add` from inside the VM (`claude-vm ssh`). The legacy `~/.claude/mcp.json` is synced too, but `claude mcp add` no longer writes there.

## Directory Layout

```
~/.claude-vm/
  config                   User configuration file
  keys/
    id_ed25519             SSH keypair for VM access
    id_ed25519.pub
  base/
    base-<flavor>.qcow2    Provisioned golden image (one per flavor)
    <cloud-image>          Downloaded cloud image (cached)
  snapshots/
    <hash>.qcow2           Per-project linked snapshot
    <hash>.project          Project directory path (sidecar)
    <hash>.ports            Per-project forward port config (sidecar)
  backups/
    <hash>/                 Per-project state extracted during rebase (removed after restore)
      .claude/              Claude Code settings, credentials, plugins
      .claude/.claude.json  Theme, onboarding state
      .config/gh/           GitHub CLI auth tokens
      .gitconfig            Git identity
      .rebase-paths         Manifest of extracted REBASE_BACKUP_PATHS entries
      _abs/                 Absolute REBASE_BACKUP_PATHS entries (/etc/ssh → _abs/etc/ssh)
  cloud-init/
    user-data              Generated cloud-init config
    meta-data
    network-config
    cloud-init.iso         Generated ISO
  run/
    <hash>/
      qemu.pid             QEMU process ID
      virtiofsd.pid         virtiofsd process ID
      ssh_port              SSH port number
      monitor.sock          QEMU HMP monitor socket
      virtiofs.sock         virtiofsd socket
      serial.log            VM serial console output
      launch.log            Launch phase output (for debugging)
      shutdown.log          Shutdown phase output
      virtiofsd.log         virtiofsd daemon output
```

## Module Map

| File | Responsibility |
|-|-|
| `claude-vm` | CLI entry point, command dispatch |
| `lib/config.sh` | Config loading, defaults, flavor registry, path helpers |
| `lib/build.sh` | Base image download, provisioning, prerequisites check |
| `lib/cloud-init.sh` | Cloud-init ISO generation, flavor-specific packages/runcmd |
| `lib/launch.sh` | VM launch, SSH connection, config sync |
| `lib/shutdown.sh` | Graceful shutdown, state save, cleanup |
| `lib/snapshot.sh` | Linked snapshot creation, backing chain verification, deletion |
| `lib/virtiofs.sh` | virtiofsd binary detection, guest mount management |
| `lib/ui.sh` | Spinner, log capture, status output |
| `lib/rebase.sh` | Base image rebuild with per-VM state migration |
