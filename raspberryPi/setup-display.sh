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

# waits (seconds)
KIOSK_WAIT_WAYLAND_SOCKET="${KIOSK_WAIT_WAYLAND_SOCKET:-30}"
KIOSK_WAIT_DISPLAY_READY="${KIOSK_WAIT_DISPLAY_READY:-10}"
KIOSK_WAIT_BEFORE_CHROME="${KIOSK_WAIT_BEFORE_CHROME:-12}"

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

log "Target user: ${TARGET_USER}"
log "Target home: ${TARGET_HOME}"

SCREEN_NUMBER="$(detect_screen_number)"
case "$SCREEN_NUMBER" in 1|2|3|4) ;; *) die "SCREEN_NUMBER must be 1..4" ;; esac

KIOSK_URL="${KIOSK_BASE_URL}/display/${SCREEN_NUMBER}"
log "Kiosk URL: ${KIOSK_URL}"

log "Installing required packages..."
sudo apt-get update -y
sudo apt-get install -y chromium wlr-randr wlopm util-linux || true

# Chromium binary
CHROME_BIN="/usr/bin/chromium"
[[ -x "$CHROME_BIN" ]] || CHROME_BIN="/usr/bin/chromium-browser"
PROFILE_DIR="${TARGET_HOME}/.config/chromium-kiosk"

# Includes: --password-store=basic (prevents keyring prompts)
COMMON_FLAGS="--kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --hide-crash-restore-bubble --check-for-update-interval=31536000 --password-store=basic"

# --------------------------------------------------------------------
# labwc-kiosk-display.sh (rotate + scale + keep DPMS on), runs detached
# --------------------------------------------------------------------
ROTATE_HELPER="/usr/local/bin/labwc-kiosk-display.sh"
sudo tee "$ROTATE_HELPER" >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail

WAIT_SOCKET="${KIOSK_WAIT_WAYLAND_SOCKET:-30}"
WAIT_DISPLAY="${KIOSK_WAIT_DISPLAY_READY:-10}"

echo "==== $(date) labwc-kiosk-display ===="
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"
echo "waits: socket=${WAIT_SOCKET}s display=${WAIT_DISPLAY}s"
echo "vars: rotate=${KIOSK_ROTATE_ENABLE:-} out=${KIOSK_OUTPUT_NAME:-} rot=${KIOSK_OUTPUT_ROTATION:-} scale=${KIOSK_OUTPUT_SCALE:-}"

tries=$(( WAIT_SOCKET * 10 ))
for ((i=1; i<=tries; i++)); do
  if [[ -n "${XDG_RUNTIME_DIR:-}" && -n "${WAYLAND_DISPLAY:-}" && -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]]; then
    echo "Wayland socket ready: ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"
    break
  fi
  sleep 0.1
done

sleep "$WAIT_DISPLAY"

ROTATE_ENABLE="${KIOSK_ROTATE_ENABLE:-1}"
OUT_NAME="${KIOSK_OUTPUT_NAME:-}"
ROT="${KIOSK_OUTPUT_ROTATION:-270}"
SCALE="${KIOSK_OUTPUT_SCALE:-2}"

if [[ "$ROTATE_ENABLE" == "1" ]]; then
  if [[ -z "$OUT_NAME" ]]; then
    # Best-effort fallback: first connected DRM connector name
    OUT_NAME="$(basename "$(dirname "$(grep -l '^connected$' /sys/class/drm/card*-*/status | head -n1)")")"
    OUT_NAME="${OUT_NAME#card*-}"
  fi

  case "$ROT" in 0|90|180|270) ;; *) ROT=270 ;; esac

  echo "Applying: output=${OUT_NAME} transform=${ROT} scale=${SCALE}"
  wlr-randr --output "$OUT_NAME" --transform "$ROT" >/dev/null 2>&1 || echo "WARN: wlr-randr transform failed"
  wlr-randr --output "$OUT_NAME" --scale "$SCALE"    >/dev/null 2>&1 || echo "WARN: wlr-randr scale failed"
fi

# Keep DPMS on
while true; do
  wlopm --on '*' >/dev/null 2>&1 || true
  sleep 30
done
SH
sudo chmod 0755 "$ROTATE_HELPER"

# --------------------------------------------------------------------
# labwc-kiosk-start.sh (logs + waits + starts display helper detached)
# --------------------------------------------------------------------
KIOSK_STARTER="/usr/local/bin/labwc-kiosk-start.sh"
sudo tee "$KIOSK_STARTER" >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${HOME}/.cache"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/labwc-kiosk.log"
DISPLAY_LOG="${LOG_DIR}/labwc-kiosk-display.log"

exec >>"$LOG_FILE" 2>&1
echo "==== $(date) labwc-kiosk-start ===="
echo "USER=$(id -un) HOME=$HOME"
echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-}"
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"
echo "KIOSK_URL=${KIOSK_URL:-}"
echo "vars: rotate=${KIOSK_ROTATE_ENABLE:-} out=${KIOSK_OUTPUT_NAME:-} rot=${KIOSK_OUTPUT_ROTATION:-} scale=${KIOSK_OUTPUT_SCALE:-}"
echo "waits: socket=${KIOSK_WAIT_WAYLAND_SOCKET:-} display=${KIOSK_WAIT_DISPLAY_READY:-} before_chrome=${KIOSK_WAIT_BEFORE_CHROME:-}"

WAIT_SOCKET="${KIOSK_WAIT_WAYLAND_SOCKET:-30}"
WAIT_BEFORE_CHROME="${KIOSK_WAIT_BEFORE_CHROME:-12}"

# Wait for Wayland socket
tries=$(( WAIT_SOCKET * 10 ))
for ((i=1; i<=tries; i++)); do
  if [[ -n "${XDG_RUNTIME_DIR:-}" && -n "${WAYLAND_DISPLAY:-}" && -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]]; then
    echo "Wayland socket ready: ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"
    break
  fi
  sleep 0.1
done

# Detach display helper from labwc/autostart (avoid SIGHUP / no-tty issues)
setsid -f /usr/local/bin/labwc-kiosk-display.sh >>"$DISPLAY_LOG" 2>&1
echo "Started display helper (detached). Display log: $DISPLAY_LOG"

# Give display helper time to rotate/scale before launching Chromium
sleep "$WAIT_BEFORE_CHROME"

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

# ---------------------------
# labwc autostart (IMPORTANT)
# ---------------------------
# labwc may not run autostart as a single shell; exports across lines can be lost.
# So we generate a SINGLE 'env ... command &' line.
LABWC_DIR="${TARGET_HOME}/.config/labwc"
AUTOSTART="${LABWC_DIR}/autostart"
mkdir -p "$LABWC_DIR"

if [[ -f "$AUTOSTART" ]]; then
  ts="$(date +%Y%m%d_%H%M%S)"
  cp -a "$AUTOSTART" "${AUTOSTART}.bak_${ts}"
  log "Backup created: ${AUTOSTART}.bak_${ts}"
fi

tmp="$(mktemp)"
cat >"$tmp" <<EOF
# labwc autostart - generated
env \\
  KIOSK_URL="${KIOSK_URL}" \\
  KIOSK_ROTATE_ENABLE="${KIOSK_ROTATE_ENABLE}" \\
  KIOSK_OUTPUT_NAME="${KIOSK_OUTPUT_NAME}" \\
  KIOSK_OUTPUT_ROTATION="${KIOSK_OUTPUT_ROTATION}" \\
  KIOSK_OUTPUT_SCALE="${KIOSK_OUTPUT_SCALE}" \\
  KIOSK_WAIT_WAYLAND_SOCKET="${KIOSK_WAIT_WAYLAND_SOCKET}" \\
  KIOSK_WAIT_DISPLAY_READY="${KIOSK_WAIT_DISPLAY_READY}" \\
  KIOSK_WAIT_BEFORE_CHROME="${KIOSK_WAIT_BEFORE_CHROME}" \\
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
log "display log:      ${TARGET_HOME}/.cache/labwc-kiosk-display.log"
log "URL:              ${KIOSK_URL}"
