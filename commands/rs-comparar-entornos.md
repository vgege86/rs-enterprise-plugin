---
description: "Compara el esquema de BD entre dos conexiones (entornos). Uso: /rs-comparar-entornos [id1] [id2] [tablas]"
argument-hint: "[id1] [id2] [tablas]"
---

⛔ Self-contained — do NOT invoke the `rs-enterprise-agent` skill. Everything this mode needs is
below; loading the skill costs ~7k tokens and adds nothing to a read-only dispatch. This mode
works off `.rs-databases.json` connections — it never resolves a `.sln`.

Usage: /rs-comparar-entornos [id1] [id2] [tablas]
Example: /rs-comparar-entornos dev pro
Example: /rs-comparar-entornos dev pro RCLIENTES,RPEDIDOS

Dispatch to the `rs-comparar-entornos` subagent (runs on Sonnet — queries each connection's real schema via db_query with the `conexion` parameter and diffs tables/columns/types/lengths/indexes; read-only, SELECT only) via the Agent tool. Pass in the prompt: `workspace` (cwd of this session, the "Primary working directory"), `plugin_root` (normalize the path you were given for this command — if it ends in `\skills\<x>`, go up two levels — and verify with Glob that it contains `hooks\` and `runner\`; ⛔ never `${CLAUDE_PLUGIN_ROOT}`, it is not expanded in markdown), plus the two connection ids and optional table list. Relay the subagent's output verbatim — do not reformat or summarize it.
