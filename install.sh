#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Installs the three-finger-drag libinput plugin.
#
#   curl -fsSL https://raw.githubusercontent.com/alex-spataru/three-finger-drag/main/install.sh | bash
#
# When run from a clone, the plugin next to this script is installed instead
# of downloading it.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/alex-spataru/three-finger-drag/${THREE_FINGER_DRAG_REF:-main}"
PLUGIN="50-three-finger-drag.lua"
DEST_DIR="/etc/libinput/plugins"
MIN_LIBINPUT="1.30"

info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

libinput_version() {
  if command -v libinput >/dev/null 2>&1; then
    libinput --version 2>/dev/null && return
  fi
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libinput 2>/dev/null; then
    pkg-config --modversion libinput && return
  fi
  if command -v rpm >/dev/null 2>&1; then
    rpm -q --qf '%{VERSION}\n' libinput 2>/dev/null && return
  fi
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f '${Version}\n' libinput10 2>/dev/null | cut -d- -f1 && return
  fi
  if command -v pacman >/dev/null 2>&1; then
    pacman -Q libinput 2>/dev/null | awk '{print $2}' | cut -d- -f1 && return
  fi
  return 1
}

main() {
  [ "$(uname -s)" = "Linux" ] || die "this plugin only works on Linux"

  local sudo=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "run as root or install sudo"
    sudo="sudo"
  fi

  local ver
  if ver="$(libinput_version)" && [ -n "$ver" ]; then
    if version_ge "$ver" "$MIN_LIBINPUT"; then
      info "libinput $ver detected"
    else
      die "libinput $ver is too old, Lua plugins need $MIN_LIBINPUT or newer"
    fi
  else
    warn "could not detect the libinput version (needs $MIN_LIBINPUT or newer), continuing"
  fi

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT

  local here=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  if [ -n "$here" ] && [ -f "$here/$PLUGIN" ]; then
    info "using $here/$PLUGIN"
    cp "$here/$PLUGIN" "$tmp"
  else
    command -v curl >/dev/null 2>&1 || die "curl is required"
    info "downloading $PLUGIN"
    curl -fsSL "$REPO_RAW/$PLUGIN" -o "$tmp" || die "download failed"
  fi

  grep -q 'libinput:register' "$tmp" || die "$PLUGIN does not look like a libinput plugin"

  local action="installed"
  [ -f "$DEST_DIR/$PLUGIN" ] && action="updated"

  info "installing to $DEST_DIR/$PLUGIN"
  $sudo install -Dm644 "$tmp" "$DEST_DIR/$PLUGIN"

  if command -v restorecon >/dev/null 2>&1; then
    $sudo restorecon "$DEST_DIR/$PLUGIN" 2>/dev/null || true
  fi

  echo
  info "three-finger drag $action."
  echo "   Log out and back in for your compositor to load it."
  echo "   Uninstall: curl -fsSL $REPO_RAW/uninstall.sh | bash"
}

main "$@"
