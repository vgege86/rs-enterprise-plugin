---
description: "Muestra el esquema real de una o varias tablas de BD (columnas, tipos, longitudes, nullabilidad, índices)."
argument-hint: "<tabla|keyword>"
---

⛔ Self-contained — do NOT invoke the `rs-enterprise-agent` skill. Everything this mode needs is
below; loading the skill costs ~7k tokens and adds nothing to a read-only dispatch. This mode
queries the DB model/schema directly — it never resolves a `.sln`.

Usage: /rs-schema <tabla|keyword>
Example: /rs-schema RCLIENTES

Dispatch to the `rs-esquema` subagent (runs on Haiku — read-only schema lookup, mechanical) via the Agent tool. Pass in the prompt: `workspace` (cwd of this session, the "Primary working directory"), `plugin_root` (normalize the path you were given for this command — if it ends in `\skills\<x>`, go up two levels — and verify with Glob that it contains `hooks\` and `runner\`; ⛔ never `${CLAUDE_PLUGIN_ROOT}`, it is not expanded in markdown), and the table name(s) or keyword the user gave. Relay the subagent's output verbatim — do not reformat or summarize it.
