---
description: "Estadísticas del pipeline: total ejecuciones, tasa éxito, agentes más usados, tendencia 7 días."
---

⛔ Self-contained — do NOT invoke the `rs-enterprise-agent` skill. Everything this mode needs is
below; loading the skill costs ~7k tokens and adds nothing to a read-only dispatch.

Usage: /rs-stats [solution]
Examples:
  /rs-stats
  /rs-stats RSProcIN

Dispatch to the `rs-stats` subagent (runs on Haiku — read-only, mechanical, no need for the chat's model) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (the "Primary working directory") and the solution filter if the user gave one. Relay the subagent's output verbatim — do not reformat or summarize it.
