#!/bin/bash
# =============================================================================
# Coolify fail2ban + Traefik Integration
# Enables Traefik access logging and configures fail2ban to ban abusive IPs
# via the DOCKER-USER iptables chain (which Docker actually respects)
# Run as root on a Coolify server
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
echo "  Coolify fail2ban + Traefik Integration"
echo "============================================"
echo ""

# --------------------------------------------------
# 1. PRE-FLIGHT CHECKS
# --------------------------------------------------
info "Running pre-flight checks..."

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root."
    exit 1
fi
log "Running as root."

# Coolify must be installed
if [ ! -d /data/coolify/proxy ]; then
    err "Coolify proxy directory not found at /data/coolify/proxy/"
    err "Is Coolify installed? This script requires Coolify."
    exit 1
fi
log "Coolify proxy directory found."

# Docker must be running
if ! docker info &>/dev/null; then
    err "Docker is not running. Start Docker and try again."
    exit 1
fi
log "Docker is running."

# fail2ban — install if missing
if ! command -v fail2ban-client &>/dev/null; then
    warn "fail2ban is not installed."
    if ask_yn "Install fail2ban now?"; then
        log "Installing fail2ban..."
        apt update -y
        apt install -y fail2ban
        systemctl enable fail2ban
        systemctl start fail2ban
        log "fail2ban installed and started."
    else
        err "fail2ban is required. Exiting."
        exit 1
    fi
else
    log "fail2ban is installed."
fi

# Verify the Traefik docker-compose exists
COMPOSE_FILE="/data/coolify/proxy/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
    err "Traefik compose file not found at ${COMPOSE_FILE}"
    exit 1
fi
log "Traefik compose file found."

echo ""

# --------------------------------------------------
# 2. ENABLE TRAEFIK ACCESS LOGGING
# --------------------------------------------------
info "Configuring Traefik access logging..."

# Create log directory on host
if [ ! -d /var/log/traefik ]; then
    mkdir -p /var/log/traefik
    log "Created /var/log/traefik/ directory."
else
    log "/var/log/traefik/ already exists."
fi

# Back up compose file
BACKUP_FILE="${COMPOSE_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$COMPOSE_FILE" "$BACKUP_FILE"
log "Backed up compose file to ${BACKUP_FILE}"

# Add volume mount if not already present
if grep -q '/var/log/traefik' "$COMPOSE_FILE"; then
    log "Traefik log volume mount already present."
else
    info "Adding /var/log/traefik volume mount to Traefik service..."
    # Insert the volume mount after the existing volumes list
    # Find the volumes section under the traefik service and append our mount
    if grep -q 'volumes:' "$COMPOSE_FILE"; then
        sed -i '/volumes:/,/^[^ ]/{
            /^ *- .*coolify\|^ *- .*docker\.sock\|^ *- .*letsencrypt\|^ *- .*traefik/{
                # Find the last volume line in the block and append after it
            }
        }' "$COMPOSE_FILE" 2>/dev/null || true

        # Simpler approach: find any existing volume line and add after the last one
        # We look for the last "- /data/coolify" or "- /var/run" volume line
        LAST_VOLUME_LINE=$(grep -n '^ *- ' "$COMPOSE_FILE" | tail -1 | cut -d: -f1)
        if [ -n "$LAST_VOLUME_LINE" ]; then
            sed -i "${LAST_VOLUME_LINE}a\\      - /var/log/traefik:/var/log/traefik" "$COMPOSE_FILE"
            log "Added volume mount: /var/log/traefik:/var/log/traefik"
        else
            err "Could not find volume entries in compose file. Add manually:"
            info "  volumes:"
            info "    - /var/log/traefik:/var/log/traefik"
        fi
    else
        err "No volumes section found in compose file. Add manually:"
        info "  volumes:"
        info "    - /var/log/traefik:/var/log/traefik"
    fi
fi

# Add access log command args if not already present
NEEDS_ACCESSLOG=false
if ! grep -q 'accesslog=true\|accesslog\.filepath\|accessLog' "$COMPOSE_FILE" 2>/dev/null; then
    NEEDS_ACCESSLOG=true
fi

if [ "$NEEDS_ACCESSLOG" = true ]; then
    info "Adding Traefik access log command arguments..."
    # Find the last --command line and add after it
    LAST_CMD_LINE=$(grep -n '^ *- --' "$COMPOSE_FILE" | tail -1 | cut -d: -f1)
    if [ -n "$LAST_CMD_LINE" ]; then
        sed -i "${LAST_CMD_LINE}a\\      - --accesslog=true\n      - --accesslog.filePath=/var/log/traefik/access.log\n      - --accesslog.format=common" "$COMPOSE_FILE"
        log "Added access log command arguments."
    else
        warn "Could not find command arguments in compose file."
        warn "Add these to the Traefik command section manually:"
        info "  - --accesslog=true"
        info "  - --accesslog.filePath=/var/log/traefik/access.log"
        info "  - --accesslog.format=common"
    fi
else
    log "Traefik access log arguments already present."
fi

# Restart Traefik
echo ""
info "Restarting Traefik to apply changes..."
if ask_yn "Restart Traefik now? (brief downtime for proxied services)"; then
    cd /data/coolify/proxy
    docker compose up -d --force-recreate
    cd - >/dev/null
    log "Traefik restarted."

    # Wait a moment for the log file to appear
    sleep 3
    if [ -f /var/log/traefik/access.log ]; then
        log "Access log file confirmed at /var/log/traefik/access.log"
    else
        warn "Access log file not yet created. It will appear after the first HTTP request."
    fi
else
    warn "Traefik not restarted. You must restart it manually for logging to take effect:"
    info "  cd /data/coolify/proxy && docker compose up -d --force-recreate"
fi

echo ""

# --------------------------------------------------
# 3. CONFIGURE FAIL2BAN FILTERS
# --------------------------------------------------
info "Creating fail2ban filters for Traefik..."

# Filter: traefik-auth — catches 401/403 (brute force / auth failures)
cat > /etc/fail2ban/filter.d/traefik-auth.conf << 'EOF'
# fail2ban filter for Traefik authentication failures (401/403)
# Works with Traefik common log format

[Definition]
failregex = ^<HOST> - - \[.*\] "[A-Z]+ .+" (401|403) \d+
ignoreregex =
EOF
log "Created /etc/fail2ban/filter.d/traefik-auth.conf (401/403 responses)"

# Filter: traefik-flood — catches 429 (rate limiting / flood)
cat > /etc/fail2ban/filter.d/traefik-flood.conf << 'EOF'
# fail2ban filter for Traefik rate-limited requests (429)
# Works with Traefik common log format

[Definition]
failregex = ^<HOST> - - \[.*\] "[A-Z]+ .+" 429 \d+
ignoreregex =
EOF
log "Created /etc/fail2ban/filter.d/traefik-flood.conf (429 responses)"

echo ""

# --------------------------------------------------
# 4. IP WHITELIST
# --------------------------------------------------
info "IP Whitelist Configuration"
info "Whitelisted IPs will never be banned by these jails."
info "You should add your own IP and any monitoring/office IPs."
echo ""

WHITELIST_IPS="127.0.0.1/8 ::1"

if ask_yn "Add IPs to the whitelist?"; then
    while true; do
        read -p "Enter an IP or CIDR to whitelist (or press Enter to finish): " NEW_IP
        if [ -z "$NEW_IP" ]; then
            break
        fi
        WHITELIST_IPS="${WHITELIST_IPS} ${NEW_IP}"
        log "Added ${NEW_IP} to whitelist."
    done
fi

log "Whitelist: ${WHITELIST_IPS}"
echo ""

# --------------------------------------------------
# 5. CONFIGURE FAIL2BAN JAILS (DOCKER-USER CHAIN)
# --------------------------------------------------
info "Creating fail2ban jails with DOCKER-USER chain..."

cat > /etc/fail2ban/jail.d/traefik.conf << EOF
# Traefik jails for Coolify — bans via DOCKER-USER chain
# so they apply to Docker-proxied traffic

[traefik-auth]
enabled  = true
filter   = traefik-auth
logpath  = /var/log/traefik/access.log
port     = http,https
maxretry = 5
findtime = 600
bantime  = 3600
chain    = DOCKER-USER
ignoreip = ${WHITELIST_IPS}

[traefik-flood]
enabled  = true
filter   = traefik-flood
logpath  = /var/log/traefik/access.log
port     = http,https
maxretry = 10
findtime = 60
bantime  = 3600
chain    = DOCKER-USER
ignoreip = ${WHITELIST_IPS}
EOF

log "Created /etc/fail2ban/jail.d/traefik.conf"
info "  traefik-auth:  ban after 5 auth failures in 10min, ban 1hr"
info "  traefik-flood: ban after 10 rate-limited requests in 1min, ban 1hr"

echo ""

# --------------------------------------------------
# 6. LOG ROTATION
# --------------------------------------------------
info "Setting up log rotation for Traefik access logs..."

# Get Traefik container name for the USR1 signal
TRAEFIK_CONTAINER=$(docker ps --filter "name=coolify-proxy" --format '{{.Names}}' | head -1)
if [ -z "$TRAEFIK_CONTAINER" ]; then
    TRAEFIK_CONTAINER=$(docker ps --filter "ancestor=traefik" --format '{{.Names}}' | head -1)
fi
if [ -z "$TRAEFIK_CONTAINER" ]; then
    TRAEFIK_CONTAINER="coolify-proxy"
    warn "Could not detect Traefik container name, defaulting to '${TRAEFIK_CONTAINER}'."
    info "Update /etc/logrotate.d/traefik if the container name differs."
fi

cat > /etc/logrotate.d/traefik << EOF
/var/log/traefik/access.log {
    weekly
    rotate 13
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        docker kill --signal=USR1 ${TRAEFIK_CONTAINER} >/dev/null 2>&1 || true
    endscript
}
EOF

log "Created /etc/logrotate.d/traefik (weekly rotation, 13 backups, compressed)"

echo ""

# --------------------------------------------------
# 7. RESTART AND VERIFY
# --------------------------------------------------
info "Restarting fail2ban and verifying configuration..."

# Ensure the DOCKER-USER chain exists (Docker creates it, but verify)
if ! iptables -L DOCKER-USER &>/dev/null; then
    warn "DOCKER-USER iptables chain not found. Docker may need to be restarted."
    info "Run: systemctl restart docker"
fi

systemctl restart fail2ban
sleep 2

# Verify jails are loaded
JAIL_STATUS=$(fail2ban-client status 2>&1)
AUTH_JAIL_OK=false
FLOOD_JAIL_OK=false

if echo "$JAIL_STATUS" | grep -q 'traefik-auth'; then
    AUTH_JAIL_OK=true
    log "traefik-auth jail is active."
else
    err "traefik-auth jail failed to load. Check: fail2ban-client status"
fi

if echo "$JAIL_STATUS" | grep -q 'traefik-flood'; then
    FLOOD_JAIL_OK=true
    log "traefik-flood jail is active."
else
    err "traefik-flood jail failed to load. Check: fail2ban-client status"
fi

# Verify access log
if [ -f /var/log/traefik/access.log ]; then
    log "Traefik access log exists at /var/log/traefik/access.log"
else
    warn "Access log not yet created — it will appear after the first HTTP request to Traefik."
fi

echo ""

# --------------------------------------------------
# SUMMARY
# --------------------------------------------------
echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
echo "  Traefik Access Log:  /var/log/traefik/access.log"
echo "  Compose Backup:      ${BACKUP_FILE}"
echo "  Log Rotation:        weekly, 13 backups"
echo ""
echo "  Jails:"
if [ "$AUTH_JAIL_OK" = true ]; then
echo "    traefik-auth:      active (5 retries / 10min → 1hr ban)"
else
echo "    traefik-auth:      FAILED — check fail2ban logs"
fi
if [ "$FLOOD_JAIL_OK" = true ]; then
echo "    traefik-flood:     active (10 retries / 1min → 1hr ban)"
else
echo "    traefik-flood:     FAILED — check fail2ban logs"
fi
echo ""
echo "  Whitelisted IPs:     ${WHITELIST_IPS}"
echo "  Ban Chain:           DOCKER-USER (applies to container traffic)"
echo ""

# --------------------------------------------------
# 8. BAN MANAGEMENT COMMANDS
# --------------------------------------------------
echo "============================================"
echo "  Useful Commands"
echo "============================================"
echo ""
echo "  Check banned IPs:"
echo "    fail2ban-client status traefik-auth"
echo "    fail2ban-client status traefik-flood"
echo ""
echo "  Unban an IP:"
echo "    fail2ban-client set traefik-auth unbanip <IP>"
echo "    fail2ban-client set traefik-flood unbanip <IP>"
echo ""
echo "  List all jails:"
echo "    fail2ban-client status"
echo ""
echo "  View Traefik access log:"
echo "    tail -f /var/log/traefik/access.log"
echo ""
echo "  Edit whitelist:"
echo "    nano /etc/fail2ban/jail.d/traefik.conf"
echo "    systemctl restart fail2ban"
echo ""
echo "  Test a filter against the log:"
echo "    fail2ban-regex /var/log/traefik/access.log /etc/fail2ban/filter.d/traefik-auth.conf"
echo ""
