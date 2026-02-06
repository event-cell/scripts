#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Raspberry Pi "golden image" prep script
# - Mandatory argument: screen number (single digit 1..4)
# - Sets hostname to screen01..screen04
# - Friendly status output
# - Installs a one-shot "uniquify" service for post-clone identity fixes
#   (machine-id + SSH host keys)
#
# Usage:
#   ./prep.sh <screen_number>
# Example:
#   ./prep.sh 1   -> hostname screen01
#   ./prep.sh 4   -> hostname screen04
# ============================================================================

# ---------- pretty logging ----------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""
fi

log()    { echo "${C_BLU}•${C_RESET} $*"; }
ok()     { echo "${C_GRN}✔${C_RESET} $*"; }
warn()   { echo "${C_YEL}⚠${C_RESET} $*"; }
err()    { echo "${C_RED}✖${C_RESET} $*" >&2; }
section(){ echo; echo "${C_BOLD}== $* ==${C_RESET}"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <screen_number>

<screen_number> is mandatory and must be a single digit 1..4.
It will be expanded to hostname screen01..screen04.

Examples:
  $(basename "$0") 1   # -> screen01
  $(basename "$0") 2   # -> screen02
  $(basename "$0") 3   # -> screen03
  $(basename "$0") 4   # -> screen04
EOF
}

validate_screen_number() {
  local n="$1"
  if [[ ! "$n" =~ ^[1-4]$ ]]; then
    err "Invalid screen number: '$n' (must be 1..4)"
    usage
    exit 2
  fi
}

# ---------- mandatory arg ----------
SCREEN_NUMBER_ARG="${1:-}"
if [[ -z "${SCREEN_NUMBER_ARG}" ]]; then
  err "Screen number argument is required."
  usage
  exit 2
fi
validate_screen_number "${SCREEN_NUMBER_ARG}"

SCREEN_NUMBER="${SCREEN_NUMBER_ARG}"
HOSTNAME_ARG
HOSTNAME_ARG="$(printf 'screen%02d' "${SCREEN_NUMBER}")"

# ---------- sanity checks ----------
need_cmd sudo
need_cmd grep
need_cmd sed
need_cmd systemctl
need_cmd timedatectl
need_cmd wget

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  warn "You're running as root. This script is intended to be run as user 'pi' (it uses sudo). Continuing anyway."
fi

# ---------- constants ----------
REPO_HOST="mirror.aarnet.edu.au"
REPO_PATH="mirror.aarnet.edu.au/pub/raspbian/raspbian/"
DEFAULT_TZ="Australia/Sydney"

# Uniquify components
UNIQ_SCRIPT="/usr/local/sbin/pi-uniquify-once.sh"
UNIQ_SERVICE="/etc/systemd/system/pi-uniquify-once.service"
HOSTNAME_MARKER="/etc/pi-hostname-set.done"

# Display/kiosk setup (Wayland)
DISPLAY_SETUP_URL="https://raw.githubusercontent.com/event-cell/scripts/refs/heads/main/raspberryPi/setup-display.sh"
DISPLAY_SETUP_LOCAL="/usr/local/sbin/setup-display.sh"

# ============================================================================
# 1) User setup (pi)
# ============================================================================
section "User SSH setup (pi)"

log "Ensuring ~/.ssh exists with correct permissions..."
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
ok "~/.ssh and authorized_keys ready"

# ============================================================================
# 2) Hostname (derived from screen number)
# ============================================================================
section "Hostname"

CUR_HOST="$(hostname)"
if [[ "$CUR_HOST" != "$HOSTNAME_ARG" ]]; then
  log "Setting hostname: ${CUR_HOST} -> ${HOSTNAME_ARG}"
  sudo hostnamectl set-hostname "${HOSTNAME_ARG}"

  # Update /etc/hosts for 127.0.1.1 mapping
  if sudo grep -qE '^\s*127\.0\.1\.1\s+' /etc/hosts; then
    sudo sed -i -E "s|^\s*127\.0\.1\.1\s+.*$|127.0.1.1\t${HOSTNAME_ARG}|g" /etc/hosts
  else
    echo -e "127.0.1.1\t${HOSTNAME_ARG}" | sudo tee -a /etc/hosts >/dev/null
  fi

  echo "${HOSTNAME_ARG}" | sudo tee /etc/pi-hostname-set >/dev/null
  sudo touch "${HOSTNAME_MARKER}"
  ok "Hostname set to ${HOSTNAME_ARG}"
else
  ok "Hostname already ${HOSTNAME_ARG}"
fi

ok "SCREEN_NUMBER=${SCREEN_NUMBER} (from argument)"

# ============================================================================
# 3) Base OS config (root tasks)
# ============================================================================
section "System timezone & clock"

log "Setting timezone to ${DEFAULT_TZ}..."
sudo timedatectl set-timezone "${DEFAULT_TZ}"
ok "Timezone set to $(timedatectl show -p Timezone --value)"

log "Current date/time:"
date

# ============================================================================
# 4) APT mirror + cleanup + updates
# ============================================================================
section "APT mirror, cleanup and updates"

log "Checking APT sources for ${REPO_HOST}..."
if ! grep -Fq "${REPO_HOST}" /etc/apt/sources.list; then
  log "Switching raspbian mirror to ${REPO_PATH}..."
  sudo sed -i -e "s|raspbian\.raspberrypi\.org/raspbian/|${REPO_PATH}|g" /etc/apt/sources.list
  ok "Mirror updated in /etc/apt/sources.list"

  log "Removing preinstalled desktop apps you don't want..."
  sudo apt-get purge -y vlc geany thonny qpdfview dillo gpicview cups git || true
  sudo apt-get autoremove -y
  sudo apt-get autoclean -y
  ok "Package cleanup complete"

  log "Updating package lists..."
  sudo apt-get update -y

  log "Upgrading packages..."
  sudo apt-get upgrade -y
  ok "APT update/upgrade complete"
else
  ok "Mirror already set (${REPO_HOST} present); skipping mirror swap + heavy upgrade block"
  log "Running a lightweight update anyway..."
  sudo apt-get update -y
fi

# ============================================================================
# 5) Services and packages
# ============================================================================
section "Services and packages"

# -----------------------------------------------------------------------------
# VNC (Wayland/Bookworm): replace RealVNC X11 service with WayVNC
# - RealVNC's vncserver-x11-serviced does not work on Wayland.
# - Use wayvnc (the supported VNC server for Wayland sessions on Raspberry Pi OS).
# -----------------------------------------------------------------------------

# Remove the old RealVNC package if it was being installed (best-effort)
sudo apt-get purge -y realvnc-vnc-server || true

# Install WayVNC + a minimal RDP/VNC helper stack (Wayland)
sudo apt-get update -y
sudo apt-get install -y wayvnc

# Disable the old X11 VNC service (best-effort) so it doesn't conflict / mislead
sudo systemctl disable --now vncserver-x11-serviced.service 2>/dev/null || true
sudo systemctl disable --now vncserver-x11.service 2>/dev/null || true
sudo systemctl disable --now vncserver.service 2>/dev/null || true

# Enable and start WayVNC (Wayland VNC server)
sudo systemctl enable --now wayvnc.service

# Quick sanity check
sudo systemctl --no-pager --full status wayvnc.service || true

# Optional: confirm it’s listening on TCP/5900
# (will show LISTEN entries if active)
sudo ss -ltnp | grep -E ':5900\b' || true

log "Installing useful packages..."
sudo apt-get install -y \
  baobab \
  rsync \
  wget \
  ca-certificates \
  tar
ok "Packages installed"

# ============================================================================
# 6) Journald size management
# ============================================================================
section "Journald log size management"

log "Vacuuming journal to ~20MB (best-effort)..."
sudo journalctl --vacuum-size=20M || true

log "Ensuring SystemMaxUse=32MB is set..."
JOURNALD_CONF="/etc/systemd/journald.conf"
if sudo grep -Eq '^\s*SystemMaxUse\s*=' "$JOURNALD_CONF"; then
  sudo sed -i -E 's|^\s*SystemMaxUse\s*=.*$|SystemMaxUse=32MB|g' "$JOURNALD_CONF"
  ok "Updated existing SystemMaxUse to 32MB"
else
  if sudo grep -Eq '^\s*#\s*SystemMaxUse\s*=' "$JOURNALD_CONF"; then
    sudo sed -i -E 's|^\s*#\s*SystemMaxUse\s*=.*$|SystemMaxUse=32MB|g' "$JOURNALD_CONF"
    ok "Uncommented and set SystemMaxUse=32MB"
  else
    echo "SystemMaxUse=32MB" | sudo tee -a "$JOURNALD_CONF" >/dev/null
    ok "Appended SystemMaxUse=32MB"
  fi
fi

log "Restarting journald..."
sudo systemctl restart systemd-journald
ok "journald configured"

# ============================================================================
# Log2ram install
# ============================================================================
section "Log2ram install"

log "Checking if log2ram appears installed..."
if command -v log2ram >/dev/null 2>&1 || systemctl list-unit-files | grep -q '^log2ram\.service'; then
  ok "log2ram already installed; skipping"
else
  TMPDIR="$(mktemp -d)"
  log "Downloading log2ram into ${TMPDIR}..."
  wget -4 -q https://github.com/azlux/log2ram/archive/master.tar.gz -O "${TMPDIR}/log2ram.tar.gz"
  tar -C "$TMPDIR" -xf "${TMPDIR}/log2ram.tar.gz"

  log "Installing log2ram (running install.sh from its directory)..."
  (
    cd "${TMPDIR}/log2ram-master"
    sudo bash ./install.sh
  )
  ok "log2ram installed"

  if [[ ! -f /etc/log2ram.conf ]]; then
    warn "/etc/log2ram.conf missing after install; attempting to recover from repo default..."
    sudo cp -a "${TMPDIR}/log2ram-master/log2ram.conf" /etc/log2ram.conf || true
  fi

  sudo systemctl daemon-reload || true
  sudo systemctl enable log2ram.service >/dev/null 2>&1 || true
  sudo systemctl restart log2ram.service || true

  rm -rf "$TMPDIR"
  ok "Cleaned up temp files"
fi

# ============================================================================
# 8) Display / kiosk setup (Wayland)
# ============================================================================
section "Display / kiosk setup (Wayland)"

log "Removing old LXDE autostart (best-effort)..."
AUTOSTART_FILE="$HOME/.config/lxsession/LXDE-pi/autostart"
if [[ -f "$AUTOSTART_FILE" ]]; then
  rm -f "$AUTOSTART_FILE" || true
  ok "Removed old LXDE autostart file: ${AUTOSTART_FILE}"
else
  ok "No old LXDE autostart file found"
fi

log "Downloading display setup script..."
sudo mkdir -p "$(dirname "$DISPLAY_SETUP_LOCAL")"
sudo wget -4 -q "$DISPLAY_SETUP_URL" -O "$DISPLAY_SETUP_LOCAL"
sudo chmod 0755 "$DISPLAY_SETUP_LOCAL"
ok "Downloaded: ${DISPLAY_SETUP_LOCAL}"

log "Running display setup script with SCREEN_NUMBER=${SCREEN_NUMBER}..."
sudo env \
  SCREEN_NUMBER="${SCREEN_NUMBER}" \
  KIOSK_BASE_URL="http://timing.sdma" \
  KIOSK_ROTATE_ENABLE="${KIOSK_ROTATE_ENABLE:-0}" \
  KIOSK_OUTPUT_ROTATION="${KIOSK_OUTPUT_ROTATION:-270}" \
  KIOSK_OUTPUT_PREFER="${KIOSK_OUTPUT_PREFER:-HDMI}" \
  "${DISPLAY_SETUP_LOCAL}"
ok "Display setup complete"

# ============================================================================
# 9) Make-clone-unique (recommended for imaging/cloning)
# ============================================================================
section "Clone uniqueness (first-boot one-shot)"

log "Installing first-boot uniquify script: ${UNIQ_SCRIPT}"
sudo tee "${UNIQ_SCRIPT}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG="/var/log/pi-uniquify-once.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date -Is) pi-uniquify-once starting ==="

echo "Resetting machine-id..."
rm -f /etc/machine-id /var/lib/dbus/machine-id || true
systemd-machine-id-setup

echo "Regenerating SSH host keys..."
rm -f /etc/ssh/ssh_host_* || true
ssh-keygen -A

if systemctl is-active --quiet ssh; then
  systemctl restart ssh || true
elif systemctl is-active --quiet sshd; then
  systemctl restart sshd || true
fi

echo "Uniquify complete; creating marker file."
touch /var/lib/pi-uniquify-once.done

echo "=== $(date -Is) pi-uniquify-once finished ==="
EOF

sudo chmod 0755 "${UNIQ_SCRIPT}"
ok "Uniquify script installed"

log "Installing systemd service: ${UNIQ_SERVICE}"
sudo tee "${UNIQ_SERVICE}" >/dev/null <<EOF
[Unit]
Description=Make cloned Raspberry Pi unique (machine-id, SSH keys) - run once
After=network-pre.target
Wants=network-pre.target
ConditionPathExists=!/var/lib/pi-uniquify-once.done

[Service]
Type=oneshot
ExecStart=${UNIQ_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable pi-uniquify-once.service
ok "First-boot uniquify service enabled (will run once)"

# ============================================================================
# Done
# ============================================================================
section "Complete"

ok "Prep completed successfully."
log "Screen number: ${SCREEN_NUMBER}"
log "Hostname set to: ${HOSTNAME_ARG}"
log "On first boot after cloning, the device will:"
log "  - regenerate /etc/machine-id"
log "  - regenerate SSH host keys"
log "Logs: /var/log/pi-uniquify-once.log"
warn "A reboot is required for the new hostname to be active system-wide."
