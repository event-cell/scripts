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

# NEW: output scale (2 = “2x DPI”)
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

# Give compositor time to come up
sleep 2

ROTATE_ENABLE="${KIOSK_ROTATE_ENABLE:-1}"
OUT_NAME="${KIOSK_OUTPUT_NAME:-}"
ROT="${KIOSK_OUTPUT_ROTATION:-270}"
SCALE="${KIOSK_OUTPUT_SCALE:-2}"

if [[ "$ROTATE_ENABLE" == "1" ]]; then
  if [[ -z "$OUT_NAME" ]]; then
    # Take first connected and strip card prefix:
    OUT_NAME="$(basename "$(dirname "$(grep -l '^connected$' /sys/class/drm/card*-*/status | head -n1)")")"
    OUT_NAME="${OUT_NAME#card*-}"
  fi

  case "$ROT" in 0|90|180|270) ;; *) ROT=270 ;; esac

  # Apply transform + scale (scale=2 gives “2x DPI” effect)
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

# Write deterministic autostart:
tmp="$(mktemp)"
cat >"$tmp" <<EOF
# labwc autostart - generated

# Rotate + scale + keep DPMS on
env KIOSK_ROTATE_ENABLE=${KIOSK_ROTATE_ENABLE} KIOSK_OUTPUT_NAME=${KIOSK_OUTPUT_NAME} KIOSK_OUTPUT_ROTATION=${KIOSK_OUTPUT_ROTATION} KIOSK_OUTPUT_SCALE=${KIOSK_OUTPUT_SCALE} ${ROTATE_HELPER} &

EOF

if [[ "$KIOSK_ENABLE" == "1" ]]; then
  echo "${CHROME_BIN} ${COMMON_FLAGS} --user-data-dir=${PROFILE_DIR} ${KIOSK_URL} &" >>"$tmp"
fi

sudo mv "$tmp" "$AUTOSTART"
sudo chown "${TARGET_USER}:${TARGET_USER}" "$AUTOSTART"
sudo chmod 0644 "$AUTOSTART"

log "Done."
log "labwc autostart:  ${AUTOSTART}"
log "display helper:   ${ROTATE_HELPER}"
log "URL:              ${KIOSK_URL}"
