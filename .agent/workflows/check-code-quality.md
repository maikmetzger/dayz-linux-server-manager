---
description: Check code quality (Bash TUI frontend + Python backend in Docker): structure, maintainability, SOLID-ish separation, safety under set -euo, tests, UX, and regression risks.
---

## Inputs (required)
1. Identify the change scope:
   - Which files changed?
   - Which behavior changed?
   - Which layer is involved: Bash UI, Python backend, or the Bash↔Python contract?

## 1) Architecture / separation check (frontend vs backend)
2. Confirm responsibilities are not mixed:
   - Bash only: UI, input handling, orchestration, rendering
   - Python only: parsing, data extraction, heavy logic, normalization
3. If logic exists in both Bash and Python, move it to Python unless it is pure UI.

## 2) Contract check (Bash ↔ Python)
4. Verify backend output is valid JSON for success and error.
5. Verify schema stability:
   - required keys exist (even if null/empty)
   - add `schema_version` if missing
6. Verify Bash uses defaults for missing fields and cannot crash on absent keys.

## 3) Bash safety (set -euo pipefail)
7. Search for bash “crash magnets” in changed code:
   - `((x++))` / `((++x))` (replace with `x=$((x + 1))`)
   - unguarded `find`, `rm`, `cat`, `cp`, `mv`
   - pipelines that may return non-zero (`grep`, `head`) without handling
8. Verify all filesystem operations are guarded:
   - `[[ -d ... ]]` before directory reads/find
   - `[[ -f ... ]]` before file ops
9. Verify patterns + arithmetic inside `[[ ]]` are safe:
   - quote globs: `== "----"*`
   - wrap arithmetic: `$(())`

## 4) Maintainability / readability
10. Check for magic numbers (especially TUI layout):
   - if present, add a short comment explaining line math
11. Check for duplication:
   - if 3+ lines repeated, extract a helper function
12. Check naming consistency:
   - no cryptic abbreviations for important things
   - functions grouped by purpose (`ui_*`, `state_*`, `actions_*`, `backend_*`)

## 5) Reusability
13. Confirm reusable helpers exist for repeated UI patterns:
   - row renderer, box renderer, status line, prompts
14. Confirm paths/constants are centralized (no scattered hardcoded directories).

## 6) Debuggability
15. Verify there is a clear debug path:
   - frontend: `DEBUG=1` logs commands + exit codes
   - backend: error returns JSON with `ok:false` + `error.code/message`
16. Verify failures are visible in UI (not silent, not a crash).

## 7) Testability (minimum bar)
17. Backend:
   - run `python3 -m py_compile` on changed Python files
   - run tests if present (or add at least one regression test/fixture for fixed bugs)
18. Frontend:
   - run `bash -n` on changed bash files
   - run a quick smoke run of the TUI in the target environment (SSH/Docker terminal)
19. Parsers:
   - test against at least 2 real workshop HTML variants (fixtures or live samples)

## 8) UX / TUI quality
20. Verify changes render correctly at minimum terminal width.
21. Verify ASCII fallback for critical UI elements (don’t rely on unicode/OSC-8).
22. Verify immediate feedback for state changes (dirty/sync needed highlights update instantly).

## 9) Regression & risk check
23. List what this change could break:
   - layout line counts
   - menu matching / dynamic labels
   - dual state (memory + file)
   - caching (stale UI)
24. Add or update one guardrail for the biggest risk:
   - a test
   - a fixture
   - a runtime guard
   - a log line

## 10) Done definition
25. Only call it “done” if:
   - schema + defaults are safe
   - no bash crash magnets added
   - UI verified in target terminal
   - at least one regression protection exists for the bug/feature