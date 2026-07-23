---
description: "Prepara un workspace nuevo para el plugin: config BD, andamiaje de docs y primer modelo BD. Uso: /rs-init"
argument-hint: "[motor datasource usuario ...]"
---

Invoke the `rs-enterprise-agent` skill in init mode.

Usage: /rs-init
Example: /rs-init

Dispatch to the `rs-init` subagent (runs on Sonnet — bootstraps a new uCollect/RS workspace: creates docs/.rs-databases.json, scaffolds docs/agentic_manual, and builds the first DB model; never overwrites existing files) via the Agent tool. Pass in the prompt: `workspace` (the session cwd) and `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), plus any connection details the user provided. If the subagent returns `STATUS: NEEDS_INPUT`, ask the user for the missing connection details and re-dispatch. Relay the subagent's output verbatim — do not reformat or summarize it.
