# DayZ Docker Hub

A toolset to run and manage DayZ servers on Linux using Docker. It handles the tedious parts like SteamCMD updates, mod syncing, and config editing so you can focus on your community.

---

## Key Features

### Mod Management & Validation
The mod manager does more than just download files; it helps keep your server stable.
- **Load Order Checks**: The script warns you [⚠️] if dependencies are missing or in the wrong order.
- **Client/Server Sorting**: Mark mods as "Client", "Server", or "Both" to keep your load list optimized.
- **Automation**: Fixes mod casing (lowercase) and handles your `.bikey` and `.bisign` keys automatically.

### Central Economy Tools
Take control of your loot without manually editing giant XML files.
- **Loot Editor**: Search for items in a table view and edit spawn rates (nominal, lifetime, etc.) instantly.
- **Modular Loot**: Register workshop loot as modular includes. This keeps your main `types.xml` clean and makes it easy to add or remove mods.
- **Link Toggle**: Enable or disable specific loot files with a single keypress.

### Maintenance & Reliability
- **Selective Wipe**: Choose exactly what to reset. You can refresh the loot on the ground (CLE) without destroying player bases, or wipe vehicles and players individually.
- **Backups**: Quickly tar your mission and profile data for safe keeping.
- **Crash Guard**: Includes a dummy crash reporter to prevent the server from hanging on error dialogs.
- **Health Checks**: Containers monitor the server process and report its status back to the manager.

### Logs & Console
- **Log Browser**: View RPT and ADM logs directly in the terminal with live tailing (`tail -f`).
- **RCON Console**: A built-in BattlEye RCON client that connects to your server automatically for interactive commands.

---

## Getting Started

### 1. Installation
Clone the scripts and run the installer. It will walk you through setting up your first instance.
```bash
git clone https://github.com/maikmetzger/dayz-linux-server-scripts.git
cd dayz-linux-server-scripts
./install-dayz-docker.sh
```

### 2. Management
Launch the TUI to manage your servers:
```bash
./server-manager.sh
```

---

## Navigation & Keys

- **[↑/↓]**: Move selection
- **[Enter]**: Confirm / Select / Toggle
- **[/]**: Search / Filter lists
- **[L]**: Live Tail (when viewing logs)
- **[M]**: Register as Modular Loot (in the editor)
- **[S]**: Sync All Mods (Download -> Casing -> Keys)
- **[F]**: Fast Fix (Fixes casing/keys without a slow Steam update)

---

## Technical Details

### Sync vs Fix
- **Sync [S]** is for when you need to download mod updates from Steam.
- **Fix [F]** is for when you just need to refresh keys or fix casing after manually moving files. It skips the Steam check and finishes almost instantly.

### Networking
The installer sets up UFW firewall rules automatically:
- `2302 UDP` range (Game traffic)
- `27016 UDP` (Steam query)
- `RCON Port` (GamePort + 3)

## Requirements
- Ubuntu or Debian Linux
- About 30GB of space for the server and mods
- Docker installed (the script can handle this for you)

## License
MIT. Built to make hosting DayZ less of a chore.
