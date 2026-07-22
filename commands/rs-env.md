---
description: "Valida entorno de desarrollo: .rs-databases.json, AIS, dotnet, SVN, modelo BD y docs agentic."
---

Invoke the `rs-enterprise-agent` skill in environment-validation mode.

Usage: /rs-env [workspace]
Example: /rs-env

Dispatch to the `rs-validar-entorno` subagent (runs on Haiku — read-only, mechanical, no need for the chat's model) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (see SKILL.md "Workspace y Rutas"), or the one the user specified. Relay the subagent's output verbatim — do not reformat or summarize it.
