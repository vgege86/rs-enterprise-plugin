---
description: "Genera documentación técnica de la solución: estructura, tablas, flujo y config."
argument-hint: "<Solution>.sln"
---

Invoke the `rs-enterprise-agent` skill in documentation mode.

Usage: /rs-doc <Solution>.sln
Example: /rs-doc RSProcIN.sln

Dispatch to the `rs-documentar` subagent (runs on Sonnet — technical prose generation, GenerarDoc mode) via the Agent tool. Pass in the prompt: `sln_path` and `workspace` (resolved per SKILL.md rules). Relay the subagent's output verbatim — do not reformat or summarize it.

Note: this is GenerarDoc (full doc) mode. The pipeline's UpdateDocs mode (step 8c) dispatches this same `rs-documentar` subagent with `FILES_CHANGED`/plan context instead of a bare `sln_path`.
