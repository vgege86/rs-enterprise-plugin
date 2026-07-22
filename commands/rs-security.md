---
description: "Escanea SQL injection, credenciales hardcoded, XSS e inputs sin validar."
argument-hint: "<Solution>.sln"
---

Invoke the `rs-enterprise-agent` skill in security-scan mode.

Usage: /rs-security <Solution>.sln
Example: /rs-security AgendaWeb.sln

Dispatch to the `rs-seguridad` subagent (runs on Opus — triaging false positive/negative on a vulnerability is the costliest judgment call in this skill) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md rules). Relay the subagent's output verbatim — do not reformat or summarize it.
