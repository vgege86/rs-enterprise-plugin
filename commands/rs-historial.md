---
description: Muestra ejecuciones recientes del pipeline desde history.json. Uso: /rs-historial [Solution.sln] [N]
---

Invoke the `rs-enterprise-agent` skill in history mode.

Usage: /rs-historial [Solution.sln] [N]
Example: /rs-historial RSProcIN.sln 5

Dispatch to the `rs-historial` subagent (runs on Haiku — read-only, mechanical, no need for the chat's model) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (see SKILL.md "Workspace y Rutas"), plus any solution/project filter and N the user specified. Relay the subagent's output verbatim — do not reformat or summarize it.
