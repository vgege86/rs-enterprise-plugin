---
description: "Análisis estático de calidad/riesgo de un diff o cambio concreto (no de toda la solución)."
argument-hint: "<Solution>.sln [revisión|ficheros]"
---

Invoke the `rs-enterprise-agent` skill in change-analysis mode.

Usage: /rs-analizar <Solution>.sln [revisión|ficheros]
Example: /rs-analizar RSProcIN.sln

1. Call `mcp__plugin_rs-enterprise-agent_rs-workspace__detect_vcs(workspace)` first (`workspace` = cwd of this session, see SKILL.md "Workspace y Rutas") so the subagent can reconstruct the delta.
2. Dispatch to the `rs-analisis` subagent (runs on Sonnet — static analysis of the change delta, advisory, doesn't write code) via the Agent tool. Pass in the prompt: `sln_path` and `workspace` (resolved per SKILL.md), `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), the detected `vcs`, and the optional revision/files the user gave (default: pending changes). Relay the subagent's output verbatim — do not reformat or summarize it.
