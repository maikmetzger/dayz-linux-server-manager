# DayZ Docker Hub

A simple but powerful toolkit for running DayZ servers on Linux. It handles everything from the initial install to daily maintenance and mod management, all through a clean terminal interface.

## Core Features

### 🏢 Instance Management
- **Multi-Instance Support**: Run multiple isolated servers on a single machine.
- **Instance Selector**: Switch between your different servers easily from the main menu.
- **Auto-Installation**: Handles Docker, firewall rules (UFW), and directory structures automatically.

### 🎮 Mod & Workshop Ecosystem
- **Workshop Browser**: Search for mods directly on the Steam Workshop without leaving your terminal.
- **Dependency Resolver**: Automatically detects and shows required mods when installing.
- **Sync System**: One-click download and update for all your mods.
- **Automated Keys**: The script handles copying `.bisign`, `.bikey`  keys for you.

### 📦 Loot & Central Economy
- **Loot Editor**: A high-performance table view to filter and edit `types.xml` values (nominal, lifetime, etc.) instantly.
- **Modular Loot Manager**: Use the `cfgeconomycore.xml` include system. Add mod loot as separate files to keep your mission folder clean.
- **Link Toggling**: Easily enable or disable specific modular loot files with a single keypress.

### 🧹 Maintenance & Monitoring
- **Precision Wipe**: Choose exactly what to reset. You can wipe just the loot (CLE), or target bases, vehicles, or player data separately.
- **RCON Console**: Built-in interactive BattlEye RCON client for server commands.
- **Log Suite**: Browse RPT and ADM logs with a built-in viewer that supports live tailing (`tail -f`).

---

## Getting Started

### 1. Installation
Clone the scripts and run the installer. It will walk you through the setup.
```bash
git clone https://github.com/maikmetzger/dayz-linux-server-scripts.git
cd dayz-linux-server-scripts
./install-dayz-docker.sh
```

### 2. Daily Usage
Launch the management TUI:
```bash
./server-manager.sh
```

---

## Feature Deep Dive

### The Workshop Browser
When managing mods, press **[W]** to open the Workshop Browser. You can search for mods, read their descriptions, and check for dependencies before hitting install. It simplifies the process of hunting down IDs manually.

### The Table-based Loot Editor
Located in the **Config Editor** for `types.xml`. Instead of scrolling through thousands of lines of XML, you get a clean table where you can search for "Sledgehammer" and change its spawn rate in seconds.

### Modular Loot Workflow
1. Browse a mod's config files.
2. If you see a `types.xml`, press **[m]**.
3. The script copies it, normalizes the filename, and registers it in your economy.
4. You can manage these links later in the **Loot Economy** menu.

### Surgical Wiping
DayZ servers often need a clean start.
- **Soft Wipe (Loot)**: Deletes `types.bin` and `dynamics.bin`. This refreshes the loot on the ground without destroying anyone's base.
- **Hard Wipe**: Deletes persistence data or player databases for a fresh start.

---

## TUI Keybinds Guide

- **[↑/↓]**: Move selection
- **[Enter]**: Action / Select / Toggle checkbox
- **[/]**: Open search filter
- **[L]**: Live Tail (in the log browser)
- **[V]**: View or edit file
- **[N]**: Create new file/folder
- **[D]**: Delete file/folder

## Requirements
- **OS**: Ubuntu or Debian (amd64)
- **Space**: ~30GB for base server + mods
- **Permissions**: Docker group access or sudo for the initial setup

## License
MIT. Built to make server hosting less of a chore.
