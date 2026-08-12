---
description: "Valida entorno de desarrollo: requisitos del MCP (Python + paquete mcp), .rs-databases.json, AIS, dotnet, SVN, modelo BD y docs agentic."
---

⛔ Self-contained — do NOT invoke the `rs-enterprise-agent` skill. Everything this mode needs is
below; loading the skill costs ~7k tokens and adds nothing to a read-only dispatch.

Usage: /rs-env [workspace]
Example: /rs-env

Dispatch to the `rs-validar-entorno` subagent (runs on Haiku — read-only, mechanical, no need for the chat's model) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (the "Primary working directory"), or the one the user specified, and `plugin_root` (normalize the path you were given for this command — if it ends in `\skills\<x>`, go up two levels — and verify with Glob that it contains `hooks\` and `runner\`; ⛔ never `${CLAUDE_PLUGIN_ROOT}`, it is not expanded in markdown). `plugin_root` is what lets the subagent run `scripts/check-requisitos.ps1` (Python + `mcp` package) without going through the MCP server — which is precisely what is dead when those are missing. Relay the subagent's output verbatim — do not reformat or summarize it.
