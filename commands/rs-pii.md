---
description: "Gestiona la protección de datos personales en las consultas a BD: estado, inventario y cambio de modo (off/audit/enforce). Uso: /rs-pii [status|bootstrap|audit|enforce|off]"
argument-hint: "[status|bootstrap|audit|enforce|off]"
---

Invoke the `rs-enterprise-agent` skill in PII-protection mode.

Usage: /rs-pii [status|bootstrap|audit|enforce|off]
Example: /rs-pii status
Example: /rs-pii bootstrap
Example: /rs-pii enforce

Dispatch to the `rs-pii` subagent (runs on Sonnet — reads the `pii` block from `check_env`, classifies
model columns and samples data to build the inventory, and writes `pii_policy.mode` in the BD model
plus the `PreToolUse` guards in the user's personal Claude Code settings, both only after explicit
confirmation) via the Agent tool. Pass in the prompt: `workspace`, `plugin_root` (resolved per
SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), and
the subcommand requested (`status` if none given). Relay the subagent's output verbatim — do not
reformat or summarize it.
