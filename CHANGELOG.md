# Changelog

## 1.0.0

### Added
- Server Control menu (shutdown, lock, unlock, monitor)
- Ban expiry daemon runs inside the container
- Hidden password input in all prompts
- Read-only view mode for the file browser
- Unit tests for the Python modules (131 tests)

### Changed
- Steam credentials are read from `data/config/.steam.env` instead of `.env` and the compose environment
- Passwords no longer appear on command lines or in the container environment
- All menus split into small refresh/draw/handler functions; screens look the same
- Far fewer processes per key press in the player, ban, loot, config and file screens
- CE merges for presets and event groups go to the mission root instead of `db/`
- Removed the host-side ban expiry scripts, debug scripts and ~950 lines of dead code

### Fixed
- Unban could wipe the whole `bans.txt`
- Ban durations were not validated and failures were reported as success
- Multipart RCON replies were cut off; lobby players were missing from the player list
- Mod Manager: Remove/Info buttons, unreachable Back button, FixMods running sync, crash with a pending sync
- Workshop rules never loaded, so conflicts and frameworks were not marked
- Server Settings showed "(not set)" after opening Admin Tools
- Installer ignored the entered admin password
- Command execution through crafted player names, file names and workshop ids
- Menus looped forever when input ended
