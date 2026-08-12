---
description: "Orquesta una tarea de Mantis sobre una solución RS (selección/creación → formateo → En Proceso → pipeline → commit → adjuntar SQL → En Validación)."
argument-hint: "[1234 | crear | proyectos | init]"
---

Invoke the `rs-mantis` skill.

This is the **explicit** Mantis door — it skips detection. `/rs-tarea` reaches the same skill by
autodetecting the workspace's ticket system (`docs\.mantis-dev-config.json` → Mantis).

Usage: /rs-mantis [1234 | crear | proyectos | init]
Examples:
- /rs-mantis              → elige proyecto de la lista curada y lista sus issues abiertas
- /rs-mantis 1234         → arranca directamente con esa issue (id global Mantis)
- /rs-mantis crear        → crea una issue nueva (crear-y-trabajar / crear-suelto)
- /rs-mantis proyectos    → gestiona la lista curada de proyectos en docs\.mantis-dev-config.json
- /rs-mantis init         → crea docs\.mantis-dev-config.json del workspace

This orchestrates a Mantis issue through its full dev lifecycle by **following
`skills/rs-mantis/SKILL.md` in the main thread**. It does NOT modify the `rs-enterprise-agent`
pipeline — Fase 3 launches that pipeline with the formatted prompt. Mantis operations use the
autonomous REST client `hooks/mantis-cli.ps1` (no MCP; token auth) instead of an MCP integration.

Read `<plugin_root>/skills/rs-mantis/SKILL.md` — `plugin_root` resolved per SKILL.md "Raíz del
plugin" (normalize the received path, verify it contains `hooks\`) — and run its
phases (F0 proyecto · F1 selección/creación · F2 formateo · F3 transición+lanzamiento · F4
commit+cierre), respecting every ⛔ gate. Relay Mantis results and the pipeline output verbatim.
