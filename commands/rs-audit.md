---
description: Revisión de calidad estática de una solución sin modificar código. Uso: /rs-audit <Solution>.sln
---

Invoke the `rs-enterprise-agent` skill in audit mode.

Usage: /rs-audit <Solution>.sln
Example: /rs-audit RSProcIN.sln

Dispatch to the `rs-auditoria` subagent (runs on Sonnet — static quality review, advisory only, doesn't write code) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md "Resolución de solución") and `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\). Relay the subagent's output verbatim — do not reformat or summarize it.
