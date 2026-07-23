---
description: "Ejecuta los tests de la solución y reporta el resultado (sin lanzar el pipeline). Uso: /rs-test <Solution>.sln"
argument-hint: "<Solution>.sln"
---

Invoke the `rs-enterprise-agent` skill in test mode.

Usage: /rs-test <Solution>.sln
Example: /rs-test RSProcIN.sln

Dispatch to the `rs-test` subagent (runs on Haiku — runs dotnet test on the solution and reports passed/failed/skipped; read-only, doesn't launch the pipeline) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md "Resolución de solución") and `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\). Relay the subagent's output verbatim — do not reformat or summarize it.
