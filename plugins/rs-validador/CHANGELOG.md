# RS Validador — Changelog

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
