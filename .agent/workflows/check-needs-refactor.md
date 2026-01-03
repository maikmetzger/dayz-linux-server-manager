---
description: Detect whether recent changes (Bash TUI frontend + Python backend in Docker) need refactoring, and produce a concrete refactor plan with minimal churn.
---

## Inputs (required)
1. Identify the target area:
   - Which file(s) and function(s) feel wrong?
   - Is it Bash UI, Python backend, or the Bash↔Python contract?

## 1) Quick smell scan (trigger conditions)
2. Mark **REFactor Needed** if any are true:
   - A function does 2+ jobs (UI + parsing, parsing + IO, IO + state + formatting)
   - Same logic exists in Bash and Python
   - 3+ blocks of near-duplicate code exist
   - Any “17 args” style plumbing is growing
   - UI layout relies on multiple magic numbers with no explanation
   - State is stored in 2 places (file + memory) without a single setter function
   - Fixes keep causing regressions (same class of bug repeats)
   - Backend output schema is inconsistent across commands
   - Error handling is “best effort” but not standardized (random fallbacks everywhere)

## 2) Layering check (frontend/backend boundary)
3. If Bash is parsing/transforming complex data → move to Python.
4. If Python is formatting UI output → move to Bash.
5. If the contract is unclear → define a stable JSON schema + `schema_version`.

## 3) Complexity check (keep it simple)
6. Bash:
   - Nesting deeper than 3 levels → refactor into helpers
   - Conditionals with mixed arithmetic + glob + array math → isolate into named predicates
   - Large functions (>60 lines) → split by responsibility
7. Python:
   - Functions >80 lines → split
   - Multiple try/except patches → centralize parsing + normalization
   - Repeated selectors/splits → extract into reusable helpers

## 4) Duplication check (fast wins)
8. Replace repeated UI patterns with helpers:
   - `ui_row(label, value)`
   - `ui_box(title, content_fn)`
   - `ui_prompt(...)`
9. Replace repeated state handling with a state manager:
   - `set_dirty(mid)`
   - `clear_dirty()`
   - `load_state() / save_state()`

## 5) Stability check (refactor priority)
10. Highest priority refactors are the ones that stop recurring bugs:
   - TUI layout math (off-by-one, overflow) → row builder / layout manager
   - Scraping brittleness → parser helpers + fixtures + “best effort” selectors
   - Dual-state (file + memory) → single source of truth or encapsulated setters
   - Menu matching by exact labels → wildcard / ID-based routing

## 6) Output: refactor plan (minimal churn)
11. Produce a plan with:
   - **Goal** (1 sentence)
   - **Scope** (files/functions)
   - **Steps** (small, reversible)
   - **Risk** (what could break)
   - **Proof** (how to verify)

## 7) Refactor guardrails (required)
12. Before refactoring:
   - Add at least one regression fixture/test for the current behavior
13. After refactoring:
   - Verify schema still matches
   - Run `bash -n` and `python3 -m py_compile`
   - Run TUI in target environment (SSH/Docker terminal)

## 8) Done definition
14. Refactor is complete when:
   - responsibilities are separated (UI vs logic vs state vs integration)
   - duplication reduced (helpers exist)
   - state updates are centralized
   - layout no longer depends on fragile magic numbers
   - at least one regression guard exists