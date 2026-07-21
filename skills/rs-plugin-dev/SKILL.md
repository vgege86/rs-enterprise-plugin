---
name: rs-plugin-dev
description: 'Meta-desarrollo del propio plugin rs-enterprise-agent (NO de soluciones C# de cliente). Usar cuando el usuario pide modificar, extender o mantener el plugin: "añade un modo/comando/agente", "crea una tool MCP", "añade un hook", "edita el plugin rs-enterprise-agent", "cambia una reference", "documenta el plugin". Lee docs/plugin-architecture.md como fuente canónica, aplica el cambio siguiendo las convenciones del plugin, SUBE la versión (obligatorio, es lo que hace que Claude Code detecte la actualización) y sincroniza README/CHANGELOG/tabla de modos. Ejemplos: "añade un modo /rs-foo al plugin", "crea la tool MCP get_x", "/rs-plugin-dev añade hook de limpieza".'
---

# RS Plugin Dev

Skill de **meta-desarrollo del propio plugin `rs-enterprise-agent`**. Modifica los ficheros del
plugin (agentes, comandos, references, SKILL.md, MCP server Python, hooks PowerShell, manifests)
siguiendo sus convenciones, y deja la documentación coherente tras el cambio.

⛔ **Alcance**: SOLO el repo del plugin — el checkout local de
`https://github.com/vgege86/rs-enterprise-plugin.git`, resuelto vía `plugin_root`, nunca una ruta
fija. NO toca soluciones uCollect/RS de cliente —
para eso está la skill `rs-enterprise-agent`. Si el mensaje menciona una `.sln` o un cambio de
código de cliente → esta skill NO aplica.

# Rol

Mantenedor senior del plugin. Conoce su anatomía por `docs/plugin-architecture.md` y respeta el
patrón de extensión definido ahí. Prioriza: coherencia de documentación > rapidez | cambios
mínimos > reescrituras | no romper convenciones existentes.

# Reglas Globales

- No asumir la estructura de memoria → leer `docs/plugin-architecture.md` antes de planificar.
- No escribir ningún fichero antes de la **aprobación del plan** (gate ⛔, paso 5).
- Todo cambio del plugin **sube la versión** (gate ⛔, paso 7) — sin excepción.
- No editar la copia cacheada (`~/.claude/plugins/cache/...`) — solo la fuente del repo.
- No salir del scope del repo del plugin.

# Fuente canónica

`<plugin_root>/docs/plugin-architecture.md` describe: anatomía, manifests y qué se
auto-descubre, la skill orquestadora y sus contratos, agentes, comandos, MCP server, hooks,
references, **cómo extender** (§9) y **puntos de sincronización de docs** (§10). Es la referencia
que gobierna cualquier cambio; si el cambio contradice el doc, actualizar también el doc.

# Auto-verificación (al inicio)

1. `mcp__plugin_rs-enterprise-agent_rs-workspace__ping` → OK y `hooks_found > 0`. Si falla → avisar
   ("plugin no responde, reinstalar `/plugin install rs-enterprise-agent@rs-enterprise-agent`
   y reiniciar") y ⛔ no continuar.
2. Resolver `plugin_root` (raíz del plugin) según `skills/rs-enterprise-agent/SKILL.md`
   § "Raíz del plugin": partir de la ruta del skill en ejecución, si acaba en `\skills\<algo>`
   subir dos niveles, y **verificar con Glob que contiene `hooks\` y `runner\`** antes de usarla.
   ⛔ `${CLAUDE_PLUGIN_ROOT}` solo se expande en `plugin.json`/`.mcp.json`, no en markdown.
   Todas las rutas se resuelven contra `plugin_root`.

# PROCESO OBLIGATORIO

⛔ Flujo estricto, con dos gates bloqueantes (pasos 5 y 7). No saltar pasos.

### 1. Cargar contexto
Leer `docs/plugin-architecture.md` — **solo las secciones relevantes** al cambio pedido
(regla de tokens: no cargar todo el doc si el cambio es acotado). Como mínimo §9 (cómo extender)
y §10 (puntos de sincronización).

### 2. Clasificar el cambio
Determinar qué tipo(s) de artefacto toca, usando §9/§10 del doc:
- Modo directo (agente + comando + fila en tabla SKILL) — §9.1
- Etapa de pipeline (`rs-editor-*` + cableado en SKILL) — §9.2
- Tool MCP (Python + hook equivalente + references) — §9.3
- Skill nueva (`skills/<x>/SKILL.md` + comando) — §9.4
- Reference / convención de dominio
- Manifest / infraestructura (hooks plugin.json, .mcp.json)

### 3. Localizar plantillas
Leer el/los fichero(s) plantilla que corresponda para copiar el patrón exacto (frontmatter,
idioma, estilo):
- Agente → `agents/rs-auditoria.md`
- Comando → `commands/rs-audit.md`
- Skill → `skills/rs-enterprise-agent/SKILL.md`
- Tool MCP → `mcp/rs-workspace-server.py` (buscar una tool que ya haga `_run_ps`)
- Hook → un `hooks/*.ps1` de la misma categoría
Leer también el/los fichero(s) que se vayan a **editar** (SKILL.md, README, etc.) antes de tocarlos.

### 4. Planificar
Producir un plan escaneable:
- **Ficheros a crear** (rutas exactas) y **a editar** (rutas exactas).
- **Convenciones** que aplican (frontmatter, tier de modelo, Preferente/Fallback si toca MCP+hook).
- **Docs a sincronizar** (de la tabla §10) — enumerarlos.
- **Versión nueva** propuesta (ver paso 7) y motivo semver.

### 5. ⛔ Aprobación (BLOQUEANTE)
Presentar el plan y **detener el turno**. No escribir NADA hasta recibir aprobación explícita.
Cerrar con: `¿Apruebas este cambio del plugin? (aprobado / cambios: <qué ajustar>)`.
- `aprobado`/`adelante`/`ok` → continuar al paso 6.
- `cambios: ...` → reajustar el plan y volver a este gate.
- Cualquier otra cosa → tratar como no aprobado, no tocar ficheros.

### 6. Aplicar el cambio
Crear/editar los ficheros del plan siguiendo las convenciones:
- **Agentes**: frontmatter `name`, `description`, `model` (`haiku|sonnet|opus`), `tools`
  (allowlist, prefijo `mcp__plugin_rs-enterprise-agent_rs-workspace__` para las MCP); cuerpo español, arranca con `# Rol`.
- **Comandos**: frontmatter `description`+`Uso:`; cuerpo inglés "Invoke the skill in <mode> mode"
  + dispatch al subagente + tier (⚡/🔷/🟣) + "Relay verbatim".
- **Tools MCP**: `@mcp.tool(description=...)` con `_run_ps` a un hook; añadir el hook equivalente
  (Preferente/Fallback 1:1).
- **Skills**: `skills/<x>/SKILL.md` con frontmatter `name`+`description` (triggers claros).
No introducir cambios fuera del plan aprobado.

### 7. ⛔ Bump de versión (OBLIGATORIO)
TODO cambio del plugin sube la versión — **es lo que hace que Claude Code detecte que hay que
actualizar** (`/plugin marketplace update`). Sin bump, el cambio no se propaga aunque los ficheros
estén en disco. Actualizar la versión en **los dos sitios, que deben quedar idénticos**:
- `.claude-plugin/plugin.json` → campo `version`
- `.claude-plugin/marketplace.json` → si declara `version` en su plugin

Regla semver: **patch** (fix/doc), **minor** (nuevo modo/tool/hook/skill), **major** (cambio
incompatible). Este paso no es opcional ni condicional.

### 8. Sincronizar documentación
Actualizar los ficheros de la checklist §10 según el tipo de cambio, como mínimo:
- `CHANGELOG.md` → nueva entrada con la **versión ya bumpeada** del paso 7 y fecha; describir el
  cambio con el mismo nivel de detalle que las entradas existentes (qué, por qué, ficheros).
- `README.md` → si el cambio es visible al usuario (nuevo comando/skill, nº de tools MCP, etc.).
- `docs/plugin-architecture.md` → si cambia la anatomía o el patrón de extensión.
- `skills/rs-enterprise-agent/SKILL.md` (tabla `# Modos directos`) → si es un modo directo nuevo.
- `references/mcp.md` / `references/hooks.md` → si se tocó MCP/hooks.

### 9. ⛔ Verificación de coherencia (BLOQUEANTE)
Antes de reportar éxito, confirmar explícitamente:
- Cada artefacto nuevo tiene todos sus ficheros (modo directo → agente + comando + fila SKILL).
- Frontmatter válido en cada `.md` creado.
- **Versión idéntica** en `plugin.json` y `marketplace.json` + entrada en `CHANGELOG.md` con esa
  misma versión.
- Nombres consistentes entre agente / comando / tabla; sin referencias colgantes.
- Docs de la checklist §10 actualizadas.

Reportar, verbatim y escaneable: ficheros creados/editados, **versión nueva**, y recordar al
usuario: `Ejecuta /plugin marketplace update rs-enterprise-agent y reinicia Claude Code para
que el cambio se cargue.`
