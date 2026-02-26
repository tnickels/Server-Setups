#!/bin/bash
# =============================================================================
# Ubuntu Server Initial Setup Script
# Safe to run on systems with Coolify or HestiaCP already installed
# Run as root on an Ubuntu server
# =============================================================================

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# Helper to ask yes/no questions (default no)
ask_yn() {
    local prompt="$1"
    local response
    read -p "${prompt} [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]]
}

echo "============================================"
echo "  Ubuntu Server Initial Setup"
echo "============================================"
echo ""

# --------------------------------------------------
# DETECT EXISTING SERVICES
# --------------------------------------------------
COOLIFY_RUNNING=false
HESTIA_RUNNING=false

if systemctl is-active --quiet coolify 2>/dev/null || docker ps 2>/dev/null | grep -q coolify; then
    COOLIFY_RUNNING=true
    warn "Coolify detected — will skip conflicting steps."
fi

if systemctl is-active --quiet hestia 2>/dev/null || [ -d /usr/local/hestia ]; then
    HESTIA_RUNNING=true
    warn "HestiaCP detected — will skip conflicting steps."
fi

echo ""

# --------------------------------------------------
# 0. HOSTNAME / COMPUTER NAME
# --------------------------------------------------
CURRENT_HOSTNAME=$(hostname)
SUGGESTED_HOSTNAME=${CURRENT_HOSTNAME}

# Generate a friendlier suggestion if it's a generic cloud hostname
if echo "${CURRENT_HOSTNAME}" | grep -qiE '^(localhost|ubuntu|vps|server|ip-|ec2-|instance)'; then
    SUGGESTED_HOSTNAME="node-server"
fi

if [ "$HESTIA_RUNNING" = true ]; then
    warn "HestiaCP uses the hostname for panel access and SSL certificates."
    warn "Changing it can break your panel if you don't update Hestia's config afterwards."
    info "Current hostname: ${CURRENT_HOSTNAME}"
    if ask_yn "Change hostname anyway?"; then
        read -p "Enter computer name [${SUGGESTED_HOSTNAME}]: " NEW_HOSTNAME
        NEW_HOSTNAME=${NEW_HOSTNAME:-${SUGGESTED_HOSTNAME}}
    else
        NEW_HOSTNAME=${CURRENT_HOSTNAME}
        log "Keeping hostname: ${CURRENT_HOSTNAME}"
    fi
else
    read -p "Enter computer name [${SUGGESTED_HOSTNAME}]: " NEW_HOSTNAME
    NEW_HOSTNAME=${NEW_HOSTNAME:-${SUGGESTED_HOSTNAME}}
fi

# Sanitise hostname (lowercase, alphanumeric and hyphens only)
NEW_HOSTNAME=$(echo "${NEW_HOSTNAME}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/^-//;s/-$//')

if [ "${NEW_HOSTNAME}" != "${CURRENT_HOSTNAME}" ]; then
    log "Setting hostname to: ${NEW_HOSTNAME}"
    hostnamectl set-hostname "${NEW_HOSTNAME}"

    # Update /etc/hosts
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/127.0.1.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
    else
        echo "127.0.1.1	${NEW_HOSTNAME}" >> /etc/hosts
    fi
else
    log "Keeping hostname: ${NEW_HOSTNAME}"
fi

# --------------------------------------------------
# 1. SYSTEM UPDATE & UPGRADE
# --------------------------------------------------
if [ "$HESTIA_RUNNING" = true ] || [ "$COOLIFY_RUNNING" = true ]; then
    log "Updating package lists (skipping upgrade to protect panel-managed packages)..."
    apt update -y
else
    log "Updating and upgrading system packages..."
    apt update -y && apt upgrade -y
    apt autoremove -y
    apt autoclean -y
fi

# --------------------------------------------------
# 2. TIMEZONE
# --------------------------------------------------
log "Setting timezone to Australia/Adelaide..."
timedatectl set-timezone Australia/Adelaide

# --------------------------------------------------
# 3. SWAP CONFIGURATION
# --------------------------------------------------
RECOMMENDED_SWAP="4G"
RECOMMENDED_SWAP_BYTES=$((4 * 1024 * 1024 * 1024))

CURRENT_SWAP_BYTES=$(swapon --show --bytes --noheadings 2>/dev/null | awk '{sum += $3} END {print sum+0}')
CURRENT_SWAP_HUMAN=""

if [ "$CURRENT_SWAP_BYTES" -gt 0 ] 2>/dev/null; then
    CURRENT_SWAP_HUMAN=$(numfmt --to=iec-i --suffix=B ${CURRENT_SWAP_BYTES} 2>/dev/null || echo "${CURRENT_SWAP_BYTES} bytes")

    if [ "$CURRENT_SWAP_BYTES" -ne "$RECOMMENDED_SWAP_BYTES" ]; then
        echo ""
        info "Current swap: ${CURRENT_SWAP_HUMAN}"
        info "Recommended:  ${RECOMMENDED_SWAP}"
        if ask_yn "Change swap to ${RECOMMENDED_SWAP}?"; then
            log "Reconfiguring swap to ${RECOMMENDED_SWAP}..."
            swapoff -a
            [ -f /swapfile ] && rm /swapfile
            fallocate -l ${RECOMMENDED_SWAP} /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            sed -i '/\/swapfile/d' /etc/fstab
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        else
            log "Keeping current swap: ${CURRENT_SWAP_HUMAN}"
        fi
    else
        log "Swap already set to ${RECOMMENDED_SWAP}, no changes needed."
    fi
else
    log "No swap detected — creating ${RECOMMENDED_SWAP} swap file..."
    fallocate -l ${RECOMMENDED_SWAP} /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
fi

# --------------------------------------------------
# 4. SWAPPINESS & CACHE PRESSURE
# --------------------------------------------------
log "Tuning swappiness and cache pressure..."
cat > /etc/sysctl.d/99-server-tuning.conf << 'EOF'
# Swap tuning - lower value means less swapping (default 60)
vm.swappiness = 10

# Cache pressure - lower value keeps directory/inode caches longer (default 100)
vm.vfs_cache_pressure = 50
EOF

# --------------------------------------------------
# 5. NETWORK / TCP TUNING
# --------------------------------------------------
log "Applying network and TCP optimisations..."
cat >> /etc/sysctl.d/99-server-tuning.conf << 'EOF'

# TCP tuning for WebSocket/real-time workloads
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Increase buffer sizes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Security
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# File system
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
EOF

sysctl -p /etc/sysctl.d/99-server-tuning.conf

# --------------------------------------------------
# 6. FILE DESCRIPTOR LIMITS
# --------------------------------------------------
RECOMMENDED_NOFILE=65535

CURRENT_NOFILE=$(grep -E '^\*\s+hard\s+nofile' /etc/security/limits.conf 2>/dev/null | awk '{print $4}' | tail -1)

if [ -n "$CURRENT_NOFILE" ] && [ "$CURRENT_NOFILE" -gt 0 ] 2>/dev/null; then
    if [ "$CURRENT_NOFILE" -ne "$RECOMMENDED_NOFILE" ]; then
        echo ""
        info "Current file descriptor limit (nofile hard): ${CURRENT_NOFILE}"
        info "Recommended:                                 ${RECOMMENDED_NOFILE}"
        if ask_yn "Change file descriptor limits to ${RECOMMENDED_NOFILE}?"; then
            log "Updating file descriptor limits..."
            sed -i '/^\*.*nofile/d' /etc/security/limits.conf
            sed -i '/^root.*nofile/d' /etc/security/limits.conf
            cat >> /etc/security/limits.conf << EOF
*    soft    nofile    ${RECOMMENDED_NOFILE}
*    hard    nofile    ${RECOMMENDED_NOFILE}
root soft    nofile    ${RECOMMENDED_NOFILE}
root hard    nofile    ${RECOMMENDED_NOFILE}
EOF
        else
            log "Keeping current file descriptor limit: ${CURRENT_NOFILE}"
        fi
    else
        log "File descriptor limits already set to ${RECOMMENDED_NOFILE}, no changes needed."
    fi
else
    log "Setting file descriptor limits to ${RECOMMENDED_NOFILE}..."
    cat >> /etc/security/limits.conf << EOF
*    soft    nofile    ${RECOMMENDED_NOFILE}
*    hard    nofile    ${RECOMMENDED_NOFILE}
root soft    nofile    ${RECOMMENDED_NOFILE}
root hard    nofile    ${RECOMMENDED_NOFILE}
EOF
fi

# --------------------------------------------------
# 7. JOURNALD LOG SIZE LIMIT
# --------------------------------------------------
log "Limiting journal log size to 500MB..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size-limit.conf << 'EOF'
[Journal]
SystemMaxUse=500M
EOF
systemctl restart systemd-journald

# --------------------------------------------------
# 8. AUTOMATIC SECURITY UPDATES (optional)
# --------------------------------------------------
# Skipped for HestiaCP/Coolify — auto-updates can break
# panel-managed packages and dependencies
if [ "$HESTIA_RUNNING" = true ] || [ "$COOLIFY_RUNNING" = true ]; then
    warn "Skipping unattended-upgrades (can break panel-managed packages)."
    info "Manage updates manually or through your panel instead."
else
    echo ""
    if ask_yn "Enable automatic security updates?"; then
        log "Installing and configuring unattended-upgrades..."
        apt install -y unattended-upgrades
        cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    else
        log "Skipping unattended-upgrades."
    fi
fi

# --------------------------------------------------
# 9. ESSENTIAL PACKAGES
# --------------------------------------------------
log "Installing essential packages..."
apt install -y \
    curl \
    wget \
    git \
    htop \
    iotop \
    net-tools \
    ncdu \
    zip \
    unzip \
    software-properties-common \
    ca-certificates \
    gnupg \
    lsb-release

# --------------------------------------------------
# 10. FAIL2BAN (skip if HestiaCP — it manages its own)
# --------------------------------------------------
if [ "$HESTIA_RUNNING" = true ]; then
    warn "Skipping fail2ban setup (HestiaCP manages its own fail2ban configuration)."
else
    log "Installing and configuring fail2ban..."
    apt install -y fail2ban

    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
maxretry = 3
bantime = 7200
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
fi

# --------------------------------------------------
# 11. SSH HARDENING (skip if HestiaCP — it manages its own)
# --------------------------------------------------
if [ "$HESTIA_RUNNING" = true ]; then
    warn "Skipping SSH hardening (HestiaCP manages its own SSH configuration)."
else
    log "Hardening SSH configuration..."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 5/' /etc/ssh/sshd_config
    sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 300/' /etc/ssh/sshd_config
    sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 3/' /etc/ssh/sshd_config

    # Ubuntu 24.04 uses ssh.service, older versions use sshd.service
    if systemctl list-units --type=service | grep -q 'ssh.service'; then
        systemctl restart ssh
    elif systemctl list-units --type=service | grep -q 'sshd.service'; then
        systemctl restart sshd
    else
        warn "Could not determine SSH service name — restart SSH manually."
    fi
fi

# --------------------------------------------------
# 12. UFW FIREWALL (optional — skipped for Coolify/HestiaCP)
# --------------------------------------------------
UFW_INSTALLED=false

if [ "$HESTIA_RUNNING" = true ]; then
    warn "Skipping UFW (HestiaCP has its own iptables firewall)."
elif [ "$COOLIFY_RUNNING" = true ]; then
    warn "Skipping UFW (Docker bypasses UFW rules)."
    info "Use your cloud provider's firewall or ufw-docker instead."
else
    echo ""
    if ask_yn "Install and configure UFW firewall?"; then
        log "Installing and configuring UFW..."
        apt install -y ufw
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow ssh
        UFW_INSTALLED=true
        warn "UFW is installed but NOT enabled. Add your rules then run: ufw enable"
    else
        log "Skipping UFW installation."
    fi
fi

# --------------------------------------------------
# 13. CUSTOM SHELL PROMPT
# --------------------------------------------------
log "Setting up custom shell prompt..."
PROMPT_DEFAULT=$(echo "${NEW_HOSTNAME}" | tr '[:lower:]' '[:upper:]')
read -p "Enter display name for prompt [${PROMPT_DEFAULT}]: " PROMPT_NAME
PROMPT_NAME=${PROMPT_NAME:-${PROMPT_DEFAULT}}
HOSTNAME_UPPER=$(echo "${PROMPT_NAME}" | tr '[:lower:]' '[:upper:]')

# Prompt format: user@COMPUTERNAME: /current/path %
PROMPT_LINE="PS1='\u@${HOSTNAME_UPPER}: \w % '"

# Apply to all existing users and root
for HOMEDIR in /root /home/*/; do
    if [ -d "${HOMEDIR}" ]; then
        BASHRC="${HOMEDIR}.bashrc"
        if [ -f "${BASHRC}" ]; then
            sed -i '/# NodeHoldings custom prompt/d' "${BASHRC}"
        fi
        echo "${PROMPT_LINE}  # NodeHoldings custom prompt" >> "${BASHRC}"
    fi
done

# Apply to all future users via /etc/profile.d
cat > /etc/profile.d/custom-prompt.sh << EOF
# Custom prompt: user@COMPUTERNAME: path %
${PROMPT_LINE}
EOF
chmod +x /etc/profile.d/custom-prompt.sh

# Apply to current session
eval "${PROMPT_LINE}"

# --------------------------------------------------
# SUMMARY
# --------------------------------------------------
echo ""
echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
echo "  Hostname:       ${NEW_HOSTNAME}"
echo "  Prompt:         user@${HOSTNAME_UPPER}: /path %"
echo "  Timezone:       $(timedatectl | grep 'Time zone' | awk '{print $3}')"
echo "  Swap:           $(swapon --show --noheadings | awk '{print $3}' | head -1)"
echo "  Swappiness:     $(cat /proc/sys/vm/swappiness)"
echo "  Cache Pressure: $(cat /proc/sys/vm/vfs_cache_pressure)"
echo "  File Desc:      $(grep -E '^\*\s+hard\s+nofile' /etc/security/limits.conf | awk '{print $4}' | tail -1)"
if [ "$HESTIA_RUNNING" = true ]; then
echo "  HestiaCP:       detected (using its own firewall, fail2ban, SSH config)"
fi
if [ "$COOLIFY_RUNNING" = true ]; then
echo "  Coolify:        detected (use provider firewall or ufw-docker)"
echo "  Fail2ban:       $(systemctl is-active fail2ban)"
fi
if [ "$HESTIA_RUNNING" = false ] && [ "$COOLIFY_RUNNING" = false ]; then
echo "  Fail2ban:       $(systemctl is-active fail2ban)"
fi
if [ "$UFW_INSTALLED" = true ]; then
echo "  UFW:            installed (NOT enabled — review rules first)"
fi
echo ""
if [ "$UFW_INSTALLED" = true ]; then
    warn "REMINDER: UFW is NOT enabled. Add your port rules then run: ufw enable"
fi
warn "REMINDER: Reboot recommended to apply all changes."
warn "REMINDER: Reconnect your SSH session to see the new prompt."
echo ""
