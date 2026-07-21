---
description: Muestra el esquema real de una o varias tablas de BD (columnas, tipos, longitudes, nullabilidad, índices). Uso: /rs-schema <tabla|keyword>
---

Invoke the `rs-enterprise-agent` skill in schema-query mode.

Usage: /rs-schema <tabla|keyword>
Example: /rs-schema RCLIENTES

Dispatch to the `rs-esquema` subagent (runs on Haiku — read-only schema lookup, mechanical) via the Agent tool. Pass in the prompt: `workspace` (cwd of this session, see SKILL.md "Workspace y Rutas"), `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), and the table name(s) or keyword the user gave. Relay the subagent's output verbatim — do not reformat or summarize it.
