# Integración MantisBT (skill `rs-mantis` / `/rs-mantis`)

La skill `rs-mantis` orquesta el ciclo de vida de una tarea de MantisBT sobre una solución
uCollect/RS, espejando `rs-jira`, y además permite **crear tareas nuevas**. A diferencia de Jira,
MantisBT **no tiene MCP** (no hay Atlassian Rovo equivalente): la skill llama a un **cliente REST
autónomo en PowerShell**, `hooks/mantis-cli.ps1`, invocado por Bash — nunca a tools del MCP
`rs-workspace`.

Motivo de esta arquitectura: si las operaciones Mantis fueran tools del MCP `rs-workspace`,
dependerían del proceso `python.exe` vivo desde la primera fase, exponiéndose al falso positivo de
CrowdStrike que cuelga el turno hasta 1800s (ver `docs/crowdstrike-fp-justification.md`). `rs-jira`
solo toca `rs-workspace` en su Fase 4 por la misma razón. Un hook autónomo esquiva `python.exe` por
completo, tiene un único camino de auth (API token) y es testeable con guardas puras y un test de
fallo de red local, sin tocar la instancia real.

Instancia objetivo: `https://soporte.ais-int.net/mantis/` — REST API 2.x confirmada viva.

## Base REST

⚠️ El rewrite `.htaccess` **no está activo** en esta instalación: `/api/rest/projects` → 404. La
API solo responde por el front controller, así que la **base real** que usa el cliente es:

```
{baseUrl}/api/rest/index.php
```

(p. ej. `GET {baseUrl}/api/rest/index.php/projects` + token → 200). Esta forma es además **más
portable**: funciona con y sin rewrite activo, por eso es la que construye `New-MantisRequest` en
`hooks/lib-mantis.ps1`. Verificado en vivo contra la instancia objetivo: 41 proyectos; estados del
workflow `new`/`acknowledged`/`assigned`/`confirmed`/`resolved`/`closed` (etiquetas ES
nueva/aceptada/asignada/confirmada/resuelta/cerrada); categorías incluyen
`General`/`Evolutivo`/`Incidencia`.

## Config del workspace — `docs\.mantis-dev-config.json`

En la carpeta `docs\` del workspace, **junto a `.rs-databases.json`** (misma convención que la
config de Jira). **No contiene secretos** (aun así, recomendado añadirlo al ignore de VCS):

```json
{
  "projects": [
    { "id": 12, "name": "ClienteX 2025" },
    { "id": 8,  "name": "ClienteX 2024" }
  ],
  "defaultCategory": "General",
  "statusChain": ["new", "acknowledged", "assigned", "confirmed"],
  "statusMap": { "inProgress": "assigned", "inValidation": "confirmed" }
}
```

- `projects[]` — lista **curada manualmente** de proyectos Mantis del cliente (un repo puede tener
  varios; a menudo uno nuevo por año, los viejos siguen abiertos). No se filtra por nombre porque
  los nombres de cliente en Mantis no son consistentes. Se gestiona con `/rs-mantis proyectos`.
- `defaultCategory` — categoría por defecto al crear una issue.
- `statusChain` — la cadena **ordenada** de nombres de estado del workflow de esta instancia, de
  inicial a final, tal como los recorre el subcomando `advance` (ver más abajo). Verificado en vivo
  contra la instancia objetivo: `new` (Nueva) → `acknowledged` (Aceptada) → `assigned` (Asignada) →
  `confirmed` (Confirmada) → `resolved` (Resuelta) → `closed` (Cerrada), con etiquetas en español.
  `statusChain` solo necesita cubrir el tramo que la skill recorre (`new`..`confirmed`); no hace
  falta incluir `resolved`/`closed` si no se transiciona hasta ahí.
- `statusMap` — **atajos** dentro de la cadena que usan las fases de la skill: `inProgress` → nombre
  de estado para "En Proceso" (en la instancia objetivo, `assigned` = Asignada, el paso en que el
  desarrollo se entrega al pipeline RS) e `inValidation` → nombre de estado para "En Validación" (en
  la instancia objetivo, `confirmed` = Confirmada, el paso al terminar el pipeline — y solo entonces
  se adjuntan los scripts SQL, ver Fase 4 de la skill). Estos nombres deben ser valores presentes en
  `statusChain`.

Scaffolding rápido: `/rs-mantis proyectos` (lista todos los proyectos que ve el token, numerados
`id — nombre (estado)`, y permite **Añadir** a la lista existente sin duplicar por `id`, o
**Crear** reemplazándola).

## Credenciales — `~/.claude/rs-mantis-credentials.json`

**Fuera de cualquier repo/workspace.**

```json
{ "baseUrl": "https://soporte.ais-int.net/mantis", "token": "<API token de Mantis>" }
```

- El token es un **API token de Mantis** (Mantis → *My Account → API Tokens → Create*).
- Es **por usuario**: identifica al reporter/handler de las operaciones; no se guarda un usuario
  aparte (a diferencia de Jira, que usa Basic auth `email:token`).
- `hooks/lib-mantis.ps1` (`Get-MantisCreds`) lee este fichero y valida que `baseUrl` y `token`
  estén presentes antes de tocar red; si falta o está incompleto, el error indica cómo crearlo.
- ⛔ El token **nunca** se imprime en output de hook/tool/log, ni se guarda en
  `.mantis-dev-config.json`.

## `hooks/mantis-cli.ps1` — subcomandos ↔ endpoint REST

Cliente REST autónomo con contrato JSON in/out: éxito `{ "success": true, ... }`, error
`{ "success": false, "error": "<msg>" }` + `exit 1`. Reutiliza el patrón `HttpClient` de
`hooks/jira-attach.ps1` (compatible Windows PowerShell 5.1), fuerza TLS 1.2 y UTF-8 en stdout.
Header de autenticación: `Authorization: <token>` — token **crudo**, **sin** prefijo `Bearer`.

| Subcomando | Llamada REST | Uso |
|---|---|---|
| `projects` | `GET /projects` | listar todos los proyectos que ve el token |
| `list -Project <id> [-PageSize <n>]` | `GET /issues?project_id={id}&page_size={n}` | issues del proyecto |
| `get -Id <n>` | `GET /issues/{id}` | leer una issue |
| `create -Project <id> -Category <s> -Summary <s> -Description <s> [-Handler <id>]` | `POST /issues` | crear issue |
| `transition -Id <n> -Status <name>` | `PATCH /issues/{id}` body `{"status":{"name":"<name>"}}` | cambiar estado (un solo salto, sin recorrer la cadena) |
| `advance -Id <n> -To <name> -Chain <csv> [-Handler <id>] [-HandlerStatus <name>]` | `GET /issues/{id}` + N × `PATCH /issues/{id}` | recorre `statusChain` paso a paso desde el estado actual hasta `-To`, sin saltos |
| `me` | `GET /users/me` | usuario del token (`{id,name,real_name}`) |
| `comment -Id <n> -Text <s>` | `POST /issues/{id}/notes` body `{"text":"<s>"}` | añadir nota |
| `attach -Id <n> -Files a,b` | `POST /issues/{id}/files` (multipart, campo `files[]`) | adjuntar ficheros |
| `download -Id <n> -FileId <f> -Out <ruta>` | `GET /issues/{id}/files/{f}` | descargar un adjunto |

Notas de contrato:
- `create` devuelve `{ success, id, issue }` con el id de la issue creada.
- `attach` reutiliza el multipart de `jira-attach.ps1` (`ByteArrayContent` +
  `MultipartFormDataContent`), un `HttpClient` propio (no pasa por `Invoke-MantisHttp`).
- `advance` devuelve `{ success, id, from, applied, to }` (o `note: "ya en el estado destino"` si no
  hay nada que recorrer). Ver detalle del protocolo en la sección siguiente.
- `me` devuelve `{ success, id, name, real_name }` — no requiere `-Id` ni ningún otro argumento.
- Todos los subcomandos validan argumentos obligatorios (guarda pura, sin red) y luego
  credenciales presentes/completas **antes** de la llamada HTTP; si faltan, el error remite a este
  documento.

## Protocolo de transición ordenada (`advance` + `me`)

Esta instancia de Mantis usa un workflow **encadenado sin saltos**: una issue no puede pasar
directamente de `new` a `assigned`, tiene que recorrer `acknowledged` primero. Verificado en vivo:
`new` (Nueva) → `acknowledged` (Aceptada) → `assigned` (Asignada) → `confirmed` (Confirmada) →
`resolved` (Resuelta) → `closed` (Cerrada).

`transition` (un `PATCH` directo a un nombre de estado) no respeta esto — si el estado destino no es
alcanzable en un salto desde el actual, Mantis devuelve el error del workflow tal cual. Por eso, para
mover una issue varios pasos (p. ej. de `new` a `assigned`), la skill usa `advance` en vez de
`transition`:

```
mantis-cli.ps1 advance -Id <n> -To assigned -Chain "new,acknowledged,assigned,confirmed" -Handler <id> -HandlerStatus assigned
```

- **`-Chain`** es la cadena ordenada completa (viene de `statusChain` en la config del workspace),
  coma-separada.
- `advance` primero lee el estado actual de la issue (`GET /issues/{id}`), calcula el tramo de la
  cadena entre el estado actual y `-To` (sin incluir el actual), y aplica un `PATCH` por cada paso
  intermedio, **en orden**, sin saltárselos.
- **Idempotente hacia delante**: si la issue ya está en `-To` (o después de él dentro de la cadena),
  no hace ningún `PATCH` y devuelve `applied: []` con `note: "ya en el estado destino"`.
- **No permite retroceder**: si `-To` está *antes* que el estado actual en la cadena, `Get-MantisAdvancePath`
  lanza error y el hook responde `success:false` con el `error` correspondiente — no reordena ni
  fuerza un retroceso.
- **Fallo a mitad de camino**: si un `PATCH` intermedio falla (HTTP no-2xx), `advance` **para ahí** y
  devuelve `success:false` con un `error` que incluye qué pasos sí se aplicaron (`Aplicados: ...`) —
  la issue queda en un estado intermedio real de Mantis, no en `-To`. Quien llama a `advance` debe
  leer ese detalle y decidir cómo seguir (reintentar el tramo restante, avisar al usuario), nunca
  asumir que `-To` se alcanzó.
- **`-Handler` / `-HandlerStatus`**: si se pasan, el `PATCH` del paso cuyo nombre coincide con
  `-HandlerStatus` (por defecto `assigned`) incluye también `"handler":{"id":<Handler>}` en el body —
  así el handler se fija en el mismo paso en que la issue pasa a Asignada, no en una llamada aparte.
  El id del handler es el del propio usuario del token, resuelto con `me` (ver abajo) — es decir, el
  desarrollador que ejecuta el pipeline se asigna a sí mismo la issue al ponerla en curso.

`me` (`GET /users/me`) resuelve la identidad del token: `{ id, name, real_name }`. La skill lo llama
una vez en la Fase 3 para obtener el `id` que pasa como `-Handler` a `advance`.

## Nota sobre estados

MantisBT **no tiene un endpoint de "transiciones"** como Jira (`getTransitions`/
`transitionJiraIssue`): el estado es simplemente un **campo** de la issue, que se cambia con
`PATCH /issues/{id}` enviando `{"status":{"name":"<nombre>"}}`. Por eso `statusMap` en
`.mantis-dev-config.json` guarda **nombres de estado destino** (`assigned`, `confirmed`, …), no ids
de transición — y esos nombres varían por instalación/workflow, por lo que deben confirmarse con
token real (`get`, o `GET /projects/{id}`) antes de fijarlos en la config. Un nombre de estado
desconocido hace que `transition` devuelva el error tal cual lo reporta Mantis. Además, esta
instancia impone un workflow **encadenado** (ver sección anterior): `transition` solo sirve para
saltos válidos de un paso; para recorrer varios estados en orden sin saltárselos, usar `advance`.

## Seguridad

- El token vive únicamente en `~/.claude/rs-mantis-credentials.json`, fuera del repo.
- ⛔ Nunca se imprime ni se loguea el token ni el contenido del fichero de credenciales.
- `Protect-MantisToken` (en `hooks/lib-mantis.ps1`) redacta el token a `***` en cualquier mensaje
  de error antes de emitirlo (por ejemplo, si el propio token aparece reflejado en un cuerpo de
  respuesta HTTP de error).
- La config del workspace (`.mantis-dev-config.json`) no contiene secretos y está separada de las
  credenciales — misma disciplina que `rs-jira`.
