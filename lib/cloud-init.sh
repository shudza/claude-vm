#!/usr/bin/env bash
# Cloud-init configuration generation for base image provisioning
# This is the key to fast first-launch: cloud-init provisions the VM
# on first boot without needing Ansible overhead.

set -euo pipefail

# Generate cloud-init user-data for base image provisioning
# Dispatches to flavor-specific sections for packages and runcmd
generate_cloud_init_userdata() {
    local output_dir="$1"
    local flavor="${FLAVOR:-debian-slim}"

    # Ensure SSH keypair exists for VM access
    local key_dir="${CLAUDE_VM_DIR:-$HOME/.claude-vm}/keys"
    local key_path="$key_dir/id_ed25519"
    if [[ ! -f "$key_path" ]]; then
        mkdir -p "$key_dir"
        chmod 700 "$key_dir"
        ssh-keygen -t ed25519 -f "$key_path" -N "" -C "claude-vm" -q
        chmod 600 "$key_path"
    fi
    local pub_key
    pub_key=$(cat "${key_path}.pub")

    # Flavor-specific: packages list
    local packages_block
    packages_block="$(_cloud_init_packages "$flavor")"

    # Flavor-specific: package manager tuning (written before packages install)
    local pkg_tuning_files
    pkg_tuning_files="$(_cloud_init_pkg_tuning_files "$flavor")"

    # Flavor-specific: extra early boot commands (run before the package stage)
    local bootcmd_extra
    bootcmd_extra="$(_cloud_init_bootcmd_extra "$flavor")"

    # Installer prefetch script (uv included on full flavors only)
    local prefetch_file
    prefetch_file="$(_cloud_init_prefetch_file "$flavor")"

    # Inline uv fallback line (full flavors only)
    local uv_fallback=""
    if [[ "$(flavor_variant "$flavor")" == "full" ]]; then
        uv_fallback="  - test -f /run/claude-vm-prefetch-ok || sudo -u $VM_USER bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'"
    fi

    local cleanup_runcmd
    cleanup_runcmd="$(_cloud_init_cleanup_runcmd "$flavor")"

    # SSH service name differs
    local ssh_service
    ssh_service="$(_cloud_init_ssh_service "$flavor")"

    cat > "$output_dir/user-data" << USERDATA
#cloud-config
# claude-vm base image provisioning (flavor: $flavor)

hostname: claude-vm

# Sync package DB before installing (needed for pacman/dnf; harmless for apt)
package_update: true
package_upgrade: false

# The prefetch launcher detaches a waiter that execs the prefetch script the
# moment write_files lands it — overlapping the uv + Claude Code downloads
# with the package phase (the two dominant network-bound build phases)
bootcmd:
  - [sh, -c, "setsid sh -c 'i=0; while [ ! -x /usr/local/sbin/claude-vm-prefetch ] && [ \$i -lt 60 ]; do sleep 1; i=\$((i+1)); done; exec /usr/local/sbin/claude-vm-prefetch $VM_USER' >/var/log/claude-vm-prefetch.log 2>&1 </dev/null &"]
$bootcmd_extra

users:
  - name: $VM_USER
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    # Password: claude (for emergency console access)
    passwd: \$6\$rounds=4096\$saltsalt\$ZKMEXv3MnQXpWLGfKsHrOjfFjCGPQY0fAXlxqYFwC.dqI6/dR7bEvFRNABpiRPfOJYCkLKOGnSq1EFqLm9ER1
    ssh_authorized_keys:
      - $pub_key

$packages_block

write_files:
$pkg_tuning_files
$prefetch_file
  - path: /etc/ssh/sshd_config.d/claude-vm.conf
    content: |
      PermitRootLogin no
      PasswordAuthentication yes
      PubkeyAuthentication yes
      UseDNS no
      GSSAPIAuthentication no
      MaxSessions 64
      MaxStartups 64:30:128
      AcceptEnv LANG LC_*
    permissions: '0644'
  - path: /home/$VM_USER/.bashrc
    content: |
      export PATH="\$HOME/.local/bin:\$PATH"
      [ -z "\$COLORTERM" ] && export COLORTERM=truecolor
      if [ -d /workspace ]; then
        cd /workspace 2>/dev/null
      fi
    permissions: '0644'
    defer: true
  - path: /etc/modules-load.d/virtiofs.conf
    content: |
      virtiofs
    permissions: '0644'
  - path: /etc/systemd/system/workspace.mount
    content: |
      [Unit]
      Description=Virtiofs workspace mount
      After=local-fs.target
      ConditionPathExists=/workspace

      [Mount]
      What=workspace
      Where=/workspace
      Type=virtiofs
      Options=defaults,nofail

      [Install]
      WantedBy=multi-user.target
    permissions: '0644'
  - path: /etc/systemd/system/workspace-chown.service
    content: |
      [Unit]
      Description=Set ownership of /workspace to $VM_USER user
      After=workspace.mount
      Requires=workspace.mount

      [Service]
      Type=oneshot
      ExecStart=/bin/chown $VM_USER:$VM_USER /workspace
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
    permissions: '0644'

runcmd:
  # Workspace mount point
  - mkdir -p /workspace
  - grep -q 'virtiofs' /etc/fstab || echo 'workspace /workspace virtiofs defaults,nofail 0 0' >> /etc/fstab
  - chown $VM_USER:$VM_USER /workspace
  # Fix ownership of deferred write_files
  - chown -R $VM_USER:$VM_USER /home/$VM_USER/.bashrc /home/$VM_USER/.ssh
  # Claude Code (plus uv on full) installs in the background from bootcmd —
  # wait for the prefetch, then fall back to inline installs if it didn't
  # complete
  - timeout 300 sh -c 'while [ ! -f /run/claude-vm-prefetch-done ]; do sleep 1; done' || true
$uv_fallback
  - test -f /run/claude-vm-prefetch-ok || sudo -u $VM_USER bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
  - cat /var/log/claude-vm-prefetch.log || true
  # Enable virtiofs workspace mount
  - systemctl daemon-reload
  - systemctl enable workspace.mount
  - systemctl enable workspace-chown.service
  - systemctl start workspace.mount || true
  - systemctl start workspace-chown.service || true
  # SSH
  - ssh-keygen -A
  - systemctl enable $ssh_service
  - systemctl start $ssh_service
  # Done
  - echo "claude-vm-ready" > /dev/console
  - touch /var/lib/cloud/instance/claude-vm-ready
  # Cleanup (flavor-specific)
$cleanup_runcmd
  # Disable cloud-init on subsequent boots (provisioning is done)
  - touch /etc/cloud/cloud-init.disabled

power_state:
  mode: poweroff
  message: "claude-vm base image provisioning complete"
  timeout: 30
  condition: true

USERDATA
}

# ── Flavor-specific helpers ──────────────────────────────────────────────────

# Emit the packages: block for a flavor. Everything installs in the single
# cloud-init package transaction — nodejs/npm/gh come from the distro repos,
# so no extra apt sources or index refreshes are needed. Slim is the base
# set; full appends build tools and extra utilities.
_cloud_init_packages() {
    local flavor="$1"
    local distro variant
    distro="$(flavor_distro "$flavor")"
    variant="$(flavor_variant "$flavor")"

    case "$distro" in
        debian|ubuntu)
            cat << 'PKG'
packages:
  # Infrastructure (SSH access, config sync, installer downloads)
  - openssh-server
  - rsync
  - curl
  - ca-certificates
  # Core (Claude Code depends on these; less = git's pager with recommends off)
  - git
  - jq
  - ripgrep
  - less
  - zip
  - unzip
  # Runtimes + GitHub CLI (distro repos)
  - gh
  - nodejs
  - npm
  - python3
  - python3-pip
  - python3-venv
PKG
            ;;
        archlinux)
            cat << 'PKG'
packages:
  # Infrastructure (SSH access, config sync, installer downloads)
  - openssh
  - rsync
  - curl
  - ca-certificates
  # Core (Claude Code depends on these; less = git's pager)
  - git
  - jq
  - ripgrep
  - less
  - zip
  - unzip
  # Runtimes + GitHub CLI (distro repos)
  - github-cli
  - nodejs
  - npm
  - python
  - python-pip
PKG
            ;;
        fedora)
            cat << 'PKG'
packages:
  # Infrastructure (SSH access, config sync, installer downloads)
  - openssh-server
  - rsync
  - curl
  - ca-certificates
  # Core (Claude Code depends on these; less = git's pager with weak deps off)
  - git
  - jq
  - ripgrep
  - less
  - zip
  - unzip
  # Runtimes + GitHub CLI (distro repos; npm resolves to nodejs-npm)
  - gh
  - nodejs
  - npm
  - python3
  - python3-pip
PKG
            ;;
        *)
            echo "ERROR: unknown flavor '$flavor' in _cloud_init_packages" >&2
            return 1
            ;;
    esac

    [[ "$variant" == "full" ]] || return 0

    case "$distro" in
        debian)
            cat << 'PKG'
  # Build tools (native npm modules, compilation)
  - build-essential
  - cmake
  # Tools Claude reaches for in bash
  - xxd
  - file
  - sqlite3
  - bc
  - strace
  - lsof
  - dnsutils
  - netcat-openbsd
  - iputils-ping
  - socat
  - patch
  # Utilities
  - tmux
  - vim-tiny
  - tree
  - wget
  - gnupg
PKG
            ;;
        ubuntu)
            cat << 'PKG'
  # Build tools (native npm modules, compilation)
  - build-essential
  - cmake
  # Tools Claude reaches for in bash
  - xxd
  - file
  - sqlite3
  - bc
  - strace
  - lsof
  - dnsutils
  - netcat-openbsd
  - iputils-ping
  - socat
  - patch
  # Utilities
  - tmux
  - vim
  - tree
  - wget
  - gnupg
PKG
            ;;
        archlinux)
            cat << 'PKG'
  # Build tools (native npm modules, compilation)
  - base-devel
  - cmake
  # Tools Claude reaches for in bash
  - vim
  - file
  - sqlite
  - bc
  - strace
  - lsof
  - bind-tools
  - openbsd-netcat
  - iputils
  - socat
  - patch
  # Utilities
  - tmux
  - tree
  - wget
  - gnupg
PKG
            ;;
        fedora)
            cat << 'PKG'
  # Build tools (native npm modules, compilation)
  - gcc
  - gcc-c++
  - make
  - cmake
  # Tools Claude reaches for in bash
  - vim-minimal
  - file
  - sqlite
  - bc
  - strace
  - lsof
  - bind-utils
  - nmap-ncat
  - iputils
  - socat
  - patch
  # Utilities
  - tmux
  - tree
  - wget
  - gnupg2
PKG
            ;;
    esac
}

# Extra bootcmd items appended after the prefetch launcher, run in the init
# stage before package_update fetches indexes. The Debian cloud image ships
# deb822 sources with deb-src enabled; dropping the Sources indexes roughly
# halves the apt index download.
_cloud_init_bootcmd_extra() {
    local flavor="$1"
    case "$(flavor_distro "$flavor")" in
        debian|ubuntu)
            cat << 'BOOT'
  - [sh, -c, "sed -i 's/^Types: deb deb-src$/Types: deb/' /etc/apt/sources.list.d/*.sources 2>/dev/null || true"]
BOOT
            ;;
        archlinux|fedora)
            ;;
        *)
            echo "ERROR: unknown flavor '$flavor' in _cloud_init_bootcmd_extra" >&2
            return 1
            ;;
    esac
}

# The installer prefetch script, written via write_files and launched from
# bootcmd. It waits for its preconditions (user created, network up, curl and
# sudo present — on images without curl the package transaction provides it),
# then installs Claude Code (plus uv on full flavors) while cloud-init's
# package phase is still working. Both installers are plain downloads into
# ~/.local and never touch the package manager, so they cannot contend with
# the package transaction. runcmd waits on the -done marker and reruns the
# installers inline unless -ok is present (both are idempotent).
_cloud_init_prefetch_file() {
    local flavor="$1"
    cat << 'PREFETCH'
  - path: /usr/local/sbin/claude-vm-prefetch
    permissions: '0755'
    content: |
      #!/bin/sh
      user="$1"
      deadline=$(( $(date +%s) + 240 ))
      while :; do
          if id "$user" >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 \
             && curl -fsm 3 -o /dev/null https://claude.ai/install.sh 2>/dev/null; then
              break
          fi
          if [ "$(date +%s)" -ge "$deadline" ]; then
              echo "prefetch: preconditions not met before deadline, deferring to runcmd"
              touch /run/claude-vm-prefetch-done
              exit 0
          fi
          sleep 1
      done
PREFETCH
    if [[ "$(flavor_variant "$flavor")" == "full" ]]; then
        cat << 'PREFETCH'
      sudo -u "$user" sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' \
          && sudo -u "$user" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' \
          && touch /run/claude-vm-prefetch-ok
      touch /run/claude-vm-prefetch-done
PREFETCH
    else
        cat << 'PREFETCH'
      sudo -u "$user" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' \
          && touch /run/claude-vm-prefetch-ok
      touch /run/claude-vm-prefetch-done
PREFETCH
    fi
}

# Package manager tuning written before the package transaction runs
# (cloud-init processes write_files in the init stage, packages in the config
# stage, so these are active for the whole install). Skips docs/man pages and
# recommended/weak dependencies to cut download and install time.
_cloud_init_pkg_tuning_files() {
    local flavor="$1"
    case "$(flavor_distro "$flavor")" in
        debian|ubuntu)
            cat << 'TUNING'
  - path: /etc/dpkg/dpkg.cfg.d/claude-vm
    content: |
      force-unsafe-io
      path-exclude=/usr/share/man/*
      path-exclude=/usr/share/doc/*
      path-include=/usr/share/doc/*/copyright
    permissions: '0644'
  - path: /etc/apt/apt.conf.d/99claude-vm
    content: |
      APT::Install-Recommends "false";
      APT::Install-Suggests "false";
      Acquire::Languages "none";
    permissions: '0644'
TUNING
            ;;
        archlinux)
            ;;
        fedora)
            cat << 'TUNING'
  - path: /etc/dnf/dnf.conf
    content: |
      install_weak_deps=False
      tsflags=nodocs
    append: true
TUNING
            ;;
        *)
            echo "ERROR: unknown flavor '$flavor' in _cloud_init_pkg_tuning_files" >&2
            return 1
            ;;
    esac
}

_cloud_init_cleanup_runcmd() {
    local flavor="$1"
    case "$(flavor_distro "$flavor")" in
        debian)
            cat << 'CMD'
  # Disable background services that bloat snapshots and waste CPU
  - systemctl disable --now unattended-upgrades.service || true
  - systemctl disable --now apt-daily.timer apt-daily-upgrade.timer || true
  - systemctl disable --now man-db.timer || true
  - systemctl disable --now e2scrub_all.timer || true
  - systemctl disable --now dpkg-db-backup.timer || true
  - apt-get purge -y --auto-remove unattended-upgrades || true
  - apt-get clean
  - rm -rf /var/lib/apt/lists/*
  - journalctl --vacuum-size=8M || true
CMD
            ;;
        ubuntu)
            cat << 'CMD'
  - apt-get purge -y --auto-remove snapd || true
  - rm -rf /var/cache/snapd /snap
  # Disable background services that bloat snapshots and waste CPU
  - systemctl disable --now unattended-upgrades.service || true
  - systemctl disable --now apt-daily.timer apt-daily-upgrade.timer || true
  - systemctl disable --now man-db.timer || true
  - systemctl disable --now e2scrub_all.timer || true
  - systemctl disable --now dpkg-db-backup.timer || true
  - apt-get purge -y --auto-remove unattended-upgrades || true
  - apt-get clean
  - rm -rf /var/lib/apt/lists/*
  - journalctl --vacuum-size=8M || true
CMD
            ;;
        archlinux)
            cat << 'CMD'
  # Clean package cache
  - pacman -Scc --noconfirm || true
  - journalctl --vacuum-size=8M || true
CMD
            ;;
        fedora)
            cat << 'CMD'
  # Disable background services that bloat snapshots and waste CPU
  - systemctl disable --now dnf-makecache.timer || true
  - dnf clean all
  - journalctl --vacuum-size=8M || true
CMD
            ;;
        *)
            echo "ERROR: unknown flavor '$flavor' in _cloud_init_cleanup_runcmd" >&2
            return 1
            ;;
    esac
}

_cloud_init_ssh_service() {
    local flavor="$1"
    case "$(flavor_distro "$flavor")" in
        debian) echo "ssh" ;;
        ubuntu) echo "ssh" ;;
        archlinux) echo "sshd" ;;
        fedora) echo "sshd" ;;
        *)
            echo "ERROR: unknown flavor '$flavor' in _cloud_init_ssh_service" >&2
            return 1
            ;;
    esac
}

# Generate cloud-init meta-data
generate_cloud_init_metadata() {
    local output_dir="$1"
    cat > "$output_dir/meta-data" << 'METADATA'
instance-id: claude-vm-base
local-hostname: claude-vm
METADATA
}

# Generate cloud-init network-config
generate_cloud_init_network() {
    local output_dir="$1"
    cat > "$output_dir/network-config" << 'NETCONFIG'
version: 2
ethernets:
  enp0s2:
    dhcp4: true
NETCONFIG
}

# Create the cloud-init ISO (NoCloud datasource)
create_cloud_init_iso() {
    local output_dir="$1"
    local iso_path="$2"

    generate_cloud_init_userdata "$output_dir"
    generate_cloud_init_metadata "$output_dir"
    generate_cloud_init_network "$output_dir"

    # Create ISO with cloud-init data
    if command -v genisoimage &>/dev/null; then
        genisoimage -output "$iso_path" -volid cidata -joliet -rock \
            "$output_dir/user-data" \
            "$output_dir/meta-data" \
            "$output_dir/network-config" 2>/dev/null
    elif command -v mkisofs &>/dev/null; then
        mkisofs -output "$iso_path" -volid cidata -joliet -rock \
            "$output_dir/user-data" \
            "$output_dir/meta-data" \
            "$output_dir/network-config" 2>/dev/null
    elif command -v xorrisofs &>/dev/null; then
        xorrisofs -output "$iso_path" -volid cidata -joliet -rock \
            "$output_dir/user-data" \
            "$output_dir/meta-data" \
            "$output_dir/network-config" 2>/dev/null
    else
        echo "ERROR: No ISO creation tool found. Install genisoimage, mkisofs, or xorrisofs." >&2
        return 1
    fi
}
