---
description: "Modifica/extiende el propio plugin rs-enterprise-agent siguiendo su doc de arquitectura, con gate de aprobación, bump de versión obligatorio y sincronización de docs."
argument-hint: "<qué cambiar en el plugin>"
---

Invoke the `rs-plugin-dev` skill.

Usage: /rs-plugin-dev <qué cambiar en el plugin>
Examples:
- /rs-plugin-dev añade un modo directo /rs-foo que hace X
- /rs-plugin-dev crea la tool MCP get_x con su hook
- /rs-plugin-dev documenta la nueva convención Y

This is **meta-development of the plugin itself** — NOT a change to any uCollect/RS client
solution. Follow `skills/rs-plugin-dev/SKILL.md`: read `docs/plugin-architecture.md` as the
canonical source, classify the change, plan, **stop for explicit approval before writing**, apply
following the plugin conventions, **bump the version** in `.claude-plugin/plugin.json` and
`.claude-plugin/marketplace.json` (mandatory — this is what makes Claude Code detect the update),
then sync `CHANGELOG.md`/`README.md`/`SKILL.md`/references and verify coherence.

Do not dispatch to a `rs-editor-*` pipeline subagent — this is the plugin-maintenance skill, run
its process in the main thread.
