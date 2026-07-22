---
description: "Estadísticas del pipeline: total ejecuciones, tasa éxito, agentes más usados, tendencia 7 días."
---

Invoke the `rs-enterprise-agent` skill in stats mode.

Usage: /rs-stats [solution]
Examples:
  /rs-stats
  /rs-stats RSProcIN

Dispatch to the `rs-stats` subagent (runs on Haiku — read-only, mechanical, no need for the chat's model) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (see SKILL.md "Workspace y Rutas") and the solution filter if the user gave one. Relay the subagent's output verbatim — do not reformat or summarize it.
