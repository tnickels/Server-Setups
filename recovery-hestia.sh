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

# Remove the broken jail.local we created
if [ -f /etc/fail2ban/jail.local ]; then
    warn "Removing overwritten /etc/fail2ban/jail.local..."
    rm /etc/fail2ban/jail.local
fi

# HestiaCP stores its fail2ban config in /etc/fail2ban/jail.local
# but it also uses configs in /etc/fail2ban/jail.d/
# Reinstall HestiaCP's fail2ban configuration
if [ -d /usr/local/hestia ]; then
    log "Regenerating HestiaCP fail2ban configuration..."

    # HestiaCP has a rebuild command that restores its fail2ban jails
    /usr/local/hestia/bin/v-update-firewall

    # Verify HestiaCP's fail2ban filters exist
    if [ -d /etc/fail2ban/filter.d ]; then
        HESTIA_FILTERS=$(ls /etc/fail2ban/filter.d/hestia* 2>/dev/null | wc -l)
        if [ "$HESTIA_FILTERS" -gt 0 ]; then
            log "Found ${HESTIA_FILTERS} HestiaCP fail2ban filters."
        else
            warn "No HestiaCP fail2ban filters found — they may need manual restoration."
        fi
    fi
else
    err "HestiaCP not found at /usr/local/hestia — cannot auto-restore."
fi

# Restart fail2ban
log "Restarting fail2ban..."
systemctl restart fail2ban
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

# The SSH restart failed, so changes may not have applied.
# But the backup was created, so restore it to be safe.
if [ -f /etc/ssh/sshd_config.bak ]; then
    log "Restoring SSH config from backup..."
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    rm /etc/ssh/sshd_config.bak

    # Use correct service name for Ubuntu 24.04
    log "Restarting SSH service..."
    systemctl restart ssh
    log "SSH status: $(systemctl is-active ssh)"
else
    warn "No sshd_config.bak found — SSH config may not have been modified."
    warn "The restart failed earlier so changes likely didn't apply."
fi

# --------------------------------------------------
# 3. VERIFY HESTIA SERVICES
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
echo "    - Removed overwritten /etc/fail2ban/jail.local"
echo "    - Regenerated HestiaCP fail2ban configuration"
echo "    - Restored original SSH config from backup"
echo "    - Restarted fail2ban and SSH services"
echo ""
warn "Please verify your HestiaCP panel is accessible at https://vps.nodeholdings.com.au:8083"
warn "Check fail2ban jails above match what you expect."
echo ""
