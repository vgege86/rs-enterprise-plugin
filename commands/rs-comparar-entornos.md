---
description: "Compara el esquema de BD entre dos conexiones (entornos). Uso: /rs-comparar-entornos [id1] [id2] [tablas]"
argument-hint: "[id1] [id2] [tablas]"
---

Invoke the `rs-enterprise-agent` skill in compare-environments mode.

Usage: /rs-comparar-entornos [id1] [id2] [tablas]
Example: /rs-comparar-entornos dev pro
Example: /rs-comparar-entornos dev pro RCLIENTES,RPEDIDOS

Dispatch to the `rs-comparar-entornos` subagent (runs on Sonnet — queries each connection's real schema via db_query with the `conexion` parameter and diffs tables/columns/types/lengths/indexes; read-only, SELECT only) via the Agent tool. Pass in the prompt: `workspace`, `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), plus the two connection ids and optional table list. Relay the subagent's output verbatim — do not reformat or summarize it.
