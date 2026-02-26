# Server Setups

Bash scripts for provisioning and hardening Ubuntu servers. Designed to be safe to run on fresh installs or existing systems with Coolify or HestiaCP already running.

## What it does

The base setup script (`server-setup_base.sh`) configures:

- Hostname
- System update & upgrade
- Timezone (Australia/Adelaide)
- Swap file (4GB) with tuned swappiness
- TCP/network optimisations for WebSocket/real-time workloads
- File descriptor limits
- Journal log size cap (500MB)
- Automatic security updates
- Essential packages (curl, wget, git, htop, fail2ban, etc.)
- Fail2ban with SSH jail (+ HestiaCP jail if detected)
- SSH hardening
- UFW firewall (optional, skipped when Coolify/HestiaCP detected)
- Custom shell prompt

The script is interactive — it will prompt you before making changes to existing settings.

## Quick Start

SSH into your Ubuntu server as root, then run:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/tnickels/server-setups/main/server-setup_base.sh)
```

Process substitution (`bash <(...)`) is used instead of piping (`| bash`) so that interactive prompts stay connected to your terminal.

Or clone the repo and run locally:

```bash
git clone https://github.com/tnickels/server-setups.git
cd server-setups
chmod +x server-setup_base.sh
./server-setup_base.sh
```

## Requirements

- Ubuntu (tested on 22.04 / 24.04)
- Root access
- Internet connection

## After running

- Reboot the server to apply all changes
- If UFW was installed, add your port rules then run `ufw enable`
- Reconnect your SSH session to see the new prompt