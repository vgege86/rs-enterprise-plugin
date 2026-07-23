---
description: "Análisis de rendimiento de acceso a BD: índices que faltan, full-scans, filtros no-sargables. Uso: /rs-perf <Solution>.sln [DALC|tabla]"
argument-hint: "<Solution>.sln [DALC|tabla]"
---

Invoke the `rs-enterprise-agent` skill in perf mode.

Usage: /rs-perf <Solution>.sln [DALC|tabla]
Example: /rs-perf RSProcIN.sln
Example: /rs-perf RSProcIN.sln CobrosDalc.cs

Dispatch to the `rs-perf` subagent (runs on Opus — cross-checks DALC SQL against the DB model's indexes to flag missing indexes, full-scans and non-sargable filters; advisory, doesn't modify code or DB) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md "Resolución de solución"), `workspace`, `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), plus the optional DALC/table argument. Relay the subagent's output verbatim — do not reformat or summarize it.
