# Entregas a cliente: instalador y actualizador

Convenciones comunes a los dos modos de entrega:

| Modo | Comando | Destino | Contenido |
|------|---------|---------|-----------|
| Instalación limpia | `/rs-instalador` | `C:\AIS\<Proyecto>\Instalador` | Producto completo: EXES, AgendaWeb, ServiceManager+Modulos, Scripts (DDL + inserts paramétricas) |
| Actualizador | `/rs-actualizador` | `C:\AIS\<Proyecto>\Actualizador\<ENTORNO>_<AAAAMMDD>` | Solo el delta desde la última entrega de ese entorno |

Ambos incluyen el mismo **paquete de instalación en cliente** (`hooks\instalacion-paquete.ps1`,
plantillas en `assets\instalacion\`): `Instalar.ps1`, `Ejecutar-Scripts.ps1`, `rutas.json`, `readme.txt`.
En modo instalación se añaden además el DDL de `RVERSIONES` y su **fila base**, generada por el hook
(no la redacta el modelo): `Scripts\PorEntorno\99-RVERSIONES-<ENTORNO>.sql`, una por entorno declarado.

---

# 🗂️ Tabla `RVERSIONES`

Registro de entregas. Vive en **dos sitios**: nuestra BD de control (histórico de todas las entregas
de todos los entornos) y la BD del cliente (lo entregado en ese entorno). DDL idempotente en
`assets\instalacion\RVERSIONES-oracle.sql` / `-sqlserver.sql`.

| Columna | Tipo | Significado |
|---------|------|-------------|
| `ID_VERSION` | NUMBER/IDENTITY | PK (Oracle: `SEQ_RVERSIONES.NEXTVAL`) |
| `ENTORNO` | VARCHAR(10) | `DESA` \| `TEST` \| `PROD` (CHECK) |
| `SOLUCION` | VARCHAR(100) | Nombre de la solución entregada |
| `VERSION` | VARCHAR(30) | Etiqueta de la entrega: `<ENTORNO>_<AAAAMMDD>` |
| `FECHA_ENTREGA` | DATE | Cuándo se entregó (default SYSDATE/GETDATE) |
| `FECHA_CORTE` | DATE | Hasta qué fecha de commits entra la entrega |
| `DESCRIPCION` | VARCHAR(4000) | **Funcional, no técnica** — la lee el usuario final |
| `TAREAS` | VARCHAR(500) | IDs de Mantis/Jira incluidos |
| `USUARIO` | VARCHAR(50) | Quién generó la entrega |

⛔ `FECHA_CORTE`, no `FECHA_ENTREGA`, es el punto de partida del delta siguiente: una entrega
generada con `--hasta` deja fuera commits posteriores, y entregar desde la fecha de entrega los
perdería.

⛔ `DESCRIPCION` sin jerga técnica (ni clases, ni tablas, ni ficheros): el objetivo es que el usuario
final de la herramienta pueda llegar a leer estos comentarios.

---

# 🔁 Cálculo del delta

1. `SELECT MAX(FECHA_CORTE) FROM RVERSIONES WHERE ENTORNO=? AND SOLUCION=?` → última entrega.
2. `vcs_delta(workspace, desde=<última>, hasta=<corte>, ruta=<carpeta de la solución>)` →
   commits, ficheros e IDs de tarea (SVN o Git, autodetectado).
3. Fichero del delta ∈ `get_scope(<sln>)` ⇒ solución afectada.

Sin fila previa en `RVERSIONES` (primera entrega en ese entorno) → **preguntar la fecha de partida**.
Nunca asumirla: un delta mal acotado entrega código no validado.

---

# 📦 Qué se empaqueta

| Artefacto | Instalador | Actualizador |
|-----------|------------|--------------|
| Batch | Todos los activos del JSON | Solo las soluciones afectadas, con **Rebuild completo de cada una** |
| AgendaWeb | Publicación completa | Publicación completa (nunca delta de ficheros web) |
| ServiceManager | Host + Modulos | Solo DLL de los módulos afectados, compiladas en ese build |
| Scripts SQL | DDL + inserts paramétricas + `RVERSIONES` | Scripts de las tareas del rango + insert `RVERSIONES` |

**Por qué la solución batch entera y no el `.csproj` tocado**: las DLL compartidas
(`Comun`/`BusComun`/`RSModel`) no tienen strong-name y el CLR enlaza por nombre simple. Mezclar
binarios de builds distintos produce `StackOverflowException` en arranque. De ahí el gate de
coherencia (todo binario desplegado debe ser de ESTE build) en `installer-batch.ps1` y
`actualizador-build.ps1`.

---

# ⛔ Ficheros de configuración

Hay que distinguir dos cosas que ambas "son .config":

| Qué | En un actualizador | Por qué |
|-----|--------------------|---------|
| `*.config` **del binario** — `RSProcIN.exe.config`, `<dll>.config` | ✅ **viaja** | Llevan los binding redirects. Entregar la DLL sin su `.config` alineado da `FileLoadException` → `StackOverflow` en arranque (es lo que vigila el gate de binding redirects de `installer-batch.ps1`) |
| **Configuración funcional del entorno** — `web.config` de la web, `<proceso>.xml` de cada batch (`rsprocin.exe` → `rsprocin.xml`), `appsettings*.json` | ⛔ **no viaja** | Es del cliente: tiene sus cadenas de conexión, rutas y credenciales. Pisarla rompe su instalación |

Triple defensa sobre la segunda:

1. `actualizador-build.ps1` la excluye del paquete y la lista. El `<proceso>.xml` se identifica por
   coincidencia de nombre base con un `.exe` entregado; los `.xml` de `Exes\` que **no** coinciden se
   dejan y se avisa (revisar y, si son configuración, añadirlos a `excluirEntrega` del JSON).
2. `Instalar.ps1 -Modo Actualizacion` aborta si encuentra alguno.
3. Los parámetros nuevos se documentan en `readme.txt` (punto 3) con nombre, valor y fichero destino,
   para que el cliente los añada a su propia configuración.

En una **instalación limpia** viaja todo, incluida la configuración: el cliente no tiene nada previo
que pisar (pero lleva valores de desarrollo → el readme lista los que hay que ajustar).

---

# 🖥️ `rutas.json` (servidor del cliente)

Una entrada por entorno; lo consumen `Instalar.ps1` y `Ejecutar-Scripts.ps1`.

```json
{ "proyecto": "<P>",
  "entornos": {
    "TEST": {
      "backup": "D:\\Backups\\<P>\\TEST",
      "modulos": { "AgendaWeb": "...", "Exes": "...", "ServiceManager": "...", "Modulos": "..." },
      "bd": { "motor": "ORACLE", "conexion": "//host:1521/SID", "usuario": "USR",
              "autenticacion": "usuario", "tnsAdmin": "", "schema": "" }
    } } }
```

⛔ Sin contraseñas: `Ejecutar-Scripts.ps1` las pide por consola (`Read-Host -AsSecureString`) y
**nunca las pasa por la línea de comandos** (Oracle: `/nolog` + `CONNECT` en fichero temporal;
SQL Server: `SQLCMDPASSWORD`), donde quedarían visibles en la lista de procesos del cliente.

`autenticacion` decide el modo de conexión:

| Valor | Oracle | SQL Server |
|-------|--------|------------|
| `wallet` \| `externa` \| `integrada` | `sqlplus /@<alias>` (autenticación externa) | `sqlcmd -E` |
| `usuario` | `/nolog` + `CONNECT` | `sqlcmd -U` + `SQLCMDPASSWORD` |
| *(ausente)* | se deduce de si hay `usuario` — los `rutas.json` ya entregados siguen valiendo | ídem |

⛔ Con wallet, `conexion` es el **alias exacto** de `tnsnames.ora`, nunca un descriptor
`(DESCRIPTION=...)` ni un EZConnect `host:puerto/servicio`: el wallet indexa la credencial por el
texto del alias, y el troceo por `/` y `@` rompe un descriptor TCPS y da un ORA-12154 que parece de
red y no lo es. `Ejecutar-Scripts.ps1` rechaza esos formatos **antes** de intentar conectar.
`tnsAdmin` es la carpeta con `sqlnet.ora`/`tnsnames.ora`/wallet (vacío → `%TNS_ADMIN%`), y `schema`
fija el `CURRENT_SCHEMA` para cuando el usuario de conexión no es el dueño de las tablas.

Origen: bloque `entornos` de `docs\<proyecto>-actualizador.json` o `docs\<proyecto>-instalador.json`.
Si falta, `instalacion-paquete.ps1` copia la plantilla y avisa — **entregar un `rutas.json` sin
rellenar rompe la instalación en cliente**.

---

# 🔧 Orden de instalación en cliente

1. `Ejecutar-Scripts.ps1 -Entorno <E>` — scripts SQL (pide confirmación y password; fail-fast).
2. `Instalar.ps1 -Entorno <E>` — backup ZIP de cada carpeta destino y copia.
3. Parámetros de configuración a mano (readme punto 3).

Qué scripts se ejecutan y en qué orden lo decide **el manifiesto si existe, y si no la convención**.

## `scripts.json` (manifiesto, opcional)

Si hay un `scripts.json` junto a los `.sql`, **manda sobre el descubrimiento por carpetas**: el
orden es el declarado, no el alfabético. Lo genera `/rs-actualizador` —es quien tiene orden
significativo y ya pregunta al usuario por las dependencias entre scripts—; `/rs-instalador` no lo
genera porque su orden es estructural. Formato en `assets\instalacion\scripts.json.tpl`:

```json
{ "scripts": [
    { "ruta": "01-<TAREA>-<n>.sql" },
    { "ruta": "Inserts/10-PARAM.sql", "opcional": true },
    { "ruta": "99-RVERSIONES-<E>.sql", "entorno": "<E>" },
    { "ruta": "_PURGA-<x>.sql", "purga": true }
] }
```

| Campo | Efecto |
|-------|--------|
| `ruta` | obligatorio, relativa a la carpeta de scripts (admite `/` o `\`) |
| `opcional` | si falta en disco, avisa y continúa. Por defecto `false` |
| `entorno` | solo se ejecuta si coincide con `-Entorno` |
| `purga` | solo con `-Recargar`, y va antes que el resto |

⛔ Un script **obligatorio ausente aborta antes de conectar**: una entrega incompleta no se empieza,
es preferible no tocar la BD a dejarla a medias. Un `.sql` que viaja en el paquete pero **no** está
declarado se avisa y **no se ejecuta** — lanzar SQL no declarado contra la BD de un cliente es peor
que omitirlo, y el aviso destapa el olvido.

## Convención (sin manifiesto)

**Tres tandas**, alfabético dentro de cada una y parando al primer error:

| # | Origen | Contenido |
|---|--------|-----------|
| 1 | `<carpeta>\*.sql` | DDL de `RVERSIONES`, creación de tablas, scripts SQL de las tareas |
| 2 | `<carpeta>\Inserts\*.sql` | tablas paramétricas (solo instalación limpia) |
| 3 | `<carpeta>\PorEntorno\99-RVERSIONES-<E>.sql` | fila base, **solo la del `-Entorno` recibido** |

Las tandas 2 y 3 se saltan si su carpeta no existe (un actualizador solo trae la 1: su
`99-RVERSIONES-<ENTORNO>.sql` va suelto en `scripts\`). Los ficheros que empiezan por `_` se
ignoran, salvo `_PURGA-*.sql`, que se ejecutan los primeros y **solo con `-Recargar`**.

## Flags

`-Simular` conecta y lista el plan sin escribir · `-Recargar` incluye los scripts de purga (opt-in) ·
`-SinConfirmar` desatendido · `-Schema` fija `CURRENT_SCHEMA` · `-NlsLang` fuerza el `NLS_LANG`.

⚠️ `-Simular` **conecta de verdad** (comprueba usuario, `CURRENT_SCHEMA` y protocolo); lo único que
no hace es escribir. Por eso en modo usuario pide la contraseña también al simular: sin ella el
`CONNECT` sale como `usuario/@alias` y da `SP2-0306`, que no es fallo de wallet ni de red sino de
sintaxis.

⚠️ `NLS_LANG` describe el encoding del **fichero** `.sql`, no el de la BD. Precedencia: `-NlsLang` >
`%NLS_LANG%` > `AMERICAN_AMERICA.AL32UTF8`. Con un valor no-UTF-8 los acentos entran corruptos y
Oracle **no da ningún error**: se descubre al consultar. El script avisa y pide confirmación.

En local, tras la entrega: `_local\99-RVERSIONES-local.sql`. Si no se ejecuta, el siguiente
actualizador repite los mismos commits.
