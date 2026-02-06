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
#   NOTE: RPi may capitalise first letter (Screen01). We handle this.
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

  # Add section if missing
  if ! grep -qE "^\[$(printf '%s' "$section" | sed 's/[]\/$*.^|[]/\\&/g')\]\s*$" "$file"; then
    {
      echo ""
      echo "[$section]"
      echo "${key}=${value}"
    } >>"$file"
    return 0
  fi

  awk -v section="$section" -v key="$key" -v value="$value" '
    function print_kv() { print key "=" value; }
    BEGIN { in_section=0; key_done=0; }
    {
      if ($0 ~ /^\[/) {
        if (in_section && !key_done) { print_kv(); key_done=1; }
        in_section = ($0 == "[" section "]") ? 1 : 0;
        print $0;
        next;
      }
      if (in_section) {
        if ($0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
          if (!key_done) { print_kv(); key_done=1; }
          next;
        }
      }
      print $0;
    }
    END { if (in_section && !key_done) { print_kv(); } }
  ' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
}

ini_autostart_remove_key() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -v key="$key" '
    BEGIN { in_autostart=0; }
    {
      if ($0 ~ /^\[autostart\][[:space:]]*$/) { in_autostart=1; print; next; }
      if ($0 ~ /^\[/ && $0 !~ /^\[autostart\][[:space:]]*$/) { in_autostart=0; print; next; }
      if (in_autostart && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") { next; }
      print;
    }
  ' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
}

# Ensure Wayfire plugins needed for our settings are enabled
# (Without 'idle' and 'autostart', dpms_timeout + autostart keys may do nothing.)
ensure_wayfire_plugins() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  touch "$file"

  # Ensure [core] exists
  if ! grep -qE '^\[core\]\s*$' "$file"; then
    {
      echo ""
      echo "[core]"
      echo "plugins = autostart idle"
    } >>"$file"
    return 0
  fi

  # Get current plugins line (if any)
  local plugins
  plugins="$(awk '
    BEGIN{in=0}
    /^\[core\]/{in=1; next}
    /^\[/{in=0}
    in && $0 ~ /^[[:space:]]*plugins[[:space:]]*=/ {
      sub(/^[^=]*=/,""); print; exit
    }
  ' "$file" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"

  if [[ -z "$plugins" ]]; then
    ini_set "$file" "core" "plugins" "autostart idle"
    return 0
  fi

  for p in autostart idle; do
    if ! echo " $plugins " | grep -q " $p "; then
      plugins="$plugins $p"
    fi
  done
  plugins="$(echo "$plugins" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
  ini_set "$file" "core" "plugins" "$plugins"
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

  # screen01..screen04 (handles Screen01 etc.)
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

log "Installing required packages (ydotool + chromium)..."
sudo apt-get update -y
sudo apt-get install -y ydotool chromium-browser || sudo apt-get install -y ydotool chromium || true

log "Creating/ensuring ydotoold systemd service..."
sudo tee /etc/systemd/system/ydotoold.service >/dev/null <<'UNIT'
[Unit]
Description=ydotool daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/ydotoold --socket-path=/tmp/ydotool_socket --socket-perm=0666
Restart=always
RestartSec=1
User=root

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now ydotoold.service

log "Creating hide-cursor helper script..."
HIDE_CURSOR_SCRIPT="/usr/local/bin/hide-cursor-wayland.sh"
sudo tee "$HIDE_CURSOR_SCRIPT" >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail

sleep 8

SOCK="/tmp/ydotool_socket"
export YDOTOOL_SOCKET="$SOCK"

for i in {1..30}; do
  [[ -S "$SOCK" ]] && break
  sleep 0.2
done

while true; do
  /usr/bin/ydotool mousemove --delay 0 100000 100000 >/dev/null 2>&1 || true
  sleep 30
done
SH
sudo chmod 0755 "$HIDE_CURSOR_SCRIPT"

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

# Write a deterministic wayfire.ini (ordering matters; keep [core] first)
tmp="$(mktemp)"
cat >"$tmp" <<EOF
[core]
plugins = autostart idle

[idle]
dpms_timeout = -1

[autostart]
cursor = ${HIDE_CURSOR_SCRIPT}
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
log "Cursor script:  ${HIDE_CURSOR_SCRIPT}"
log "URL:            ${KIOSK_URL}"
