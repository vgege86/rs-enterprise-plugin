---
description: "Genera un actualizador incremental de cliente para un entorno (DESA/TEST/PROD) en C:\\AIS\\<Proyecto>\\Actualizador\\<ENTORNO>_<AAAAMMDD> — delta de commits desde la última entrega registrada en RVERSIONES, con scripts SQL, instalador PS y readme."
argument-hint: "<DESA|TEST|PROD> [<Solucion1> <Solucion2>...] [--hasta AAAA-MM-DD]"
---

Invoke the `rs-enterprise-agent` skill in updater mode.

Usage: /rs-actualizador <DESA|TEST|PROD> [<Solucion1> <Solucion2>...] [--hasta AAAA-MM-DD]
Example: /rs-actualizador TEST RSProcIN AgendaWeb
Example: /rs-actualizador PROD RSProcIN --hasta 2026-07-15

Dispatch to the `rs-actualizador` subagent (runs on Opus — decides what reaches a client
environment, orchestrates build + delivery packaging and writes SQL, high blast radius) via the
Agent tool. Pass in the prompt: `workspace` = the resolved trunk path of the project (session cwd if
it is a valid trunk, otherwise resolve from the argument), `entorno`, the requested solutions, the
optional `--hasta` cut-off date, and `plugin_root` (resolved per SKILL.md "Raíz del plugin":
normalize the received path, verify it contains hooks\ and runner\). Relay the subagent's output
verbatim — do not reformat or summarize it.
