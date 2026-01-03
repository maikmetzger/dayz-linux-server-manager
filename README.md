# DayZ Docker Hub

A toolset to run and manage DayZ servers on Linux using Docker. It handles the tedious parts like SteamCMD updates, mod syncing, and config editing so you can focus on your community.

---

## Key Features

### Mod Management & Validation
The mod manager does more than just download files; it helps keep your server stable.
- **Refined Selection**: Use the Workshop Browser [W] to search and install mods directly from Steam, or add them manually by ID.
- **Load Order Checks**: The script warns you [⚠️] if dependencies are missing or in the wrong order.
- **Client/Server Sorting**: Mark mods as "Client", "Server", or "Both" to keep your load list optimized.
- **Sync Status**: Mods with pending changes appear **yellow** until synced. A `[SYNC NEEDED]` indicator shows in both the header and main menu.
- **Automation**: Fixes mod casing (lowercase) and handles your `.bikey` and `.bisign` keys automatically.

### Workshop Folder Browser [NEW]
Inspect the contents of any mod directly from the Workshop Manager or Loot Manager.
- **Browse Files**: Navigate through `addons/`, `data/`, and other mod folders.
- **View Content**: Identify if a mod has hidden XML configs or valid keys.
- **Access**: Press `[B]` on any mod to open the file browser.

### Steam Workshop Browser
A fully integrated TUI browser for the Steam Workshop.
- **Search**: Find mods by name, author, or relevance directly in the terminal.
- **Install**: Automatically resolves and installs dependencies.
- **Details**: View mod descriptions, subscriber counts, ratings, release/update dates, and Steam links.
- **Images**: Press [I] in the details view to browse all mod images with scrolling support.

### Configuration Editor
Edit server settings without touching raw files.
- **Server Config**: A form-based editor for `serverDZ.cfg` with validation for every field.
- **RCON Settings**: Manage your BattlEye settings securely.
- **Globals**: Tweak `globals.xml` values easily.

### Central Economy Tools
Take control of your loot without manually editing giant XML files.
- **Loot Editor**: Search for items in a table view and edit spawn rates (nominal, lifetime, etc.) instantly.
- **Modular Loot**: Register workshop loot as modular includes. This keeps your main `types.xml` clean and makes it easy to add or remove mods.
- **Link Toggle**: Enable or disable specific loot files with a single keypress.
- **Smart CE Detection**: Automatically identifies Central Economy files even in subfolders or with weird names (e.g., `Control/Config/types.xml`), and correctly ignores non-CE files like Trader Configs.

### Maintenance & Reliability
- **Selective Wipe**: Choose exactly what to reset. You can refresh the loot on the ground (CLE) without destroying player bases, or wipe vehicles and players individually.
- **Backups**: Quickly tar your mission and profile data for safe keeping.
- **Crash Guard**: Includes a dummy crash reporter to prevent the server from hanging on error dialogs.
- **Health Checks**: Containers monitor the server process and report its status back to the manager.
- **Exit Warning**: Get prompted if you try to quit with unsync'd mod changes.

### Logs & Console
- **Log Browser**: View RPT and ADM logs directly in the terminal with live tailing (`tail -f`).
- **RCON Console**: A built-in BattlEye RCON client that connects to your server automatically for interactive commands.

### Multi-Instance Support
Run multiple isolated servers on the same machine.
- **Isolation**: Each server has its own storage, configuration, and port mappings.
- **Management**: Switch between instances instantly from the main menu.

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
- **[←/→]**: Page up/down (in description views)
- **[Enter]**: Confirm / Select / Toggle mod type
- **[/]**: Search / Filter lists
- **[L]**: Live Tail (when viewing logs)
- **[W]**: Open Workshop Browser
- **[I]**: Browse mod images (in Workshop details)
- **[B]**: Open Steam Workshop page in browser
- **[M]**: Register as Modular Loot (in the editor)
- **[S]**: Sync All Mods (Download → Casing → Keys)
- **[F]**: Fast Fix (Fixes casing/keys without a slow Steam update)
- **[Q]**: Quit / Back (with confirmation if sync needed)

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
