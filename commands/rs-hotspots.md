---
description: "Puntos calientes de riesgo: cruza frecuencia de cambios (churn) con complejidad. Uso: /rs-hotspots <Solution>.sln"
argument-hint: "<Solution>.sln"
---

Invoke the `rs-enterprise-agent` skill in hotspots mode.

Usage: /rs-hotspots <Solution>.sln
Example: /rs-hotspots RSProcIN.sln

First call `detect_vcs(workspace)` so the subagent branches correctly (SVN/Git). Then dispatch to the `rs-hotspots` subagent (runs on Sonnet — crosses VCS churn with code complexity/size to rank risk hotspots; advisory, doesn't modify code) via the Agent tool. Pass in the prompt: `sln_path`/`workspace` (resolved per SKILL.md "Resolución de solución") and `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\). Relay the subagent's output verbatim — do not reformat or summarize it.
