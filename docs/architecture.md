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
  +-- rsync over SSH       Syncs ~/.claude/, ~/.gitconfig, ~/.config/gh/
```

## Snapshot Strategy

**Base image** (`~/.claude-vm/base/base.qcow2`): Golden image with OS + Claude Code + dev tools. Built once via cloud-init provisioning, updated occasionally with `claude-vm build --force`.

**Linked snapshots** (`~/.claude-vm/snapshots/<hash>.qcow2`): QCOW2 files backed by the base image. Copy-on-write means only the delta from base consumes disk. Each project directory gets its own snapshot identified by a 12-char SHA-256 hash of the absolute path.

**Sidecar metadata** (`~/.claude-vm/snapshots/<hash>.project`): Stores the project directory path so `claude-vm list` can display human-readable names.

```
base.qcow2 (golden image, ~1.5GB)
  <- project-abc123.qcow2 (COW delta, starts at ~200KB)
  <- project-def456.qcow2 (COW delta)
  <- ...
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
9. Sync host config into guest via rsync (~/.claude/, ~/.gitconfig, ~/.config/gh/)
10. `exec` into SSH session running Claude Code

All output goes to `~/.claude-vm/run/<hash>/launch.log`. The user sees a spinner per phase.

## Shutdown Flow

1. Save VM state into QCOW2 for fast resume (via QMP `savevm`)
2. Send QMP `quit` (preferred) or HMP `system_powerdown` (fallback)
3. Wait up to 15s for graceful exit
4. SIGTERM then SIGKILL if still alive
5. Stop virtiofsd
6. Verify snapshot file integrity (exists, non-empty)
7. Clean up runtime artifacts (PID files, sockets) -- snapshot is **never** deleted

## Build/Provisioning Flow

1. Download cloud image (Debian 12 or Ubuntu 24.04 depending on flavor)
2. Convert to QCOW2 and resize to 20GB
3. Generate cloud-init ISO with user-data, meta-data, and network-config
4. Boot VM with cloud-init attached (headless, auto-poweroff when done)
5. Cloud-init provisions: user account, SSH, dev tools, Node.js, Claude Code, virtiofs mounts
6. Move provisioned image to final base image location

## Filesystem Sharing (virtiofs)

Host runs `virtiofsd` pointing at the project directory. QEMU connects via a Unix socket with `vhost-user-fs-pci`. The guest mounts it at `/workspace` via a systemd mount unit.

Requires `memory-backend-memfd` with `share=on` for DAX support.

## Multi-Instance Support

Multiple `claude-vm` invocations in the same directory each get their own SSH session and Claude Code process. The guest sshd is configured with `MaxSessions 64`. No locking or coordination -- each instance is independent.

## Config Sync (rsync)

On each launch, rsync transfers host config into the guest:

| Source | Destination | Purpose |
|-|-|-|
| `~/.claude/` | `~/.claude/` | Claude Code settings, credentials, plugins |
| `~/.claude.json` | `~/.claude.json` | Theme, onboarding state |
| `~/.gitconfig` | `~/.gitconfig` | Git identity and preferences |
| `~/.config/gh/` | `~/.config/gh/` | GitHub CLI auth tokens |

The `~/.claude/` sync excludes ephemeral data: sessions, cache, debug logs, tasks, history, backups.

Rsync is incremental -- after the first launch, only changed files transfer.

## Directory Layout

```
~/.claude-vm/
  config                   User configuration file
  keys/
    id_ed25519             SSH keypair for VM access
    id_ed25519.pub
  base/
    base.qcow2             Provisioned golden image
    <cloud-image>          Downloaded cloud image (cached)
  snapshots/
    <hash>.qcow2           Per-project linked snapshot
    <hash>.project          Project directory path (sidecar)
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
| `lib/snapshot.sh` | Linked snapshot create/verify/list/delete |
| `lib/virtiofs.sh` | virtiofsd management, guest mount verification |
| `lib/ssh.sh` | SSH key management, connectivity checks |
| `lib/ui.sh` | Spinner, log capture, status output |
| `lib/resume.sh` | VM state save/load for fast resume |
| `lib/wait-ready.sh` | SSH readiness polling |
| `lib/boot-timer.sh` | Boot performance measurement |
| `lib/claude-code.sh` | Claude Code verification, credential detection |
