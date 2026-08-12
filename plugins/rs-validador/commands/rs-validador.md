---
description: "Desarrolla, corrige o amplía RSValidador (el validador de ficheros) con gate de PLAN humano. Uso: /rs-validador <cambio a realizar>"
argument-hint: "<cambio a realizar>"
---

Invoke the `rs-validador` skill — main mode (full `PROCESO OBLIGATORIO`, steps 1 to 9).

Usage: /rs-validador <cambio a realizar>
Example: /rs-validador añade el campo `separador_decimal` al schema de estructura
Example: /rs-validador el generador de RARCHIVOS ordena mal los atributos

This runs in the **main thread** — do not dispatch to a subagent. Follow SKILL.md end to end:

1. Resolve `validador_root` (per SKILL.md "Resolución del workspace de RSValidador": the folder
   containing `estructura.py`, `validator_service.py` and `docs\` — never hardcode a path; ask if
   ambiguous) and `plugin_root` (per SKILL.md "Raíz del plugin": normalize the received path, verify
   it contains `references\` and `.claude-plugin\`).
2. Read only the relevant section of `docs/documentacion-tecnica.md` (plus the functional doc if the
   change is user-visible) and load the references that apply per the SKILL.md references table.
3. Analyse: locate the affected code, state the blast radius (Pydantic `Schema`, SQL generator,
   ORM/DDL, HTML screen), and if it is a bug, reproduce it first.
4. ⛔ **Stop at the PLAN gate (step 3 of SKILL.md).** Present the `## PLAN` block and end the turn.
   Write nothing — not code, not docs — until the user approves explicitly.

After approval, continue with steps 4 to 9: implement, plan-check, static verification
(`py_compile` + the manual checklist), functional verification with the app running, mandatory
documentation update, and the closing report.

⛔ Not for C#/`.sln` uCollect/RS solutions — that is the `rs-enterprise-agent` plugin.
