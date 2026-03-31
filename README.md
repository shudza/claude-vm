# claude-vm

QEMU sandbox for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Run Claude Code with full permissions in an isolated VM, with near-native filesystem performance via virtiofs.

```
$ claude-vm
  ✓ Setting up filesystem sharing
  ✓ Starting VM
  ✓ Waiting for VM to boot
  ✓ Mounting workspace
  ✓ Syncing config

  Ready in 12s — my-project

╭──────────────────────────────────────╮
│ Claude Code                          │
│ /workspace (virtiofs)                │
╰──────────────────────────────────────╯
```

## Why

Claude Code works best with `--dangerously-skip-permissions`, but running an AI agent with unrestricted access to your host is a reasonable concern. claude-vm gives Claude Code a full Linux environment with sudo, network access, and every tool it needs -- inside a VM that can't touch your host filesystem outside the project directory.

- **Isolated**: QEMU VM with KVM acceleration. Claude Code can `rm -rf /` and your host is fine.
- **Fast**: virtiofs gives near-native filesystem performance. No copying files in or out.
- **Lightweight**: Linked QCOW2 snapshots share a base image. Each project adds only its delta (~200KB initially).
- **Multi-instance**: Run multiple Claude Code sessions in the same project VM simultaneously.
- **Batteries included**: Git identity, GitHub CLI auth, and Claude Code config are synced automatically.

## Requirements

- Linux with KVM support (`/dev/kvm` accessible)
- QEMU (`qemu-system-x86_64`, `qemu-img`)
- virtiofsd
- An ISO creation tool (`genisoimage`, `mkisofs`, or `xorrisofs`)
- curl, rsync

### Install dependencies

**Arch / CachyOS:**
```bash
sudo pacman -S qemu-full virtiofsd cdrtools curl rsync
```

**Ubuntu / Debian:**
```bash
sudo apt install qemu-system-x86 qemu-utils virtiofsd genisoimage curl rsync
```

## Install

```bash
git clone https://github.com/anthropics/claude-vm.git
sudo ln -s "$(pwd)/claude-vm/claude-vm" /usr/local/bin/claude-vm
```

## Quick Start

```bash
cd ~/my-project
claude-vm
```

First run builds a base image (~90s), creates a project snapshot, and launches the VM. Subsequent runs resume in seconds.

## Commands

| Command | Description |
|-|-|
| `claude-vm` | Launch sandbox and enter Claude Code |
| `claude-vm build [--flavor X]` | Build (or rebuild) the base image |
| `claude-vm ssh` | Shell into the running VM |
| `claude-vm stop` | Stop the VM (preserves snapshot) |
| `claude-vm reset` | Reset project snapshot to fresh state |
| `claude-vm destroy` | Remove all artifacts for this project |
| `claude-vm list` | List all project snapshots |
| `claude-vm status` | Show current project status |
| `claude-vm config` | Show/set configuration |
| `claude-vm help` | Show help |

See [docs/usage.md](docs/usage.md) for the full reference with all flags and examples.

## Configuration

```bash
claude-vm config set VM_RAM 8G
claude-vm config set VM_CPUS 4
claude-vm config set FLAVOR debian
```

Or edit directly:

```bash
# ~/.claude-vm/config
FLAVOR="debian"
VM_RAM="8G"
VM_CPUS="4"
```

Environment variables override config: `VM_RAM=16G claude-vm`

## Flavors

| Flavor | Base Image | Notes |
|-|-|-|
| `debian` (default) | Debian 12 genericcloud | Minimal, no snapd |
| `ubuntu` | Ubuntu 24.04 minimal | snapd auto-removed |

```bash
claude-vm build --flavor ubuntu
```

## How It Works

1. **Base image** is built once: cloud image + cloud-init provisions Claude Code, dev tools, and SSH
2. **Linked snapshots** (QCOW2 copy-on-write) give each project its own VM state backed by the shared base
3. **virtiofs** mounts your project directory into the VM at `/workspace` with near-native I/O
4. **Config sync** (rsync) copies your Claude Code settings, git identity, and gh auth into the VM
5. **SSH** connects your terminal to Claude Code running inside the VM

See [docs/architecture.md](docs/architecture.md) for the full design.

## Pre-installed Tools

The base image includes everything Claude Code commonly reaches for:

**Core:** git, ripgrep, gh (GitHub CLI), curl, wget, jq

**Build:** gcc, g++, make, cmake

**Runtimes:** Node.js 22, Python 3 (with pip and venv)

**Debug:** strace, lsof, socat, netcat, dig

**Utilities:** tmux, vim, xxd, sqlite3, bc, ping, tree, rsync, file, patch, unzip

Claude Code has full sudo access to install anything else at runtime.

## Multiple Instances

Open multiple terminals in the same project directory and run `claude-vm` in each. Each gets its own Claude Code session sharing the same VM and `/workspace` mount.

## Troubleshooting

**See full launch output:**
```bash
CLAUDE_VM_VERBOSE=true claude-vm
```

**Check logs:**
```bash
cat ~/.claude-vm/run/$(echo -n "$PWD" | sha256sum | cut -c1-12)/launch.log
```

**KVM not available:**
claude-vm falls back to TCG (software emulation) but it will be significantly slower. Ensure your user has access to `/dev/kvm`:
```bash
sudo usermod -aG kvm $USER
```

**Fresh start for a project:**
```bash
claude-vm reset   # Deletes snapshot, next launch creates a fresh one
```

**Fresh start for everything:**
```bash
claude-vm destroy --all   # Removes base image + all snapshots
```

## Contributing

See [docs/contributing.md](docs/contributing.md) for conventions, project structure, and how to add new commands or flavors.

## License

MIT
