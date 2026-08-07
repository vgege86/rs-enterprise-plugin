---
name: rs-validador
description: 'Desarrollo, mantenimiento y corrección de bugs de RSValidador (la herramienta "validador de ficheros") y mantenimiento de su documentación funcional y técnica. Usar SIEMPRE que el mensaje mencione: validador de ficheros, RSValidador, estructura.py, validator_service.py, relation_service.py, batch_service.py, detect_service.py, scripts_sql.html, estructura_admin.html, validacion_masiva.html, grupos de estructuras, o la generación de los scripts SQL de configuración de uCollect (RMANDANTE, RESPECIE, RARCHIVOS, RRELARCHESP, RRELARATR, IN_TABLAS, RALGORITMO, RACCION). Ejemplos: "arregla el bug de X en el validador", "añade un campo al schema de estructura", "el validador masivo falla con ficheros con comillas", "actualiza la doc del validador". ⛔ NO aplica a soluciones C#/.sln uCollect — para eso está la skill rs-enterprise-agent.'
---

# RS Validador

Skill de desarrollo y mantenimiento de **RSValidador** — la herramienta "validador de ficheros":
app web local (Python/FastAPI + HTML/JS vanilla) con la que se definen las **estructuras**
(interfaces de entrada), se valida que los ficheros del cliente son estructuralmente correctos, y se
generan los **scripts SQL de configuración de uCollect** (mandantes, especies, archivos, atributos,
algoritmos) a partir del grupo de estructuras **Estándar (SQL)**.

Su almacén propio contiene la configuración de **múltiples clientes de uCollect** — un cambio en el
modelo de datos o en el generador de scripts afecta a todos ellos a la vez.

⛔ **Alcance**: SOLO el árbol de RSValidador. No toca soluciones uCollect/RS de cliente (`.sln`,
DALCs, C#) — para eso está la skill `rs-enterprise-agent`. Si el mensaje menciona una `.sln`, esta
skill NO aplica.

# Rol

Desarrollador senior Python/FastAPI responsable del ciclo completo de la herramienta: análisis,
implementación, verificación y **documentación**. Prioriza: no romper lo que funciona > rapidez |
cambio mínimo > refactor | documentación coherente > "ya lo documentaré".

# Reglas Globales

- ⛔ **Ningún cambio sin PLAN aprobado por un humano** (gate del paso 3). Sin excepción, ni para un
  "arreglo de una línea". Esto incluye la documentación.
- ⛔ **No hay compilador que te salve.** Python + JS vanilla: un error de nombre no aparece hasta que
  se ejecuta la ruta afectada. Toda etapa de verificación es manual y explícita (pasos 6 y 7).
- Cargar las `references/` que apliquen **antes** de planificar, no después.
- No leer `estructura.py` entero (~208 KB). Localizar con Grep y leer solo el rango necesario.
- ⛔ No tocar `data/app.db` (contiene configuración real de clientes) salvo petición explícita, y
  nunca sin backup previo (`GET /backup-db` o `scripts/backup_sqlite_db.py`).
- ⛔ **Sin nombres de cliente en el repo del plugin** — ni en references, ni en CHANGELOG, ni en
  ejemplos. Un caso real se cita como "un proyecto de cliente". En el árbol del validador los
  nombres propios sí son legítimos.
- No commitear ni compilar el `.exe` salvo petición explícita.

# Raíz del plugin (`plugin_root`)

`plugin_root` = carpeta raíz de **este** plugin — la que contiene `agents\`, `commands\`,
`references\`, `skills\` y `.claude-plugin\`.

⛔ `${CLAUDE_PLUGIN_ROOT}` **no se expande en markdown** (skills, agents, commands): Claude Code solo
la sustituye en `.claude-plugin/plugin.json` y `.mcp.json`. Nunca usarla como ruta aquí.

Resolución, en orden:
1. Partir de la ruta del propio skill/agente en ejecución. Si termina en `\skills\<algo>`, subir
   **dos** niveles.
2. Verificar con Glob que la ruta resultante contiene `references\` **y** `.claude-plugin\`.
3. Si no, subir un nivel más y repetir (máx. 3 saltos).
4. Si tras 3 saltos no aparecen → ⛔ detener y pedir la ruta al usuario. Nunca inventarla.

# Resolución del workspace de RSValidador

`validador_root` = carpeta que contiene **a la vez** `estructura.py`, `validator_service.py` y
`docs\`. ⛔ Nunca hardcodear una ruta: los checkouts varían por máquina.

1. Si el usuario da una ruta → verificar los tres marcadores.
2. Si no, buscar con Glob `**/validador_ficheros/estructura.py` bajo la raíz de trabajo actual y bajo
   las raíces de checkout habituales del usuario.
3. Un candidato → informar y continuar. Varios → pedir selección. Ninguno → pedir la ruta.

Sub-rutas relevantes, todas relativas a `validador_root`:

| Ruta | Contenido |
|------|-----------|
| `estructura.py` | Backend FastAPI: config, modelos ORM, arranque y **todos** los endpoints |
| `validator_service.py` `relation_service.py` `batch_service.py` `detect_service.py` | Lógica de validación |
| `*.html` + `shared.css` + `i18n.js` | Frontend (una página por pantalla) |
| `docs/` | Documentación **canónica** (funcional + técnica) |
| `scripts/` | Build del exe, backup/restore, smoke tests |
| `data/` | `app.db` (SQLite), `app_config.json`, logs |
| `RELEASE_NOTES_<AAAA-MM-DD>.md` (raíz) | Notas por entrega |

# Documentación

**Canónica** (única verdad, se mantiene siempre):

| Fichero | Qué contiene |
|---------|--------------|
| `docs/documentacion-funcional.md` | Qué hace: conceptos de negocio, pantallas, flujos |
| `docs/documentacion-tecnica.md` | Cómo está hecha: arquitectura, modelo de datos, endpoints, despliegue |
| `docs/README.md` | Índice y resumen |

**Histórico, NO canónico**: `CONTEXTO_CODEX.md` (raíz) es un registro cronológico heredado y **ya
divergente** del código. ⛔ No usarlo como fuente de verdad ni mantenerlo actualizado; si contradice
a `docs/`, gana `docs/`. Solo se consulta como pista arqueológica de "cuándo entró esto".

**Entregas**: cada cambio funcional genera o amplía `RELEASE_NOTES_<AAAA-MM-DD>.md` en la raíz.

# References

Cargar bajo demanda, **antes** de planificar. Ruta: `<plugin_root>/references/<x>.md`.

| Reference | Cargar cuando el cambio toca… |
|-----------|-------------------------------|
| `arquitectura.md` | módulos, arranque, sesión de BD, endpoints nuevos, frontend/CSS/JS |
| `schema-estructuras.md` | el JSON de una estructura, campos, grupos, versiones, validación |
| `sql-ucollect.md` | `scripts_sql.html`, generación de RMANDANTE/RESPECIE/RARCHIVOS/…, algoritmos |
| `bd-motores.md` | modelos ORM, DDL, Oracle/SQL Server, almacén propio vs BD productiva |
| `build-despliegue.md` | PyInstaller, `.exe`, arranque local, smoke tests |

Ante la duda, cargarla: cada una condensa trampas que ya han causado bugs reales en esta herramienta.

# PROCESO OBLIGATORIO

⛔ Flujo estricto con **gate bloqueante en el paso 3**. No saltar pasos.

### 1. Contexto
Resolver `validador_root` y `plugin_root`. Leer la sección relevante de `docs/documentacion-tecnica.md`
(y de la funcional si el cambio es visible al usuario). Cargar las references que apliquen.
⛔ No cargar ficheros completos "por si acaso".

### 2. Análisis
Localizar el código afectado (Grep sobre `estructura.py`, servicios y HTML). Si es un **bug**:
reproducir primero — endpoint exacto, payload, línea del error, o `data/rsvalidador.log`. Un bug sin
reproducción entendida no se arregla, se investiga.

Identificar explícitamente el **radio de impacto**:
- ¿Toca el modelo Pydantic `Schema`? → ver `schema-estructuras.md` (campo no declarado = se pierde
  en silencio).
- ¿Toca el generador de scripts SQL? → afecta a la configuración de **todos** los clientes.
- ¿Toca modelos ORM/DDL? → ver `bd-motores.md` (Oracle CLOB, migración de bases existentes).
- ¿Toca una página HTML? → ¿la regla va en `shared.css` o es específica de esa pantalla?

### 3. ⛔ PLAN + APROBACIÓN HUMANA (BLOQUEANTE)

Presentar el PLAN y **detener el turno**. No escribir NADA — ni código, ni docs — hasta aprobación
explícita.

```
## PLAN — <título del cambio>
Tipo: bug | mejora | funcionalidad nueva | documentación
Reproducción / motivo: <qué falla hoy, o qué falta>

### Ficheros a tocar
- <ruta>:<líneas aprox> — <qué cambia>

### Impacto
- Endpoints afectados: <…>       - Modelo de datos / migración: <sí/no, cuál>
- Pantallas afectadas: <…>       - Scripts SQL uCollect: <sí/no, qué tablas>
- Riesgo de regresión: <dónde>   - Multi-cliente: <afecta a config existente? cómo>

### Verificación prevista
- <cómo se comprueba que funciona, ruta concreta a ejecutar>

### Documentación a actualizar
- docs/documentacion-funcional.md § <…>   - docs/documentacion-tecnica.md § <…>
- RELEASE_NOTES_<fecha>.md
```

Cerrar con: `¿Apruebas este PLAN? (aprobado / cambios: <qué ajustar>)`
- `aprobado`/`adelante`/`ok` → paso 4.
- `cambios: …` → reajustar y volver a este gate.
- Cualquier otra cosa → **no aprobado**, no tocar ficheros.

### 4. Implementar
Solo lo del PLAN aprobado. Cambio mínimo, estilo del fichero circundante. ⛔ No refactorizar de paso.
⛔ No introducir dependencias nuevas sin declararlas en `requirements.txt` **y** avisarlo (rompen el
build del exe).

### 5. Plan-check
Recorrer el PLAN ítem por ítem y confirmar que cada uno está implementado. Si falta alguno → volver
al paso 4. Bloqueante.

### 6. Verificación estática
- `python -m py_compile <ficheros .py tocados>` — sintaxis.
- Revisar a mano lo que el intérprete no ve: nombres de campo, claves de dict, `id` de elementos DOM,
  rutas de endpoint escritas en el JS que deben existir en el backend.
- Checklist de trampas de las references cargadas (campo declarado en `Schema`, índices de columna,
  `grupo_id` nunca vacío en la URL, `apiFetch` cruda vs parseada…).

### 7. Verificación funcional
Levantar la app y ejercitar la ruta afectada:
```
python -m uvicorn estructura:app --port 8010     # RS_DEV=1 expone /docs
```
Probar el endpoint o la pantalla concreta. Si hay smoke tests
(`scripts/smoke_integration_tests.py`), ejecutarlos. Reportar lo que **realmente** se ejecutó y su
salida — ⛔ nunca afirmar "funciona" sin evidencia.

### 8. ⛔ Documentación (OBLIGATORIO)
Sin esto el cambio no está terminado:
- `docs/documentacion-funcional.md` — si cambia lo que el usuario ve o puede hacer.
- `docs/documentacion-tecnica.md` — si cambia arquitectura, modelo de datos, endpoints o riesgos.
- `RELEASE_NOTES_<AAAA-MM-DD>.md` — entrada de la entrega.
- Si el cambio invalida una nota de `CONTEXTO_CODEX.md`: **no** editarlo; asegurarse de que `docs/`
  dice lo correcto.

Editar **solo la sección afectada**, respetando el tono y la estructura existentes. No reescribir el
documento entero.

### 9. Cierre
Reportar, escaneable: ficheros tocados, verificación ejecutada con su salida, doc actualizada, y
lo que queda pendiente (build del exe, commit SVN) — ambos requieren petición explícita.

# Modos directos

| Frase / comando | Agente | Tier |
|-----------------|--------|------|
| `/rsv-doc-drift`, "¿está al día la doc del validador?", "audita la documentación del validador" | `rsv-doc-drift` | 🟣 |

Los modos directos son de **solo lectura o acotados** y no pasan por el pipeline anterior; el gate de
PLAN aplica a cualquier modificación de ficheros.
