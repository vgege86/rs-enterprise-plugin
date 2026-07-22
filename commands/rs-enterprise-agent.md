---
description: "Pipeline completo de desarrollo automatizado para una solución RS: planificación, análisis, validación, testing y build."
argument-hint: "<Solución>.sln - <cambio a realizar>"
---

Invoke the `rs-enterprise-agent` skill — full pipeline mode (planning → analysis → validation → testing → build).

Trigger: message matches `<Solution>.sln - <change description>` (e.g. "AgendaWeb.sln - FrmBusqueda.aspx - cambia X").
Not for the direct modes (audit/diff/ERD/idiomas/commit/etc.) — those have their own `/rs-*` command and dispatch to a single subagent instead of running this pipeline.

The main thread is the **orchestrator**: resolve solution + scope once, then run each stage below as an isolated Task-tool subagent, forwarding only the `FILES_CHANGED`/`SUMMARY`/`STATUS` contract block between stages — never full code or diffs.

0. Resolve solution: build path (`Batch\Soluciones\<Solution>.sln` for RSProc*, `OnLine\Soluciones\<Solution>.sln` for Web/UI) using `workspace` = cwd of this session (see SKILL.md "Workspace y Rutas"). ServiceManager family lives outside `Soluciones\`: host `OnLine\AISServiceManager\AISServiceManager\AIS.ServicesManager.sln`, framework `OnLine\AISServiceManager\ArqNet\`, modules `OnLine\AISServiceManager\Modulos\<Modulo>\*.sln` (⚠️ `.sln` name may differ from project). If missing, Glob for `*.sln` and disambiguate with the user.
1. Validate solution (orchestrator, direct) → `mcp__plugin_rs-enterprise-agent_rs-workspace__validate_solution(sln_path)`.
1b. **Scope** (orchestrator, direct, once) → `mcp__plugin_rs-enterprise-agent_rs-workspace__get_scope(sln_path)` → `scope_dirs`, `tipo`, `workspace`. Forward these three in the header of every following stage (Planner included).
    - All Glob/Grep/Read in any stage stays inside `scope_dirs`.
2. **Planner** (the brain) → Task `rs-editor-planner` (+ `cambio` = user's request text, + `sln_path`/`scope_dirs`/`tipo`/`workspace` already resolved in 1/1b). It analyzes with real access to the BD model and code, classifies the task against the technical master index (task→docs table), and returns a readable `PLAN` block + `STAGES` + `READ_DOCS` (technical docs Core must read + CHECKLIST) + `CONTEXT` + `STATUS`. The pipeline never reaches Core without a `PLAN`.
   - `STATUS: NEEDS_INPUT` → stop, resolve with the user before continuing.
2b. **Plan approval** → **Gate A** (`references/gates.md`). ⛔ MANDATORY STOP — present the `PLAN`, end the turn, do NOT invoke Core in this turn until the user approves explicitly. Applies with the harness Plan Mode ON or OFF.
3. **Run `STAGES` in order.** The orchestrator iterates the Planner's list and runs each token — it does NOT re-decide which stages run. Common header per stage + forward only the `FILES_CHANGED`/`SUMMARY`/`STATUS` contract.
   - `core` → `rs-editor-core` (+ `plan`, `cambio`, `READ_DOCS`; reads exactly those technical docs by section + applies the CHECKLIST before emitting). Returns `FILES_CHANGED`, `TABLES_TOUCHED`, `IDIOMAS_HINT`, `NEW_PATTERN`, `STATUS`. `STATUS=FAIL` → stop, escalate, go to Log `status="partial"`.
   - `validator` → `rs-editor-validator` (+ `FILES_CHANGED`; includes static analysis, absorbs the old analyzer). `STATUS: OK|FAIL` + `ERRORS`. FAIL → **Fixer** (+ `ERRORS`, `FILES_CHANGED`) → new `FILES_CHANGED` → back to validator. Max **2 cycles total** (shared with tester). Exhausted / `NO SAFE FIX` → stop, escalate, Log `partial`.
   - `tester` → `rs-editor-tester` (+ `FILES_CHANGED`, Validator PASS, `IDIOMAS_HINT`). Handles the idiomas-scripts gate internally (Online). `NEEDS_TESTS` → Task `rs-crear-tests` → re-run tester (anti-loop mark); advisory (don't abort if tests won't compile — Log `partial`). `FAIL` → Fixer → validator → tester (same 2-cycle limit).
   - `build` → `rs-editor-build` (+ `tipo`, `workspace`). Only if validator PASS + tester OK (or tester not in `STAGES`) + no open doubts.
   - `db-modeler` → `rs-editor-db-modeler` (+ `TABLES_TOUCHED`, `FILES_CHANGED`), incremental mode. **Safety net:** if Core returns non-empty `TABLES_TOUCHED` and `db-modeler` was NOT in `STAGES` → run it anyway and note it (the only empirical override of `STAGES`).
   - `documentar` → `rs-documentar`, UpdateDocs mode (+ `CONTEXT`, `FILES_CHANGED`, `SUMMARY`, `NEW_PATTERN`). Updates functional doc + per-solution summary (auto). If `NEW_PATTERN` is non-empty it returns `TECNICA_PROPUESTA` (a proposed edit to the shared conventions manual) — the orchestrator surfaces it as a pending action; ⛔ never written to `tecnica/` without explicit user confirmation.
   - **Docs safety net:** if `core` returned `NEW_PATTERN` and `documentar` was not in `STAGES` → run it anyway to produce the proposal.
4. **Final checklist** → **Gate B** (`references/gates.md`). ⛔ Verify real evidence before reporting success.
5. **Log** → **always** (`references/gates.md`), `agents=<STAGES stages actually run>`.

Global rules (see SKILL.md for full detail): security > speed | robustness > simplicity | minimal changes > rewrites. Don't assume behavior — ask. Don't continue with open doubts. Don't leave scope. Don't build without prior validation.
