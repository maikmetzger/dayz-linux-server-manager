# Mod Sync Integration & Version Tracking System (v2)

> **Status**: PLANNING PHASE - Revised After Review  
> **Created**: 2026-01-01  
> **Revised**: 2026-01-01 (incorporated feedback)  
> **Complexity**: HIGH - Multiple subsystems affected

---

## Executive Summary

Two major features:
1. **CE Auto-Detection After Sync**: Detect CE files in mods, offer to link/merge after sync
2. **Update Notifications**: Track mod updates AND DayZ server updates with UI indicators

---

## Key Design Decisions (Revised)

| Topic | Decision |
|-------|----------|
| CE change detection | Direct file comparison (no manifest) |
| Version tracking | Use Steam API `time_updated` stored at install |
| Merge feature | **KEEP** - Users want convenience, not manual editing |
| DayZ server updates | **INCLUDE** - Check for game updates too |
| Update check timing | Synchronous with "Checking..." indicator, cached 2 min |
| Hook point | `server-manager.sh` after sync completes (host-side) |

---

## Code Architecture Principles

> [!IMPORTANT]
> All implementations MUST follow these principles. Code review against this section.

### SOLID Principles

| Principle | Application |
|-----------|-------------|
| **S**ingle Responsibility | Each function does ONE thing. `diff_ce_files()` only diffs, doesn't merge. `merge_ce_file()` only merges, doesn't prompt. |
| **O**pen/Closed | Use registries/config for extensibility. New CE types added to `CE_TYPE_REGISTRY`, not scattered if/else. |
| **L**iskov Substitution | N/A for bash/python scripts (no inheritance) |
| **I**nterface Segregation | CLI commands are granular: `diff-ce`, `merge-ce`, `count-items` - not one mega-command |
| **D**ependency Inversion | Bash calls Python for complex logic. Python provides clean CLI interface, bash doesn't embed Python inline. |

### Function Design (Cognitive Complexity)

```bash
# BAD: Deep nesting, multiple responsibilities
scan_and_merge_and_prompt() {
    for mod in mods; do
        for file in files; do
            if is_ce; then
                if is_linked; then
                    if has_changes; then
                        # 5 levels deep, unreadable
                    fi
                fi
            fi
        done
    done
}

# GOOD: Flat, single-purpose, early returns
scan_mods_for_ce_files() {
    # Returns: array of {mod_id, file_path, ce_type, status}
    # Does NOT prompt, does NOT merge
}

check_ce_file_status() {
    local workshop_file="$1"
    local local_file="$2"
    # Returns: "new" | "changed" | "unchanged"
    # Single responsibility
}

prompt_ce_action() {
    local file_info="$1"
    # Only handles user interaction
    # Returns: "link" | "merge" | "replace" | "skip"
}
```

### Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Functions | `verb_noun()` descriptive | `scan_mods_for_ce_files()`, `get_mod_version()` |
| Variables | Full words, no abbreviations | `workshop_file` not `ws_f`, `modification_time` not `mtime` |
| Constants | UPPER_SNAKE | `CACHE_TTL_SECONDS`, `CE_TYPE_REGISTRY` |
| CLI commands | kebab-case | `diff-ce`, `check-updates` |

### File Organization (Separation of Concerns)

```
lib/
├── xml_parser.py      # XML operations ONLY (diff, parse, merge logic)
├── workshop.sh        # Version tracking, update checks, Steam API cache
├── mod_config.sh      # CE file management, linking, scanning
├── dialogs.sh         # User prompts (reusable confirm/input dialogs)
└── mods.sh            # Mod list management (add/remove/enable)

server-manager.sh      # TUI orchestration, calls lib functions
```

### Extensibility Patterns

**Adding new CE file types:**
```python
# Just add to registry - no other changes needed
CE_TYPE_REGISTRY = {
    'types': {...},
    'events': {...},
    'new_future_type': {  # ← Just add here
        'ce_type': 'newtype',
        'folder': 'CustomCE/newtype',
        'description': 'Something new'
    }
}
```

**Adding new update sources:**
```bash
# Version check is modular
check_all_updates() {
    check_mod_updates "$@"      # Existing
    check_server_update "$@"    # Existing
    check_battleye_update "$@"  # Future: just add function
}
```

### Reusability Requirements

| Component | Must Be Reusable For |
|-----------|---------------------|
| `diff_ce_files()` | Any XML with `<type name="">` structure |
| `prompt_choice()` | Any multi-option dialog (not CE-specific) |
| `cache_fetch_with_ttl()` | Any cached API call (mods, server, future) |
| `format_timestamp_as_date()` | Any date display in UI |

### Error Handling

```bash
# REQUIRED: Graceful degradation
get_remote_mod_version() {
    local mod_id="$1"
    local result
    
    # Try API with timeout
    if ! result=$(timeout 5 python3 workshop_search.py --details "$mod_id" 2>/dev/null); then
        # Fallback to cache
        result=$(get_cached_version "$mod_id")
        log_warn "API timeout for mod $mod_id, using cached data"
    fi
    
    echo "$result"
}

# REQUIRED: Never crash the TUI
merge_ce_file() {
    # Always backup first
    cp "$target_file" "${BACKUP_DIR}/$(date +%s)_$(basename "$target_file")"
    
    # If merge fails, restore backup
    if ! do_merge "$@"; then
        cp "${BACKUP_DIR}/..."  "$target_file"
        log_error "Merge failed, restored backup"
        return 1
    fi
}
```

### Documentation Requirements

```python
def diff_ce_files(source_file: str, local_file: str) -> dict:
    """
    Compare two CE XML files at the item level.
    
    Args:
        source_file: Path to workshop/upstream version
        local_file: Path to user's CustomCE version
        
    Returns:
        dict with keys:
            - added: list of item names in source but not local
            - removed: list of item names in local but not source
            - modified: list of item names with different values
            - unchanged: count of identical items
            
    Raises:
        FileNotFoundError: If either file doesn't exist
        xml.etree.ElementTree.ParseError: If XML is malformed
    """
```

```bash
# scan_mods_for_ce_files - Find all CE XML files in installed mods
#
# Usage: scan_mods_for_ce_files "$instance_dir"
# 
# Output: JSON array to stdout
#   [{"mod_id": "123", "mod_name": "Foo", "file": "/path/to.xml", 
#     "ce_type": "types", "status": "new|changed|unchanged"}]
#
# Dependencies: python3, xml_parser.py, detect_ce_type()
scan_mods_for_ce_files() {
```

---


## Part 1: CE Auto-Detection After Mod Sync

### 1.1 Overview

After mod sync completes:
1. Scan all installed mod folders for CE XML files
2. Use `detect_ce_type()` to identify file type
3. For each CE file found:
   - **NEW**: Prompt to link
   - **ALREADY LINKED**: Compare to workshop source
     - If different: Show what changed, offer Merge/Replace/Skip

### 1.2 Change Detection (Simplified)

**No manifest needed.** Just compare files directly:

```bash
# For a linked file "ModName_types.xml" in CustomCE/types/
# Find the original workshop source and compare

workshop_file="${workshop_base}/${mod_id}/path/to/types.xml"
local_file="${mission_path}/CustomCE/types/ModName_types.xml"

# Compare by parsing and diffing items, NOT by hash
# (Hash changes with any tweak; we want structural changes)
diff_result=$(python3 xml_parser.py diff-ce "$workshop_file" "$local_file")
```

### 1.3 Structural Diff (Item-Level)

Compare at the **item level**, not file level:

```python
def diff_ce_files(source_file, local_file):
    """
    Returns:
    {
        "added": ["ItemA", "ItemB"],      # In source, not in local
        "removed": ["ItemC"],             # In local, not in source  
        "modified": ["ItemD"],            # Same name, different values
        "unchanged": 42                   # Count of identical items
    }
    """
```

This way:
- User tweaks `nominal` value → Shows in diff but NOT auto-reverted during merge
- Mod adds new item → Flagged as "added" → AUTO-ADD during merge
- Mod removes item → Flagged as "removed" → PROMPT before removing

> [!IMPORTANT]
> "Modified" items are shown in the diff for transparency, but merge preserves user's values.
> We don't auto-revert user changes - that would defeat the purpose.

### 1.4 Merge Strategy

**Safe merge logic:**

```
For each item in workshop file:
  - If NOT in local file → ADD to local (new item from mod update)
  
For each item in local file:
  - If NOT in workshop file:
      - Was it in ORIGINAL workshop file (at link time)? 
        → If yes: Mod author REMOVED it → prompt to remove
        → If no: User ADDED it manually → KEEP
  - If IN workshop file with DIFFERENT values:
      → KEEP local values (user's tweaks preserved)
```

**Problem 1**: We need to know what was in the "original" workshop file at link time.

**Solution**: Store a reference copy when linking:
```
CustomCE/
├── types/
│   ├── ModName_types.xml          # User's working copy (may be edited)
│   └── .originals/
│       └── ModName_types.xml      # Snapshot from workshop at link time
```

**Problem 2**: We need to map CustomCE files back to their workshop source.

**Solution**: Embed source metadata in filename convention:
```
# Filename convention: {ModID}_{OriginalFilename}
# Example: 1564026768_types.xml

# This allows us to:
# 1. Find the mod folder: workshop/content/221100/1564026768/
# 2. Search for matching XML: find "$mod_folder" -name "types.xml"
# 3. Compare to the linked copy
```

> [!NOTE]
> This changes the current naming from `ModName_filename.xml` to `ModID_filename.xml`.
> ModID is stable; ModName can change if author renames their mod.

### 1.5 Post-Sync Hook Point

```bash
# In server-manager.sh, after sync completes:
run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "..."

# NEW: After sync, scan for CE files
scan_and_prompt_ce_files "$SELECTED_DIR"
```

### 1.6 User Flow (CE Detection)

```
┌─────────────────────────────────────────────────────────────┐
│ Syncing All Mods...                                        │
│ ████████████████████████████████████ 100%                   │
│                                                             │
│ Sync complete. Scanning for Central Economy files...       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ NEW CE File Found                                          │
├─────────────────────────────────────────────────────────────┤
│ Mod: DayZ Expansion (2116151222)                           │
│ File: expansion_types.xml                                   │
│ Type: TYPES (item spawn definitions)                        │
│                                                             │
│ Items: 127 type definitions                                 │
│                                                             │
│ Link this file to your server economy?                      │
│                                                             │
│ [Y] Yes, link it    [N] No, skip    [A] Link all new       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ CE File Updated: DayZDog_types.xml                         │
├─────────────────────────────────────────────────────────────┤
│ Mod: DayZ Dogs updated their types.xml                      │
│                                                             │
│ Changes from workshop update:                               │
│   + 3 items added: DogFood, DogBowl, DogLeash              │
│   - 1 item removed: OldDogTreat                            │
│                                                             │
│ Your local file has 2 custom edits (will be preserved)     │
│                                                             │
│ [M] Merge (add new, remove old, keep your edits)           │
│ [R] Replace (use workshop version, lose your edits)        │
│ [S] Skip (keep current, ignore update)                     │
│ [V] View detailed diff                                      │
└─────────────────────────────────────────────────────────────┘
```

### 1.7 Implementation Steps (CE Detection)

| Step | File | Description |
|------|------|-------------|
| 1.1 | `lib/xml_parser.py` | Add `diff-ce` CLI command for structural diff |
| 1.2 | `lib/xml_parser.py` | Add `count-items` CLI command for quick stats |
| 1.3 | `lib/mod_config.sh` | Update `register_modular_loot()` to save original copy |
| 1.4 | `lib/mod_config.sh` | Create `scan_mods_for_ce_files()` |
| 1.5 | `lib/mod_config.sh` | Create `check_ce_updates()` using diff-ce |
| 1.6 | `lib/mod_config.sh` | Create `merge_ce_file()` for safe merging |
| 1.7 | `lib/mod_config.sh` | Create `prompt_ce_detection()` TUI dialog |
| 1.8 | `server-manager.sh` | Hook `scan_and_prompt_ce_files()` after sync |

---

## Part 2: Update Notifications (Mods + DayZ Server)

### 2.1 Overview

Track updates for:
1. **Mods**: Compare local `time_updated` vs Steam API `time_updated`
2. **DayZ Server**: Compare installed build ID vs Steam's latest

### 2.2 Version Tracking Mechanism

**At install/sync time:**
```bash
# Store the time_updated from Steam API
echo "$time_updated" > "${workshop_dir}/${mod_id}/.installed_version"
```

**On check:**
```bash
# Compare stored value to current Steam API value
local_version=$(cat "${workshop_dir}/${mod_id}/.installed_version")
remote_version=$(python3 workshop_search.py --details "$mod_id" | jq '.updated')
[[ "$remote_version" -gt "$local_version" ]] && has_update=true
```

### 2.3 DayZ Server Update Detection

```bash
# Get installed buildid from Steam manifest
installed_build=$(grep -oP 'buildid"\s+"\K[0-9]+' \
    "${serverfiles}/steamapps/appmanifest_223350.acf" 2>/dev/null || echo "0")

# Getting latest build is tricky - Steam doesn't expose this via public API
# Options:
#   A) Run steamcmd +app_info_print 223350 (slow, requires auth)
#   B) Scrape steamdb.info (fragile)
#   C) Use a public tracking service if one exists
#   D) Compare installed mtime to known update schedule (hacky)

# RECOMMENDED: Option A with caching
# Run steamcmd once per session, cache result for 30 min
get_dayz_latest_build() {
    local cache_file="${STATE_DIR}/dayz_latest_build.cache"
    local cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
    
    if [[ $cache_age -gt 1800 ]]; then  # 30 min cache
        # This runs inside the container where steamcmd is available
        $DOCKER exec "$container" steamcmd +login anonymous +app_info_update 1 \
            +app_info_print 223350 +quit 2>/dev/null \
            | grep -oP 'buildid"\s+"\K[0-9]+' | head -1 > "$cache_file"
    fi
    cat "$cache_file"
}
```

> [!WARNING]
> DayZ Server (appid 223350) requires login for app_info.
> If anonymous doesn't work, we may need to use the user's Steam credentials.
> Fallback: Just skip server update detection if steamcmd fails.

### 2.4 Caching Strategy

**Cache file**: `${instance_dir}/data/state/update_cache.json`
```json
{
  "last_checked": 1735761600,
  "server": {
    "installed_build": "15847320",
    "latest_build": "15847892", 
    "has_update": true
  },
  "mods": {
    "1564026768": {
      "installed": 1735603200,
      "latest": 1735689600,
      "has_update": true
    }
  }
}
```

**Refresh rules:**
- Check if `now - last_checked > 120` seconds
- If stale: Show "Checking for updates..." then fetch
- Batch mod checks (100 at a time via Steam API)
- **Rate limiting**: Max 1 API call per 2 seconds, respect Steam's limits
- **Global cache**: Mod versions cached globally (not per-instance) since workshop content is shared

### 2.5 UI Changes

#### 2.5.1 Instance Selector

```
┌───────────────────────────────────────────────────┐
│ DayZ Server Manager - Select Instance             │
├───────────────────────────────────────────────────┤
│ ● server1 [RUNNING] (⚠ 1 server, 3 mods)        │  ← YELLOW
│ ○ server2 [STOPPED]                               │
│ ─────────────────────────────────────────────     │
│ ✨ Install/Manage Instances                       │
│ ❌ Quit                                           │
└───────────────────────────────────────────────────┘
```

#### 2.5.2 Main Menu Header

```
┌───────────────────────────────────────────────────┐
│ DayZ: server1 [● RUNNING] (⚠ 1 server, 3 mods)  │  ← YELLOW
├───────────────────────────────────────────────────┤
│ ▶️ Start Server                                   │
│ ...                                               │
│ ⚒️ Mod Manager (3 updates)                      │  ← YELLOW highlight
│ ...                                               │
│ ⬆️ Update Server (new version!)                 │  ← YELLOW highlight
└───────────────────────────────────────────────────┘
```

#### 2.5.3 Mod Manager Table (VERSION Column)

```
STATUS  VERSION          MOD NAME                    WORKSHOP ID    TYPE
─────────────────────────────────────────────────────────────────────────
✓       Dec 15 → Jan 01  DayZ Dog                    1564026768     [Cli]
        ~~~~~~~ YELLOW ~~~~~~~~
✓       Jan 01           Expansion Core              2116151222     [C+S]
        ↑ WHITE (up to date)
⚠       Dec 01 → Jan 01  Broken Mod                  9999999999     [Off]
        ↑ Shows update but also has warning
```

**Version format**: `MMM DD` (e.g., "Jan 01")
- Up to date: Just shows date in white
- Update available: `Dec 15 → Jan 01` in yellow

### 2.6 Implementation Steps (Version Tracking)

| Step | File | Description |
|------|------|-------------|
| 2.1 | `lib/workshop.sh` | Create `store_mod_version()` called after sync |
| 2.2 | `lib/workshop.sh` | Create `get_mod_local_version()` |
| 2.3 | `lib/workshop_search.py` | Add `--check-updates` flag to batch check |
| 2.4 | `lib/workshop.sh` | Create `check_all_updates()` with caching |
| 2.5 | `lib/workshop.sh` | Create `get_dayz_server_version()` |
| 2.6 | `lib/workshop.sh` | Create `check_server_update()` |
| 2.7 | `lib/workshop.sh` | Create `get_update_summary()` for UI |
| 2.8 | `server-manager.sh` | Update `select_instance()` with update counts |
| 2.9 | `server-manager.sh` | Update `main_menu()` header and highlights |
| 2.10 | `server-manager.sh` | Update `mod_manager()` with VERSION column |

---

## Part 3: Safety & Edge Cases

### 3.1 Merge Safety

1. **Before any merge**: Create timestamped backup in `CustomCE/.backups/`
2. **Conflict resolution**: When in doubt, preserve user's version
3. **Audit log**: Write merge actions to `CustomCE/.merge_log`
4. **Rollback UI**: Add menu option "Restore from backup" in modular_loot_manager

**Rollback Flow:**
```
[d] Delete   [b] Restore Backup   [q] Back

┌───────────────────────────────────────────────────┐
│ Restore Backup: DayZDog_types.xml                │
├───────────────────────────────────────────────────┤
│ Available backups:                                │
│  1. 2026-01-01 20:15:32 (before merge)           │
│  2. 2026-01-01 19:00:00 (before merge)           │
│  3. 2025-12-28 14:30:00 (initial link)           │
│                                                   │
│ Select backup to restore: [1-3]                  │
└───────────────────────────────────────────────────┘
```

### 3.2 DayZ Major Updates (e.g., 1.27 → 1.28)

When DayZ itself updates, vanilla types.xml changes. This is separate from mod detection.

**Proposed handling:**
- After server update, prompt: "DayZ updated. Check vanilla economy changes?"
- Compare `mpmissions/*/db/types.xml` to known vanilla baseline
- Show what BI added/removed
- User can choose to apply vanilla changes to their customized file

> [!NOTE]
> This is a future enhancement. For now, focus on mod CE files.

### 3.3 Network Failures

- Steam API timeout: 5 seconds
- On failure: Use cached data, show "Last checked: X min ago"
- Don't block UI for network issues

### 3.4 First Run / No Cache

- If no cache exists: Show "Checking for updates..." on first menu entry
- Pre-populate cache after first check
- Subsequent views are instant (use cache)

---

## Part 4: Implementation Order

### Phase 1: Version Infrastructure (Foundation)
1. `lib/workshop.sh` - Version storage/retrieval functions
2. `lib/workshop_search.py` - Batch update check
3. Caching infrastructure
4. DayZ server version detection

### Phase 2: UI Update Indicators
5. Instance selector update counts
6. Main menu header updates
7. Mod Manager VERSION column  
8. Yellow highlighting for update items

### Phase 3: CE Detection
9. `xml_parser.py` diff-ce command
10. Original file storage on link
11. `scan_mods_for_ce_files()`
12. Post-sync hook in server-manager.sh

### Phase 4: Merge System
13. Safe merge algorithm
14. Backup system
15. Merge confirmation dialogs
16. Audit logging

---

## Part 5: Test Strategy

> [!CAUTION]
> The merge system is HIGH RISK. Must have tests before deployment.

### 5.1 Unit Tests (Python)

```python
# tests/test_xml_parser.py

def test_diff_detects_added_items():
    """New items in source should appear in 'added' list"""
    
def test_diff_detects_removed_items():
    """Items missing from source should appear in 'removed' list"""

def test_diff_detects_modified_values():
    """Same item name with different nominal should appear in 'modified'"""

def test_merge_adds_new_items():
    """Merge should add items from source that don't exist in local"""

def test_merge_preserves_user_edits():
    """Merge should NOT overwrite user's modified values"""

def test_merge_handles_removed_items():
    """Items removed by mod author should be flagged but not auto-deleted"""
```

### 5.2 Integration Tests (Bash)

```bash
# tests/test_ce_detection.sh

test_scan_finds_types_xml() {
    # Create mock mod folder with types.xml
    # Run scan_mods_for_ce_files
    # Assert file is detected with correct ce_type
}

test_already_linked_file_detected() {
    # Link a file, then re-scan
    # Assert status is "unchanged" not "new"
}

test_changed_file_detected() {
    # Link a file, modify workshop source
    # Assert status is "changed"
}
```

### 5.3 Manual Test Cases

| Scenario | Expected Result |
|----------|----------------|
| Fresh mod install with types.xml | Prompt to link appears |
| Mod update adds 2 items | Merge shows "+2 items", adds them |
| Mod update removes 1 item | Merge shows "-1 item", prompts before remove |
| User edited nominal value | Merge preserves user's value |
| Merge fails mid-operation | Backup restored, error shown |
| Network timeout during update check | Cache used, warning shown |

---

## Files Affected (Summary)

| File | Changes |
|------|---------|
| `lib/xml_parser.py` | +`diff-ce`, +`count-items` commands |
| `lib/workshop_search.py` | +`--check-updates` batch flag |
| `lib/workshop.sh` | +version tracking, +caching, +update checks |
| `lib/mod_config.sh` | +original storage, +CE scan, +merge |
| `server-manager.sh` | +VERSION column, +update indicators, +post-sync hook |

---

## Estimated Effort (Revised)

| Phase | Complexity | Estimate |
|-------|------------|----------|
| Phase 1: Version Infrastructure | Medium | 1-2 hours |
| Phase 2: UI Update Indicators | Medium | 1-2 hours |
| Phase 3: CE Detection | Medium-High | 2-3 hours |
| Phase 4: Merge System | High | 2-3 hours |

**Total**: 6-10 hours

---

## Open Questions Resolved ✓

| Question | Decision |
|----------|----------|
| Manifest vs direct compare | Direct compare (no manifest) |
| Version source | Steam API `time_updated` |
| Merge feature | Keep - users want it |
| What to track | Mods AND DayZ server |
| Hook point | `server-manager.sh` (host-side) |
| Auto vs manual CE scan | Auto after sync, but prompt per file |
