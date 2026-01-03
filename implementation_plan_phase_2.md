# Implementation Plan: Phase 2 - Merge Tracking System

> [!IMPORTANT]
> The current detection system correctly identifying `cfgrandompresets.xml` and `cfgeventgroups.xml` now exposes the need for a merge tracking system. These files **cannot** be linked via `cfgeconomycore.xml` (unlike types.xml).

> [!WARNING]
> This phase introduces a Breaking Change: Switching from "Link" to "Merge" workflow for specific file types.

---

## 2. Architecture Overview

### Problem
Certain DayZ Central Economy files (`cfgrandompresets.xml`, `cfgeventgroups.xml`) must be single files in the `db/` folder. Mods often provide fragments for these files. We cannot use `cfgeconomycore.xml` to include them.

### Solution: Automated Tracking & Merge
We must physically merge mod entries into the main file, but track exactly what was added so we can cleanly uninstall it later.

```mermaid
flowchart TD
    A[Mod Sync] --> B{CE Type?}
    B -->|types, events| C[Link (DONE)]
    B -->|randompresets, etc| D[Merge Request]
    
    D --> E[Parse Entries]
    E --> F{Collision?}
    F -->|Yes| G[Detect / Rename]
    F -->|No| H[Direct Merge]
    
    H --> I[Write to Target XML]
    I --> J[Update Tracking JSON]
```

---

## 3. Detailed Design

### Tracking Data Model
Location: `/data/state/ce_merge_tracking/{target_file}.json`

This JSON acts as the source of truth for uninstalls. It maps Mod IDs to the specific XML entries they contributed.

```json
{
  "target_file": "db/cfgrandompresets.xml",
  "last_updated": "2026-01-02T22:00:00",
  "entries": {
    "2646817942": [
      {
        "xpath": "cargo[@name='MedicalPreset']",
        "original_name": "MedicalPreset",
        "current_name": "TF_MedicalPreset",
        "was_renamed": true
      }
    ]
  }
}
```

### Visual Markers (XML Comments)
Entries in the target file will be wrapped with comments for manual auditing redundancy:

```xml
<!-- [BEGIN: 2646817942] Tactical Flava -->
<cargo name="TF_MedicalPreset" chance="0.1">
    <item name="Bandage" />
</cargo>
<!-- [END: 2646817942] -->
```

---

## 4. Workflows

### 4.1 Merge Workflow
1.  **Parse Source**: Extract valid entries (skipping non-compliant tags).
2.  **Check Collisions**:
    *   Compare entry names against target file.
    *   If collision found: Prompt user to "Prefix with ModID" (e.g., `ModID_PresetName`).
3.  **Merge**:
    *   Inject entries into target DOM.
    *   Add XML comments.
    *   Save file.
4.  **Track**: Update JSON with added entries.

### 4.2 Uninstall Workflow
1.  **Read Tracking**: Load JSON for the target file.
2.  **Locate Entries**: Find entries by ID or Name.
3.  **Safety Check**: Grep other CE files (like `cfgspawnabletypes.xml`) to see if they reference the preset being removed.
    *   If referenced: Warn user "Preset in use by...".
4.  **Remove**: Delete XML block.
5.  **Clean**: Remove from tracking JSON.

---

## 5. Implementation Steps

### Step 1: Python Tracking Module
Create `lib/merge_tracking.py`:
- `load_tracking(file)`
- `save_tracking(file, data)`
- `check_collisions(source_xml, target_xml)`

### Step 2: XML Injection Logic
Extend `xml_parser.py` or new module:
- `inject_entries(target, entries, comments=True)`
- `remove_entries_by_comment(target, mod_id)` (Regex fallback)
- `remove_entries_by_xpath(target, xpath_list)` (Precise cleanup)

### Step 3: TUI Integration
- Update `mod_config.sh` to show "MERGE" instead of "LINK" for these specific file types.
- Add "Merge Conflict" UI dialog (Rename / Skip / Overwrite).

### Step 4: Migration
- If user previously manually merged files, offer a "Scan & Adopt" feature to retroactively track them? (Maybe post-MVP).

---

## 6. Verification
- [ ] Test merging `randompresets` from 2 different mods.
- [ ] Test collision (same preset name).
- [ ] Test Uninstall (clean removal).
- [ ] Test Uninstall with References (warning trigger).
