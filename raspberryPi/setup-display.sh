#!/usr/bin/env bash
set -euo pipefail

log() { printf "\n[%s] %s\n" "$(date +'%F %T')" "$*" >&2; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

KIOSK_ENABLE="${KIOSK_ENABLE:-1}"
KIOSK_BASE_URL="${KIOSK_BASE_URL:-http://timing.sdma}"

SCREEN_NUMBER="${SCREEN_NUMBER:-}"

# rotate left 90
KIOSK_ROTATE_ENABLE="${KIOSK_ROTATE_ENABLE:-1}"
KIOSK_OUTPUT_NAME="${KIOSK_OUTPUT_NAME:-}"             # optional
KIOSK_OUTPUT_ROTATION="${KIOSK_OUTPUT_ROTATION:-270}"  # 270 = left 90
KIOSK_OUTPUT_PREFER="${KIOSK_OUTPUT_PREFER:-HDMI}"

# output scale (2 = “2x DPI”)
KIOSK_OUTPUT_SCALE="${KIOSK_OUTPUT_SCALE:-2}"

TARGET_USER="${KIOSK_USER:-${SUDO_USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Could not resolve home for user: $TARGET_USER"

detect_screen_number() {
  [[ -n "${SCREEN_NUMBER}" ]] && { echo "${SCREEN_NUMBER}"; return; }
  local hn hn_lc
  hn="$(hostname 2>/dev/null || true)"
  hn_lc="$(printf '%s' "$hn" | tr '[:upper:]' '[:lower:]')"
  [[ "$hn_lc" =~ ^screen0([1-4])$ ]] && { echo "${BASH_REMATCH[1]}"; return; }
  die "SCREEN_NUMBER not set and hostname '$hn' is not one of screen01..screen04"
}

detect_output_name_sysfs() {
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

log "Target user: ${TARGET_USER}"
log "Target home: ${TARGET_HOME}"

SCREEN_NUMBER="$(detect_screen_number)"
case "$SCREEN_NUMBER" in 1|2|3|4) ;; *) die "SCREEN_NUMBER must be 1..4" ;; esac

KIOSK_URL="${KIOSK_BASE_URL}/display/${SCREEN_NUMBER}"
log "Kiosk URL: ${KIOSK_URL}"

log "Installing required packages..."
sudo apt-get update -y
sudo apt-get install -y chromium wlr-randr wlopm || true

# Chromium binary
CHROME_BIN="/usr/bin/chromium"
[[ -x "$CHROME_BIN" ]] || CHROME_BIN="/usr/bin/chromium-browser"
PROFILE_DIR="${TARGET_HOME}/.config/chromium-kiosk"

# Includes: --password-store=basic (prevents keyring prompts)
COMMON_FLAGS="--kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --hide-crash-restore-bubble --check-for-update-interval=31536000 --password-store=basic"

# Helper: rotate + scale + keep DPMS on (labwc session)
ROTATE_HELPER="/usr/local/bin/labwc-kiosk-display.sh"
sudo tee "$ROTATE_HELPER" >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail

# Wait for Wayland socket (autostart can run before it exists)
for i in {1..50}; do
  if [[ -n "${XDG_RUNTIME_DIR:-}" && -n "${WAYLAND_DISPLAY:-}" && -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]]; then
    break
  fi
  sleep 0.2
done

# Give compositor/outputs a moment to settle
sleep 1

ROTATE_ENABLE="${KIOSK_ROTATE_ENABLE:-1}"
OUT_NAME="${KIOSK_OUTPUT_NAME:-}"
ROT="${KIOSK_OUTPUT_ROTATION:-270}"
SCALE="${KIOSK_OUTPUT_SCALE:-2}"

if [[ "$ROTATE_ENABLE" == "1" ]]; then
  if [[ -z "$OUT_NAME" ]]; then
    OUT_NAME="$(basename "$(dirname "$(grep -l '^connected$' /sys/class/drm/card*-*/status | head -n1)")")"
    OUT_NAME="${OUT_NAME#card*-}"
  fi

  case "$ROT" in 0|90|180|270) ;; *) ROT=270 ;; esac

  # Apply transform + scale
  wlr-randr --output "$OUT_NAME" --transform "$ROT" >/dev/null 2>&1 || true
  wlr-randr --output "$OUT_NAME" --scale "$SCALE"    >/dev/null 2>&1 || true
fi

# Keep DPMS on: if anything turns outputs off, force them back on
while true; do
  wlopm --on '*' >/dev/null 2>&1 || true
  sleep 30
done
SH
sudo chmod 0755 "$ROTATE_HELPER"

# NEW: Wrapper that logs + waits for Wayland, then starts helper + Chromium
KIOSK_STARTER="/usr/local/bin/labwc-kiosk-start.sh"
sudo tee "$KIOSK_STARTER" >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${HOME}/.cache"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/labwc-kiosk.log"

exec >>"$LOG_FILE" 2>&1
echo "==== $(date) labwc-kiosk-start ===="
echo "USER=$(id -un) HOME=$HOME"
echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-}"
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"

# Wait for Wayland socket
for i in {1..50}; do
  if [[ -n "${XDG_RUNTIME_DIR:-}" && -n "${WAYLAND_DISPLAY:-}" && -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]]; then
    echo "Wayland socket ready: ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"
    break
  fi
  sleep 0.2
done

sleep 1

/usr/local/bin/labwc-kiosk-display.sh &
echo "Started display helper (PID $!)"

CHROME_BIN="/usr/bin/chromium"
[[ -x "$CHROME_BIN" ]] || CHROME_BIN="/usr/bin/chromium-browser"

PROFILE_DIR="${HOME}/.config/chromium-kiosk"
URL="${KIOSK_URL:-http://timing.sdma/display/1}"

COMMON_FLAGS="--kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble \
--hide-crash-restore-bubble --check-for-update-interval=31536000 --password-store=basic"

echo "Launching Chromium: $CHROME_BIN $URL"
exec "$CHROME_BIN" $COMMON_FLAGS --user-data-dir="$PROFILE_DIR" "$URL"
SH
sudo chmod 0755 "$KIOSK_STARTER"

# labwc autostart
LABWC_DIR="${TARGET_HOME}/.config/labwc"
AUTOSTART="${LABWC_DIR}/autostart"
mkdir -p "$LABWC_DIR"

# Back up once per run
if [[ -f "$AUTOSTART" ]]; then
  ts="$(date +%Y%m%d_%H%M%S)"
  cp -a "$AUTOSTART" "${AUTOSTART}.bak_${ts}"
  log "Backup created: ${AUTOSTART}.bak_${ts}"
fi

# Write deterministic autostart: call ONLY the wrapper (most reliable)
tmp="$(mktemp)"
cat >"$tmp" <<EOF
# labwc autostart - generated

# Export kiosk variables for the starter/helper
export KIOSK_URL="${KIOSK_URL}"
export KIOSK_ROTATE_ENABLE="${KIOSK_ROTATE_ENABLE}"
export KIOSK_OUTPUT_NAME="${KIOSK_OUTPUT_NAME}"
export KIOSK_OUTPUT_ROTATION="${KIOSK_OUTPUT_ROTATION}"
export KIOSK_OUTPUT_SCALE="${KIOSK_OUTPUT_SCALE}"

${KIOSK_STARTER} &
EOF

sudo mv "$tmp" "$AUTOSTART"
sudo chown "${TARGET_USER}:${TARGET_USER}" "$AUTOSTART"
sudo chmod 0644 "$AUTOSTART"

log "Done."
log "labwc autostart:  ${AUTOSTART}"
log "display helper:   ${ROTATE_HELPER}"
log "starter script:   ${KIOSK_STARTER}"
log "log file:         ${TARGET_HOME}/.cache/labwc-kiosk.log"
log "URL:              ${KIOSK_URL}"
