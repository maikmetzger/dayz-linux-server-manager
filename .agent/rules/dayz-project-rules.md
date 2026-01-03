---
trigger: always_on
---

# dev-rules.md

## 0) Goal
Keep changes safe, readable, testable, and easy to revert. TUI + Bash + Python means “small mistakes = big breakage”.

---

## 1) Structure rules (SOLID-ish for Bash/Python)
- One file = one job. Don’t mix UI drawing, scraping, and state updates in the same function.
- One function = one responsibility. If a function does UI + parsing + file writes, split it.
- Separate layers:
  - **UI**: draw, input handling, navigation
  - **State**: load/save, caching, “dirty” flags
  - **Domain**: mod operations (install/uninstall/sync), server actions
  - **Integration**: workshop fetch/scrape, external commands
- Depend “inward”:
  - UI calls Domain
  - Domain calls State + Integration
  - Integration never calls UI
- The project has the following structure inside the docker container:
~/servers/dayz-server1/              # instance_dir
├── data/
│   ├── backups/
│   ├── config/
│   │   ├── mods.txt
│   │   └── serverDZ.cfg
│   │   └── ...
│   ├── profile/
│   ├── serverfiles/                 # ← serverfiles IS INSIDE data/
│   │   ├── mpmissions/
│   │   │   └── dayzOffline.chernarusplus/
│   │   │       └── CustomCE/
│   │   │       └── ...
│   │   └── steamapps/workshop/...
│   └── state/                       # ← state for tracking should go here
│       └── ce_merge_tracking/       # NEW
│       └── ...

### Bash version of SOLID
- **S (Single responsibility):** function names describe one action (`load_state`, `save_state`, `draw_mod_row`).
- **O (Open/closed):** extend by adding new handlers/functions, not rewriting existing logic.
- **L (Liskov):** if you swap implementation (scrape v1 vs v2), callers shouldn’t change.
- **I (Interface segregation):** pass only what a function needs (avoid “17 args” if possible).
- **D (Dependency inversion):** pass command/adapter functions (`fetch_workshop_data`) so you can mock them in tests.

---

## 2) Maintainability rules
- No magic numbers without a comment explaining the math.
- No duplicated code blocks. If you copy 3+ lines twice, extract a function.
- Use consistent naming:
  - `snake_case` in bash and python
  - `is_*` for booleans (`is_dirty`, `is_installed`)
- Keep functions short:
  - Bash: aim < 60 lines
  - Python: aim < 80 lines
- Prefer data-driven tables over scattered `printf` calls.

---

## 3) Reusability rules
- Make “building blocks”:
  - `ui_*` functions for drawing
  - `state_*` for persistence
  - `mod_*` for mod actions
  - `ws_*` for workshop parsing/fetch
- Avoid hardcoding paths everywhere:
  - centralize paths in one config section (`ROOT`, `CACHE_DIR`, `STATE_DIR`)
- Don’t hardcode “DayZ only” in helpers if they’re generic (progress bar, menu, prompt).

---

## 4) Debuggability rules
- Add a debug mode:
  - `DEBUG=1 ./tool.sh`
  - Use `log_debug`, `log_info`, `log_warn`, `log_error`
- Every external call must be traceable:
  - log command + key params (not secrets)
- Always show “why” on failure:
  - include exit code, missing file, bad parse, empty result, etc.
- Never silently swallow errors unless you log that you did.

Suggested Bash logging helpers:
- `log_debug "msg"`
- `die "msg"` (prints + exits non-zero)

---

## 5) Testability rules (realistic for Bash/Py)
### Minimum test harness
- Every “unit” should be runnable without the TUI:
  - `./tool.sh --selftest`
  - `./tool.sh --test-parse <fixture.html>`
  - `./tool.sh --test-layout`
- Add fixtures:
  - `tests/fixtures/workshop_1.html`
  - `tests/fixtures/workshop_2.html` (variant structure)
  - `tests/fixtures/modlist_small.txt`
- Write at least 1 test per bug you fix (regression test).

### Make code mockable
- Wrap external commands:
  - `steamcmd()` wrapper
  - `curl()` wrapper
  - `docker()` wrapper
So tests can replace them with fake implementations.

---

## 6) Reliability rules (avoid crashes)
- Guard every filesystem op (`-d`, `-f`).
- In Bash with `set -e`, avoid constructs that “fail successfully”:
  - no `((x++))`
  - careful with `grep` / `head` / `read` pipelines
- Handle empty/partial data:
  - workshop fields missing is normal → defaults required
- In dual-state (file + memory): update both or neither.

---

## 7) Performance rules
- Poll slower by default; add “manual refresh” key.
- Cache expensive fetches; add clear invalidation rules.
- Avoid re-parsing large content every redraw; parse once, render many.

---

## 8) UX/UI rules (TUI)
- ASCII-first; unicode is optional.
- Test in target env (SSH/Docker).
- Every action should give feedback:
  - success message or visible state change
- Don’t hide state transitions:
  - dirty/sync needed must be obvious
- Keybinds should be discoverable (help screen / footer).

---

## 9) Implementation workflow (what to do every time)
- Reproduce the problem in the real environment.
- Locate the data flow: source → parse → state → UI.
- Implement in this order:
  1) domain/state logic
  2) integration/parsing
  3) UI rendering
- Add regression test/fixture.
- Run checks:
  - `bash -n`
  - `python3 -m py_compile`
  - run TUI visually

---

## 10) “Senior check” before merging
- Did I reduce complexity or add it?
- Did I make the next change easier?
- Did I add at least one guardrail (test, fixture, log, wrapper)?
- Did I avoid hidden coupling (layout numbers, exact label matches, single ID scraping)?
- Can someone else debug this without asking me?

---

## How this fits your DayZ server manager console
- Treat it as a small app with layers:
  - `ui/*.sh`  (draw + input)
  - `state/*.sh` (files, cache, dirty flags)
  - `domain/*.sh` (mods, sync, server lifecycle)
  - `integrations/*.sh` (steamcmd, docker, ssh)
  - `workshop/*.py` (parsing/fetching with clear CLI)
- Keep Python as a proper CLI tool:
  - `workshop_search.py --id <mid> --out json`
- Bash reads JSON in one place and maps to UI fields with defaults.
- Add `tests/` with fixtures for workshop HTML and mod lists.