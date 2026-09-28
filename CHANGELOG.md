# Changelog

All notable changes to DayZ Docker Hub are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-28

First tagged release. It bundles the security fixes, the bug-scan fixes and
the restructuring of the TUI that landed in pull requests
[#1](https://github.com/maikmetzger/dayz-linux-server-manager/pull/1),
[#2](https://github.com/maikmetzger/dayz-linux-server-manager/pull/2),
[#3](https://github.com/maikmetzger/dayz-linux-server-manager/pull/3),
[#4](https://github.com/maikmetzger/dayz-linux-server-manager/pull/4) and
[#5](https://github.com/maikmetzger/dayz-linux-server-manager/pull/5).
Every change was verified against a fixture instance with a fake BattlEye
server and a docker stub (piped-key drivers for all menus, 142 end-to-end
checks) and 131 unit tests.

### Upgrade notes

- **Steam credentials** are read from `data/config/.steam.env` (mode 0600)
  and handed to `steamcmd` through a private `+runscript` file. New instances
  no longer get `STEAM_USER`/`STEAM_PASS` in `.env` or in the compose
  environment. Existing instances that still set the environment variables
  keep working; to move an existing instance, create `.steam.env` with
  `STEAM_USER=...` and `STEAM_PASS=...` and remove the two variables from
  `.env` and `docker-compose.yml`.
- **Ban expiry** runs as a daemon inside the container (`lib/ban_expiry_daemon.sh`);
  the host-side timer scripts are gone. Re-run the installer's update mode or
  copy `lib/` into the instance so the container has the daemon.
- **CE merges** for `cfgrandompresets.xml` and `cfgeventgroups.xml` now target
  the files in the mission root. Files that earlier versions wrote under `db/`
  were never read by the server and can be deleted.
- The Loot Manager debug log moved from the repository directory to
  `$XDG_STATE_HOME/dayz-docker-hub/loot_manager.log` (default `~/.local/state/...`).

### Added

- Server Control menu (Shutdown / Lock / Unlock / Monitor) in the main menu;
  the module existed but was never loaded.
- In-container ban expiry daemon replacing the host-side systemd timer scripts.
- Shared libraries: `lib/rcon_lib.sh` (single RCON path), `lib/json_helpers.sh`,
  `lib/constants.sh`, `lib/fileutil.py` (atomic writes), `lib/rowfmt.py` (row
  format for bash readers), `lib/ban_manager.py`, `lib/player_manager.py`,
  `lib/ce_scanner.py` (CE file scan, link/merge/ignore state), `lib/mod_status.py`
  (Mod Manager date and update columns).
- `xml_parser.py` commands `validate-ce`, `add-ce-file` and `remove-ce-file`
  for `cfgeconomycore.xml`; `mod_status.py --dates`; `ce_scanner.py --only-new`
  and `--ignore-file`.
- Hidden password input (`read_secret`) in the admin, VPP, installer and
  config editor prompts; the config table shows `********` for password keys.
- Read-only `view` mode for the file browser; the workshop folder browser uses it.
- One Steam API request for all unknown mod names (`prefetch_mod_names`).
- Unit test suite (`tests/`, 131 tests) is tracked in git.
- Shared table drawing helpers `tui_draw_*` in `lib/tui.sh`.
- CLAUDE.md documents the module layout and the menu/helper structure.

### Changed

- RCON has one implementation (`rcon_action` in `lib/rcon_lib.sh`); it honours
  `$DOCKER` (RCON works with `sudo docker`) and `RConPort` from `BEServer_x64.cfg`.
- Passwords travel through the environment only (`docker exec -e RCON_PASSWORD
  -e ADMIN_PASSWORD`, `be_rcon.py --password-env/--admin-password-env`).
- Mod Manager, Loot Manager, Config Editor, Players, Ban List, File Browser and
  Workshop Browser are short loops over refresh, draw and key handler functions
  instead of 250 to 750 line blocks; rendered screens are unchanged.
- Fewer processes per key press: players and bans refresh with one Python call
  for the whole list (was 5 to 6 per row), the Loot Manager rescans only after
  an action, the config editor reads all values in one process, the file
  browser runs one `find` and one `stat` per listing, workshop description
  markup and ban list dates are formatted in bash.
- The post-sync "link new CE files" checklist merges merge-only types
  (randompresets, eventgroups) instead of linking them as files; one function
  (`ce_activate_file`) decides between merge and link.
- "Move frameworks to top" moves only the frameworks to the top of the load
  order; dependent mods are appended below.
- Mod name lookups never cache failures; names recover as soon as the Steam
  API answers again.
- Installer: `docker-compose.yml` comes from one template (in bridge mode the
  `ports` block now precedes `stop_signal`; same content), instance files are
  written by one function each.
- Workshop folder browser shows size, created and modified columns like the
  other file browsers.
- Every menu leaves on end of input instead of looping forever.
- `((x++))` replaced by plain arithmetic assignments (fails under `set -e`);
  the undeclared `bc` dependency is gone.

### Fixed

#### Bans and players
- Unban wiped the whole `bans.txt` (IP bans included) when the name contained
  a quote or the GUID was empty; `U` in the ban list aborted the TUI.
- Ban durations are validated (`1.5h` no longer crashes, `garbage` no longer
  becomes a silent permanent ban); kick, file write, `loadBans` and the record
  save are reported honestly instead of a fixed "Success".
- `ban_manager.py` no longer swallows write errors or overwrites a corrupt file.
- Lobby players (no GUID yet) are listed; rows with empty fields no longer
  shift columns (rows are 0x1F separated, bash `read` collapses empty tab fields).
- Join timestamps reset on refresh; the ban expiry daemon logs failures
  instead of reporting "Done".

#### RCON
- Multipart replies are reassembled and decoded once (UTF-8 split across
  packets survives), late replies with a wrong sequence byte are ignored, an
  incomplete reply or no reply is an error instead of an empty player list.
- Server control menu read no container name from the instance marker;
  `rcon.sh` crashed under `set -u`.

#### Mod Manager and Workshop
- Remove and Info action bar buttons did nothing; the `[Q] Back` button was
  unreachable by cursor; FixMods ran `sync-mods`; the Sync highlight used an
  undefined colour and crashed the manager with a pending sync.
- Mod status display died for a mod that was not downloaded yet.
- Dependency checks consider enabled mods only; the footer no longer runs a
  Python process per key press.
- Workshop rules were never loaded (a one-line Python with two `for`
  statements): conflicts and frameworks were not marked and "Move frameworks
  to top" was never offered.
- Workshop details: first Right key scrolled by a negative amount, scrolling
  past the end is clamped, ascending subscriber sort sorted by the wrong
  column, mod type check matched id prefixes, undefined `BG_BLUE`/`ITALIC`.
- Workshop: 15 s network timeouts, failed searches are not cached as empty,
  failed scrapes are not retried forever, strict mode restored after installs.
- "Move frameworks to top" via `sed 1i` did nothing on an empty list and
  reversed the order otherwise.
- `run.sh mod add 1,2` added nothing and exited 0.

#### Central Economy
- `cfgrandompresets.xml`/`cfgeventgroups.xml` merges wrote under `db/`
  instead of the mission root; `<eventgroupdef>` is a known root tag.
- `get_mission_path` parses `class Missions { class DayZ { template = ... } }`
  as the installer writes it (wrong mission with two folders).
- `register_modular_loot` refuses malformed XML, returns the Python step's
  exit code, checks duplicates only in the target CustomCE block; rollback
  looks for `<mod id>_<file>`; `get_ce_ignore_file` fails instead of
  degrading to `/CustomCE` at the filesystem root.
- Fragment files (bare `<type>` rows) keep their format on update.
- Re-merging skips entries already present in the target.
- `parse_scan_result` leaked its loop variable into the caller, so removing a
  mod after a CE scan removed nothing while reporting success.
- Removing a mod from the Mod Manager wrote the loot log into a directory the
  Loot Manager had not created yet.

#### Config and installer
- Server Settings showed "(not set)" for every field once Admin Tools had been
  opened (JSON helper name collision); the in-container config editor failed
  with `ModuleNotFoundError` (`fileutil.py` was not copied).
- Only numbers and booleans are written unquoted to `serverDZ.cfg`; admin
  passwords go through the config parser instead of `sed`.
- Installer used the collected admin password (the prompt was repeated or the
  `CHANGEME` default written); `$` in `.env` values is escaped for compose.
- Appends to `mods.txt`, `servermods.txt`, admin id lists and the pending-sync
  file no longer glue ids together when the file lacks a final newline.
- Config files, CE XMLs and merge tracking are written atomically.

#### Misc
- Startup no longer dies under `set -u` when `USER` is unset (cron, `env -i`).
- File browser: the search text was used as a printf format string; new names
  may not contain `/`.
- File viewer offset clamped at 0; stray global `ERR` trap removed.

### Security

- Command execution through crafted names: player names, ban reasons, CE file
  names and workshop ids were pasted into Python source, shell command strings
  (`eval`) or generated shell files under `/tmp` that were `source`d. All
  values travel as arguments now.
- RCON, admin and Steam passwords no longer appear on host or container
  command lines or in the container environment (`docker inspect`); the RCON
  debug log no longer records the admin password.
- Passwords are typed without echo and never printed in the config table.
- Installer runs docker, compose and `rm` without `eval` (an apostrophe in the
  instance path broke quoting, including `rm -rf`).

### Removed

- Host-side ban expiry scripts (`lib/check_ban_expiry.sh`,
  `lib/setup_ban_expiry_timer.sh`), root debug scripts (`debug_ce_scan.sh`,
  `test_debug.sh`), `config_editor_menu`, the never-wired version tracking,
  the Phase-4 merge prompt and other uncalled helpers: about 950 lines of
  dead code.
- The second file browser (`workshop_folder_browser` implementation) and the
  Python heredocs inside `register_modular_loot`, `unregister_modular_loot`,
  `scan_dayz_ce_files_python` and the Mod Manager rebuild.
- `bc` as a runtime dependency.

[Unreleased]: https://github.com/maikmetzger/dayz-linux-server-manager/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/maikmetzger/dayz-linux-server-manager/releases/tag/v1.0.0
