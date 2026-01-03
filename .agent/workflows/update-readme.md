---
description: Update README for the Bash TUI frontend + Python backend (Docker-only) DayZ server/mod manager. Keep it accurate, minimal, and useful for first-time setup and debugging.
---

## Inputs (required)
1. Identify what changed since the last README update:
   - Features added/removed
   - Commands/flags changed
   - Files/paths changed
   - Contract/schema changed

## 1) README must answer these first
2. What is this project (one paragraph)?
3. What does it do (bullet list)?
4. What does it NOT do / limitations (bullet list)?
5. Where does it run (Docker-only backend, Bash TUI frontend)?

## 2) Setup (copy/paste runnable)
6. Document prerequisites:
   - Docker version requirement
   - any host deps (bash, jq if used, etc.)
7. Provide the minimal setup commands:
   - build/pull image
   - run container
   - start TUI
8. Document required env vars and defaults:
   - instance paths
   - cache/state paths
   - DEBUG flags
9. Document filesystem layout:
   - where state files live (`.needs_sync`, `.pending_sync_mods`, caches)

## 3) Usage (what users actually do)
10. Add a quick-start section:
    - start
    - select instance
    - browse mods
    - sync/apply changes
11. Key bindings:
    - list the important keys only
12. Common workflows:
    - install mod
    - uninstall mod
    - detect deps
    - refresh workshop data
    - handle “sync needed”

## 4) Backend contract (only what matters)
13. Document how Bash calls Python:
    - command entrypoints
    - expected JSON output
    - `schema_version`
14. Document caching + invalidation:
    - TTL or manual refresh
    - where cache is stored
    - how to force refresh

## 5) Troubleshooting (short and real)
15. Add “Most common issues” with fix steps:
    - “0 dependencies”
    - layout overflow / terminal width
    - unicode rendering
    - stale cache / not updating
    - permission/path issues inside container
16. Add debug instructions:
    - `DEBUG=1`
    - where logs are
    - how to run backend command manually

## 6) Keep it honest
17. Remove anything that is no longer true.
18. If a feature is flaky, say so and give the workaround.

## Done definition
19. README matches current behavior and someone new can:
    - run it
    - understand the UI
    - debug the most common failures