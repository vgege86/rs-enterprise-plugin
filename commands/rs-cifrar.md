---
description: "Cifra en reposo (DPAPI) los secretos en texto plano: password BD + tokens Jira/Mantis. Uso: /rs-cifrar"
argument-hint: "[workspace]"
---

Invoke the `rs-enterprise-agent` skill in encrypt-credentials mode.

Usage: /rs-cifrar
Example: /rs-cifrar

Dispatch to the `rs-cifrar` subagent (runs on Haiku — encrypts at rest, via DPAPI, the plaintext DB password in .rs-databases.json and the Jira/Mantis tokens in ~/.claude; idempotent, never prints secrets, backward-compatible) via the Agent tool. Pass in the prompt: `workspace` (the session cwd) and `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\). Relay the subagent's output verbatim — do not reformat or summarize it.
