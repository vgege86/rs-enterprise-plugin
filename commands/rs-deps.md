---
description: "Mapa de dependencias entre soluciones, proyectos compartidos y conflictos NuGet."
argument-hint: "[project_name]"
---

Invoke the `rs-enterprise-agent` skill in dependency-map mode.

Usage: /rs-deps [project_name]
Examples:
  /rs-deps
  /rs-deps RSDalc

Dispatch to the `rs-dependencias` subagent (runs on Haiku — read-only, mechanical, no need for the chat's model) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (see SKILL.md "Workspace y Rutas") and the project filter if the user gave one. Relay the subagent's output verbatim — do not reformat or summarize it.
