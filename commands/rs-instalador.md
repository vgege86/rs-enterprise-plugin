---
description: "Genera el instalador completo de cliente (instalación limpia) en C:\\AIS\\<Proyecto>\\Instalador — EXES batch, AgendaWeb, ServiceManager+Modulos y Scripts SQL."
argument-hint: "[<Proyecto>|<workspace>]"
---

Invoke the `rs-enterprise-agent` skill in installer mode.

Usage: /rs-instalador [<Proyecto>|<workspace>]
Example: /rs-instalador <Proyecto>

Dispatch to the `rs-instalador` subagent (runs on Opus — orchestrates mass build + deploy to the
Instalador folder, manages the per-client config JSON, high blast radius) via the Agent tool. Pass
in the prompt: `workspace` = the resolved trunk path of the project (session cwd if it is a valid
trunk, otherwise resolve from the argument) and `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\). Relay the
subagent's output verbatim — do not reformat or summarize it.
