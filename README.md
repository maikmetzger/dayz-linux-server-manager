# DayZ Docker Server

A complete solution for running DayZ dedicated servers in Docker containers on Linux, with TUI management and Workshop mod support.

## Features

- 🐳 **Docker-based** - Isolated, reproducible server environment
- 🎮 **Workshop Mods** - Download, enable/disable mods via Steam Workshop
- 📺 **TUI Manager** - Full-featured text UI for server management
- ⚡ **CLI Mode** - Non-interactive install for automation/scripting
- 🔥 **UFW Integration** - Automatic firewall configuration
- ♻️ **Auto-updates** - Optional server/mod sync on startup

## Quick Start

### Prerequisites

- Ubuntu/Debian Linux
- Docker (installed automatically if missing)
- Steam account (for Workshop mods)

### Installation

```bash
# Clone or download the scripts
git clone https://github.com/yourusername/dayz-docker.git
cd dayz-docker

# Interactive wizard (recommended for first-time setup)
./install-dayz-docker.sh

# Or CLI mode for automation
./install-dayz-docker.sh \
  --steam-user YOUR_STEAM_USERNAME \
  --steam-pass YOUR_STEAM_PASSWORD \
  --admin-pass YOUR_ADMIN_PASSWORD
```

## Usage

### Server Manager (TUI)

Launch the interactive server manager:

```bash
./server-manager.sh
```

**Features:**
- Start/Stop/Restart servers
- View container logs
- **Mod Management:**
  - Add mods by Workshop ID
  - Enable/disable mods with checkboxes
  - Sync (download) all mods
  - Uninstall mod files
- Update server files
- Enter container shell

### Installer CLI Options

```
REQUIRED (CLI mode):
  --steam-user <user>     Steam username
  --steam-pass <pass>     Steam password  
  --admin-pass <pass>     Server admin password

OPTIONAL:
  --name <name>           Instance name (default: server1)
  --dir <path>            Install directory
  --port <port>           Game port (default: 2302)
  --query-port <port>     Query port (default: 27016)
  --host-net              Use host networking (default)
  --no-host-net           Use bridge networking
  --sync-on-start         Auto-sync mods on start
  --update-on-start       Auto-update on start
  --no-ufw                Skip firewall config
  --no-start              Don't start after install
  --help                  Show help
```

### Container Commands

```bash
# View logs
docker compose logs -f --tail=200

# Enter container
docker exec -it dayz-server1 /bin/bash

# Inside container:
/dayz/run.sh status           # Check status
/dayz/run.sh mod add 1234567  # Add mod
/dayz/run.sh sync-mods        # Download mods
/dayz/run.sh update-server    # Update DayZ
/dayz/run.sh backup           # Backup mission/profile
```

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 2302 | UDP | Game port (base) |
| 2303-2305 | UDP | Game port +1 to +3 |
| 27016 | UDP | Steam query port |

## Directory Structure

```
~/servers/dayz-<name>/
├── docker-compose.yml
├── Dockerfile
├── run.sh
├── .env                    # Credentials (chmod 600)
├── .dayz-instance          # Instance marker
└── data/
    ├── serverfiles/        # DayZ server files
    ├── config/
    │   ├── serverDZ.cfg    # Server config
    │   ├── mods.txt        # Workshop mod IDs
    │   └── servermods.txt  # Server-side mod IDs
    ├── profile/            # Player data, logs
    ├── state/              # Runtime state
    └── backups/            # Mission/profile backups
```

## Mod Management

### Adding Mods

1. Find the mod on [Steam Workshop](https://steamcommunity.com/app/221100/workshop/)
2. Copy the Workshop ID from the URL (e.g., `1559212036`)
3. Use TUI: `./server-manager.sh` → Manage Mods → Actions → Add
4. Or manually: Add ID to `data/config/mods.txt`
5. Sync mods to download

### Mod Status Icons

| Icon | Meaning |
|------|---------|
| ✓ | Enabled - mod will load |
| ✗ | Disabled - in list but commented out |
| - | Removed - uninstalled from disk |

## Troubleshooting

### "Permission denied" on Docker socket
```bash
sudo usermod -aG docker $USER
newgrp docker  # Or log out/in
```

### Server won't start
```bash
docker logs dayz-<name>
# Check for missing files, port conflicts
```

### Mods not loading
1. Ensure mods are synced: `./server-manager.sh` → Sync Mods
2. Check mod IDs in `mods.txt`
3. Restart the container

## License

MIT
