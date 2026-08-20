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
claude-vm -- --model sonnet         # Pass extra args to claude
```

### `claude-vm build`

Build or rebuild the base image.

```bash
claude-vm build                        # Build base image (skips if exists)
claude-vm build --force                # Rebuild from scratch
claude-vm build --flavor ubuntu-slim   # Build with a specific flavor
```

| Flag | Description |
|-|-|
| `--force`, `--from-scratch` | Delete existing base image and rebuild |
| `--flavor NAME` | Override flavor for this build (`<distro>-slim` or `<distro>-full`; bare distro names alias to `-full`) |

Each flavor builds into its own base image (`~/.claude-vm/base/base-<flavor>.qcow2`), so building a second flavor doesn't replace the first.

The downloaded cloud image is verified against the upstream checksum file (SHA512 for Debian, SHA256 for the others) before provisioning. On mismatch the image is deleted and the build fails. If the checksum file can't be fetched, verification is skipped with a warning.

### `claude-vm launch`

Launch a sandbox for a specific directory.

```bash
claude-vm launch /path/to/project
claude-vm launch /path/to/project -- --model sonnet   # With extra claude args
```

### `claude-vm ssh`

Open a plain shell (no Claude Code) in the running VM.

```bash
claude-vm ssh
```

The shell gets the same environment as the Claude Code launch, including `CLAUDE_CODE_PROJECT_DIR_NAME` (see below), so running `claude` by hand writes to the same transcript directory.

### Transcript directory inside the VM

Every project mounts at `/workspace`, so by default Claude Code would keep every VM's transcripts under `~/.claude/projects/-workspace`. `claude-vm` sets `CLAUDE_CODE_PROJECT_DIR_NAME` to the project's directory name (restricted to `A-Za-z0-9_-`, max 64 chars — Claude Code silently ignores anything else; `my-app` for `~/code/my-app`), so transcripts land in `~/.claude/projects/my-app` instead. `CLAUDE_CONFIG_DIR` is also set to its default `~/.claude`, because Claude Code only honors the name when a config dir is explicitly set; as a consequence the guest's global config json lives at `~/.claude/.claude.json` (the sync and rebase handle this). To override either, export the variable from `~/.env` inside the VM — it is sourced after the defaults are set. VMs created before this feature are migrated automatically on their next connect: the config json is copied to the new location and `projects/-workspace` is renamed to the project name; if the target directory already exists, entries are merged file-wise without overwriting anything (one-time and idempotent).

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

### `claude-vm rebase`

Rebuild the base image from the latest cloud image while preserving per-VM state.

```bash
claude-vm rebase                      # Interactive confirmation
claude-vm rebase --yes                # Skip confirmation prompt
claude-vm rebase --force              # Drop broken VM snapshots that can't be extracted
```

| Flag | Description |
|-|-|
| `--yes`, `-y` | Skip the confirmation prompt |
| `--force`, `-f` | Drop snapshots for VMs that fail extraction |

**What it does:**

1. Stops all running VMs
2. For each project: boots the VM headless (no virtiofs), extracts persistent state via SSH/rsync
3. Removes all project snapshots and the old base image
4. Downloads and provisions a fresh base image
5. On the next launch, each project gets a fresh snapshot from the new base, and the extracted state is restored

**State preserved:** `~/.claude/` (settings, credentials, plugins, skills, agents, commands, workflows, transcripts, plans, history), `~/.claude.json`, `~/.gitconfig`, `~/.config/gh/`, `~/.config/glab-cli/`, plus any extra paths configured via `REBASE_BACKUP_PATHS` (see below). Everything else in each VM is lost.

**State dropped on purpose:** runtime state under `~/.claude/` — `daemon/`, `jobs/`, `sessions/`, `session-env/`, `shell-snapshots/`, `paste-cache/`, `tasks/`, `telemetry/`, `cache/`, `downloads/`, `backups/`, `file-history/` and a few cache files. Carrying a stale `daemon.lock` (its PID gets reused by the fresh VM) or an old worker roster breaks Claude Code's background agents, and the caches are worthless after a rebase. The pre-flight summary lists exactly what is kept.

**Extra backup paths:** persist arbitrary guest paths through a rebase with a comma-separated list of absolute (`/etc/ssh`) or home-relative (`~/.ssh`) paths:

```bash
claude-vm config set REBASE_BACKUP_PATHS "/etc/ssh,~/.ssh"
```

Unlike the built-in set, these are synced with `sudo rsync` and keep permissions and ownership (root-owned files included). The extracted paths are recorded in a manifest inside the backup, so changing `REBASE_BACKUP_PATHS` between a rebase and the next launch doesn't affect what gets restored. Restore is an overlay (no `--delete`): backed-up files overwrite same-named files in the fresh image, but files the new image ships that aren't in the backup are untouched. Prefer narrow paths (`/etc/ssh/sshd_config`) over broad ones (`/etc`) — restoring a whole system directory wholesale over a freshly provisioned image is your responsibility. Preserving root ownership in the host-side backup uses rsync `--fake-super`, which requires user-xattr support on the filesystem holding `~/.claude-vm/backups/`.

**State restore is lazy:** extracted state sits in `~/.claude-vm/backups/<hash>/` until the project is next launched, at which point it is rsynced into the fresh VM and the backup directory is removed.

**When to use:** the base image drifts over time — new Claude Code releases, OS kernel CVEs, updated cloud images. `claude-vm rebase` is the clean way to refresh the base without losing your VM-side credentials and settings.

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

Base images:
  1.1G  ~/.claude-vm/base/base-debian-slim.qcow2
  1.6G  ~/.claude-vm/base/base-debian-full.qcow2
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

Base image: 1.1G  base-debian-slim.qcow2
```

### `claude-vm show`

Display the full QEMU launch command and SSH command for the current project. Useful for debugging, scripting, or understanding what `claude-vm` does under the hood.

```bash
claude-vm show
claude-vm show /path/to/project
```

If the VM is running, shows the actual SSH port in use. Otherwise, shows the configured base port.

Output:

```
# QEMU command
qemu-system-x86_64 \
  -name "claude-vm-abc123def456" \
  -machine "type=q35,accel=kvm" \
  -cpu host \
  -smp 2 \
  ...
  -daemonize

# SSH command
ssh -i ~/.claude-vm/keys/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p 10022 user@localhost
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
FLAVOR="debian-slim"
VM_RAM="8G"
VM_CPUS="4"
SSH_PORT_BASE="10022"
CLAUDE_ARGS="--dangerously-skip-permissions --model sonnet"
```

### Config Keys

| Key | Default | Validation | Description |
|-|-|-|-|
| `FLAVOR` | `debian-slim` | `<distro>-slim`/`<distro>-full` for debian, ubuntu, archlinux, fedora (bare names alias to `-full`) | Base image flavor |
| `VM_USER` | `$USER` | Username | Guest username (also used for SSH login) |
| `VM_RAM` | `4G` | `\d+[GMgm]` | RAM allocation |
| `VM_CPUS` | `4` (clamped to the host's core count) | Positive integer | CPU cores. Claude Code's subagent/workflow fan-out scales with the guest's `nproc`, so the default errs high; an explicit value is never clamped |
| `SSH_PORT_BASE` | `10022` | 1024-65535 | Starting SSH port |
| `BASE_IMAGE_URL` | (from flavor) | URL | Cloud image download URL |
| `BASE_IMAGE_NAME` | (from flavor) | Filename | Cloud image filename |
| `FORWARD_PORTS` | (none) | Comma-separated port specs | Extra ports to forward (per-project) |
| `CLAUDE_ARGS` | `--dangerously-skip-permissions` | Free-form string | Args passed to `claude` inside the VM |
| `REBASE_BACKUP_PATHS` | (none) | Comma-separated guest paths | Extra paths preserved through `rebase` (see the rebase section) |

### Priority

```
defaults < config file < environment variables
```

### Environment Variables

| Variable | Description |
|-|-|
| `CLAUDE_VM_DIR` | Data directory (default: `~/.claude-vm`) |
| `FLAVOR` | Override flavor |
| `VM_USER` | Override guest username |
| `VM_RAM` | Override RAM |
| `VM_CPUS` | Override CPUs |
| `SSH_PORT_BASE` | Override SSH port base |
| `BASE_IMAGE_URL` | Override cloud image URL |
| `BASE_IMAGE_NAME` | Override cloud image filename |
| `FORWARD_PORTS` | Extra port forwards (see Port Forwarding below) |
| `CLAUDE_ARGS` | Override args passed to `claude` (default: `--dangerously-skip-permissions`) |
| `REBASE_BACKUP_PATHS` | Override extra paths preserved through `rebase` |
| `CLAUDE_VM_VERBOSE` | Set to `true` to show all output (no spinner) |
| `CLAUDE_VM_QUIET` | Set to `true` to suppress the redrawing status line (one plain line per phase) |
| `CLAUDE_VM_FORCE_TTY` | Set to `true` to force the interactive single-line output without a tty (used by tests) |

## Flavors

Flavors are named `<distro>-<variant>`. The **slim** variant carries the everyday tool set (git, Node.js, Python, gh) and builds fast; **full** adds compilers and extra utilities. Bare distro names (`debian`, `ubuntu`, `archlinux`, `fedora`) alias to the `-full` variant for backward compatibility and are stored normalized.

| Flavor | Image | Package manager | Notes |
|-|-|-|-|
| `debian-slim` (default) | Debian 13 (trixie) genericcloud | apt | Minimal, no snapd |
| `debian-full` | Debian 13 (trixie) genericcloud | apt | Adds build-essential, cmake, tmux, ... |
| `ubuntu-slim` / `ubuntu-full` | Ubuntu 24.04 minimal | apt | snapd auto-removed during provisioning |
| `archlinux-slim` / `archlinux-full` | Arch Linux cloud image | pacman | Rolling release |
| `fedora-slim` / `fedora-full` | Fedora 44 Cloud Base | dnf | |

All flavors of a variant install the same tool set; package names differ per distro (e.g. `build-essential` vs `base-devel`, `gh` vs `github-cli`). Each flavor keeps its own base image (`base-<flavor>.qcow2`), so multiple flavors coexist and different projects can use different flavors.

Set the flavor:

```bash
# Via config
claude-vm config set FLAVOR archlinux-slim

# Via environment
FLAVOR=ubuntu-slim claude-vm build

# Via flag (build only)
claude-vm build --flavor fedora-full

# Bare names still work and mean the full variant
claude-vm build --flavor debian    # == debian-full
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

Everything comes from the distro's own repositories and installs in one cloud-init package transaction (no NodeSource or cli.github.com apt repos).

**Slim** (every flavor):

**Core:** git, curl, jq, ripgrep (rg), less, zip/unzip, gh (GitHub CLI), rsync

**Runtimes:** Node.js + npm (distro version), Python 3, pip, venv, Claude Code

**Full** adds:

**Build:** build-essential/base-devel/gcc + g++ + make (per distro), cmake

**Runtimes:** uv (Python package manager)

**GitLab:** glab (GitLab CLI; `~/.config/glab-cli/` is synced from the host like `gh`'s config)

**Debugging:** strace, lsof, socat, netcat, dig

**Utilities:** tmux, vim/vim-tiny, tree, xxd, file, sqlite3, bc, ping, patch, wget, gnupg

Node.js versions follow the distro: 20.x on Debian 13, 18.x on Ubuntu 24.04, current on Arch and Fedora. Claude Code also has full `sudo` access (NOPASSWD), so anything missing — including a newer Node from NodeSource or nvm — can be installed at runtime.

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
claude-vm build --flavor ubuntu-slim

# Check what's running
claude-vm status

# Fresh start for current project (keeps base image)
claude-vm reset
claude-vm

# Nuclear option: remove everything
claude-vm destroy --all

# Pass extra args to claude
claude-vm -- --model sonnet

# Override default claude args via config
claude-vm config set CLAUDE_ARGS "--dangerously-skip-permissions --model sonnet"

# Debug a launch issue
CLAUDE_VM_VERBOSE=true claude-vm
cat ~/.claude-vm/run/$(echo -n "$PWD" | sha256sum | cut -c1-12)/launch.log
```
