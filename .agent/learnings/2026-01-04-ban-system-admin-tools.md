# Ban System & Admin Tools Learnings

**Date:** 2026-01-04  
**Session Goals:** Implement automatic ban expiry, improve player/ban list UX

---

## What Happened

### 1. RCON Ban Commands Silent Failure
**Symptom:** RCON `addBan`/`writeBans` commands would return "OK" but players could immediately reconnect.

**Root Cause:** BattlEye RCON `addBan` and `writeBans` commands fail silently - they report success but don't actually persist to `bans.txt` on DayZ servers.

**Fix:** Implemented workaround strategy:
- `#kick PlayerName` to disconnect player (this works reliably)
- Direct file write via `docker exec` to append GUID to `bans.txt`
- `loadBans` RCON command to reload ban list

### 2. Wrong `loadBans` Command Syntax
**Symptom:** Bans weren't reloading after direct file modification.

**Root Cause:** Used `#exec loadBans` but correct BattlEye command is just `loadBans`.

**Fix:** Changed `be_rcon.py` action_loadbans from `#exec loadBans` to `loadBans`.

### 3. Ban Expiry Script Path Bug
**Symptom:** `check_ban_expiry.sh` exited immediately without processing expired bans.

**Root Cause:** Script looked for `bans.json` at `/data/state/bans.json` but actual path is `/data/state/players/bans.json`.

**Fix:** Updated `state_dir` to include `players` subdirectory.

### 4. Python Heredoc Argument Bug  
**Symptom:** Python script inside bash heredoc wasn't receiving the file path.

**Root Cause:** Used `sys.argv[1]` to get bans path, but heredoc syntax `<< 'PYTHON_SCRIPT' ... PYTHON_SCRIPT "$bans_json"` doesn't pass args - the file path runs as a separate command.

**Fix:** Changed to unquoted heredoc `<< PYTHON_SCRIPT` and embedded `${bans_json}` directly in Python code.

---

## What Changed (Features Added)

### Ban System
- **Reliable Ban:** Kick + direct file write + loadBans
- **Reliable Unban:** Direct file removal + loadBans  
- **Ban Expiry:** Automatic removal of expired bans via systemd timer
- **Timer Integration:** Auto-setup during instance creation

### Player List Table View
- Full-width table with columns: ID, Name, Joined, Time, Ping, GUID
- Session tracking via `sessions.json` - persists join times
- Time on server displayed as `5m` or `1h23m`
- Keyboard shortcuts: K=kick, B=ban, M=message, R=refresh

### Ban List Table View  
- Full-width table with columns: Name, Reason, Duration, Banned At, Expires, GUID
- Full 32-char GUID display
- Quick unban with `U` key
- Matches player list visual style

### Menu Selection Memory
- Admin tools menu remembers last selection
- Passwords menu remembers last selection

---

## Failure Patterns Identified

| Pattern | Example | Prevention |
|---------|---------|------------|
| **Silent RCON Failure** | `addBan` returns OK but doesn't persist | Always verify actual file state after RCON commands |
| **Path Mismatch** | `state/` vs `state/players/` | Trace full path with `bash -x` when debugging |
| **Heredoc Arg Passing** | Can't pass args after heredoc terminator | Embed variables in unquoted heredocs |
| **Datetime Timezone** | `datetime.utcnow()` deprecated warning | Use `datetime.now(datetime.UTC)` |

---

## Prevention Rules

1. **RCON commands are unreliable for state changes** - always verify by checking actual files
2. **Test heredocs with embedded paths** - use `bash -x` to see variable expansion
3. **Use full debug output first** - `bash -x script.sh` before assuming logic errors
4. **Systemd timers need service restart** after script changes (or wait for next trigger)
5. **Player state paths**: `$inst_dir/data/state/players/` for bans.json, sessions.json
6. **Ban file in container**: `/dayz/serverfiles/battleye/bans.txt`

---

## State Files Created

| File | Location | Purpose |
|------|----------|---------|
| `bans.json` | `$inst_dir/data/state/players/` | Local ban records with expiry |
| `sessions.json` | `$inst_dir/data/state/players/` | Player join timestamps |
| `dayz-ban-expiry.service` | `~/.config/systemd/user/` | Systemd service for expiry check |
| `dayz-ban-expiry.timer` | `~/.config/systemd/user/` | Timer (runs every minute) |
