# Entregas a cliente: instalador y actualizador

Convenciones comunes a los dos modos de entrega:

| Modo | Comando | Destino | Contenido |
|------|---------|---------|-----------|
| Instalación limpia | `/rs-instalador` | `C:\AIS\<Proyecto>\Instalador` | Producto completo: EXES, AgendaWeb, ServiceManager+Modulos, Scripts (DDL + inserts paramétricas) |
| Actualizador | `/rs-actualizador` | `C:\AIS\<Proyecto>\Actualizador\<ENTORNO>_<AAAAMMDD>` | Solo el delta desde la última entrega de ese entorno |

Ambos incluyen el mismo **paquete de instalación en cliente** (`hooks\instalacion-paquete.ps1`,
plantillas en `assets\instalacion\`): `Instalar.ps1`, `Ejecutar-Scripts.ps1`, `rutas.json`, `readme.txt`.

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
      "bd": { "motor": "ORACLE", "conexion": "//host:1521/SID", "usuario": "USR" }
    } } }
```

⛔ Sin contraseñas: `Ejecutar-Scripts.ps1` las pide por consola (`Read-Host -AsSecureString`).

Origen: bloque `entornos` de `docs\<proyecto>-actualizador.json` o `docs\<proyecto>-instalador.json`.
Si falta, `instalacion-paquete.ps1` copia la plantilla y avisa — **entregar un `rutas.json` sin
rellenar rompe la instalación en cliente**.

---

# 🔧 Orden de instalación en cliente

1. `Ejecutar-Scripts.ps1 -Entorno <E>` — scripts SQL (pide confirmación y password; fail-fast).
2. `Instalar.ps1 -Entorno <E>` — backup ZIP de cada carpeta destino y copia.
3. Parámetros de configuración a mano (readme punto 3).
4. `99-RVERSIONES-<ENTORNO>.sql` — registro de la entrega en la BD del cliente.

En local, tras la entrega: `_local\99-RVERSIONES-local.sql`. Si no se ejecuta, el siguiente
actualizador repite los mismos commits.
