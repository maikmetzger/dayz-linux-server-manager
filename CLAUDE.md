# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DayZ Docker Hub - A bash-based TUI for managing DayZ servers on Linux via Docker. Pure bash + stdlib Python (no external dependencies like dialog/whiptail/jq).

## Commands

```bash
# Run the TUI server manager
./server-manager.sh

# RCON console for a specific instance
./rcon.sh ~/servers/dayz-server1

# Installation wizard
./install-dayz-docker.sh

# Run tests
python3 -m pytest tests/
python3 tests/test_merge_tracking.py

# Syntax validation
bash -n lib/*.sh
python3 -m py_compile lib/*.py
```

## Architecture

### Entry Points
- `server-manager.sh` - Main TUI menu (instance selector, mod manager, config editor)
- `run.sh` - Container initialization (mod sync, server startup)
- `rcon.sh` - BattlEye RCON wrapper
- `install-dayz-docker.sh` - First-run setup wizard

### Library Structure (lib/)
Libraries are sourced at startup via a loop. Each has double-source guards.

**Core Infrastructure:**
- `colors.sh` - ANSI color codes, cursor control
- `tui.sh` - Terminal UI primitives
- `menu.sh` - Menu rendering (arrow keys, selection)
- `dialogs.sh` - User prompts/confirmations
- `utils.sh` - Logging, file helpers

**Feature Modules:**
- `mods.sh` + `mod_config.sh` + `workshop.sh` - Mod management, Steam API, load order
- `workshop_search.py` - Steam Workshop HTML scraping
- `players.sh` + `admin_config.sh` - Player list, ban system, admin IDs
- `be_rcon.py` - BattlEye UDP RCON protocol (CRC32 packets)
- `types.sh` + `xml_parser.py` - Central Economy loot editor
- `config.sh` + `config_parser.py` - Server config editor (CFG/JSON/XML)
- `instance.sh` + `docker.sh` - Instance discovery, Docker commands

### Layer Dependencies
```
UI (tui, menu, dialogs) → Domain (mods, players, types) → State + Integration
Integration (workshop, docker, steamcmd) never calls UI
```

### Data Locations
- `data/workshop_cache_v3.json` - Steam mod metadata cache
- `data/workshop_rules.json` - Core mod list, framework priorities, incompatibilities
- `data/state/players/bans.json` - Active bans with expiry timestamps
- `data/state/ce_merge_tracking/*.json` - Merge history for CE files

### Instance Directory (inside Docker)
```
~/servers/dayz-server1/
├── data/
│   ├── config/           # serverDZ.cfg, mods.txt
│   ├── profile/          # Server profiles
│   ├── serverfiles/      # Game files, mpmissions/, steamapps/workshop/
│   └── state/            # Runtime state (bans, tracking)
```

## Code Conventions

### SOLID for Bash/Python
- **Single responsibility:** One function = one job. Don't mix UI + parsing + file writes.
- **Open/closed:** Extend by adding handlers, not rewriting existing logic.
- **Interface segregation:** Pass only what a function needs (avoid 17-arg functions).
- **Dependency inversion:** Wrap external commands (steamcmd, curl, docker) for testability.

### Naming
- `snake_case` everywhere
- `is_*` for booleans (`is_dirty`, `is_installed`)
- Prefix by domain: `ui_*`, `state_*`, `mod_*`, `ws_*`

### Functions
- Bash: aim < 60 lines
- Python: aim < 80 lines
- No magic numbers without comments
- No duplicated 3+ line blocks - extract a function

### Error Handling
- Guard filesystem ops with `-d`, `-f`
- With `set -e`, avoid `((x++))` and careful with `grep`/`head` pipelines
- Handle empty/partial data with defaults
- Never silently swallow errors - log them
- Debug mode: `DEBUG=1 ./tool.sh` with `log_debug`, `log_info`, `log_warn`, `log_error`

### TUI Guidelines
- ASCII-first; unicode optional
- Every action gives feedback (success message or visible state change)
- Dirty/sync state must be obvious (`[SYNC NEEDED]` in header)
- Keybinds discoverable via help screen/footer

## Testing

- Fixtures in `tests/fixtures/`
- Write regression test for every bug fix
- Make code mockable: wrap steamcmd, curl, docker
- Python CLI tools should be runnable standalone with `--test-*` flags
