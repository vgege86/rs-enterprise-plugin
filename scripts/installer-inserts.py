"""
Genera un fichero INSERT por cada tabla paramétrica, para el instalador de cliente
(carpeta Instalador\\Scripts\\Inserts). Instalación limpia: carga los datos paramétricos
del cliente en el servidor destino.

Fuente de la clasificación paramétrica:
    BD\\<proyecto>-model.json  →  clave raíz "subviews" = { "<vista>": [ "TABLA", ... ] }
    Vista por defecto: "Parametricas" (configurable en docs\\<proyecto>-instalador.json).

Conexión a BD: se lee de docs\\.rs-databases.json (conexión principal, conexiones[0]),
igual que hace la tool MCP db_query / get-config.ps1 / _get_db_password — sin exponer la
password en la línea de comando (se pasa a sqlplus por fichero temporal).

Detección de NULL fiable: cada columna se envuelve en el SELECT con
    CASE WHEN col IS NULL THEN '@@NULL@@' ELSE <texto de col> END
para distinguir NULL de cadena vacía. El tipeado (numérico crudo vs texto entrecomillado)
se decide con el tipo de la columna en el model.json.

Columnas binarias: los binarios cortos (RAW/VARBINARY) se extraen en hexadecimal y se
reconstruyen en el INSERT (HEXTORAW / literal 0x) — TO_CHAR sobre RAW da ORA-00932. Los LOB
binarios (BLOB/LONG RAW/IMAGE) no son inlineables: se emiten como NULL y se avisa en la
cabecera del .sql generado.

RENDIMIENTO
    El coste de esta etapa NO está en formatear los INSERT, está en el cliente SQL:
    1. Una sesión por CHUNK de tablas, no por tabla. Cada arranque de sqlplus/sqlcmd paga
       spawn de proceso + login; con decenas de tablas paramétricas (todas pequeñas) eso
       domina el reloj. Las tablas de un chunk se piden en UNA sesión, separadas por el
       marcador @@TBL:<TABLA>@@ que emite PROMPT (Oracle) / PRINT (SQL Server), y la salida
       se trocea por ese marcador. El aislamiento de error se mantiene: ni sqlplus ni sqlcmd
       abortan la sesión ante un error de una sentencia, así que un ORA-/Msg queda dentro
       del bloque de SU tabla y las demás del chunk se generan igual.
    2. VARCHAR2 en vez de CLOB cuando la fila cabe. Envolver la concatenación en TO_CLOB
       siempre es caro (concatenación LOB por fila + fetch de LOB); solo hace falta si la
       fila de salida puede pasar de 4000. Se estima el ancho con los tipos del model.json
       y, si la estimación se queda corta, el ORA-01489 se reintenta con TO_CLOB.
    3. ARRAYSIZE alto: el default de sqlplus es 15 filas por roundtrip.
    4. Config de BD cacheada: si el hook exporta RS_DB_CONFIG_JSON no se vuelve a lanzar
       PowerShell para releer get-config.ps1.

Uso: python installer-inserts.py <workspace> <proyecto> <out_dir> [ORACLE|SQLSERVER]
     Variables de entorno opcionales:
       RS_DB_CONFIG_JSON  ruta a la salida ya cacheada de hooks/get-config.ps1
       RS_INSERTS_TABLAS  lista `T1;T2` — regenera solo esas tablas paramétricas
"""

import sys
import os
import re
import json
import time
import subprocess
import tempfile
import concurrent.futures
from pathlib import Path
from datetime import datetime

# Salida siempre UTF-8 (la consola Windows por defecto es cp1252 y rompe con →, é, etc.)
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

DELIM   = "|@#@|"      # separador de columnas en la salida de la query
NULLTOK = "@@NULL@@"   # sentinel de NULL
ROWEND  = "@@ROWEND@@" # terminador de fila: se añade al final de cada fila en el SELECT y se usa
                       # para trocear la salida. Imprescindible porque un valor de texto puede
                       # contener saltos de línea: si se troceara por '\n' (1 línea = 1 fila) la
                       # fila se partiría y se perdería. Con el terminador, los '\n' internos de
                       # un valor se conservan.
# Tokens de salto de línea: el cliente SQL (sqlplus con PAGESIZE 0) TRUNCA el valor en el
# primer CHR(10) interno, descartando el resto del dato Y el terminador de fila -> las filas se
# funden y se pierden todas. Por eso la query codifica CR/LF como estos tokens (cada fila queda
# en UNA sola línea física, sin truncado) y Python los revierte a saltos reales en el literal SQL.
LFTOK   = "@@LF@@"     # CHR(10) / \n
CRTOK   = "@@CR@@"     # CHR(13) / \r

# Marcador de tabla dentro de una sesión multi-tabla: `@@TBL:<TABLA>@@`, emitido con PROMPT
# (Oracle) / PRINT (SQL Server) antes de cada SELECT. Es lo que permite pedir varias tablas
# en una sola sesión y seguir sabiendo qué filas son de quién.
TBLMARK     = "@@TBL:"
TBLMARK_FIN = "@@"

# Filas por roundtrip del cliente Oracle (default 15). Sube el throughput de las tablas
# paramétricas con muchas filas sin coste apreciable de memoria.
ARRAYSIZE = 200

# Máximo de tablas por sesión SQL. Acota el pico de memoria: en vuelo hay como mucho
# `workers` chunks, cada uno con la salida de hasta CHUNK_MAX tablas.
CHUNK_MAX = 12

# Ancho de fila por debajo del cual la concatenación se queda en VARCHAR2 (sin TO_CLOB).
# El límite duro de VARCHAR2 en SQL es 4000 **bytes**, y aquí se estima en caracteres a
# partir del model.json: el margen hasta 4000 cubre tanto los tokens @@CR@@/@@LF@@ como
# los acentos (2 bytes en UTF-8). Si aun así se queda corto, Oracle da ORA-01489 y main()
# reintenta esa tabla con TO_CLOB — la estimación no puede producir un fichero incorrecto.
VARCHAR_SAFE_WIDTH = 3000
ANCHO_ILIMITADO    = 10 ** 6   # centinela: tipo sin longitud conocida -> forzar CLOB

# Prefijos con los que los clientes SQL anuncian un error en stdout (returncode 0 incluido).
ERR_PREFIXES = ("ORA-", "SP2-", "PLS-", "Msg ", "Sqlcmd:", "HResult")

NUMERIC_BASES = {
    'NUMBER', 'INTEGER', 'INT', 'BIGINT', 'SMALLINT', 'TINYINT',
    'DECIMAL', 'NUMERIC', 'FLOAT', 'REAL', 'BINARY_FLOAT', 'BINARY_DOUBLE', 'BIT',
}

# Binario corto: se extrae en hexadecimal y se reconstruye en el INSERT
# (Oracle RAWTOHEX/HEXTORAW, SQL Server CONVERT(...,2)/literal 0x).
# TO_CHAR sobre RAW da ORA-00932 "expected NUMBER got BINARY".
RAW_BASES = {'RAW', 'VARBINARY', 'BINARY'}

# Binario grande: no se puede inline en un INSERT de texto -> se emite NULL con aviso.
BLOB_BASES = {'BLOB', 'LONG RAW', 'IMAGE'}


def _unprotect_secret(value: str) -> str:
    """Descifra un valor 'enc:<base64>' con DPAPI (CurrentUser, Windows). Sin el prefijo 'enc:' se
    devuelve tal cual (texto plano legacy). ⛔ PARIDAD con _unprotect_secret de mcp/rs-workspace-server.py
    y con Unprotect-RsSecret de hooks/lib-crypto.ps1 (mismo blob DPAPI). Windows-only."""
    if not value or not value.startswith("enc:"):
        return value
    import base64
    import ctypes
    from ctypes import wintypes
    if not hasattr(ctypes, "windll"):
        raise OSError("DPAPI (descifrado de secretos) solo está disponible en Windows")

    class _DataBlob(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    raw = base64.b64decode(value[len("enc:"):])
    buf_in = ctypes.create_string_buffer(raw, len(raw))
    blob_in = _DataBlob(len(raw), ctypes.cast(buf_in, ctypes.POINTER(ctypes.c_char)))
    blob_out = _DataBlob()
    ok = ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out))
    if not ok:
        raise OSError("CryptUnprotectData falló (¿secreto cifrado por otro usuario/máquina?)")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData).decode("utf-8")
    finally:
        ctypes.windll.kernel32.LocalFree(blob_out.pbData)


def _read_password(workspace: str, conexion: str = "") -> str:
    """Mirror de _get_db_password del MCP: password directo de docs/.rs-databases.json.
    No pasar por get-config.ps1, que la omite deliberadamente.
    Normaliza el workspace igual que Resolve-RsWorkspace: si apunta a una subcarpeta
    docs/BD/Batch/OnLine, sube al trunk — si no, la password sale vacía.

    `conexion` vacío → la principal (conexiones[0]). ⛔ Un id que NO existe lanza, nunca cae a
    conexiones[0]: mezclar la password de una conexión con los datos de otra produce un fallo de
    autenticación cuyo mensaje no apunta a ningún sitio — o, peor, entra en el entorno que no era.
    Misma regla que Select-RsConexion en hooks/lib-dbconfig.ps1."""
    ws = Path(workspace)
    if ws.name in ("docs", "BD", "Batch", "OnLine"):
        ws = ws.parent
    cfg_path = ws / "docs" / ".rs-databases.json"
    if not cfg_path.exists():
        return ""
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8-sig"))
    except Exception:
        return ""

    conexiones = cfg.get("conexiones") or []
    if not conexiones:
        return ""
    if conexion:
        sel = next((c for c in conexiones
                    if str(c.get("id", "")).lower() == conexion.lower()), None)
        if sel is None:
            validas = ", ".join(str(c.get("id", "")) for c in conexiones)
            raise SystemExit(f"ERROR: conexión '{conexion}' no existe en .rs-databases.json. Válidas: {validas}")
    else:
        sel = conexiones[0]

    try:
        for part in str(sel.get("cadena", "")).split(";"):
            part = part.strip()
            if part.lower().startswith("password="):
                # El valor puede venir cifrado (enc:<base64>) o en texto plano (legacy).
                return _unprotect_secret(part.split("=", 1)[1].strip())
    except Exception:
        pass
    return ""


def arg_conexion(argv: list) -> str:
    """Lee `--conexion <id>` de la línea de comandos. "" si no viene.

    Un único parser para los tres scripts que lo aceptan: si cada uno lo troceara a su manera,
    `--conexion` acabaría significando algo distinto según qué script lo recibe."""
    for i, a in enumerate(argv):
        if a == "--conexion" and i + 1 < len(argv):
            return argv[i + 1].strip()
        if a.startswith("--conexion="):
            return a.split("=", 1)[1].strip()
    return ""


def read_visibilidad(workspace: str, conexion: str = "") -> dict:
    """Diagnóstico de visibilidad de la conexión sobre su esquema: si la cuenta es dueña, qué
    GRANTs tiene y cuántos objetos de cada tipo ve el diccionario.

    ⛔ Delega en hooks/db-visibilidad.ps1 en vez de repetir aquí las consultas. Es la misma
    razón por la que `read_db_config` llama a get-config.ps1: dos implementaciones de la misma
    regla acaban divergiendo, y esta decide si un cero significa "no hay" o "no lo veo".

    Se cachea en RS_DB_VISIBILIDAD_JSON igual que la config: arrancar PowerShell cuesta ~1s y
    esto lo consultan varios scripts de la misma etapa.

    Nunca lanza: devuelve `{"ok": False, "soportado": False, "error": ...}` si no se pudo
    diagnosticar. El llamante decide (avisar y seguir, o cortar)."""
    cache = os.environ.get("RS_DB_VISIBILIDAD_JSON", "")
    if cache and Path(cache).exists():
        try:
            return json.loads(Path(cache).read_text(encoding="utf-8-sig"))
        except Exception:
            pass

    hook = Path(__file__).resolve().parent.parent / "hooks" / "db-visibilidad.ps1"
    if not hook.exists():
        return {"ok": False, "soportado": False, "error": f"no se encuentra {hook}"}
    cmd = ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
           "-File", str(hook), workspace]
    if conexion:
        cmd += ["-Conexion", conexion]
    try:
        r = subprocess.run(cmd, capture_output=True)
        return json.loads((r.stdout or b"").decode("utf-8", errors="replace").strip())
    except Exception as e:
        return {"ok": False, "soportado": False, "error": f"{type(e).__name__}: {e}"}


def read_db_config(workspace: str, model: dict, conexion: str = "") -> dict:
    """Obtiene la config de conexión llamando a get-config.ps1 (el mismo parser que usa db_query),
    para tolerar dataSource en formato connection-string ODP.NET. El password se lee aparte
    (get-config.ps1 lo omite deliberadamente).

    Si el hook ya resolvió la config y exportó su ruta en RS_DB_CONFIG_JSON, se lee de ahí:
    arrancar PowerShell cuesta ~1s y esta función se llama una vez por cada script Python de
    la etapa. ⛔ Ese fichero NO contiene la password (get-config.ps1 no la emite); la password
    la sigue leyendo _read_password del .rs-databases.json.

    ⛔ Con `conexion` explícita NO se usa la caché: RS_DB_CONFIG_JSON lo escribió el hook para
    la conexión que él resolvió, y devolverlo aquí daría los datos de una conexión con la
    password de otra."""
    out = ""
    cache = os.environ.get("RS_DB_CONFIG_JSON", "")
    if cache and not conexion and Path(cache).exists():
        try:
            out = Path(cache).read_text(encoding="utf-8-sig").strip()
        except Exception:
            out = ""
    if not out:
        hook = Path(__file__).resolve().parent.parent / "hooks" / "get-config.ps1"
        cmd = ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
               "-File", str(hook), workspace]
        if conexion:
            cmd += ["-Conexion", conexion]
        r = subprocess.run(cmd, capture_output=True)
        out = (r.stdout or b"").decode("utf-8", errors="replace").strip()
    try:
        cfg = json.loads(out)
    except Exception:
        raise SystemExit(f"ERROR: get-config.ps1 no devolvió JSON válido:\n{out[:400]}")
    if cfg.get("error"):
        raise SystemExit(f"ERROR: {cfg['error']}")

    motor      = (cfg.get("motor") or "").upper()
    datasource = cfg.get("datasource") or ""
    schema     = cfg.get("schema") or ""
    user       = cfg.get("user") or ""
    password   = _read_password(workspace, conexion)

    if motor == "ORACLE" and not schema:
        schema = (model.get("schema") or user).upper()

    # `conexion` viaja en el dict para que el llamante lo publique en su salida: sin eso, una
    # lectura hecha con una conexión privilegiada es indistinguible de una hecha con la de
    # consulta, que es justo lo que hacía inseguro editar el fichero a mano.
    return {"motor": motor, "datasource": datasource, "schema": schema,
            "user": user, "password": password,
            "conexion": conexion or (cfg.get("conexion") or "")}


def read_max_paralelo(workspace: str, proyecto: str, default: int = 8) -> int:
    """`parametricas.max_paralelo` del JSON de config del instalador — cap de sesiones BD
    simultáneas. Lo comparten esta etapa y la extracción de objetos (installer-objects.py):
    es una sola palanca para el Oracle del cliente, no una por script."""
    cfg_path = Path(workspace) / "docs" / f"{proyecto}-instalador.json"
    if not cfg_path.exists():
        return default
    try:
        with open(cfg_path, encoding="utf-8-sig") as f:
            p = (json.load(f).get("parametricas", {}) or {})
        return max(1, int(p.get("max_paralelo", default)))
    except (TypeError, ValueError):
        print(f"AVISO: parametricas.max_paralelo no es un entero — usando {default}")
    except Exception as e:
        print(f"AVISO: no se pudo leer {cfg_path}: {e}")
    return default


def parametric_tables(model: dict, workspace: str, proyecto: str) -> tuple:
    """Devuelve (lista_tablas, nombre_vista, max_paralelo) a partir de subviews + config del instalador."""
    vista = "Parametricas"
    excluir, incluir_extra = [], []
    max_paralelo = read_max_paralelo(workspace, proyecto)
    cfg_path = Path(workspace) / "docs" / f"{proyecto}-instalador.json"
    if cfg_path.exists():
        try:
            with open(cfg_path, encoding="utf-8-sig") as f:
                cfg = json.load(f)
            p = cfg.get("parametricas", {}) or {}
            vista = p.get("vista", vista)
            excluir = [t.upper() for t in p.get("excluir", [])]
            incluir_extra = p.get("incluir_extra", [])
        except Exception as e:
            print(f"AVISO: no se pudo leer {cfg_path}: {e}")

    subviews = model.get("subviews", {}) or {}
    if vista not in subviews:
        disponibles = ", ".join(subviews.keys()) or "(ninguna)"
        raise SystemExit(f"ERROR: vista '{vista}' no existe en subviews del modelo. "
                         f"Vistas disponibles: {disponibles}")

    tablas = list(subviews[vista]) + list(incluir_extra)
    # Preservar orden, quitar duplicados y excluidos, y solo tablas presentes en el modelo
    seen, resultado = set(), []
    model_tables = model.get("tables", {})
    for t in tablas:
        tu = t.upper()
        if tu in seen or tu in excluir:
            continue
        seen.add(tu)
        if tu not in model_tables:
            print(f"AVISO: tabla paramétrica '{tu}' no está en el modelo — se omite")
            continue
        if model_tables[tu].get("orphan"):
            print(f"AVISO: tabla paramétrica '{tu}' marcada orphan — se omite")
            continue
        resultado.append(tu)
    return resultado, vista, max_paralelo


def base_type(col_type: str) -> str:
    return (col_type or "").split("(")[0].strip().upper()


def _col_width(cdef: dict) -> int:
    """Ancho máximo estimado, en caracteres, del texto que la columna aporta al SELECT.
    Devuelve ANCHO_ILIMITADO si el tipo no acota la longitud (CLOB, o tipo desconocido):
    ante la duda se fuerza CLOB, que es el camino correcto aunque sea el lento."""
    bt = base_type(cdef.get("type"))
    if bt in BLOB_BASES:
        return len(NULLTOK)                     # se emite el centinela, no el contenido
    if bt in ("CLOB", "NCLOB", "LONG", "TEXT", "NTEXT", "XMLTYPE"):
        return ANCHO_ILIMITADO
    m = re.search(r"\((\d+)", cdef.get("type") or "")
    n = int(m.group(1)) if m else 0
    if bt in RAW_BASES:
        return n * 2 if n else ANCHO_ILIMITADO  # se extrae en hexadecimal: 2 chars por byte
    if bt in NUMERIC_BASES:
        return 45                               # signo + dígitos + separador + exponente
    if bt in ("DATE", "TIMESTAMP", "DATETIME", "DATETIME2", "SMALLDATETIME"):
        return 30
    return n if n else ANCHO_ILIMITADO


def _est_row_width(columns: list) -> int:
    """Ancho estimado de la fila completa de salida (columnas + separadores + terminador)."""
    total = len(ROWEND)
    for _, cdef in columns:
        w = _col_width(cdef)
        if w >= ANCHO_ILIMITADO:
            return ANCHO_ILIMITADO
        total += w + len(DELIM)
    return total


def build_select(table: str, columns: list, schema: str, motor: str, force_clob: bool = False) -> str:
    """SELECT con cada columna envuelta en CASE para detectar NULL y forzar texto.

    El SELECT se emite con una expresión POR LÍNEA: sqlplus corta la entrada por longitud
    de línea y una concatenación de 30+ columnas en una sola línea revienta con SP2-0341.
    En Oracle, la primera expresión va envuelta en TO_CLOB **solo si la fila puede pasar de
    4000** (VARCHAR2 se queda ahí y da ORA-01489 en tablas anchas): la concatenación LOB es
    bastante más cara en servidor, y la mayoría de tablas paramétricas son estrechas. Con
    `force_clob` se fuerza el camino CLOB — es lo que hace el reintento tras un ORA-01489.
    Los binarios cortos (RAW) se extraen en hexadecimal; los LOB binarios se emiten NULL.
    """
    exprs = []
    for name, cdef in columns:
        bt = base_type(cdef.get("type"))
        if motor == "ORACLE":
            if bt in BLOB_BASES:
                # No inlineable en un INSERT de texto: se pierde el contenido (avisado en cabecera)
                exprs.append(f"'{NULLTOK}'")
                continue
            if bt in RAW_BASES:
                val = f"RAWTOHEX({name})"
            elif bt in ("DATE", "TIMESTAMP"):
                val = f"TO_CHAR({name}, 'YYYY-MM-DD HH24:MI:SS')"
            else:
                val = f"TO_CHAR({name})"
            exprs.append(f"CASE WHEN {name} IS NULL THEN '{NULLTOK}' ELSE {val} END")
        else:  # SQLSERVER
            if bt in BLOB_BASES:
                exprs.append(f"'{NULLTOK}'")
                continue
            if bt in RAW_BASES:
                val = f"CONVERT(NVARCHAR(MAX), [{name}], 2)"   # 2 = hex sin prefijo 0x
            elif bt in ("DATETIME", "DATETIME2", "DATE", "SMALLDATETIME"):
                val = f"CONVERT(NVARCHAR(30), [{name}], 121)"
            else:
                val = f"CONVERT(NVARCHAR(MAX), [{name}])"
            exprs.append(f"CASE WHEN [{name}] IS NULL THEN '{NULLTOK}' ELSE {val} END")

    tbl = f"{schema}.{table}" if schema else table
    if motor == "ORACLE":
        # Codificar CR/LF -> tokens para que cada fila salga en UNA línea física (sqlplus trunca
        # el valor en el 1er CHR(10) interno; sin esto se pierde el resto del dato y el ROWEND).
        exprs = [f"REPLACE(REPLACE({e}, CHR(13), '{CRTOK}'), CHR(10), '{LFTOK}')" for e in exprs]
        if force_clob or _est_row_width(columns) > VARCHAR_SAFE_WIDTH:
            exprs[0] = f"TO_CLOB({exprs[0]})"
        concat = f"\n    || '{DELIM}' || ".join(exprs)
        concat += f"\n    || '{ROWEND}'"   # terminador de fila (sobrevive porque ya no hay '\n')
        return f"SELECT\n    {concat}\nFROM {tbl}"
    else:
        # SQL Server: '' + NVARCHAR evita el error de tipo; DELIM entre expresiones
        exprs = [f"REPLACE(REPLACE({e}, CHAR(13), '{CRTOK}'), CHAR(10), '{LFTOK}')" for e in exprs]
        concat = f"\n    + '{DELIM}' + ".join(exprs)
        concat += f"\n    + '{ROWEND}'"    # terminador de fila (sobrevive porque ya no hay '\n')
        tbl_sql = f"[{schema}].[{table}]" if schema else f"[{table}]"
        return f"SELECT\n    {concat}\nFROM {tbl_sql}"


def _decode(b: bytes) -> str:
    """Decodifica salida de sqlplus/sqlcmd tolerando UTF-8 o Windows-1252/Latin-1."""
    if b is None:
        return ""
    for enc in ("utf-8", "cp1252", "latin-1"):
        try:
            return b.decode(enc)
        except UnicodeDecodeError:
            continue
    return b.decode("utf-8", errors="replace")


def run_chunk_oracle(chunk: list, cfg: dict) -> str:
    """Ejecuta en UNA sola sesión sqlplus el SELECT de cada tabla del chunk `[(tabla, sql)]`,
    precedido de su marcador `@@TBL:<TABLA>@@`. Devuelve la salida completa: el troceo por
    tabla lo hace _split_tables y la detección de error por tabla, _find_error.

    ⛔ A propósito NO se pone `WHENEVER SQLERROR EXIT`: un error en una tabla no debe tumbar
    las demás del chunk. Con una sesión por tabla ese aislamiento lo daba el proceso; aquí lo
    da que sqlplus sigue con la sentencia siguiente y el error queda dentro del bloque de su
    tabla. Solo se lanza excepción si el proceso mismo falla (sqlplus ausente, etc.)."""
    connect = f"CONNECT {cfg['user']}/{cfg['password']}@{cfg['datasource']}\n" if cfg['password'] else ""
    conn_arg = "/nolog" if cfg['password'] else f"{cfg['user']}/@{cfg['datasource']}"
    schema_line = (f"ALTER SESSION SET CURRENT_SCHEMA = {cfg['schema']};\n"
                   if cfg['schema'] and cfg['schema'] != cfg['user'] else "")
    cuerpo = []
    for tabla, sql in chunk:
        cuerpo.append(f"PROMPT {TBLMARK}{tabla}{TBLMARK_FIN}")
        cuerpo.append(f"{sql};")
    script = (
        "SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON TERMOUT ON\n"
        "SET LINESIZE 32767 LONG 60000 LONGCHUNKSIZE 60000 WRAP OFF\n"
        "SET DEFINE OFF\n"                       # un '&' en el texto del script no es variable
        f"SET ARRAYSIZE {ARRAYSIZE}\n"           # default 15 filas/roundtrip = red innecesaria
        f"{connect}{schema_line}" + "\n".join(cuerpo) + "\nEXIT;\n"
    )
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".sql", delete=False, encoding="utf-8")
    tmp.write(script); tmp.close()
    # NLS_LANG con charset AL32UTF8 → el cliente Oracle entrega la salida en UTF-8
    env = dict(os.environ, NLS_LANG="AMERICAN_AMERICA.AL32UTF8")
    try:
        r = subprocess.run(["sqlplus", "-S", conn_arg, f"@{tmp.name}"],
                           capture_output=True, env=env)  # bytes (text=False)
    finally:
        os.unlink(tmp.name)
    out, err = _decode(r.stdout), _decode(r.stderr)
    if r.returncode != 0:
        raise RuntimeError(_mensaje_fallo(err, out))
    return out


def run_chunk_sqlserver(chunk: list, cfg: dict) -> str:
    """Equivalente a run_chunk_oracle para sqlcmd, con el marcador emitido por PRINT."""
    lineas = ["SET NOCOUNT ON;", "GO"]   # SET NOCOUNT es de conexión: persiste entre lotes
    for tabla, sql in chunk:
        # Un GO por tabla, por dos razones: (1) dentro de un mismo lote el flujo de mensajes
        # (PRINT) y el de resultados (SELECT) no llegan necesariamente intercalados en orden,
        # y el marcador dejaría de identificar sus filas; (2) da aislamiento de error —
        # sqlcmd sigue con el lote siguiente aunque uno falle.
        lineas.append(f"PRINT '{TBLMARK}{tabla}{TBLMARK_FIN}';")
        lineas.append(f"{sql};")
        lineas.append("GO")
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".sql", delete=False, encoding="utf-8")
    tmp.write("\n".join(lineas) + "\n"); tmp.close()
    # -f 65001 → codepage UTF-8 de entrada/salida (SQL Server 2016+)
    cmd = ["sqlcmd", "-S", cfg["datasource"], "-d", cfg["schema"],
           "-i", tmp.name, "-h", "-1", "-W", "-y", "0", "-Y", "0", "-f", "65001"]
    entorno = os.environ
    if cfg["user"]:
        # Password por variable de entorno SQLCMDPASSWORD, no como -P en argv (visible en la lista de
        # procesos). Mismo patrón que la tool MCP db_query (rs-workspace-server.py).
        cmd += ["-U", cfg["user"]]
        entorno = {**os.environ, "SQLCMDPASSWORD": cfg["password"]}
    else:
        cmd += ["-E"]  # autenticación integrada
    try:
        r = subprocess.run(cmd, capture_output=True, env=entorno)  # bytes
    finally:
        os.unlink(tmp.name)
    out, err = _decode(r.stdout), _decode(r.stderr)
    if r.returncode != 0:
        raise RuntimeError(_mensaje_fallo(err, out))
    return out


def _mensaje_fallo(err: str, out: str) -> str:
    """Mensaje útil cuando el cliente SQL termina con exit code de fallo. La primera línea de
    stdout suele ser el banner ("SQL*Plus: Release 19.0.0.0.0 - Production"), que no dice nada
    y es lo que se reportaba antes: se prefiere la primera línea que parezca un error y, si no
    hay ninguna, la última con texto. Importa porque un fallo de proceso se atribuye a TODAS las
    tablas de la sesión, y un mensaje inútil multiplicado por 12 tablas no es diagnosticable."""
    for texto in (out, err):
        e = _find_error(texto or "")
        if e:
            return e
    for texto in (err, out):
        lineas = [l.strip() for l in (texto or "").splitlines() if l.strip()]
        if lineas:
            return lineas[-1][:300]
    return "el cliente SQL terminó con error y sin salida"


def _split_tables(out: str) -> tuple:
    """Trocea la salida de una sesión multi-tabla por el marcador `@@TBL:<TABLA>@@`.
    Devuelve `(preambulo, {TABLA: cuerpo})` — el preámbulo es lo emitido antes del primer
    marcador (salida del CONNECT / ALTER SESSION), donde aparece un fallo de conexión."""
    partes = out.split(TBLMARK)
    bloques = {}
    for p in partes[1:]:
        nombre, sep, cuerpo = p.partition(TBLMARK_FIN)
        if sep:
            bloques[nombre.strip().upper()] = cuerpo
    return partes[0], bloques


def _find_error(texto: str) -> str:
    """Primera línea de error del cliente SQL en un texto, o "" si no hay. Los clientes
    vuelcan los errores en stdout con returncode 0, así que esto es lo único que distingue
    una tabla que falló de una tabla vacía. En SQL Server el mensaje legible va en la línea
    siguiente al `Msg NNN, Level ...`, así que se adjunta."""
    lineas = texto.splitlines()
    for i, ln in enumerate(lineas):
        s = ln.strip()
        if s.startswith(ERR_PREFIXES):
            if s.startswith("Msg "):
                detalle = next((x.strip() for x in lineas[i + 1:] if x.strip()), "")
                return f"{s} {detalle}"[:300]
            return s[:300]
    return ""


def _split_rows(out: str) -> list:
    """Trocea la salida del cliente SQL en filas por el terminador ROWEND — NO por '\\n', porque
    un valor de texto puede contener saltos de línea (una fila de BD ocuparía varias líneas de
    salida y se perdería). El salto que el cliente intercala ENTRE filas se recorta de los extremos
    del trozo; los '\\n' internos de un valor quedan intactos dentro de su campo."""
    filas = []
    for trozo in out.split(ROWEND):
        trozo = trozo.strip("\r\n")
        if trozo.strip():
            filas.append(trozo)
    return filas


def format_value(raw: str, cdef: dict, motor: str) -> str:
    if raw == NULLTOK:
        return "NULL"
    bt = base_type(cdef.get("type"))
    if bt in BLOB_BASES:
        return "NULL"
    if bt in RAW_BASES:
        # El SELECT lo entrega en hexadecimal → reconstruir el binario en destino
        v = raw.strip()
        if not v:
            return "NULL"
        return f"HEXTORAW('{v}')" if motor == "ORACLE" else f"0x{v}"
    if bt in NUMERIC_BASES:
        v = raw.strip()
        return v if v else "NULL"
    # Texto/fecha → entrecomillar, doblando comillas simples
    return "'" + raw.replace("'", "''") + "'"


def write_table_file(table: str, columns: list, rows_raw: str, cfg: dict, out_dir: Path) -> tuple:
    """Formatea el bloque de salida ya obtenido de la BD y escribe `<TABLA>.sql`.
    No toca la BD: la consulta la hace run_chunk_* para todo el chunk de una vez."""
    col_names = [c for c, _ in columns]
    out_path = out_dir / f"{table}.sql"
    lines = [
        f"-- Inserts tabla paramétrica {table}",
        f"-- Generado: {datetime.now().strftime('%Y-%m-%d %H:%M')} | Motor: {cfg['motor']}",
    ]
    blob_cols = [c for c, d in columns if base_type(d.get("type")) in BLOB_BASES]
    if blob_cols:
        lines.append(f"-- AVISO: columnas binarias grandes emitidas como NULL (no inlineables): "
                     f"{', '.join(blob_cols)}")
    # Cabecera de sesión Oracle: SET DEFINE OFF evita que un '&' en los datos se interprete como
    # variable de sustitución de sqlplus; los NLS_*_FORMAT fijan el formato de fecha/timestamp para
    # que los literales importen igual en cualquier entorno (independiente del NLS del cliente).
    if cfg["motor"] == "ORACLE":
        lines.append("")
        lines.append("SET DEFINE OFF;")
        lines.append("ALTER SESSION SET NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS';")
        lines.append("ALTER SESSION SET NLS_TIMESTAMP_FORMAT='YYYY-MM-DD HH24:MI:SS';")
    lines.append("")
    n = 0
    cols_csv = ", ".join(col_names)
    for line in _split_rows(rows_raw):
        fields = line.split(DELIM)
        if len(fields) != len(columns):
            lines.append(f"-- AVISO fila omitida (nº campos {len(fields)} != {len(columns)}): {line[:120]}")
            continue
        # Revertir los tokens de salto de línea a saltos reales (el literal SQL queda multilínea)
        fields = [f.replace(CRTOK, "\r").replace(LFTOK, "\n") for f in fields]
        vals = [format_value(fields[i], columns[i][1], cfg["motor"]) for i in range(len(columns))]
        lines.append(f"INSERT INTO {table} ({cols_csv}) VALUES ({', '.join(vals)});")
        n += 1

    if n == 0:
        lines.append("-- (sin filas)")

    # commit final: sqlplus no auto-commitea — sin esto los inserts se perderían al cerrar sesión.
    if cfg["motor"] == "ORACLE":
        lines.append("")
        lines.append("commit;")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    # utf-8-sig (BOM): las herramientas gráficas Oracle (SQL Developer/TOAD/PL-SQL Developer)
    # detectan el BOM y leen el fichero como UTF-8; sin él asumen Windows-1252 y los acentos
    # salen como caracteres corruptos.
    with open(out_path, "w", encoding="utf-8-sig") as f:
        f.write("\n".join(lines) + "\n")
    return ("OK", n, "")


def split_chunks(tablas: list, workers: int) -> list:
    """Reparte las tablas en chunks (= sesiones SQL). Objetivo: el menor número de sesiones
    posible —cada una cuesta un spawn de proceso y un login— sin que un chunk crezca tanto que
    su salida en memoria se dispare. Con pocas tablas sale un chunk por worker; con muchas,
    chunks de CHUNK_MAX que el executor va encolando."""
    if not tablas:
        return []
    por_chunk = min(CHUNK_MAX, max(1, -(-len(tablas) // workers)))   # ceil sin importar math
    return [tablas[i:i + por_chunk] for i in range(0, len(tablas), por_chunk)]


def generar_chunk(chunk: list, model: dict, cfg: dict, out_dir: Path, force_clob: bool = False) -> tuple:
    """Genera los `<TABLA>.sql` de un chunk con UNA sola sesión SQL.
    Devuelve `({tabla: (status, filas, mensaje)}, segundos)`."""
    t0 = time.perf_counter()
    consultas = []
    columnas = {}
    for t in chunk:
        columnas[t] = list(model["tables"][t].get("columns", {}).items())
        consultas.append((t, build_select(t, columnas[t], cfg["schema"], cfg["motor"], force_clob)))

    try:
        if cfg["motor"] == "ORACLE":
            out = run_chunk_oracle(consultas, cfg)
        else:
            out = run_chunk_sqlserver(consultas, cfg)
    except Exception as e:
        msg = str(e).splitlines()[0] if str(e) else "error desconocido"
        return {t: ("ERROR", 0, msg) for t in chunk}, time.perf_counter() - t0

    preambulo, bloques = _split_tables(out)
    err_conexion = _find_error(preambulo)
    if err_conexion:
        # Fallo antes de la primera tabla (CONNECT / ALTER SESSION): es de toda la sesión, y
        # reportar la causa raíz vale más que el SP2-0640 "not connected" de cada SELECT.
        return {t: ("ERROR", 0, err_conexion) for t in chunk}, time.perf_counter() - t0

    resultados = {}
    for t in chunk:
        cuerpo = bloques.get(t.upper())
        if cuerpo is None:
            resultados[t] = ("ERROR", 0, "la sesión SQL no devolvió salida para esta tabla")
            continue
        err = _find_error(cuerpo)
        if err:
            resultados[t] = ("ERROR", 0, err)
            continue
        resultados[t] = write_table_file(t, columnas[t], cuerpo, cfg, out_dir)
    return resultados, time.perf_counter() - t0


def write_master_script(out_dir: Path, tables: list, motor: str, proyecto: str) -> Path:
    """Genera un script maestro `_run_all.sql` que ejecuta todos los <TABLA>.sql en orden, desde
    su misma carpeta. Fail-fast: si una tabla falla, aborta (no deja una carga a medias en silencio).
    Cada <TABLA>.sql es autónomo (trae su propia cabecera de sesión y su commit)."""
    ts = datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = [
        f"-- Master: ejecuta todos los inserts paramétricos de {proyecto}",
        f"-- Generado: {ts} | Motor: {motor} | {len(tables)} tablas",
    ]
    if motor == "ORACLE":
        lines += [
            "-- Uso: sqlplus <user>/<pass>@<db> @_run_all.sql   (ejecutar DESDE esta carpeta)",
            "WHENEVER SQLERROR EXIT SQL.SQLCODE",
            "SET DEFINE OFF",
            f"PROMPT === Inserts parametricos {proyecto} ({len(tables)} tablas) ===",
        ]
        for t in tables:
            lines.append(f"PROMPT -- {t}")
            lines.append(f"@@{t}.sql")      # @@ = ruta relativa al propio master
        lines.append("PROMPT === FIN ===")
    else:  # SQLSERVER
        lines += [
            "-- Uso: sqlcmd -S <server> -d <db> -i _run_all.sql   (ejecutar DESDE esta carpeta)",
            "-- Requiere sqlcmd (procesa :r y :on error); pegado tal cual en SSMS no funciona.",
            ":on error exit",
        ]
        for t in tables:
            lines.append(f"PRINT '-- {t}';")
            lines.append(f":r {t}.sql")     # :r = incluye el fichero
            lines.append("GO")
        lines.append("PRINT '=== FIN ===';")
        lines.append("GO")
    master_path = out_dir / "_run_all.sql"
    with open(master_path, "w", encoding="utf-8-sig") as f:
        f.write("\n".join(lines) + "\n")
    return master_path


def main():
    if len(sys.argv) < 4:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> <out_dir> [ORACLE|SQLSERVER] [--conexion <id>]")
        sys.exit(1)

    workspace = sys.argv[1]
    proyecto  = sys.argv[2]
    out_dir   = Path(sys.argv[3])
    conexion  = arg_conexion(sys.argv[4:])
    # El motor posicional es opcional y `--conexion` puede ocupar su sitio: solo se toma como
    # motor si no empieza por guion.
    motor_override = (sys.argv[4].upper()
                      if len(sys.argv) > 4 and not sys.argv[4].startswith("-") else "")

    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"
    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)
    with open(model_path, encoding="utf-8-sig") as f:
        model = json.load(f)

    cfg = read_db_config(workspace, model, conexion)
    if cfg.get("conexion"):
        print(f"Conexión: {cfg['conexion']}")
    if motor_override:
        cfg["motor"] = motor_override
    if cfg["motor"] not in ("ORACLE", "SQLSERVER"):
        print(f"ERROR: motor no soportado: {cfg['motor']}")
        sys.exit(1)

    t_total = time.perf_counter()
    tablas, vista, max_paralelo = parametric_tables(model, workspace, proyecto)

    # Regeneración selectiva (RS_INSERTS_TABLAS / -Tablas del hook): reprocesar solo unas
    # tablas concretas tras un error puntual, en vez de toda la etapa.
    subconjunto = [t.strip().upper() for t in os.environ.get("RS_INSERTS_TABLAS", "").split(";") if t.strip()]
    if subconjunto:
        desconocidas = [t for t in subconjunto if t not in tablas]
        for t in desconocidas:
            print(f"AVISO: '{t}' no es una tabla paramétrica de la vista '{vista}' — se ignora")
        tablas = [t for t in tablas if t in subconjunto]
        if not tablas:
            print("ERROR: ninguna de las tablas pedidas está en la vista paramétrica")
            sys.exit(1)

    workers = max(1, min(max_paralelo, len(tablas))) if tablas else 1
    chunks = split_chunks(tablas, workers)
    print(f"Vista paramétrica: '{vista}' → {len(tablas)} tablas | Motor: {cfg['motor']} | "
          f"{len(chunks)} sesión(es) SQL, {workers} en paralelo")
    out_dir.mkdir(parents=True, exist_ok=True)

    # Generación en paralelo por CHUNK: cada chunk abre UNA conexión y escribe los ficheros de
    # sus tablas (<TABLA>.sql), sin estado compartido mutable → thread-safe. El cap `workers`
    # limita las conexiones BD simultáneas. Los resultados se recolectan y se imprimen en orden
    # de `tablas` para una salida determinista, no entrelazada.
    resultados, tiempos = {}, {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(generar_chunk, ch, model, cfg, out_dir): i for i, ch in enumerate(chunks)}
        for fut in concurrent.futures.as_completed(futs):
            res, segs = fut.result()
            resultados.update(res)
            tiempos[futs[fut]] = segs

    # Reintento de las tablas cuya fila resultó más ancha de lo estimado: se rehacen forzando
    # TO_CLOB. Es la red de seguridad del camino VARCHAR2 de build_select.
    anchas = [t for t in tablas if resultados[t][0] == "ERROR" and "ORA-01489" in resultados[t][2]]
    if anchas:
        print(f"\nReintentando {len(anchas)} tabla(s) con TO_CLOB (fila más ancha de lo estimado): "
              f"{', '.join(anchas)}")
        rechunks = split_chunks(anchas, workers)
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(workers, len(rechunks)))) as ex:
            futs = [ex.submit(generar_chunk, ch, model, cfg, out_dir, True) for ch in rechunks]
            for fut in concurrent.futures.as_completed(futs):
                res, _ = fut.result()
                resultados.update(res)

    total_rows, errores = 0, []
    for t in tablas:
        status, n, msg = resultados[t]
        if status == "OK":
            total_rows += n
            print(f"  OK  {t}: {n} filas")
        else:
            errores.append((t, msg))
            print(f"  ERR {t}: {msg}")

    for i, ch in enumerate(chunks):
        print(f"  ~ sesión {i + 1}/{len(chunks)}: {len(ch)} tabla(s) en {tiempos.get(i, 0):.1f}s")
    print(f"\nResumen: {len(tablas) - len(errores)}/{len(tablas)} tablas OK, "
          f"{total_rows} filas, {len(errores)} errores en {time.perf_counter() - t_total:.1f}s")

    ok_tablas = [t for t in tablas if resultados[t][0] == "OK"]
    if subconjunto:
        # ⛔ El master lista TODAS las paramétricas: reescribirlo con un subconjunto dejaría el
        # instalador cargando solo esas tablas, en silencio.
        print("AVISO: regeneración selectiva — _run_all.sql se deja como estaba (lista completa)")
    elif ok_tablas:
        master = write_master_script(out_dir, ok_tablas, cfg["motor"], proyecto)
        print(f"Master: {master.name} → ejecuta las {len(ok_tablas)} tablas OK de golpe")

    if errores:
        # No abortar todo el instalador por una tabla; el hook decide con el exit code
        sys.exit(2)


if __name__ == "__main__":
    main()
