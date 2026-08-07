---
description: "Muestra ejecuciones recientes del pipeline desde history.json."
argument-hint: "[Solution.sln] [N]"
---

⛔ Self-contained — do NOT invoke the `rs-enterprise-agent` skill. Everything this mode needs is
below; loading the skill costs ~7k tokens and adds nothing to a read-only dispatch. The solution
is only a text filter over `history.json` here — it is not resolved to a path.

Usage: /rs-historial [Solution.sln] [N]
Example: /rs-historial RSProcIN.sln 5

Dispatch to the `rs-historial` subagent (runs on Haiku — read-only, mechanical, no need for the chat's model) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (the "Primary working directory"), plus any solution/project filter and N the user specified. Relay the subagent's output verbatim — do not reformat or summarize it.
