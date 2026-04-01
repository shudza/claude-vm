#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/shudza/claude-vm.git"
TMPDIR="$(mktemp -d)"

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "Cloning claude-vm..."
git clone --depth 1 "$REPO" "$TMPDIR/claude-vm"

echo "Installing..."
sudo make -C "$TMPDIR/claude-vm" install

echo "Done. Run 'claude-vm' to get started."
