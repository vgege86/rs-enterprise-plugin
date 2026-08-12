# Bases de datos y motores — RSValidador

⛔ **Dos bases de datos distintas.** Confundirlas es el error más caro de esta herramienta.

| | Almacén propio | BD productiva del cliente |
|---|---|---|
| Qué guarda | Proyectos, mandantes, estructuras, relaciones, grupos, configuración SQL, algoritmos | Los datos y tablas reales de la implantación uCollect |
| Dónde se configura | Fichero `data/app_config.json` | Tabla `proyecto_connection_strings` (por proyecto) |
| Motores | SQLite (por defecto), Oracle, SQL Server | Oracle (`oracledb` thin) o SQL Server (`pyodbc`) |
| Quién la toca | La aplicación, en cada request | Solo lectura de metadatos + ejecución explícita de SQL |

Comparten los conectores, no el mecanismo. Un cambio en `_connect_to_db()` afecta a la productiva;
un cambio en `build_database_url()` afecta al almacén.

## 1. Modelos del almacén (SQLAlchemy, todos sobre `Base`)

| Modelo | Tabla | Notas |
|--------|-------|-------|
| `Proyecto` | `proyectos` | `nombre` único |
| `Mandante` | `mandantes` | `UniqueConstraint(proyecto_id, codigo)` y `(proyecto_id, nombre)` |
| `Estructura` | `estructuras` | Schema JSON en la columna `estructura`. `nombre` es `String(255)`, **no** `Text`. `grupo_id` nullable |
| `EstructuraVersion` | `estructura_versiones` | Histórico de versiones del schema |
| `Relacion` | `relaciones` | `config` JSON con el mapping F1↔F2. `grupo_id` nullable |
| `GrupoEstructura` | `grupos_estructura` | `UniqueConstraint(proyecto_id, nombre)` |
| `CatalogoEstandar` | `catalogos_estandar` | Sincronizado desde `RTABL`. `catalogo_num`/`codigo` son `String` |
| `ProyectoConnectionString` | `proyecto_connection_strings` | Conexión a la BD **productiva** por proyecto |
| `ConfiguracionSQL` | `configuraciones_sql` | Config de scripts SQL por proyecto + mandante |
| `Algoritmo` / `Accion` | `ralgoritmo` / `raccion` | Por proyecto |

`Estructura`, `Relacion`, `Algoritmo` y `Accion` tienen `created_at` / `updated_at`;
`ensure_project_schema()` los añade con `ALTER TABLE ADD COLUMN` en bases preexistentes.

## 2. ⛔ CLOB en Oracle (ORA-00932)

Una columna `Text` de SQLAlchemy se crea en Oracle como **CLOB**, y Oracle prohíbe `=`, `ORDER BY` y
`UNIQUE` sobre un LOB → `ORA-00932`.

**Regla:** toda columna que se compare, ordene o indexe (nombres, códigos) debe ser `String(n)`
(VARCHAR2), nunca `Text`. Ya corregido en `estructuras.nombre` y en
`catalogos_estandar.catalogo_num`/`codigo` — ese bug impedía guardar estructuras (el SELECT de
duplicados) y cargar catálogos.

⚠️ `create_all` **no altera columnas ya existentes**: en bases Oracle preexistentes hay que ejecutar
una vez `scripts/oracle_fix_clob_columns.sql` (o la variante para DBeaver), que convierte
CLOB→VARCHAR2 preservando los datos.

## 3. Migración de esquema

`ensure_project_schema()`:
- `Base.metadata.create_all(engine)` — crea el esquema completo en cualquier motor.
- **Solo en SQLite**, aplica la migración incremental legacy (`ALTER TABLE ADD COLUMN`,
  `CREATE UNIQUE INDEX IF NOT EXISTS`) para bases preexistentes.

En Oracle/SQL Server esa migración no aplica: `create_all` ya crea columnas y las `UniqueConstraint`
declaradas en los modelos. ⛔ El DDL no portable debe quedar aislado tras
`engine.dialect.name == "sqlite"`. Un `ALTER TABLE` nuevo fuera de esa guarda rompe los otros motores.

## 4. Configuración del almacén: `data/app_config.json`

El motor donde vive el almacén no puede guardarse dentro del propio almacén (huevo-gallina): vive en
un JSON.

```json
{ "engine": "local | oracle | sqlserver",
  "oracle":    { "host": "", "port": "1521", "service": "", "user": "", "password": "" },
  "sqlserver": { "server": "", "database": "", "user": "", "password": "" } }
```

Funciones clave: `load_app_db_config()` (fallback `{"engine": "local"}`), `build_database_url(cfg)`,
`resolve_database_url()`.

**URLs construidas:**
- `local` → `sqlite:///…/app.db`
- `oracle` → `oracle+oracledb://user:pass@host:port/?service_name=service`
- `sqlserver` → `mssql+pyodbc://user:pass@server/database?driver=ODBC+Driver+18…&TrustServerCertificate=yes`
  (driver ODBC 18/17/13 autodetectado por `_pick_sqlserver_driver()`)

**Precedencia:** env `DATABASE_URL` explícita **>** `app_config.json` **>** SQLite local.
Los launchers ya **no** fuerzan `DATABASE_URL`; respetan `app_config.json`. El exe solo la fija a
SQLite cuando la configuración es local o no existe (para preservar el modo portable).

Las contraseñas se guardan en texto plano (consistente con `proyecto_connection_strings`). Al enviar
la config al frontend se **enmascaran** (`********`); al guardar, si el frontend reenvía la máscara,
`_merge_app_cfg` conserva la contraseña previa. ⛔ No romper ese merge o se pierden las credenciales
al guardar cualquier otro campo.

Cambiar de motor requiere **reiniciar la aplicación**. Si el servidor configurado no responde al
arrancar, la app entra en **modo configuración** (ver `arquitectura.md` §4) y los endpoints de datos
devuelven 503.

## 5. BD productiva por proyecto

`ProyectoConnectionString` + `_connect_to_db()` / `_connect_to_db_sqlserver_pyodbc()` /
`_parse_dotnet_cs()`. Acepta connection string en JSON estructurado o en estilo .NET.
`POST /proyecto/{pid}/test-conexion` prueba sin persistir; la UI lo llama **antes** de guardar y
aborta el guardado si falla.

⛔ Cualquier operación que escriba en la productiva es un cambio en producción de un cliente: exige
confirmación explícita y aparece siempre en el PLAN.

## 6. Backup y restore

`GET /backup-db` (usa `sqlite3.backup()`, copia consistente) y `POST /restore-db` (valida la firma
SQLite y reemplaza con `os.replace()`). **Solo con almacén SQLite** — con otro motor devuelven **409**
y la UI los oculta. Equivalentes de línea de comandos en `scripts/backup_sqlite_db.py` y
`scripts/restore_sqlite_db.py`.

⛔ Antes de cualquier cambio que toque el esquema del almacén: backup primero.
