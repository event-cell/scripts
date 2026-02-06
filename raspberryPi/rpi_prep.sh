#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Raspberry Pi "golden image" prep script
# - Mandatory argument: hostname
# - Friendly status output
# - Installs a one-shot "uniquify" service for post-clone identity fixes
#   (machine-id + SSH host keys) while keeping hostname from argument.
#
# Usage:
#   ./prep.sh <hostname>
# Example:
#   ./prep.sh sdma-kiosk-01
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
Usage: $(basename "$0") <hostname>

<hostname> is mandatory and should be a valid Linux hostname:
- lowercase letters, digits, hyphen
- 1..63 chars per label, must start/end with alnum
Examples:
  $(basename "$0") pi-display-01
  $(basename "$0") sdma-kiosk-01
EOF
}

validate_hostname() {
  local h="$1"
  # Basic RFC-ish hostname label validation (single-label)
  if [[ ! "$h" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    err "Invalid hostname: '$h'"
    usage
    exit 2
  fi
}

# ---------- mandatory arg ----------
HOSTNAME_ARG="${1:-}"
if [[ -z "${HOSTNAME_ARG}" ]]; then
  err "Hostname argument is required."
  usage
  exit 2
fi
validate_hostname "${HOSTNAME_ARG}"

# ---------- sanity checks ----------
need_cmd sudo
need_cmd grep
need_cmd sed
need_cmd systemctl
need_cmd timedatectl

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  warn "You're running as root. This script is intended to be run as user 'pi' (it uses sudo). Continuing anyway."
fi

# ---------- constants ----------
REPO_HOST="mirror.aarnet.edu.au"
REPO_PATH="mirror.aarnet.edu.au/pub/raspbian/raspbian/"
DEFAULT_TZ="Australia/Sydney"

# Uniquify components (keeps hostname as provided)
UNIQ_SCRIPT="/usr/local/sbin/pi-uniquify-once.sh"
UNIQ_SERVICE="/etc/systemd/system/pi-uniquify-once.service"
HOSTNAME_MARKER="/etc/pi-hostname-set.done"

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
# 2) Hostname (mandatory argument)
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

log "Enabling and starting VNC server..."
sudo systemctl enable vncserver-x11-serviced.service
sudo systemctl restart vncserver-x11-serviced.service
ok "VNC server enabled and started"

log "Installing useful packages..."
sudo apt-get install -y \
  baobab \
  rsync \
  unclutter \
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
  wget -q https://github.com/azlux/log2ram/archive/master.tar.gz -O "${TMPDIR}/log2ram.tar.gz"
  tar -C "$TMPDIR" -xf "${TMPDIR}/log2ram.tar.gz"

  log "Installing log2ram (running install.sh from its directory)..."
  (
    cd "${TMPDIR}/log2ram-master"
    sudo bash ./install.sh
  )
  ok "log2ram installed"

  # Sanity checks + start
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
# 8) Desktop autostart (pi)
# ============================================================================
section "Desktop autostart (LXDE-pi)"

AUTOSTART_DIR="$HOME/.config/lxsession/LXDE-pi"
AUTOSTART_FILE="${AUTOSTART_DIR}/autostart"
log "Ensuring autostart directory exists..."
mkdir -p "$AUTOSTART_DIR"

log "Fetching autostart file..."
wget -q https://raw.githubusercontent.com/event-cell/scripts/main/raspberryPi/LXDE-pi.autostart \
  --output-document="$AUTOSTART_FILE"
ok "Autostart file updated: ${AUTOSTART_FILE}"

# ============================================================================
# 9) Make-clone-unique (recommended for imaging/cloning)
#    One-shot service that runs ONCE on first boot after cloning:
#      - machine-id => regenerated
#      - SSH host keys => regenerated
#    Hostname is NOT changed here (it comes from the mandatory argument).
# ============================================================================
section "Clone uniqueness (first-boot one-shot)"

log "Installing first-boot uniquify script: ${UNIQ_SCRIPT}"
sudo tee "${UNIQ_SCRIPT}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG="/var/log/pi-uniquify-once.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date -Is) pi-uniquify-once starting ==="

# 1) Regenerate machine-id (system identity)
echo "Resetting machine-id..."
rm -f /etc/machine-id /var/lib/dbus/machine-id || true
systemd-machine-id-setup

# 2) Regenerate SSH host keys (avoids clones sharing host identity)
echo "Regenerating SSH host keys..."
rm -f /etc/ssh/ssh_host_* || true
ssh-keygen -A

# Restart SSH so new keys are active immediately (best-effort)
if systemctl is-active --quiet ssh; then
  systemctl restart ssh || true
elif systemctl is-active --quiet sshd; then
  systemctl restart sshd || true
fi

# 3) Mark complete (so it won't run again)
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
log "Hostname now set to: ${HOSTNAME_ARG}"
log "On first boot after cloning, the device will:"
log "  - regenerate /etc/machine-id"
log "  - regenerate SSH host keys"
log "Logs: /var/log/pi-uniquify-once.log"
