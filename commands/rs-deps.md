---
description: "Mapa de dependencias entre soluciones, proyectos compartidos y conflictos NuGet."
argument-hint: "[project_name]"
---

⛔ Self-contained — do NOT invoke the `rs-enterprise-agent` skill. Everything this mode needs is
below; loading the skill costs ~7k tokens and adds nothing to a read-only dispatch.

Usage: /rs-deps [project_name]
Examples:
  /rs-deps
  /rs-deps RSDalc

Dispatch to the `rs-dependencias` subagent (runs on Haiku — read-only, mechanical, no need for the chat's model) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (the "Primary working directory") and the project filter if the user gave one. Relay the subagent's output verbatim — do not reformat or summarize it.
