---
description: "Redacta el runbook operativo de un proceso: procedimiento, precondiciones, reglas críticas, verificación y errores conocidos."
argument-hint: "<Solution>.sln <proceso>"
---

Invoke the `rs-enterprise-agent` skill in runbook mode.

Usage: /rs-runbook <Solution>.sln <proceso>
Example: /rs-runbook RSProcIN.sln carga inicial de históricos

Dispatch to the `rs-runbook` subagent (runs on Sonnet — operational prose, persists to `docs/agentic_manual/funcional/OPERACION/`, doesn't touch production code) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md "Resolución de solución"), `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), `workspace`, and `proceso` (the process to document, taken from the user's arguments). Relay the subagent's output verbatim — do not reformat or summarize it.

The subagent **interviews the user**: it extracts what is verifiable from code and asks for what isn't (operational rules, errors encountered). Surface its questions to the user verbatim and feed the answers back — do not answer on the user's behalf. If it returns a non-empty `TECNICA_PROPUESTA`, present it as a pending action requiring explicit confirmation before anything is written to `docs/agentic_manual/tecnica/`.
