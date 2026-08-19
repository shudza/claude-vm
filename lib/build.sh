#!/usr/bin/env bash
# Base image build logic for claude-vm
# Handles: download cloud image → provision via cloud-init → create base snapshot
# Target: complete within 2 minutes (excluding download time for first-ever run)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/cloud-init.sh"
source "$SCRIPT_DIR/snapshot.sh"

# Download the cloud image if not cached
download_cloud_image() {
    local img_path
    img_path="$(cloud_image_path)"

    if [[ -f "$img_path" ]]; then
        echo "  Cloud image already cached: $img_path"
        return 0
    fi

    echo "  Downloading cloud image..."
    echo "  URL: $BASE_IMAGE_URL"

    local curl_progress
    if [[ -t 2 ]]; then
        curl_progress="--progress-bar"
    else
        curl_progress="-sS"
    fi

    if ! curl -fSL $curl_progress -o "${img_path}.tmp" \
        --retry 3 --retry-delay 2 \
        "$BASE_IMAGE_URL"; then
        rm -f "${img_path}.tmp"
        echo "ERROR: Failed to download cloud image" >&2
        return 1
    fi

    mv "${img_path}.tmp" "$img_path"
    echo "  Download complete: $(du -h "$img_path" | cut -f1)"

    verify_cloud_image "$img_path"
}

# Verify downloaded cloud image against upstream checksum file
# Fetches the checksum file from the same mirror and compares
verify_cloud_image() {
    local img_path="$1"
    local checksum_url="${FLAVOR_CHECKSUM_URL[$FLAVOR]:-}"
    local checksum_type="${FLAVOR_CHECKSUM_TYPE[$FLAVOR]:-}"

    if [[ -z "$checksum_url" || -z "$checksum_type" ]]; then
        echo "  WARNING: No upstream checksum URL for flavor '$FLAVOR', skipping verification" >&2
        return 0
    fi

    echo "  Verifying image integrity ($checksum_type)..."

    # Fetch upstream checksum file
    local checksums
    if ! checksums=$(curl -fsSL --retry 2 "$checksum_url" 2>/dev/null); then
        echo "  WARNING: Could not fetch checksum file: $checksum_url" >&2
        echo "  Skipping verification (image may still be valid)" >&2
        return 0
    fi

    # Extract expected hash for our image filename
    local img_name
    img_name="$(basename "$img_path")"
    local expected_hash

    # Handle different checksum file formats:
    # - Standard:  "hash  filename" (Debian, Ubuntu)
    # - BSD/tag:   "SHA256 (filename) = hash"
    # - Fedora:    "# filename: size bytes\nhash" (hash on line after comment)
    if echo "$checksums" | grep -qE '^SHA(256|512) \('; then
        # BSD/tag format: "SHA256 (filename) = hash"
        expected_hash=$(echo "$checksums" | grep -F "$img_name" | grep -v '^#' | sed 's/.*= //')
    elif echo "$checksums" | grep -qE "^# .*${img_name}:"; then
        # Fedora format: comment with filename, hash on the next line
        expected_hash=$(echo "$checksums" | grep -A1 "^# .*${img_name}:" | tail -1)
    else
        # Standard format: "hash  filename"
        expected_hash=$(echo "$checksums" | grep -F "$img_name" | awk '{print $1}')
    fi

    if [[ -z "$expected_hash" ]]; then
        echo "  WARNING: Image '$img_name' not found in upstream checksum file" >&2
        return 0
    fi

    # Compute actual hash
    local actual_hash
    case "$checksum_type" in
        sha256) actual_hash=$(sha256sum "$img_path" | awk '{print $1}') ;;
        sha512) actual_hash=$(sha512sum "$img_path" | awk '{print $1}') ;;
        *)
            echo "  WARNING: Unknown checksum type '$checksum_type'" >&2
            return 0
            ;;
    esac

    if [[ "$actual_hash" == "$expected_hash" ]]; then
        echo "  Checksum verified ($checksum_type)"
    else
        echo "ERROR: Checksum mismatch for $img_name" >&2
        echo "  Expected: $expected_hash" >&2
        echo "  Actual:   $actual_hash" >&2
        rm -f "$img_path"
        return 1
    fi
}

# Create the base image from cloud image + cloud-init provisioning.
# Steps use explicit `|| return $?` because bash disables `set -e` inside a
# function called from `if !` — without this, failures propagate silently.
build_base_image() {
    local cloud_img base_img ci_iso build_img
    local start_time elapsed

    start_time=$(date +%s)

    load_config
    ensure_dirs

    cloud_img="$(cloud_image_path)"
    base_img="$(base_image_path)"
    ci_iso="$CLOUD_INIT_DIR/cloud-init.iso"
    build_img="$BASE_IMAGES_DIR/build-temp.qcow2"

    echo "==> Checking prerequisites..."
    check_build_prerequisites || return $?

    echo "==> Step 1/4: Cloud image"
    download_cloud_image || return $?

    echo "==> Step 2/4: Preparing build image..."
    rm -f "$build_img"
    qemu-img convert -f qcow2 -O qcow2 "$cloud_img" "$build_img" || return $?
    qemu-img resize "$build_img" 20G || return $?

    echo "==> Step 3/4: Generating cloud-init config..."
    create_cloud_init_iso "$CLOUD_INIT_DIR" "$ci_iso" || return $?

    echo "==> Step 4/4: Provisioning base image (flavor: $FLAVOR, usually under two minutes)..."
    provision_base_image "$build_img" "$ci_iso" || return $?

    mv "$build_img" "$base_img" || return $?

    elapsed=$(( $(date +%s) - start_time ))
    echo ""
    echo "==> Base image built successfully in ${elapsed}s"
    echo "    Location: $base_img"
    echo "    Size: $(du -h "$base_img" | cut -f1)"

    if (( elapsed > 120 )); then
        echo "    WARNING: Build took ${elapsed}s (target: <120s)"
        echo "    Note: Subsequent project launches will be much faster (snapshot only)"
    fi
}

# Check that required tools are available
check_build_prerequisites() {
    local missing=()

    # jq parses `qemu-img info --output=json` when validating the provisioned
    # image — without it the build fails at the very end with a misleading
    # "image is suspiciously small" error.
    for cmd in qemu-system-x86_64 qemu-img curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    # Check for ISO creation tool
    local has_iso_tool=false
    for cmd in genisoimage mkisofs xorrisofs; do
        if command -v "$cmd" &>/dev/null; then
            has_iso_tool=true
            break
        fi
    done
    if ! $has_iso_tool; then
        missing+=("genisoimage/mkisofs/xorrisofs")
    fi

    # Check KVM support
    if [[ ! -e /dev/kvm ]]; then
        echo "WARNING: /dev/kvm not available. Build will be very slow without KVM." >&2
        echo "         Make sure kvm module is loaded and you have access to /dev/kvm" >&2
    fi

    if (( ${#missing[@]} > 0 )); then
        echo "ERROR: Missing required tools: ${missing[*]}" >&2
        echo "" >&2
        echo "Install on Arch/CachyOS:" >&2
        echo "  sudo pacman -S qemu-full cdrtools curl jq" >&2
        echo "" >&2
        echo "Install on Ubuntu/Debian:" >&2
        echo "  sudo apt install qemu-system-x86 qemu-utils genisoimage curl jq" >&2
        echo "" >&2
        echo "Install on Fedora:" >&2
        echo "  sudo dnf install qemu-system-x86 qemu-img genisoimage curl jq" >&2
        return 1
    fi

    echo "  All prerequisites satisfied"
}

# Run QEMU to provision the base image via cloud-init
# The VM boots, cloud-init runs, then auto-powers off
provision_base_image() {
    local build_img="$1"
    local ci_iso="$2"
    local timeout=600  # 10 minute absolute timeout (headroom for slow mirrors/TCG)
    local accel="kvm"

    # Check KVM availability
    if [[ ! -r /dev/kvm ]] || [[ ! -w /dev/kvm ]]; then
        echo "  WARNING: KVM not accessible, falling back to TCG (will be slower)"
        accel="tcg"
    fi

    # Run QEMU for provisioning (no virtiofs needed). Cloud-init powers off
    # the VM when done. `-serial file:` writes the guest console directly to
    # disk — avoid `-nographic` here, which routes serial to QEMU stdio and
    # gets libc-buffered when stdio is a file.
    echo "  Starting provisioning VM..."

    local qemu_pid_file="$CLAUDE_VM_DIR/run/build.pid"
    local serial_log="$CLAUDE_VM_DIR/run/build-serial.log"
    local qemu_log="$CLAUDE_VM_DIR/run/build-qemu.log"
    rm -f "$serial_log" "$qemu_log"

    timeout "$timeout" qemu-system-x86_64 \
        -name "claude-vm-build" \
        -machine "type=q35,accel=$accel" \
        -cpu host \
        -smp "$VM_CPUS" \
        -m "$VM_RAM" \
        -drive "file=$build_img,format=qcow2,if=virtio,cache=writeback,discard=unmap,detect-zeroes=unmap" \
        -drive "file=$ci_iso,format=raw,if=virtio,media=cdrom,readonly=on" \
        -netdev "user,id=net0" \
        -device "virtio-net-pci,netdev=net0" \
        -display none \
        -serial "file:$serial_log" \
        -monitor none \
        -no-reboot \
        </dev/null >/dev/null 2>"$qemu_log" &

    local qemu_pid=$!
    echo "$qemu_pid" > "$qemu_pid_file"

    # If QEMU dies within the first second, the wait loop would see it gone
    # and treat that as success — probe explicitly so we fail loudly.
    sleep 1
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        wait "$qemu_pid" 2>/dev/null
        local fast_rc=$?
        echo "ERROR: provisioning VM died immediately (rc=$fast_rc)" >&2
        _dump_log "qemu stderr"  "$qemu_log"   20 >&2
        _dump_log "guest serial" "$serial_log" 20 >&2
        rm -f "$qemu_pid_file"
        return 1
    fi

    echo "  Provisioning VM started (PID: $qemu_pid)"
    echo "  Waiting for cloud-init to complete and VM to power off..."

    # Wait for QEMU to exit (cloud-init powers off the VM)
    local wait_start ready_seen=false ready_at=0
    wait_start=$(date +%s)

    while kill -0 "$qemu_pid" 2>/dev/null; do
        local now
        now=$(date +%s)
        local waited=$(( now - wait_start ))

        # Detect cloud-init ready signal in serial log
        if ! $ready_seen && [[ -f "$serial_log" ]] && grep -q "claude-vm-ready\|provisioning complete" "$serial_log" 2>/dev/null; then
            ready_seen=true
            ready_at=$waited
            echo "  Cloud-init finished (${waited}s), waiting for VM to power off..."
        fi

        # If cloud-init finished but VM hasn't powered off within 60s, force kill
        if $ready_seen && (( waited - ready_at > 60 )); then
            echo "  VM did not power off within 60s after provisioning, forcing shutdown..."
            kill "$qemu_pid" 2>/dev/null || true
            break
        fi

        # Show progress every 10 seconds
        if (( waited % 10 == 0 )) && (( waited > 0 )); then
            echo "  ... provisioning in progress (${waited}s elapsed)"
            # Show last meaningful line from serial log
            if [[ -f "$serial_log" ]]; then
                local last_line
                last_line=$(grep -E '(cloud-init|Installing|Setting up|Unpacking|apt|dnf|pacman)' "$serial_log" 2>/dev/null | tail -1 || true)
                if [[ -n "$last_line" ]]; then
                    echo "    > ${last_line:0:80}"
                fi
            fi
        fi

        sleep 1
    done

    wait "$qemu_pid" 2>/dev/null
    local qemu_rc=$?
    rm -f "$qemu_pid_file"

    local provision_time=$(( $(date +%s) - wait_start ))
    echo "  Provisioning completed in ${provision_time}s"

    # cloud-init writes "claude-vm-ready" at the end of runcmd. Without it,
    # the build image is unprovisioned and unsafe to ship as the new base.
    if ! $ready_seen; then
        echo "ERROR: cloud-init did not complete (no 'claude-vm-ready' marker)" >&2
        echo "       provisioning ran for ${provision_time}s, qemu rc=$qemu_rc" >&2
        _dump_log "qemu stderr"  "$qemu_log"   30 >&2
        _dump_log "guest serial" "$serial_log" 30 >&2
        return 1
    fi

    _verify_provisioned_size "$build_img" "$serial_log" || return $?
}

# Sanity-check the size of a freshly provisioned image. A fully-provisioned
# base is ~1.5GB+; significantly less means cloud-init ran but didn't install
# much.
#
# Errors here are not swallowed: a missing jq or an unreadable image used to
# collapse into a size of 0 and get reported as "suspiciously small", sending
# people looking for a provisioning bug that didn't exist.
# Args: $1 = image path, $2 = serial log path (for the error message)
_verify_provisioned_size() {
    local build_img="$1" serial_log="${2:-}"
    local img_size=""

    if ! img_size=$(qemu-img info --output=json "$build_img" | jq -r '.["actual-size"]'); then
        echo "ERROR: could not read the size of the provisioned image" >&2
        echo "       image: $build_img" >&2
        echo "       (qemu-img info | jq failed — see the error above)" >&2
        return 1
    fi

    if [[ ! "$img_size" =~ ^[0-9]+$ ]]; then
        echo "ERROR: unexpected image size from qemu-img info: '$img_size'" >&2
        echo "       image: $build_img" >&2
        return 1
    fi

    if (( img_size < 500000000 )); then
        echo "ERROR: provisioned image is suspiciously small ($(( img_size / 1048576 ))MB, expected >500MB)" >&2
        echo "       serial log: $serial_log" >&2
        return 1
    fi
}

# Dump tail of a log file with a label, or note that it's empty/missing.
# Args: $1 = label, $2 = log path, $3 = tail line count
_dump_log() {
    local label="$1" path="$2" lines="$3"
    if [[ -s "$path" ]]; then
        echo "  $label ($path):"
        tail -"$lines" "$path" | sed 's/^/  | /'
    elif [[ -f "$path" ]]; then
        echo "  $label: empty ($path)"
    fi
}

# Note: create_project_snapshot is provided by snapshot.sh (sourced above)
# It creates a QCOW2 linked snapshot backed by the base image for a project.
