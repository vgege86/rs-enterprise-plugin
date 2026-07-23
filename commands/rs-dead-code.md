---
description: "Detecta código no referenciado (clases/métodos/DALCs sin usos). Uso: /rs-dead-code <Solution>.sln"
argument-hint: "<Solution>.sln"
---

Invoke the `rs-enterprise-agent` skill in dead-code mode.

Usage: /rs-dead-code <Solution>.sln
Example: /rs-dead-code RSProcIN.sln

Dispatch to the `rs-dead-code` subagent (runs on Sonnet — the inverse of impact analysis: finds public/internal symbols with zero references in scope; advisory, never deletes; flags entry points and .aspx handlers as inconclusive) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md "Resolución de solución") and `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\). Relay the subagent's output verbatim — do not reformat or summarize it.
