---
description: "Valida entorno de desarrollo: .rs-databases.json, AIS, dotnet, SVN, modelo BD y docs agentic."
---

⛔ Self-contained — do NOT invoke the `rs-enterprise-agent` skill. Everything this mode needs is
below; loading the skill costs ~7k tokens and adds nothing to a read-only dispatch.

Usage: /rs-env [workspace]
Example: /rs-env

Dispatch to the `rs-validar-entorno` subagent (runs on Haiku — read-only, mechanical, no need for the chat's model) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (the "Primary working directory"), or the one the user specified. Relay the subagent's output verbatim — do not reformat or summarize it.
