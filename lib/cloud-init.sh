#!/usr/bin/env bash
# Cloud-init configuration generation for base image provisioning
# This is the key to fast first-launch: cloud-init provisions the VM
# on first boot without needing Ansible overhead.

set -euo pipefail

# known_hosts name for the shared guest host key (ssh HostKeyAlias)
VM_HOST_KEY_ALIAS="claude-vm"

# Guest ~/.bashrc line loading the per-project env file (launch.sh writes it)
GUEST_ENV_SOURCE_LINE='[ -f "$HOME/.claude-vm-env" ] && . "$HOME/.claude-vm-env"'

# Ensure the guest SSH host key exists and known_hosts pins it.
# The key is created once on the host and baked into every base image
# (cloud-init ssh_keys), so all VMs present one identity that survives
# rebuilds and flavor switches. claude-vm's own ssh calls skip host-key
# checks, but herdr's background connections force StrictHostKeyChecking=yes,
# so the claude-vm-* aliases (herdr.sh) verify against this pin via
# HostKeyAlias — one entry covers every VM regardless of its port.
ensure_vm_host_key() {
    local key known type data
    key="$(vm_host_key_path)"
    known="$(vm_known_hosts_path)"
    if [[ ! -f "$key" ]]; then
        mkdir -p "$(dirname "$key")"
        chmod 700 "$(dirname "$key")"
        ssh-keygen -t ed25519 -f "$key" -N "" -C "claude-vm-host" -q
        chmod 600 "$key"
    fi
    read -r type data _ < "${key}.pub"
    printf '%s %s %s\n' "$VM_HOST_KEY_ALIAS" "$type" "$data" > "$known"
}

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

    # Host key the guest sshd presents (pinned on the host, see above)
    ensure_vm_host_key
    local host_key_private host_key_public
    host_key_private="$(sed 's/^/    /' "$(vm_host_key_path)")"
    host_key_public="$(cat "$(vm_host_key_path).pub")"

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

# Fixed sshd host key shared by every claude-vm guest (ssh -A in runcmd only
# fills in the other key types)
ssh_keys:
  ed25519_private: |
$host_key_private
  ed25519_public: $host_key_public

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
      # Per-project Claude Code env written on first launch, so shells not
      # started by claude-vm (herdr panes, ssh claude-vm-<name>) match it
      $GUEST_ENV_SOURCE_LINE
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

    _cloud_init_append_overlay "$output_dir/user-data"
}

# ── User cloud-init overlay ──────────────────────────────────────────────────
# The user can extend the baked cloud-config with ~/.claude-vm/cloud-init.yaml
# (managed by: claude-vm config set cloud-init). The overlay is shipped as an
# extra cloud-config part of a MIME multipart user-data document.
#
# It is deliberately NOT appended to the same YAML document after a "---"
# separator: cloud-init parses a part with yaml.safe_load, which accepts a
# single document only, so a second document makes the whole part unparseable
# and cloud-init discards it — taking the baked users, SSH key, packages and
# runcmd with it. MIME multipart is the supported way to send several
# cloud-config parts in one user-data blob.

# True when the overlay holds at least one real (non-comment, non-blank) line.
# A comments-only file is the untouched scaffold and is inert: shipping it would
# make cloud-init record a part error ("empty cloud config") for a no-op overlay
# and stamp a schema-error marker into the merged config. The predicate lives in
# config.sh so show_config reports the same thing.
cloud_init_overlay_active() {
    cloud_init_overlay_has_content
}

# Path of the user overlay (CLOUD_INIT_USER_FILE from config.sh)
_cloud_init_overlay_file() {
    echo "${CLOUD_INIT_USER_FILE:-${CLAUDE_VM_DIR:-$HOME/.claude-vm}/cloud-init.yaml}"
}

# Merge type applied to the overlay part.
#
# cloud-init's own default is dict(replace)+list()+str(). Both halves are wrong
# here:
#   - m_list with no op falls back to "replace", which merges index-wise: the
#     overlay's first runcmd entry would OVERWRITE the baked first entry.
#   - m_dict's default is already no_replace, but spelling it out makes the
#     intent explicit and guards against a future default change.
# list(append) concatenates, and dict(no_replace) means a key the baked config
# already sets keeps the baked value. That is deliberate: real `replace` would
# let an overlay `users:` list drop the baked user and its authorized SSH key,
# leaving a VM that cannot be reached. recurse_list makes list-valued keys
# nested in dicts (users, write_files) append too.
# Users can override a baked scalar from their own overlay by setting
# merge_how: in it — a payload merge_how is popped out of the payload and takes
# precedence over this header.
_CLOUD_INIT_OVERLAY_MERGE_TYPE="list(append)+dict(no_replace,recurse_list)+str()"

# Parse the overlay exactly as cloud-init will: it hands the part payload to
# yaml.safe_load and requires a mapping, and a part it cannot load is dropped
# with only a log line. Prints the reason on stderr when the overlay is unusable.
_cloud_init_overlay_parse_error() {
    local file="$1"
    python3 - "$file" << 'PARSE' 2>&1
import sys

import yaml

try:
    doc = yaml.safe_load(open(sys.argv[1], "rb"))
except yaml.YAMLError as exc:
    print(exc)
    sys.exit(1)

if doc is not None and not isinstance(doc, dict):
    print(
        "root of the document is %s, but cloud-config must be a mapping of keys"
        % type(doc).__name__
    )
    sys.exit(2)
PARSE
}

# Reason the overlay cannot be used, or empty output when it is usable.
# Always exits 0: the reason is the output, not the status, so callers key on
# empty-vs-nonempty. Returning the parser's status here would make a command
# substitution assignment "fail", and callers would read that as "no problem".
_cloud_init_overlay_unusable_reason() {
    _cloud_init_overlay_parse_error "$1" || true
}

# Non-fatal YAML validation: cloud-init discards a part it cannot parse, so a
# typo silently drops the overlay. Reported as a warning at save time; the
# build fails instead (see _cloud_init_overlay_require_valid).
_cloud_init_warn_if_overlay_invalid() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 -c 'import yaml' >/dev/null 2>&1 || return 0

    local err
    if err="$(_cloud_init_overlay_unusable_reason "$file")" && [[ -n "$err" ]]; then
        {
            echo "WARNING: cloud-init cannot use the overlay: $file"
            echo "$err" | sed 's/^/  /'
            echo "  cloud-init would silently discard the overlay. It is saved anyway; fix it and rebuild."
        } >&2
    fi
}

# Fail the build when the overlay cannot be parsed. cloud-init logs and skips
# an unparseable part, then boots anyway — the build would report success with
# the user's changes missing.
_cloud_init_overlay_require_valid() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
        echo "WARNING: python3 + PyYAML unavailable — skipping overlay validation" >&2
        return 0
    fi

    local err
    if err="$(_cloud_init_overlay_unusable_reason "$file")" && [[ -n "$err" ]]; then
        echo "ERROR: cloud-init cannot use the overlay: $file" >&2
        echo "$err" >&2
        return 1
    fi
}

# Wrap a generated user-data file together with the user overlay in a MIME
# multipart document. No-op when the overlay is unset, so an untouched user-data
# stays byte-identical to a build without the feature.
_cloud_init_append_overlay() {
    local user_data="$1"
    local file
    file="$(_cloud_init_overlay_file)"

    cloud_init_overlay_active || return 0
    _cloud_init_overlay_require_valid "$file" || return $?

    local boundary="claude-vm-boundary" part1
    part1="$user_data.baked"
    if ! mv "$user_data" "$part1"; then
        # e.g. a bind-mounted or permission-restricted output dir
        cp "$user_data" "$part1" || return $?
        : > "$user_data"
    fi

    {
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
        echo ""
        _cloud_init_mime_part "$boundary" "$part1"
        _cloud_init_mime_part "$boundary" "$file" \
            "Merge-Type: $_CLOUD_INIT_OVERLAY_MERGE_TYPE"
        echo "--$boundary--"
    } > "$user_data"

    rm -f "$part1"
}
# Emit one base64-encoded MIME part. $3 is an optional extra header line.
#
# The payload is the source file byte-for-byte. Nothing is injected into it: a
# prepended merge_how: line (or a rewritten leading document marker) would turn
# an overlay that starts with "---" into two YAML documents, which yaml.safe_load
# rejects — dropping the whole part. The merge type travels in the Merge-Type
# header instead, which cloud-init's handler reads alongside the payload
# (cloudinit/handlers/cloud_config.py:_extract_mergers).
#
# base64 is not decoration either: cloud-init decodes a part's bytes to str via
# latin-1 and then decodes that str again with the part's declared charset, so a
# non-ASCII byte in a plain part becomes an unparseable surrogate and the part is
# dropped (the baked config has em dashes in its comments). A base64 body is pure
# ASCII, survives that round trip byte-exactly, and can never contain the
# boundary or a line that reads as a header.
_cloud_init_mime_part() {
    local boundary="$1" file="$2" extra_header="${3:-}"
    echo "--$boundary"
    echo "Content-Type: text/cloud-config; charset=\"utf-8\""
    echo "Content-Transfer-Encoding: base64"
    [[ -n "$extra_header" ]] && echo "$extra_header"
    echo ""
    base64 < "$file"
}


# ── Overlay management (claude-vm config set cloud-init) ─────────────────────

# Scaffolding for a new overlay. Comments only: an untouched template is
# inert (cloud_init_overlay_active ignores whitespace-only files).
_cloud_init_overlay_write_template() {
    local file="$1"
    mkdir -p "$(dirname "$file")"
    cat > "$file" << 'TEMPLATE'
# claude-vm cloud-init overlay
#
# Extends the cloud-init config baked into the base image. It is merged as an
# extra cloud-config part, so it can only ADD:
#   - list values (runcmd, packages, write_files) are APPENDED to the baked ones
#   - keys the baked config already sets keep the baked value
#   - new keys are added as written
# The sandbox's own setup (user, SSH key, virtiofs mount, installers) therefore
# always survives.
#
# Takes effect when the base image is (re)built:
#   claude-vm rebase          # rebuild + migrate existing VMs
#   claude-vm build --force   # rebuild this flavor's base image only
#
# Note /tmp is a tmpfs in the guest, so anything written there during
# provisioning does not survive into the running VM. Write to a real path.
#
# Examples:
#
# packages:
#   - ripgrep
#   - jq
#
# runcmd:
#   - install -d /usr/local/share/claude-vm
#   - echo hello > /usr/local/share/claude-vm/overlay-ran
#
# write_files:
#   - path: /etc/claude-vm-extra.conf
#     content: |
#       key = value
#     permissions: '0644'
TEMPLATE
}

# Open the overlay in an editor, creating the template when unset.
cloud_init_overlay_edit() {
    local file
    file="$(_cloud_init_overlay_file)"

    if [[ ! -s "$file" ]]; then
        _cloud_init_overlay_write_template "$file"
    fi

    local editor="${VISUAL:-${EDITOR:-}}"
    if [[ -z "$editor" ]]; then
        if [[ ! -t 0 && ! -t 1 ]]; then
            echo "No editor available: set \$EDITOR/\$VISUAL, or import a file with:" >&2
            echo "  claude-vm config set cloud-init <file>" >&2
            return 1
        fi
        editor="vi"
    fi

    # Unquoted so an editor value carrying arguments ("code -w") works.
    # shellcheck disable=SC2086
    $editor "$file" || return $?

    if ! cloud_init_overlay_active; then
        echo "Cloud-init overlay is empty — nothing will be merged: $file"
        return 0
    fi

    _cloud_init_warn_if_overlay_invalid "$file"
    echo "Cloud-init overlay saved: $file"
    cloud_init_overlay_rebuild_note
}

# Import an overlay from a file, or from stdin when the source is "-".
cloud_init_overlay_import() {
    local src="$1"
    local file
    file="$(_cloud_init_overlay_file)"

    if [[ "$src" == "-" ]]; then
        mkdir -p "$(dirname "$file")"
        cat > "$file"
    else
        if [[ ! -f "$src" ]]; then
            echo "No such file: $src" >&2
            return 1
        fi
        if [[ ! -r "$src" ]]; then
            echo "Not readable: $src" >&2
            return 1
        fi
        mkdir -p "$(dirname "$file")"
        cp "$src" "$file"
    fi

    if ! cloud_init_overlay_active; then
        echo "Cloud-init overlay is empty — nothing will be merged: $file"
        return 0
    fi

    _cloud_init_warn_if_overlay_invalid "$file"
    echo "Cloud-init overlay saved: $file"
    cloud_init_overlay_rebuild_note
}

# Remove the overlay after confirmation.
cloud_init_overlay_unset() {
    local file
    file="$(_cloud_init_overlay_file)"

    if [[ ! -f "$file" ]]; then
        echo "No cloud-init overlay set: $file"
        return 0
    fi

    local confirm
    read -rp "Remove $file? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Cancelled."
        return 0
    fi

    rm -f "$file"
    echo "Cloud-init overlay removed: $file"
}

# Report where the overlay lives and whether it is in effect.
cloud_init_overlay_status() {
    local file
    file="$(_cloud_init_overlay_file)"

    echo "$file"
    if cloud_init_overlay_active; then
        echo "status: active ($(wc -l < "$file" | tr -d ' ') lines, merged into the base user-data)"
    elif [[ -f "$file" ]]; then
        echo "status: empty — ignored"
    else
        echo "status: not set"
    fi
}

# Note that existing base images predate an overlay change.
cloud_init_overlay_rebuild_note() {
    local base
    for base in "$BASE_IMAGES_DIR"/base*.qcow2; do
        [[ -f "$base" ]] || continue
        echo "Note: cloud-init runs at base image provision time. Existing base"
        echo "      images are unaffected — run 'claude-vm rebase' (or 'claude-vm"
        echo "      build --force') to apply this to the next build."
        return 0
    done
    echo "Note: applies to the next base image build ('claude-vm build')."
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
  # GitLab CLI (same credential handling as gh in Claude Code)
  - glab
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
  # GitLab CLI (same credential handling as gh in Claude Code)
  - glab
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
  # GitLab CLI (same credential handling as gh in Claude Code)
  - glab
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
  # GitLab CLI (same credential handling as gh in Claude Code)
  - glab
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

    generate_cloud_init_userdata "$output_dir" || return $?
    generate_cloud_init_metadata "$output_dir"
    generate_cloud_init_network "$output_dir"

    # genisoimage consumes these loose files; the guest reads user-data out of
    # the cidata ISO, not from beside it.
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
