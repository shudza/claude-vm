# Usage

## Quick Start

```bash
# First time: builds base image, creates project snapshot, launches VM
claude-vm

# Subsequent runs: resumes existing snapshot, attaches Claude Code
claude-vm
```

## Commands

### `claude-vm` (default)

Launch a sandbox for the current directory and drop into Claude Code.

If the VM is already running, attaches a new Claude Code instance to the existing VM.

```bash
claude-vm
```

### `claude-vm build`

Build or rebuild the base image.

```bash
claude-vm build                   # Build base image (skips if exists)
claude-vm build --force           # Rebuild from scratch
claude-vm build --flavor ubuntu   # Build with a specific flavor
```

| Flag | Description |
|-|-|
| `--force`, `--from-scratch` | Delete existing base image and rebuild |
| `--flavor NAME` | Override flavor for this build (debian, ubuntu) |

### `claude-vm launch`

Launch a sandbox for a specific directory.

```bash
claude-vm launch /path/to/project
```

### `claude-vm ssh`

Open a plain shell (no Claude Code) in the running VM.

```bash
claude-vm ssh
```

### `claude-vm stop`

Stop the VM gracefully. Preserves the project snapshot on disk.

```bash
claude-vm stop                    # Stop current project's VM
claude-vm stop --all              # Stop all running VMs
```

| Flag | Description |
|-|-|
| `--all` | Stop all running claude-vm instances across all projects |

### `claude-vm reset`

Delete the project snapshot. Next launch creates a fresh one from the base image.

```bash
claude-vm reset
```

### `claude-vm destroy`

Remove all sandbox artifacts for the current project.

```bash
claude-vm destroy                 # Current project only
claude-vm destroy --all           # ALL claude-vm data (base + all snapshots)
claude-vm destroy --all --force   # Skip confirmation prompt
claude-vm destroy /path/to/project
```

| Flag | Description |
|-|-|
| `--all` | Remove everything: base image, all snapshots, all run data |
| `--force`, `-f` | Skip the confirmation prompt (with `--all`) |

### `claude-vm list`

List all project snapshots with their directory paths and running status.

```bash
claude-vm list
```

Output:

```
Project snapshots:

  /home/user/my-project
    abc123def456  196K  [RUNNING]
  /home/user/other-project
    789abc012def  4.2M  [stopped]

Base image:
  1.5G  ~/.claude-vm/base/base.qcow2
```

### `claude-vm status`

Show status of the current project's sandbox.

```bash
claude-vm status
```

Output:

```
Project: /home/user/my-project
Hash: abc123def456

Snapshot: ~/.claude-vm/snapshots/abc123def456.qcow2 (196K)
Status: RUNNING (PID: 12345, SSH port: 10022)
Claude Code instances: 3

Base image: 1.5G
```

### `claude-vm config`

Manage configuration.

```bash
claude-vm config                  # Show effective configuration
claude-vm config show             # Same as above
claude-vm config set VM_RAM 8G    # Set a value
claude-vm config set VM_RAM=8G    # Alternative syntax
claude-vm config get VM_RAM       # Get a value
claude-vm config edit             # Open config file in $EDITOR
```

## Configuration

### Config File

Location: `~/.claude-vm/config` (sourced as bash)

```bash
# Example ~/.claude-vm/config
FLAVOR="debian"
VM_RAM="8G"
VM_CPUS="4"
SSH_PORT_BASE="10022"
```

### Config Keys

| Key | Default | Validation | Description |
|-|-|-|-|
| `FLAVOR` | `debian` | debian, ubuntu | Base image flavor |
| `VM_RAM` | `4G` | `\d+[GMgm]` | RAM allocation |
| `VM_CPUS` | `2` | Positive integer | CPU cores |
| `SSH_PORT_BASE` | `10022` | 1024-65535 | Starting SSH port |
| `BASE_IMAGE_URL` | (from flavor) | URL | Cloud image download URL |
| `BASE_IMAGE_NAME` | (from flavor) | Filename | Cloud image filename |
| `FORWARD_PORTS` | (none) | Comma-separated port specs | Extra ports to forward (per-project) |

### Priority

```
defaults < config file < environment variables
```

### Environment Variables

| Variable | Description |
|-|-|
| `CLAUDE_VM_DIR` | Data directory (default: `~/.claude-vm`) |
| `FLAVOR` | Override flavor |
| `VM_RAM` | Override RAM |
| `VM_CPUS` | Override CPUs |
| `SSH_PORT_BASE` | Override SSH port base |
| `BASE_IMAGE_URL` | Override cloud image URL |
| `BASE_IMAGE_NAME` | Override cloud image filename |
| `FORWARD_PORTS` | Extra port forwards (see Port Forwarding below) |
| `CLAUDE_VM_VERBOSE` | Set to `true` to show all output (no spinner) |
| `CLAUDE_VM_QUIET` | Set to `true` to suppress spinner |

## Flavors

| Flavor | Image | Notes |
|-|-|-|
| `debian` (default) | Debian 12 genericcloud | Minimal |
| `ubuntu` | Ubuntu 24.04 minimal | snapd auto-removed during provisioning |

Both flavors install the same tool set. Debian uses `vim-tiny` instead of full `vim`.

Set the flavor:

```bash
# Via config
claude-vm config set FLAVOR debian

# Via environment
FLAVOR=ubuntu claude-vm build

# Via flag (build only)
claude-vm build --flavor ubuntu
```

## Multiple Instances

Run multiple Claude Code instances in the same project VM:

```bash
# Terminal 1
claude-vm

# Terminal 2 (same directory)
claude-vm

# Terminal 3
claude-vm
```

Each invocation detects the running VM and attaches a new Claude Code session via SSH. The guest sshd supports up to 64 concurrent sessions.

## Pre-installed Tools

The base image includes tools Claude Code commonly uses:

**Core:** git, curl, wget, jq, ripgrep (rg), gh (GitHub CLI)

**Build:** gcc, g++, make, cmake

**Runtimes:** Node.js 22, Python 3, pip, venv

**Debugging:** strace, lsof, socat, netcat, dnsutils (dig)

**Utilities:** tmux, vim/vim-tiny, tree, xxd, file, sqlite3, bc, ping, rsync, unzip, patch

Claude Code also has full `sudo` access (NOPASSWD) to install additional packages at runtime.

## Logs

All launch and shutdown output is captured to log files:

```bash
# Launch log
~/.claude-vm/run/<hash>/launch.log

# Shutdown log
~/.claude-vm/run/<hash>/shutdown.log

# VM serial console
~/.claude-vm/run/<hash>/serial.log

# virtiofsd daemon log
~/.claude-vm/run/<hash>/virtiofsd.log
```

To see full output during launch/stop, use verbose mode:

```bash
CLAUDE_VM_VERBOSE=true claude-vm
```

## Port Forwarding

Forward additional ports from the VM to the host using `FORWARD_PORTS`. SSH (port 22) is always forwarded automatically.

Port forwards are **per-project** — each project directory can have its own set of forwarded ports. This prevents collisions when running multiple VMs simultaneously.

### Port Spec Formats

| Format | Example | Description |
|-|-|-|
| `PORT` | `8080` | Forward host:8080 → guest:8080 |
| `HOST:GUEST` | `8080:3000` | Forward host:8080 → guest:3000 |
| `START-END` | `9000-9005` | Forward a range 1:1 (6 ports) |
| `HSTART-HEND:GSTART-GEND` | `8080-8082:3000-3002` | Mapped range (must be equal length) |

Multiple specs are comma-separated. Ranges are capped at 100 ports.

### Examples

```bash
# Forward port 8080 for the current project
claude-vm config set FORWARD_PORTS 8080

# Forward multiple ports (dev server + API)
claude-vm config set FORWARD_PORTS "3000,8080:8080"

# Forward a range of ports
claude-vm config set FORWARD_PORTS "9000-9005"

# Clear port forwards for current project
claude-vm config set FORWARD_PORTS ""

# Environment variable override (applies to this launch only)
FORWARD_PORTS="8080,3000" claude-vm
```

## Examples

```bash
# Launch with more resources
VM_RAM=16G VM_CPUS=8 claude-vm

# Build Ubuntu flavor
claude-vm build --flavor ubuntu

# Check what's running
claude-vm status

# Fresh start for current project (keeps base image)
claude-vm reset
claude-vm

# Nuclear option: remove everything
claude-vm destroy --all

# Debug a launch issue
CLAUDE_VM_VERBOSE=true claude-vm
cat ~/.claude-vm/run/$(echo -n "$PWD" | sha256sum | cut -c1-12)/launch.log
```
