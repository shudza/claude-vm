#!/usr/bin/env bash
# Cloud-init configuration generation for base image provisioning
# This is the key to fast first-launch: cloud-init provisions the VM
# on first boot without needing Ansible overhead.

set -euo pipefail

# Generate cloud-init user-data for base image provisioning
generate_cloud_init_userdata() {
    local output_dir="$1"
    cat > "$output_dir/user-data" << 'USERDATA'
#cloud-config
# claude-vm base image provisioning

# Set hostname
hostname: claude-vm

# Create claude user with sudo
users:
  - name: claude
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    # Password: claude (for emergency console access)
    passwd: $6$rounds=4096$saltsalt$ZKMEXv3MnQXpWLGfKsHrOjfFjCGPQY0fAXlxqYFwC.dqI6/dR7bEvFRNABpiRPfOJYCkLKOGnSq1EFqLm9ER1
    ssh_authorized_keys: []

# Install essential packages (minimal set for speed)
packages:
  - openssh-server
  - git
  - curl
  - wget
  - build-essential
  - python3
  - python3-pip
  - jq
  - tmux
  - vim

# Configure SSH for fast access
write_files:
  - path: /etc/ssh/sshd_config.d/claude-vm.conf
    content: |
      PermitRootLogin no
      PasswordAuthentication yes
      PubkeyAuthentication yes
      UseDNS no
      GSSAPIAuthentication no
      # Speed up SSH connection
      AcceptEnv LANG LC_*
    permissions: '0644'
  - path: /home/claude/.bashrc
    content: |
      export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
      export NPM_CONFIG_PREFIX="$HOME/.npm-global"
      # Auto-mount workspace hint
      if [ -d /workspace ]; then
        cd /workspace 2>/dev/null
      fi
    permissions: '0644'
    owner: claude:claude
  - path: /etc/fstab
    content: |
      # virtiofs workspace mount
      workspace /workspace virtiofs defaults,nofail 0 0
    append: true
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
      Description=Set ownership of /workspace to claude user
      After=workspace.mount
      Requires=workspace.mount

      [Service]
      Type=oneshot
      ExecStart=/bin/chown claude:claude /workspace
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
    permissions: '0644'
  - path: /home/claude/.ssh/authorized_keys
    content: ""
    permissions: '0600'
    owner: claude:claude
    defer: true

# Run commands for provisioning
runcmd:
  # Create workspace mount point
  - mkdir -p /workspace
  - chown claude:claude /workspace
  # Create npm global dir
  - sudo -u claude mkdir -p /home/claude/.npm-global
  # Install Node.js via nodesource (LTS)
  - curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  - apt-get install -y nodejs
  # Install Claude Code globally
  - sudo -u claude npm config set prefix '/home/claude/.npm-global'
  - sudo -u claude npm install -g @anthropic-ai/claude-code
  # Enable virtiofs workspace mount (systemd unit is more reliable than fstab)
  - systemctl daemon-reload
  - systemctl enable workspace.mount
  - systemctl enable workspace-chown.service
  # Try to mount now if virtiofs device is available (during base build it won't be)
  - systemctl start workspace.mount || true
  - systemctl start workspace-chown.service || true
  # Generate SSH host keys if missing
  - ssh-keygen -A
  - systemctl enable ssh
  - systemctl start ssh
  # Signal that provisioning is complete
  - touch /var/lib/cloud/instance/claude-vm-ready
  # Clean up apt cache to save space
  - apt-get clean
  - rm -rf /var/lib/apt/lists/*

# Power off after provisioning (for base image creation)
power_state:
  mode: poweroff
  message: "claude-vm base image provisioning complete"
  timeout: 30
  condition: true

USERDATA
}

# Generate cloud-init meta-data
generate_cloud_init_metadata() {
    local output_dir="$1"
    cat > "$output_dir/meta-data" << 'METADATA'
instance-id: claude-vm-base
local-hostname: claude-vm
METADATA
}

# Generate cloud-init network-config (use DHCP on default interface)
generate_cloud_init_network() {
    local output_dir="$1"
    cat > "$output_dir/network-config" << 'NETCONFIG'
version: 2
ethernets:
  id0:
    match:
      driver: virtio
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
