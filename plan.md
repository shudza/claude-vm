# claude-vm — QEMU Sandbox for Claude Code

## Overview

A CLI utility that wraps QEMU to provide instant, isolated sandbox environments for running Claude Code with full permissions. Uses virtiofs for near-native filesystem performance and QEMU linked snapshots for space-efficient per-project isolation.

## Architecture

```
┌─────────────────────────────────────┐
│  Host (Linux)                       │
│                                     │
│  $ claude-vm                        │
│  ├── Reads config / base snapshot   │
│  ├── Creates linked snapshot        │
│  │   for current project dir        │
│  ├── Launches QEMU with virtiofs    │
│  │   mount of $PWD → /workspace     │
│  └── Attaches terminal (SSH/serial) │
│                                     │
│  ┌────────────────────────────────┐ │
│  │ QEMU VM (linked snapshot)     │ │
│  │                               │ │
│  │  Claude Code (pre-installed)  │ │
│  │  --dangerously-skip-perms     │ │
│  │  /workspace ← virtiofs mount  │ │
│  │  Dev tools, runtimes, etc.    │ │
│  └────────────────────────────────┘ │
└─────────────────────────────────────┘
```

## Core Workflow

1. **First run (ever):** Build base image → provision with Ansible → take base snapshot
2. **First run (per project):** Create linked snapshot from base → launch VM with virtiofs mount of `$PWD`
3. **Subsequent runs (same project):** Resume existing linked snapshot → mount `$PWD`
4. **Reset:** Delete linked snapshot, next run creates a fresh one from base

## Snapshot Strategy

- **Base snapshot:** Golden image with OS + Claude Code + dev tools. Built once, updated occasionally.
- **Linked snapshots:** QEMU qcow2 backing file chains. Each project gets `~/.claude-vm/snapshots/<project-hash>.qcow2` backed by the base image. Copy-on-write means only deltas use disk space.

## Provisioning (Base Image)

Using **Ansible** for provisioning the base image:

- Base OS (Ubuntu/Debian minimal cloud image)
- Claude Code (npm install)
- Common dev tools: git, build-essential, python3, node, rust, etc.
- Shell config, SSH keys, Claude auth tokens (mounted or injected at runtime)
- Optional: user-defined Ansible playbook for custom tools

Alternative: **Packer** to build the qcow2 image directly with Ansible as a provisioner. This separates "build base image" from "run VM" cleanly.

## CLI Interface

```bash
# Run Claude Code in current project directory
claude-vm

# Build/rebuild the base image
claude-vm build [--from-scratch] [--playbook custom.yml]

# List project snapshots
claude-vm list

# Reset a project's snapshot (fresh clone from base)
claude-vm reset [project-dir]

# Destroy everything (base + all snapshots)
claude-vm destroy

# SSH into a running VM (for debugging)
claude-vm ssh

# Update Claude Code in the base image
claude-vm update
```

## virtiofs Configuration

- Host runs `virtiofsd` pointing at `$PWD`
- QEMU launched with `-chardev socket` + `-device vhost-user-fs-pci`
- Guest auto-mounts at `/workspace`
- Memory backing: `memory-backend-memfd` with `share=on` (required for virtiofs)

## Key Implementation Decisions

| Decision | Choice | Rationale |
|---|---|---|
| VM management | Direct QEMU (no libvirt) | Fewer dependencies, simpler for a single-purpose tool |
| Provisioning | Ansible (or Packer+Ansible) | Well-known, declarative, easy to extend |
| Host ↔ Guest fs | virtiofs | Near-native perf, better than 9p/sshfs |
| Terminal access | SSH (fallback: serial console) | Familiar, supports tmux/screen |
| Auth/credentials | Mount `~/.claude/` read-only or inject via env | Don't bake secrets into base image |
| Platform | Linux only (MVP) | QEMU+KVM+virtiofs is first-class on Linux |
| Language | Bash or Rust | Bash for MVP speed, Rust if it grows |

## MVP Scope

- [ ] Base image build via Ansible (Ubuntu + Claude Code + basic dev tools)
- [ ] QEMU launch with virtiofs mount of working directory
- [ ] Linked snapshot creation per project directory
- [ ] `claude-vm` / `claude-vm build` / `claude-vm reset` commands
- [ ] SSH into guest with Claude Code auto-started
- [ ] Credential forwarding (Claude auth, Git config)

## Post-MVP

- Packer-based image builds for reproducibility
- Custom Ansible playbooks per project (`.claude-vm.yml` in project root)
- Snapshot pinning (save a known-good project state)
- Resource limits config (CPU, RAM per project)
- Network policy (restrict outbound, proxy config)
- macOS support (Hypervisor.framework backend — stretch goal)
- Multi-VM / parallel Claude sessions

## Open Questions

- **Bash or Rust for the CLI?** Bash is faster to prototype, Rust is more robust for QEMU process management and error handling.
- **Direct QEMU vs libvirt?** Direct QEMU is simpler but libvirt gives you virsh snapshots, network management for free. Worth spiking on both.
- **How to handle Claude auth?** Mount `~/.claude/` read-only? Inject `ANTHROPIC_API_KEY` as env var? Both?
- **Project identity:** Hash of absolute path? Or let user name projects?