# RS Validador

Plugin de desarrollo, mantenimiento y documentación de **RSValidador** — la herramienta *validador de
ficheros*: una aplicación web local (Python/FastAPI + HTML/JS) con la que se definen **estructuras**
(interfaces de entrada), se valida que los ficheros recibidos son estructuralmente correctos y se
generan los **scripts SQL de configuración de uCollect** (mandantes, especies, archivos, atributos,
algoritmos) a partir del grupo de estructuras **Estándar (SQL)**.

⛔ Este plugin **no** trabaja sobre soluciones C#/`.sln` de uCollect/RS — para eso está
`rs-enterprise-agent`. Ambos se publican desde el mismo marketplace pero se instalan y versionan por
separado.

## Instalación

```
/plugin marketplace update rs-enterprise-agent
/plugin install rs-validador@rs-enterprise-agent
```

Reiniciar Claude Code después.

## Qué garantiza

1. **Ningún cambio sin PLAN aprobado por un humano.** Ni código, ni documentación, ni un arreglo de
   una línea. El PLAN declara ficheros, impacto (endpoints, modelo de datos, scripts SQL,
   multi-cliente), verificación prevista y documentación a actualizar.
2. **Verificación explícita.** Python y JS vanilla no tienen compilador: la skill obliga a
   `py_compile`, a la checklist de trampas conocidas y a ejercitar la ruta afectada con la app
   levantada. Nunca se declara "funciona" sin evidencia.
3. **Documentación al día.** `docs/documentacion-funcional.md`, `docs/documentacion-tecnica.md` y las
   `RELEASE_NOTES_<fecha>.md` se actualizan en el mismo cambio, no después.

## Documentación canónica de la herramienta

| Fuente | Estado |
|--------|--------|
| `docs/documentacion-funcional.md` | **Canónica** — qué hace: conceptos, pantallas, flujos |
| `docs/documentacion-tecnica.md` | **Canónica** — cómo está hecha: arquitectura, datos, endpoints, despliegue |
| `CONTEXTO_CODEX.md` | **Histórico, no canónico.** Registro cronológico heredado y ya divergente. No se mantiene; si contradice a `docs/`, gana `docs/` |

## Uso

Invocación natural — basta mencionar la herramienta:

```
arregla el bug de la validación masiva con ficheros entrecomillados en el validador
añade el campo X al schema de estructura del validador de ficheros
el generador de RARCHIVOS está poniendo mal el orden
```

La skill resuelve el workspace, carga las references que apliquen, analiza y **para en el PLAN**.

### Comandos

| Comando | Qué hace |
|---------|----------|
| `/rsv-doc-drift` | Audita si la documentación funcional y técnica sigue coherente con el código. Solo lectura: clasifica los hallazgos en obsoleta / fantasma / incompleta / sin doc, con cita de doc y de código |

## References

Conocimiento de dominio que la skill carga bajo demanda — condensa las trampas que ya han causado
bugs reales en esta herramienta:

| Reference | Contenido |
|-----------|-----------|
| `arquitectura.md` | Stack, módulos, arranque y engine perezoso, `Depends(get_db)`/503, 422 invisibles, `shared.css`, las dos variantes de `apiFetch` |
| `schema-estructuras.md` | El modelo Pydantic `Schema` (un campo no declarado se descarta **en silencio**), reglas de validación, `grupo_id IS NULL` = Estándar (SQL), versionado, validación masiva |
| `sql-ucollect.md` | Los 6 scripts generados, `armandante` (dueño) vs `aemandante` (usuario), índices de `ATRIBUTOSBD` y `RARCHIVOS`, comparación con la BD productiva, algoritmos y acciones |
| `bd-motores.md` | Almacén propio vs BD productiva del cliente, CLOB→ORA-00932 en Oracle, migración por dialecto, `app_config.json`, backup/restore |
| `build-despliegue.md` | Arranque en desarrollo, smoke tests, build del exe, resolución de rutas bajo PyInstaller, entrega |

## Estado

Fase 1. Disponibles: la skill orquestadora con el gate de PLAN, las cinco references y
`/rsv-doc-drift`.

Previsto para la fase 2: comandos de sincronización de documentación, inventario de endpoints,
verificación del generador de scripts SQL, consulta del almacén, build y commit.
