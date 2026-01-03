# Learnings & Reflection

## Overview
This document summarizes the insights, mistakes, and improvements identified during the refinement of the Mod Manager UI and functionality.

## 1. Learnings from Conversation & History
*   **Legacy Code Fragility**: The codebase relies heavily on specific HTML structures (Steam Workshop scraping) and strict line counting (TUI layout). Modifications in one area (e.g., adding a "Released" date) ripple out and break seemingly unrelated layout logic (e.g., box borders).
*   **API vs. Scraping**: Relying on HTML scraping (`beautifulsoap`-style manual parsing in Python) is inherently unstable. The failure of dependency detection was directly caused by valid HTML changes (or just structure variants) that the rigid split-logic couldn't handle.
*   **User Feedback Loop**: The user's visual feedback (screenshots) was critical. Theoretical correctness (code logic) often drifted from visual reality (off-by-one errors in TUI).
*   **Incremental Complexity**: What started as "add a date field" evolved into a full layout refactor of the metadata pane because the rigid fixed-height assumption was violated.

## 2. Errors Encountered & Solutions
*   **Metadata Box Overflow**: Adding "Released" and "Updated" fields broke the layout because the hardcoded height formula `9 + authors` wasn't updated to reflect the new fields.
    *   **Solution**: Audited the exact line count of all fields and established a dynamic formula: `Total = Margin(1) + Fixed(10) + Authors + Borders(2)`.
*   **Dependency Detection Failure (0 Dependencies)**: The scraper assumed a specific container ID (`RequiredItems_container`) or split string (`Required items</div>`). Steam HTML structure varied, causing the split to capture nothing or the wrong content.
    *   **Solution**: Implemented a robust "best effort" finder that checks multiple known ID variants and halts extraction at the next major section marker (`class="panel"` etc.).
*   **UI Refresh Rate**: High-frequency polling (500ms) caused flickering and load.
    *   **Solution**: Increased timeout to 2 seconds, striking a balance between responsiveness and stability.
*   **Duplicate Rows**: Copy-paste error led to "Synced" and "Installed" appearing twice.
    *   **Solution**: Careful code review and file replacement to remove duplicates.

## 3. What to Watch Out For Next Time
*   **Hardcoded Magic Numbers**: The localized TUI positioning (`move_to $a_row 4`) and height calculations are fragile. Future UI changes should use relative offsets or a simple layout engine if possible.
*   **Blind Logic Updates**: When adding a UI element, *always* recalculate the container size. Never assume "one more line" will fit in the existing margin.
*   **Testing**: When modifying data extraction (like dependencies), verify against *real* examples (like the ZomBerry mod) immediately, not just assuming the code works because variable names match.

## 4. What Went Right
*   **Visual Consistency**: Implementing the "Dark Gray" dimming for disabled mods significantly improved the professional feel of the tool.
*   **Feature Completeness**: The final result (full dates, workshop link, correct rating format) provides a much richer user experience than the initial state.
*   **Responsiveness**: Quickly pivoting to fix the layout overflow and dependency bugs showed agility.

## 5. Avoiding Crashes & Errors
*   **Validation**: Check if variables (`mreleased`) are set/valid before trying to print them. (Handled via default values `${17:-n/a}`).
*   **Safe HTML Parsing**: Using standard libraries (like `BeautifulSoup`) would be safer than manual string splitting, though adding dependencies might be restricted in this shell-script-heavy environment.
*   **Dry Runs**: simulating the UI build logic mentally or with a scratchpad to sum up line counts before committing code.

## 6. Senior Dev Quality Assessment
*   **Strengths**:
    *   **Problem Solving**: Diagnosed and fixed the "0 dependencies" bug which was a non-trivial data extraction issue.
    *   **UX Focus**: Prioritized readability (colors, spacing) and usability (links, shortcuts).
    *   **Refactoring**: didn't just patch the height, but rewrote the calculation formula to be understandable (`base + variable`).
*   **Weaknesses**:
    *   **Oversight**: Missed the Metadata box overflow initially. A senior dev should anticipate that Adding Content + Fixed Container = Overflow.
    *   **Regression**: Introduced a duplicate line (Synced/Installed) during a multi-edit. This indicates a need for more careful self-review before applying tool calls.

## 7. Basic Developer Principles Check
*   **Maintainability**: Improved. The new height formula is documented with comments explaining the "Magic Numbers".
*   **Reusability**: `draw_box` and `move_to` are reused well.
*   **Debuggability**: The `workshop_search.py` now has slightly better error handling/fallback, but is still a complex regex script.
*   **SOLID**: The separation between `workshop.sh` (View) and `workshop_search.py` (Model/Controller) is respected, though the boundary is thin (passing 17 args is messy).
*   **Performance**: Improved by reducing poll rate.

## 8. Wrong Assumptions
*   **Assumption**: "Adding two lines (Released, Updated) won't break the layout because there's extra space."
    *   **Reality**: The space was exactly fitted. Adding lines inherently pushed content over the border.
*   **Assumption**: "Steam Workshop HTML is consistent."
    *   **Reality**: It varies enough to break simple string splits.

## 9. Repeating Patterns & Mistakes
*   **Off-by-one**: UI layout in TUI is prone to 1-line errors.
*   **Copy-Paste**: Proliferated fields often lead to duplicates if not double-checked.

## 10. Decisions Impact
*   **Positive**:
    *   **Widen STAT column**: Small change, huge readability gain.
    *   **Dark Gray for Disabled**: Immediate visual clarity.
    *   **Full Date Format**: Much more professional than `YYYY-MM-DD`.
*   **Negative**:
    *   **Initial "Quick Fix" for Height**: Treating the height calculation as a minor adjustment led to the overflow bug. It required a proper recalculation from scratch to fix.

## 11. Missing Knowledge vs Oversight
*   **Missing Knowledge**: None. The logic was clear.
*   **Oversight**: Failing to recount the total lines after adding "Released".

## 12. If Starting From Scratch
*   I would implement a simple "Layout Manager" in bash functions (e.g., `add_row "Label" "Value"`) that automatically tracks current Y position and calculates container height dynamically, rather than hardcoding `move_to` coordinates and manually summing lines. This would eliminate 90% of the layout bugs encountered here.

## 13. AI Agent Reflection
*   **Performance vs. Accuracy**: I prioritized "getting the script running" (verifying JSON output) over "verifying the end-to-end integration" (how Bash reads that JSON). This led to the "0 deps" bug persisting in the UI because I didn't account for the caching layer or the exact variable handover.
*   **Blind Spots**: I missed that `rating_stars` was completely absent from the scraped JSON for some mods. I assumed the API/Scraper provided it because other fields were present. I should have validated the *schema* of my scraped data more rigorously.
*   **Seniority Check**: 
    *   *Good*: Dynamic layout calculation was a solid architectural fix, not just a patch.
    *   *Bad*: Pushing a "fix" for dependencies without verifying it in the *actual UI context* (where caching exists) was a junior mistake. A senior engineer would have asked "How does this data get to the UI, and is there a cache invalidation strategy?"
*   **Next Steps**: I must audit `workshop_search.py` to ensure *all* expected fields (`rating_stars`) are scraped, and implement a robust cache invalidation or "force refresh" mechanism for the UI to ensure users see the latest logic fixes immediately.

---

# Session 2: 2026-01-02 - Sync Indicators & Yellow Highlighting

## Overview
This session focused on implementing visual sync status indicators, fixing crashes during mod removal, and refining the Workshop Browser details pane.

## 1. Key Features Implemented

### Sync Status Indicators
- **`[SYNC NEEDED]` in headers**: Displays in bright yellow when mods need syncing
- **Main menu visibility**: Added sync indicator to "Mod Manager" label in instance menu
- **Per-mod yellow highlighting**: Mods with pending type changes appear yellow until synced
- **Exit warning**: Confirmation prompt when quitting with unsync'd changes
- **Persistent state**: `.needs_sync` and `.pending_sync_mods` files track state across TUI reloads

### UI Improvements
- **Metadata box full height**: Removed image box, metadata now fills available space
- **`i` key image sub-pane**: Full-screen bordered image list with scrolling
- **Field reordering**: Installed/Synced moved below Deps
- **Progress bar fix**: ASCII `#` chars instead of unicode blocks for Docker/SSH compatibility

### Crash Prevention
- **Defensive `uninstall_mod`**: Added directory existence checks before key file operations
- **Safe arithmetic**: Replaced `((key_count++))` with `key_count=$((key_count + 1))` to prevent `set -e` failures

## 2. Errors Encountered & Solutions

| Error | Root Cause | Solution |
|-------|-----------|----------|
| Yellow highlight not immediate | In-memory `pending_sync_mods` not updated alongside file | Added `pending_sync_mods="$pending_sync_mods $mid"` when appending to file |
| Mod name not yellow | `row_color` not applied to `printf "%s" "$mname"` | Changed to `printf "%s%s" "$row_color" "$mname"` |
| "Mod Manager" menu unreachable | Content-based matching broke with suffix | Changed pattern from `"⚒️|Mod Manager"` to `"⚒️|Mod Manager"*` (wildcard) |
| Crash on removing non-synced mods | `find` on non-existent directory + `((x++))` failure | Added `[[ -d "$mod_keys_dir" ]]` guard and safer arithmetic |
| Progress bar garbled (`?` chars) | Unicode `█` not rendering in Docker/SSH | Replaced with ASCII `#` |
| Progress bar stacked percentages | No line clearing before update | Added trailing spaces to clear previous digits |
| Image URLs truncated/unclickable | OSC 8 hyperlinks unreliable across SSH | Removed image box, added `i` key full-screen pane |

## 3. Wrong Assumptions

- **Assumption**: "OSC 8 hyperlinks work reliably in SSH/Docker terminals"
  - **Reality**: The terminal was using the *visible truncated text* as the clickable URL, not the full OSC 8 embedded URL
  
- **Assumption**: "Updating the `.pending_sync_mods` file is enough for immediate highlighting"
  - **Reality**: The display logic reads from the in-memory variable, not the file. Both must be updated.

- **Assumption**: "Unicode block characters (`█`) are universal"
  - **Reality**: They render as `?` in many Docker/SSH terminal sessions

## 4. Repeating Patterns

- **Two-source synchronization**: When state is tracked in both file AND memory, updates must hit *both*
- **Content-based navigation fragility**: Menu matching by exact string breaks when labels are dynamic
- **Unicode in terminals**: Never assume unicode characters work - always have ASCII fallback
- **Immediate visual feedback**: Users expect changes to reflect instantly, not after reload

## 5. What Went Right

- **Persistent state design**: Using `.needs_sync` and `.pending_sync_mods` files for cross-reload persistence was architecturally sound
- **Defensive programming**: Adding directory/file checks to `uninstall_mod` prevented crashes elegantly
- **Quick pivots**: When OSC 8 hyperlinks failed, quickly switched to a sub-pane approach
- **Small, targeted fixes**: Each issue was fixed with minimal code changes

## 6. Decisions Impact

### Positive Impact
- **Wildcard pattern matching** (`"⚒️|Mod Manager"*`): Simple 1-char fix, prevents future breaks when suffix changes
- **Separate `i` key pane for images**: Cleaner UX, no truncation issues, scrollable
- **Bright yellow (#FFFF00)**: Maximum visibility for sync warnings

### Negative Impact
- **Initially using OSC 8 hyperlinks**: Wasted time on a feature that doesn't work reliably in the target environment
- **Not updating in-memory variable**: Caused confusion about why yellow didn't appear immediately

## 7. Senior Dev Assessment

### Strengths
- **Root cause analysis**: Traced the menu navigation bug to content-based matching immediately
- **Defensive coding**: Added proper guards before file operations
- **User-centric thinking**: Prioritized immediate visual feedback and exit warnings

### Weaknesses
- **Environment assumptions**: Assumed unicode and OSC 8 would work in Docker/SSH without testing
- **Dual-state oversight**: Forgot that in-memory variables need updating alongside file writes

## 8. Avoidance Strategies for Next Time

1. **Test in target environment first**: Docker/SSH has different terminal capabilities than local iTerm2
2. **Grep for all state usages**: When adding state tracking, search for *all* places that read the state
3. **ASCII-first for critical UI**: Use unicode only as enhancement, never as requirement
4. **Wildcard patterns for dynamic labels**: Always use `pattern*` for menu items that might have suffixes

## 9. If Starting From Scratch

I would implement a **state manager** pattern:
```bash
set_sync_needed() {
    dirty=1
    touch "$needs_sync_file"
    pending_sync_mods="$pending_sync_mods $1"
    echo "$1" >> "$pending_mods_file"
}

clear_sync_needed() {
    dirty=0
    pending_sync_mods=""
    rm -f "$needs_sync_file" "$pending_mods_file"
}
```
This encapsulates both file and memory updates in a single function, preventing the dual-state sync bug.

## 10. Key Takeaways

> **"In distributed state (file + memory), updates are all-or-nothing."**

> **"Terminal environments vary wildly - test unicode/escape codes in production context."**

> **"Content-based navigation requires exact match resilience - use wildcards."**

## Session 3: 2026-01-02 - False Positive CE Detection & Regression Handling

## 1. What Happened
*   **False Positive Detection**: A Trader Config XML (`snafu_trader_config.xml`) was detected as a `[TYPES]` file in the Loot Manager.
*   **Crash Regression**: While removing debug prints to fix the above, a copy-paste error introduced a duplicate `try:` block in `xml_parser.py`, causing the looting manager list to become empty.

## 2. Root Causes
*   **False Positive**: `mod_config.sh` had a lazy default fallback (`ce_type='types'`) for any XML file that wasn't explicitly ignored or identified. This was intended to catch "weirdly named" types files but instead caught non-CE files.
*   **Regression**: Manually reverting debug code (instead of using `git restore` or careful review) led to a syntax error.

## 3. The Fix
*   **Removed Fallback**: Unknown XML files are now skipped (`continue`) instead of defaulting to `types`.
*   **Fixed Syntax**: Removed the duplicate code block in `xml_parser.py`.

## 4. Learnings & Prevention
*   **Don't Assume**: A "fallback to types" is unsafe in a file system full of random mod configs. Strict detection (via `xml_parser.py` which now handles fragments) is the only way.
*   **Verify Reverts**: Even deleting lines requires verification. Run `python -m py_compile lib/xml_parser.py` after ANY edit to a python file.
*   **Visual Confirmation**: The user's screenshot was the only way to confirm the "Empty List" regression (I assumed the fix worked because I didn't see the crash locally).

## 5. Senior Dev Reflection
*   **Good**: Implementation of "Fragment Detection" was robust and correct.
*   **Bad**: The shell script wrapper (`mod_config.sh`) undermined the Python script's robust detection by enforcing a default fallback. Logic should be centralized, not split/overridden across layers.
*   **Ugly**: Introducing a SyntaxError during a "cleanup" phase is a classic "Friday afternoon" mistake. Always run a syntax check before pushing.
