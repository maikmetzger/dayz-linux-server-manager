# Admin Tools Feature - Learnings

**Date:** 2026-01-03  
**Feature:** Admin Tools menu for managing Steam64 IDs and passwords

---

## Inputs

1. **Goal:** Add "Admin Tools" menu entry for managing admin Steam64 IDs and passwords for VPP, COT, ZomBerry, Expansion, DayZ base, and RCON.
2. **What broke/added:** New feature with multiple fixes during implementation
3. **Files touched:**
   - `lib/admin_config.sh` (NEW)
   - `server-manager.sh` (menu entry + handler)
   - `lib/config.sh` (CONFIG_REGISTRY entry - later unused)

---

## 1) What Happened

### Issue A: Menu entry not appearing
- **Symptom:** Admin Tools not visible in main menu
- **Root cause:** Added to `CONFIG_REGISTRY` but main menu is built directly in `server-manager.sh`, not from registry

### Issue B: `input_dialog` command not found
- **Symptom:** Error when trying to add Steam64 ID
- **Root cause:** Used non-existent function `input_dialog` instead of existing `read_input`

### Issue C: Admin tools not detected (VPP, ZomBerry)
- **Symptom:** Only COT showing even with VPP/ZomBerry installed
- **Root cause:** Wrong Steam Workshop IDs from web search
  - VPP was `1708571078` → correct: `1828439124`
  - ZomBerry was `2369477168` → correct: `1582756848`

### Issue D: Cannot enter Admin Tools
- **Symptom:** Nothing happens when selecting menu entry
- **Root cause:** Emoji character `👤` got corrupted during multi-replace (`�`)

---

## 2) Fix Summary

| Issue | Fix |
|-------|-----|
| Menu entry | Added directly to `server-manager.sh` main_menu() array |
| input_dialog | Changed to `read_input` (returns via stdout, not variable ref) |
| Workshop IDs | User provided correct IDs: VPP=`1828439124`, ZomBerry=`1582756848` |
| Emoji | Re-applied correct emoji `👤` to case handler |

**Side effects:**
- Steam username lookup adds ~3s latency per admin (cached after first lookup)
- In-memory cache only (no file persistence)

---

## 3) Why It Happened (Patterns)

| Issue | Pattern |
|-------|---------|
| Menu entry | **Incorrect assumption** - assumed CONFIG_REGISTRY drives main menu |
| input_dialog | **Copy-paste from memory** - invented function name |
| Workshop IDs | **Brittle web search** - outdated/incorrect search results |
| Emoji | **Terminal capability mismatch** - emoji encoding issues in multi-replace |

---

## 4) How to Avoid Next Time

1. **Before adding menu entry:** Grep for existing menu items to find where they're defined
2. **Before using dialog functions:** View `lib/dialogs.sh` outline to confirm function signatures
3. **Workshop IDs:** Always ask user to confirm IDs from their actual `mods.txt` 
4. **Emoji icons:** After editing, immediately verify both menu array AND case handler match exactly
5. **Test with bash -n:** Run syntax check after every code change
6. **Single-file edits for emojis:** Avoid multi-replace for lines with special characters

---

## 5) Regression Protection

- [x] **Runtime guard:** `validate_steam64()` function prevents invalid IDs
- [x] **Menu selection guard:** Separators and Back options handled explicitly
- [ ] **TODO:** Add fixture test for workshop ID patterns
- [ ] **TODO:** Add self-test for Steam username lookup

---

## 6) Senior-Dev Check

| Question | Answer |
|----------|--------|
| Reduced coupling? | Yes - self-contained `lib/admin_config.sh` |
| Right layer? | Yes - Bash for TUI, Python for JSON manipulation |
| Next change easier? | Yes - new admin tools can be added to `ADMIN_TOOL_PATTERNS` array |
| User feedback to apply? | **Always confirm Workshop IDs with user** - web search is unreliable |

---

## Key Takeaways

> **Workshop IDs are unreliable from web search.** Always verify with user's actual installation.

> **Dialog functions differ by project.** Never assume - always check existing code.

> **Emoji handling is fragile.** Verify after edits, especially with multi-replace tool.
