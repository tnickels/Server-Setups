#!/bin/bash
# =============================================================================
# RECOVERY SCRIPT — Fix fail2ban and SSH after setup script damage
# Run as root on your HestiaCP server
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; }

echo "============================================"
echo "  HestiaCP Recovery Script"
echo "============================================"
echo ""

# --------------------------------------------------
# 1. RESTORE FAIL2BAN
# --------------------------------------------------
echo "--- FAIL2BAN RECOVERY ---"
echo ""

# Remove the broken jail.local if it exists
if [ -f /etc/fail2ban/jail.local ]; then
    warn "Removing overwritten /etc/fail2ban/jail.local..."
    rm /etc/fail2ban/jail.local
fi

# Restore from HestiaCP's install template
HESTIA_JAIL_TEMPLATE="/usr/local/hestia/install/deb/fail2ban/jail.local"

if [ -f "$HESTIA_JAIL_TEMPLATE" ]; then
    log "Restoring jail.local from HestiaCP template..."
    cp "$HESTIA_JAIL_TEMPLATE" /etc/fail2ban/jail.local
else
    err "HestiaCP fail2ban template not found at ${HESTIA_JAIL_TEMPLATE}"
    err "You may need to manually restore /etc/fail2ban/jail.local"
    exit 1
fi

# Restart fail2ban and wait for socket
log "Restarting fail2ban..."
systemctl restart fail2ban
sleep 3

# Verify jails are loaded
log "fail2ban status: $(systemctl is-active fail2ban)"
echo ""
echo "Current fail2ban jails:"
fail2ban-client status
echo ""

# --------------------------------------------------
# 2. RESTORE SSH CONFIG
# --------------------------------------------------
echo "--- SSH RECOVERY ---"
echo ""

if [ -f /etc/ssh/sshd_config.bak ]; then
    log "Restoring SSH config from backup..."
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    rm /etc/ssh/sshd_config.bak

    # Ubuntu 24.04 uses ssh.service not sshd.service
    log "Restarting SSH service..."
    if systemctl list-units --type=service | grep -q ' ssh.service'; then
        systemctl restart ssh
        log "SSH status: $(systemctl is-active ssh)"
    elif systemctl list-units --type=service | grep -q 'sshd.service'; then
        systemctl restart sshd
        log "SSH status: $(systemctl is-active sshd)"
    else
        warn "Could not determine SSH service name — restart SSH manually."
    fi
else
    warn "No sshd_config.bak found — SSH config may not have been modified."
    warn "The restart failed earlier so changes likely didn't apply."
fi

# --------------------------------------------------
# 3. REMOVE UNATTENDED-UPGRADES IF INSTALLED
# --------------------------------------------------
echo ""
echo "--- UNATTENDED-UPGRADES CHECK ---"
echo ""

if dpkg -l | grep -q unattended-upgrades; then
    warn "unattended-upgrades is installed (can break HestiaCP packages)."
    log "Removing unattended-upgrades..."
    apt remove -y unattended-upgrades
    rm -f /etc/apt/apt.conf.d/20auto-upgrades
    log "unattended-upgrades removed."
else
    log "unattended-upgrades not installed, nothing to do."
fi

# --------------------------------------------------
# 4. VERIFY HESTIA SERVICES
# --------------------------------------------------
echo ""
echo "--- SERVICE VERIFICATION ---"
echo ""

echo "Checking HestiaCP services..."
echo "  Hestia:    $(systemctl is-active hestia 2>/dev/null || echo 'not found')"
echo "  Nginx:     $(systemctl is-active nginx 2>/dev/null || echo 'not found')"
echo "  Apache:    $(systemctl is-active apache2 2>/dev/null || echo 'not found')"
echo "  Exim:      $(systemctl is-active exim4 2>/dev/null || echo 'not found')"
echo "  Dovecot:   $(systemctl is-active dovecot 2>/dev/null || echo 'not found')"
echo "  MariaDB:   $(systemctl is-active mariadb 2>/dev/null || echo 'not found')"
echo "  fail2ban:  $(systemctl is-active fail2ban 2>/dev/null || echo 'not found')"
echo "  SSH:       $(systemctl is-active ssh 2>/dev/null || echo 'not found')"
echo ""

# --------------------------------------------------
# SUMMARY
# --------------------------------------------------
echo "============================================"
echo "  Recovery Complete"
echo "============================================"
echo ""
echo "  What was fixed:"
echo "    - Restored /etc/fail2ban/jail.local from HestiaCP template"
echo "    - Restored original SSH config from backup (if backup existed)"
echo "    - Removed unattended-upgrades (if installed)"
echo "    - Restarted fail2ban and SSH services"
echo ""
warn "Please verify your HestiaCP panel is accessible."
warn "Check fail2ban jails above match what you expect."
echo ""
