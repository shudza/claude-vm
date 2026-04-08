#!/usr/bin/env bash
# Cloud-init configuration generation for base image provisioning
# This is the key to fast first-launch: cloud-init provisions the VM
# on first boot without needing Ansible overhead.

set -euo pipefail

# Generate cloud-init user-data for base image provisioning
# Dispatches to flavor-specific sections for packages and runcmd
generate_cloud_init_userdata() {
    local output_dir="$1"
    local flavor="${FLAVOR:-debian}"

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

    # Flavor-specific: runcmd for Node.js, gh, and cleanup
    local nodejs_runcmd
    nodejs_runcmd="$(_cloud_init_nodejs_runcmd "$flavor")"

    local gh_runcmd
    gh_runcmd="$(_cloud_init_gh_runcmd "$flavor")"

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
  # Install Node.js (flavor-specific)
$nodejs_runcmd
  # Install GitHub CLI (flavor-specific)
$gh_runcmd
  # Install uv (Python package manager)
  - sudo -u $VM_USER bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  # Install Claude Code (native installer, no npm needed)
  - sudo -u $VM_USER bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
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

_cloud_init_packages() {
    local flavor="$1"
    case "$flavor" in
        debian)
            cat << 'PKG'
packages:
  # Core (Claude Code depends on these)
  - openssh-server
  - git
  - curl
  - wget
  - jq
  - ripgrep
  # Build tools (native npm modules, compilation)
  - build-essential
  - cmake
  # Runtimes
  - python3
  - python3-pip
  - python3-venv
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
  - unzip
  - rsync
  - ca-certificates
  - gnupg
PKG
            ;;
        ubuntu)
            cat << 'PKG'
packages:
  # Core (Claude Code depends on these)
  - openssh-server
  - git
  - curl
  - wget
  - jq
  - ripgrep
  # Build tools (native npm modules, compilation)
  - build-essential
  - cmake
  # Runtimes
  - python3
  - python3-pip
  - python3-venv
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
  - unzip
  - rsync
  - ca-certificates
  - gnupg
PKG
            ;;
        archlinux)
            cat << 'PKG'
packages:
  # Core (Claude Code depends on these)
  - openssh
  - git
  - curl
  - wget
  - jq
  - ripgrep
  # Build tools (native npm modules, compilation)
  - base-devel
  - cmake
  # Runtimes
  - python
  - python-pip
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
  - unzip
  - rsync
  - ca-certificates
  - gnupg
PKG
            ;;
        fedora)
            cat << 'PKG'
packages:
  # Core (Claude Code depends on these)
  - openssh-server
  - git
  - curl
  - wget
  - jq
  - ripgrep
  # Build tools (native npm modules, compilation)
  - gcc
  - gcc-c++
  - make
  - cmake
  # Runtimes
  - python3
  - python3-pip
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
  - unzip
  - rsync
  - ca-certificates
  - gnupg2
PKG
            ;;
    esac
}

_cloud_init_nodejs_runcmd() {
    local flavor="$1"
    case "$flavor" in
        debian|ubuntu)
            cat << 'CMD'
  - curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  - apt-get install -y nodejs
CMD
            ;;
        archlinux)
            cat << 'CMD'
  - pacman -Sy --noconfirm nodejs npm
CMD
            ;;
        fedora)
            cat << 'CMD'
  - dnf install -y nodejs npm
CMD
            ;;
    esac
}

_cloud_init_gh_runcmd() {
    local flavor="$1"
    case "$flavor" in
        debian|ubuntu)
            cat << 'CMD'
  # GitHub CLI (used by Claude Code for PR/issue operations)
  - mkdir -p -m 755 /etc/apt/keyrings
  - curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  - chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  - apt-get update
  - apt-get install -y gh
CMD
            ;;
        archlinux)
            cat << 'CMD'
  - pacman -Sy --noconfirm github-cli
CMD
            ;;
        fedora)
            cat << 'CMD'
  - dnf install -y gh
CMD
            ;;
    esac
}

_cloud_init_cleanup_runcmd() {
    local flavor="$1"
    case "$flavor" in
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
    esac
}

_cloud_init_ssh_service() {
    local flavor="$1"
    case "$flavor" in
        debian) echo "ssh" ;;
        ubuntu) echo "ssh" ;;
        archlinux) echo "sshd" ;;
        fedora) echo "sshd" ;;
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
