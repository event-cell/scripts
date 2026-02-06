#!/usr/bin/env bash
# configure_wayland_kiosk.sh
#
# Raspberry Pi OS (Bookworm) Wayland/Wayfire kiosk configurator:
#   - Disables blanking / DPMS (Wayfire idle)
#   - "Hides" cursor under Wayland by moving it off-screen periodically (ydotool)
#   - Autostarts ONE Chromium kiosk window per device, URL selected by SCREEN_NUMBER (1..4)
#   - Optionally rotates the primary connected output (auto-detected), or a specified output
#
# Designed to be called from another installation script. Idempotent.
#
# ----------------------
# Environment variables:
# ----------------------
# KIOSK_ENABLE=1|0                 (default 1)
# KIOSK_BASE_URL                   (default "http://timing.sdma")
#
# SCREEN_NUMBER=1..4               (recommended) selects /display/<n>
#   If not set, hostname is used:
#     screen01 -> 1, screen02 -> 2, screen03 -> 3, screen04 -> 4
#
# KIOSK_USER                        (default: invoking user, or SUDO_USER)
#
# Rotation options:
# KIOSK_ROTATE_ENABLE=1|0           (default 0)
# KIOSK_OUTPUT_NAME                 (optional; if empty and rotate enabled, auto-detect)
# KIOSK_OUTPUT_ROTATION             (default 270) 0|90|180|270
#
# Output detection preferences:
# KIOSK_OUTPUT_PREFER=HDMI          (default HDMI) one of: HDMI|DP|ANY
#
# Notes:
#   - Wayland does NOT support xset/xrandr/unclutter.
#   - Output auto-detect reads /sys/class/drm/*/status to find a connected connector and
#     maps it to wlroots/Wayfire output names (e.g., HDMI-A-1, DP-1).
#
set -euo pipefail

log() { printf "\n[%s] %s\n" "$(date +'%F %T')" "$*" >&2; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# ---------- Defaults ----------
KIOSK_ENABLE="${KIOSK_ENABLE:-1}"
KIOSK_BASE_URL="${KIOSK_BASE_URL:-http://timing.sdma}"

SCREEN_NUMBER="${SCREEN_NUMBER:-}"
KIOSK_ROTATE_ENABLE="${KIOSK_ROTATE_ENABLE:-0}"
KIOSK_OUTPUT_NAME="${KIOSK_OUTPUT_NAME:-}"
KIOSK_OUTPUT_ROTATION="${KIOSK_OUTPUT_ROTATION:-270}"
KIOSK_OUTPUT_PREFER="${KIOSK_OUTPUT_PREFER:-HDMI}"

TARGET_USER="${KIOSK_USER:-${SUDO_USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Could not resolve home for user: $TARGET_USER"

WAYFIRE_DIR="${TARGET_HOME}/.config"
WAYFIRE_INI="${WAYFIRE_DIR}/wayfire.ini"

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  cp -a "$f" "${f}.bak_${ts}"
  log "Backup created: ${f}.bak_${ts}"
}

# ---------- INI helpers ----------
ini_set() {
  local file="$1" section="$2" key="$3" value="$4"
  mkdir -p "$(dirname "$file")"
  touch "$file"

  if ! grep -qE "^\[$
