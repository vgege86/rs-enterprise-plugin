# RS Validador — Changelog

## 1.1.0 — 2026-08-07

### La skill ya tenía proceso, pero no tenía puerta

La 1.0.0 dejó la skill `rs-validador` con su gate de PLAN y sus cinco references, y un único comando:
`/rsv-doc-drift`, que audita la documentación y no escribe nada. El proceso principal —el que arregla
bugs, añade campos al schema o toca el generador de scripts SQL— solo se alcanzaba mencionando la
herramienta en lenguaje natural. Funcionaba, pero era invisible: quien escribía `/rsv` y no veía nada
concluía que el plugin no estaba, no que la entrada era otra.

Esta versión añade tres comandos que abren esa puerta.

#### `/rs-validador <cambio>` — entrada general

Ejecuta el `PROCESO OBLIGATORIO` completo, del contexto al cierre, con el gate de PLAN en su sitio.
Es el equivalente de mencionar la herramienta, pero descubrible desde el menú de comandos.

#### `/rsv-bug <síntoma>` — con la reproducción por delante

Mismo proceso con `Tipo: bug` fijado y el paso de análisis reforzado: no se propone una causa leyendo
código. Hay que fijar el endpoint, el payload que lo dispara, la línea que falla o la entrada de
`data/rsvalidador.log`, y eso viaja dentro del PLAN. Un bug sin reproducción entendida no se arregla,
se investiga — y el PLAN lo dice así.

#### `/rsv-doc <qué actualizar>` — la contrapartida escritora del drift

`/rsv-doc-drift` detecta el desfase pero no lo corrige. `/rsv-doc` lo corrige, acotado a
`docs/documentacion-funcional.md`, `docs/documentacion-tecnica.md` y las `RELEASE_NOTES_<fecha>.md`,
verificando cada afirmación contra el código antes de escribirla. ⛔ Nada de código de producción: si
la documentación es correcta y el código no, lo reporta y para — eso es un `/rsv-bug`.

#### Lo que no cambia

Ningún agente nuevo. Los tres comandos corren en el hilo principal e invocan la misma skill, así que
no hay lógica duplicada que pueda divergir. Y ninguno salta el gate: el comando elige el punto de
entrada, no el nivel de control.

**Ficheros:** `commands/rs-validador.md`, `commands/rsv-bug.md`, `commands/rsv-doc.md` (nuevos);
`skills/rs-validador/SKILL.md` (sección `# Comandos`), `README.md`, `.claude-plugin/plugin.json` y la
entrada del plugin en el `marketplace.json` del repo.

## 1.0.0 — 2026-08-07

### Primera versión: la herramienta de validación de ficheros deja de mantenerse a mano

RSValidador —el *validador de ficheros*— es una aplicación Python/FastAPI + HTML/JS con la que se
definen las estructuras de entrada, se valida lo que manda el cliente y se generan los scripts SQL
de configuración de uCollect. Su almacén guarda la configuración de **varios clientes a la vez**, y
no tiene compilador que atrape un error antes de que lo vea un usuario. Hasta ahora todo el
conocimiento sobre sus trampas vivía en la cabeza del que la escribió y en un fichero de contexto
que ya había divergido del código.

Este plugin convierte ese conocimiento en reglas ejecutables.

#### Gate de PLAN humano, sin excepción

La skill `rs-validador` **para el turno** antes de escribir nada y presenta un PLAN con ficheros,
impacto (endpoints, modelo de datos, scripts SQL, efecto multi-cliente), verificación prevista y
documentación a actualizar. Aplica igual a un arreglo de una línea y a la propia documentación.

#### Verificación en lugar de fe

Sin compilador, la etapa de validación no es «compila»: es `py_compile` + revisión manual de lo que
el intérprete no ve (nombres de campo, claves de dict, `id` de elementos DOM, rutas de endpoint
escritas en el JS) + la checklist de trampas de las references + levantar la app y ejercitar la ruta
afectada. Nunca se declara «funciona» sin decir qué se ejecutó y qué salió.

#### Cinco references con lo que ya ha costado dinero

- `schema-estructuras.md` — la trampa nº1: un campo del JSON de estructura que no esté declarado en
  el modelo Pydantic `Schema` **se descarta en silencio**, sin error ni log. Ya pasó dos veces.
- `sql-ucollect.md` — `RARCHIVOS.armandante` es el **dueño** del fichero, `RRELARCHESP.aemandante`
  es el **usuario**: iterar por el primero genera configuración equivocada. Más los índices de
  columna de `ATRIBUTOSBD` (15) y `RARCHIVOS`, y todo lo que hay que tocar al añadir una.
- `bd-motores.md` — almacén propio y BD productiva del cliente son cosas distintas que comparten
  conectores; y en Oracle una columna `Text` se crea como CLOB, que prohíbe `=`, `ORDER BY` y
  `UNIQUE` (ORA-00932).
- `arquitectura.md` — engine perezoso y modo configuración, `Depends(get_db)`/503, los 422 que no
  aparecen en el log, y que `apiFetch` no significa lo mismo en todas las pantallas.
- `build-despliegue.md` — bajo PyInstaller `Path(__file__).parent` apunta a `_internal/`; los datos
  van por `RS_DATA_DIR`.

#### `docs/` manda; el fichero de contexto pasa a histórico

`docs/documentacion-funcional.md` y `docs/documentacion-tecnica.md` son la única verdad y se
actualizan **en el mismo cambio**. `CONTEXTO_CODEX.md` queda como registro cronológico: no se
mantiene y, si contradice al código o a `docs/`, no gana.

#### `/rsv-doc-drift`

Audita la documentación **de la doc hacia el código**, no al revés: toma cada afirmación verificable
y busca su respaldo. La dirección importa —leer código y ver si «suena» a lo documentado deja pasar
justo las afirmaciones obsoletas—. Clasifica en obsoleta / fantasma / incompleta / sin doc, marca en
rojo la que puede inducir a una acción peligrosa (un borrado en la BD del cliente que ya no ocurre,
por ejemplo) y exige cita de doc **y** de código en cada hallazgo.

Ficheros: `.claude-plugin/plugin.json`, `skills/rs-validador/SKILL.md`, `agents/rsv-doc-drift.md`,
`commands/rsv-doc-drift.md`, `references/{arquitectura,schema-estructuras,sql-ucollect,bd-motores,build-despliegue}.md`,
`README.md`, `CHANGELOG.md`.
