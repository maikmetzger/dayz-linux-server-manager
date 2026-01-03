---
description: Document learnings after implementing/fixing something. Capture what happened, why it happened, how it was fixed, and how to prevent repeats (Bash TUI + Python backend in Docker).
---

## Inputs (required)
1. What was the goal?
2. What broke / what was added?
3. Which files were touched?

## 1) What happened (facts only)
4. Describe the symptom:
   - user-visible behavior
   - error messages/logs
   - environment (SSH/Docker terminal, min width, etc.)
5. Describe the root cause:
   - exact assumption that failed
   - exact code/path that caused it

## 2) Fix summary (what changed)
6. List the fix as bullets:
   - what code changed
   - what behavior changed
   - what fallback/guard was added
7. Note any side effects:
   - perf impact
   - UX impact
   - new state files / cache changes

## 3) Why it happened (pattern)
8. Tag the failure type:
   - off-by-one / layout math
   - brittle scraping
   - dual-state (memory + file)
   - cache invalidation
   - bash `set -e` trap
   - terminal capability mismatch (unicode/OSC-8)
   - copy-paste duplication

## 4) How to avoid it next time (rules)
9. Add 3–7 concrete “next time” bullets:
   - what to verify first
   - what guard to add
   - what test/fixture to create

## 5) Regression protection
10. Confirm at least one is added:
    - fixture for parser
    - smoke test
    - unit test
    - runtime guard + log
11. If none added, state why and create a follow-up task.

## 6) Senior-dev check (short)
12. Did the fix reduce coupling or increase it?
13. Did it move logic to the right layer (Bash vs Python)?
14. Did it make the next change easier?
15. What has the user instructed me to do, which I did not initially do and should do next time?

## Done definition
16. Learnings are written where they belong:
    - `learnings.md` or session notes
    - includes root cause + prevention
    - includes regression protection