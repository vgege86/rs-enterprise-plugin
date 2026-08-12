---
description: "Orquesta una tarea del gestor de tickets del proyecto (Jira o Mantis, autodetectado por el config del workspace): selección → formateo → En Proceso → pipeline → commit → adjuntar SQL → En Validación."
argument-hint: "[PROJ-123 | 1234 | init]"
---

Router command. It does NOT run the lifecycle itself — it decides **which ticket system this
workspace uses** and then invokes the matching skill (`rs-jira` or `rs-mantis`), forwarding the
arguments verbatim.

Usage: /rs-tarea [PROJ-123 | URL de Jira | 1234 | init]
Examples:
- /rs-tarea                → autodetecta el gestor y lista tus tareas abiertas
- /rs-tarea PROJ-123       → arranca con esa issue de Jira
- /rs-tarea 1234           → arranca con esa issue de Mantis (id global)
- /rs-tarea init           → crea el config del gestor que use el proyecto

## Routing rule (⛔ do this BEFORE anything else)

`workspace` = the session's cwd ("Primary working directory"). Check with Glob which config files
exist under `docs\` of that workspace:

- `docs/.jira-dev-config.json` → the project is managed in **Jira**.
- `docs/.mantis-dev-config.json` → the project is managed in **MantisBT**.

Then:

1. **Only one exists** → invoke that system's skill, passing `$ARGUMENTS` unchanged.
   - Jira → read `<plugin_root>/skills/rs-jira/SKILL.md` and run its phases.
   - Mantis → read `<plugin_root>/skills/rs-mantis/SKILL.md` and run its phases.
2. **Both exist** → ⛔ never guess. Disambiguate by argument shape:
   - `ABC-123` (letters + dash + number) or a Jira URL → `rs-jira`.
   - a bare integer (`1234`) → `rs-mantis`.
   - no argument, `init`, or any other shape → **ask the user** which system to use for this task,
     and stop until they answer.
3. **Neither exists** → ask which ticket system manages this project (Jira / Mantis), then offer to
   run that skill's `init` subroutine (`/rs-tarea init` → `.jira-dev-config.json` or
   `.mantis-dev-config.json`). ⛔ Do not write the config without explicit approval.
4. `/rs-tarea init` when **both** configs already exist → ask which one to re-create; do not
   overwrite either without confirmation.

Report the detected system in one line before starting (`Gestor detectado: Jira (docs\.jira-dev-config.json)`)
so the user can correct the routing before any ticket write happens.

`plugin_root` = root of this plugin: normalize the path Claude Code injects — if it ends in
`\skills\<x>` go up two levels — and verify with Glob that it contains `hooks\` and `runner\`
before using it. ⛔ `${CLAUDE_PLUGIN_ROOT}` does not expand in markdown.

## What the target skill does

Both skills orchestrate the issue through its full dev lifecycle **in the main thread**, and neither
modifies the `rs-enterprise-agent` pipeline — their Fase 3 launches that pipeline with the formatted
prompt, respecting every ⛔ gate. Jira operations use the connected **Atlassian Rovo** MCP (SQL
attachments via `mcp__plugin_rs-enterprise-agent_rs-workspace__jira_attach`); Mantis operations use
the autonomous REST client `hooks/mantis-cli.ps1` (token auth, no MCP).

`/rs-jira`'s door is this command; `/rs-mantis` remains the explicit door for Mantis when the user
wants to bypass detection. Relay ticket results and the pipeline output verbatim.
