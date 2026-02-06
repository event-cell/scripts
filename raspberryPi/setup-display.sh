#!/usr/bin/env bash
# configure_wayland_kiosk.sh
#
# Raspberry Pi OS (Bookworm) Wayland/Wayfire kiosk configurator:
#   - Disables blanking / DPMS (Wayfire idle)
#   - Rotates the primary connected output left 90 degrees (transform=270)
#   - Autostarts ONE Chromium kiosk window per device, URL selected by SCREEN_NUMBER (1..4)
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
# Rotation options:
# KIOSK_ROTATE_ENABLE=1|0           (default 1)
# KIOSK_OUTPUT_NAME                 (optional; if empty and rotate enabled, auto-detect)
# KIOSK_OUTPUT_ROTATION             (default 270) 0|90|180|270   (270 = left 90)
# KIOSK_OUTPUT_PREFER=HDMI          (default HDMI) HDMI|DP|ANY
#
set -euo pipefail

log() { printf "\n[%s] %s\n" "$(date +'%F %T')" "$*" >&2; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# ---------- Defaults ----------
KIOSK_ENABLE="${KIOSK_ENABLE:-1}"
KIOSK_BASE_URL="${KIOSK_BASE_URL:-http://timing.sdma}"

SCREEN_NUMBER="${SCREEN_NUMBER:-}"

# For your new requirement: rotate left 90 by default
KIOSK_ROTATE_ENABLE="${KIOSK_ROTATE_ENABLE:-1}"
KIOSK_OUTPUT_NAME="${KIOSK_OUTPUT_NAME:-}"
KIOSK_OUTPUT_ROTATION="${KIOSK_OUTPUT_ROTATION:-270}"   # 270 == rotate left 90
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

# ---------- Hostname -> number (case-insensitive) ----------
detect_screen_number() {
  if [[ -n "${SCREEN_NUMBER}" ]]; then
    echo "${SCREEN_NUMBER}"
    return 0
  fi

  local hn hn_lc
  hn="$(hostname 2>/dev/null || true)"
  hn_lc="$(printf '%s' "$hn" | tr '[:upper:]' '[:lower:]')"

  if [[ "$hn_lc" =~ ^screen0([1-4])$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  die "SCREEN_NUMBER not set and hostname '$hn' is not one of screen01..screen04"
}

# ---------- Output auto-detect ----------
detect_output_name() {
  local prefer="${KIOSK_OUTPUT_PREFER^^}"

  mapfile -t connected < <(for st in /sys/class/drm/card*-*/status; do
    [[ -f "$st" ]] || continue
    if grep -q '^connected$' "$st"; then
      echo "$(basename "$(dirname "$st")")"
    fi
  done)

  [[ "${#connected[@]}" -gt 0 ]] || die "No connected displays detected in /sys/class/drm"

  local c
  local conn=()
  for c in "${connected[@]}"; do
    conn+=( "${c#card*-}" )
  done

  if [[ "$prefer" == "HDMI" ]]; then
    for c in "${conn[@]}"; do [[ "$c" == HDMI-A-* ]] && { echo "$c"; return; }; done
    for c in "${conn[@]}"; do [[ "$c" == HDMI-*   ]] && { echo "$c"; return; }; done
    for c in "${conn[@]}"; do [[ "$c" == DP-*     ]] && { echo "$c"; return; }; done
    echo "${conn[0]}"; return
  fi

  if [[ "$prefer" == "DP" ]]; then
    for c in "${conn[@]}"; do [[ "$c" == DP-*     ]] && { echo "$c"; return; }; done
    for c in "${conn[@]}"; do [[ "$c" == HDMI-A-* ]] && { echo "$c"; return; }; done
    echo "${conn[0]}"; return
  fi

  echo "${conn[0]}"
}

# ---------- Main ----------
log "Target user: ${TARGET_USER}"
log "Target home: ${TARGET_HOME}"

require_cmd awk
require_cmd sed
require_cmd getent

SCREEN_NUMBER="$(detect_screen_number)"
case "$SCREEN_NUMBER" in
  1|2|3|4) ;;
  *) die "SCREEN_NUMBER must be 1..4" ;;
esac

KIOSK_URL="${KIOSK_BASE_URL}/display/${SCREEN_NUMBER}"
log "Screen number: ${SCREEN_NUMBER}"
log "Kiosk URL: ${KIOSK_URL}"

log "Installing Chromium..."
sudo apt-get update -y
sudo apt-get install -y chromium-browser || sudo apt-get install -y chromium || true

log "Configuring Wayfire..."

mkdir -p "$WAYFIRE_DIR"
backup_file "$WAYFIRE_INI"

# Choose chromium binary robustly
CHROME_BIN="/usr/bin/chromium-browser"
if [[ ! -x "$CHROME_BIN" ]]; then
  CHROME_BIN="/usr/bin/chromium"
fi
[[ -x "$CHROME_BIN" ]] || CHROME_BIN="chromium-browser"

PROFILE_DIR="${TARGET_HOME}/.config/chromium-kiosk"
COMMON_FLAGS="--kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --hide-crash-restore-bubble --check-for-update-interval=31536000"

# Rotation: auto-detect output unless explicitly specified
ROTATE_SECTION=""
if [[ "$KIOSK_ROTATE_ENABLE" == "1" ]]; then
  OUT_NAME="${KIOSK_OUTPUT_NAME}"
  if [[ -z "$OUT_NAME" ]]; then
    OUT_NAME="$(detect_output_name)"
  fi

  case "$KIOSK_OUTPUT_ROTATION" in
    0|90|180|270) ;;
    *) die "KIOSK_OUTPUT_ROTATION must be one of 0|90|180|270" ;;
  esac

  log "Rotation enabled. Output: ${OUT_NAME} transform=${KIOSK_OUTPUT_ROTATION}"
  ROTATE_SECTION=$(
    cat <<EOF
[output:${OUT_NAME}]
# Wayfire/wlroots transform: 270 = rotate left 90 degrees
transform = ${KIOSK_OUTPUT_ROTATION}


EOF
  )
fi

# Write deterministic wayfire.ini (ordering matters; keep [core] first)
tmp="$(mktemp)"
cat >"$tmp" <<EOF
[core]
plugins = autostart idle

[idle]
# Never blank / never DPMS-off
dpms_timeout = -1

${ROTATE_SECTION}[autostart]
EOF

# Kiosk autostart (ONE window)
if [[ "$KIOSK_ENABLE" == "1" ]]; then
  echo "kiosk = ${CHROME_BIN} ${COMMON_FLAGS} --user-data-dir=${PROFILE_DIR} ${KIOSK_URL}" >>"$tmp"
fi

sudo mv "$tmp" "$WAYFIRE_INI"
log "Fixing ownership of ${WAYFIRE_DIR} for ${TARGET_USER}..."
sudo chown "${TARGET_USER}:${TARGET_USER}" "$WAYFIRE_INI"
sudo chmod 0644 "$WAYFIRE_INI"

log "Done."
log "Wayfire config: ${WAYFIRE_INI}"
log "URL:            ${KIOSK_URL}"
