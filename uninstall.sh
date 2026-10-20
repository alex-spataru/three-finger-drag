#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Removes the three-finger-drag libinput plugin.
#
#   curl -fsSL https://raw.githubusercontent.com/alex-spataru/three-finger-drag/main/uninstall.sh | bash

set -euo pipefail

PLUGIN="50-three-finger-drag.lua"
DEST_DIR="/etc/libinput/plugins"

info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

main() {
  if [ ! -f "$DEST_DIR/$PLUGIN" ]; then
    info "three-finger drag is not installed, nothing to do"
    exit 0
  fi
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "run as root or install sudo"
  fi

  info "removing $DEST_DIR/$PLUGIN"
  as_root rm -f "$DEST_DIR/$PLUGIN"

  # The directory is only removed when nothing else lives there.
  as_root rmdir "$DEST_DIR" 2>/dev/null || true

  echo
  info "three-finger drag removed"
  echo "   Log out and back in to restore the default touchpad behavior."
}

main "$@"
