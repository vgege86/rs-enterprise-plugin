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

Uso: python installer-inserts.py <workspace> <proyecto> <out_dir> [ORACLE|SQLSERVER]
"""

import sys
import os
import json
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


def _read_password(workspace: str) -> str:
    """Mirror de _get_db_password del MCP: password directo de docs/.rs-databases.json
    (conexión principal, conexiones[0]). No pasar por get-config.ps1, que la omite deliberadamente.
    Normaliza el workspace igual que Resolve-RsWorkspace: si apunta a una subcarpeta
    docs/BD/Batch/OnLine, sube al trunk — si no, la password sale vacía."""
    ws = Path(workspace)
    if ws.name in ("docs", "BD", "Batch", "OnLine"):
        ws = ws.parent
    cfg_path = ws / "docs" / ".rs-databases.json"
    if not cfg_path.exists():
        return ""
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8-sig"))
        conexiones = cfg.get("conexiones") or []
        if not conexiones:
            return ""
        sel = conexiones[0]
        for part in str(sel.get("cadena", "")).split(";"):
            part = part.strip()
            if part.lower().startswith("password="):
                return part.split("=", 1)[1].strip()
    except Exception:
        pass
    return ""


def read_db_config(workspace: str, model: dict) -> dict:
    """Obtiene la config de conexión llamando a get-config.ps1 (el mismo parser que usa db_query),
    para tolerar dataSource en formato connection-string ODP.NET. El password se lee aparte
    (get-config.ps1 lo omite deliberadamente)."""
    hook = Path(__file__).resolve().parent.parent / "hooks" / "get-config.ps1"
    r = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
         "-File", str(hook), workspace],
        capture_output=True)
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
    password   = _read_password(workspace)

    if motor == "ORACLE" and not schema:
        schema = (model.get("schema") or user).upper()

    return {"motor": motor, "datasource": datasource, "schema": schema,
            "user": user, "password": password}


def parametric_tables(model: dict, workspace: str, proyecto: str) -> tuple:
    """Devuelve (lista_tablas, nombre_vista, max_paralelo) a partir de subviews + config del instalador."""
    vista = "Parametricas"
    excluir, incluir_extra = [], []
    max_paralelo = 8   # cap de tablas generadas en paralelo (= conexiones BD simultáneas)
    cfg_path = Path(workspace) / "docs" / f"{proyecto}-instalador.json"
    if cfg_path.exists():
        try:
            with open(cfg_path, encoding="utf-8-sig") as f:
                cfg = json.load(f)
            p = cfg.get("parametricas", {}) or {}
            vista = p.get("vista", vista)
            excluir = [t.upper() for t in p.get("excluir", [])]
            incluir_extra = p.get("incluir_extra", [])
            try:
                max_paralelo = max(1, int(p.get("max_paralelo", max_paralelo)))
            except (TypeError, ValueError):
                print(f"AVISO: parametricas.max_paralelo no es un entero — usando {max_paralelo}")
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


def build_select(table: str, columns: list, schema: str, motor: str) -> str:
    """SELECT con cada columna envuelta en CASE para detectar NULL y forzar texto.

    El SELECT se emite con una expresión POR LÍNEA: sqlplus corta la entrada por longitud
    de línea y una concatenación de 30+ columnas en una sola línea revienta con SP2-0341.
    La primera expresión va envuelta en TO_CLOB para que toda la concatenación sea CLOB
    (VARCHAR2 se queda en 4000 y da ORA-01489 en tablas anchas).
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


def run_query_oracle(sql: str, cfg: dict) -> list:
    connect = f"CONNECT {cfg['user']}/{cfg['password']}@{cfg['datasource']}\n" if cfg['password'] else ""
    conn_arg = "/nolog" if cfg['password'] else f"{cfg['user']}/@{cfg['datasource']}"
    schema_line = (f"ALTER SESSION SET CURRENT_SCHEMA = {cfg['schema']};\n"
                   if cfg['schema'] and cfg['schema'] != cfg['user'] else "")
    script = (
        "SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON TERMOUT ON\n"
        "SET LINESIZE 32767 LONG 60000 LONGCHUNKSIZE 60000 WRAP OFF\n"
        f"{connect}{schema_line}{sql};\nEXIT;\n"
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
        raise RuntimeError((err or out).strip())
    # sqlplus vuelca errores ORA-/SP2- en stdout aun con returncode 0
    for ln in out.splitlines():
        if ln.startswith("ORA-") or ln.startswith("SP2-"):
            raise RuntimeError(ln.strip())
    return out   # texto completo; el troceado en filas lo hace _split_rows (por ROWEND, no por \n)


def run_query_sqlserver(sql: str, cfg: dict) -> list:
    full = f"SET NOCOUNT ON; {sql}"
    # -f 65001 → codepage UTF-8 de entrada/salida (SQL Server 2016+)
    cmd = ["sqlcmd", "-S", cfg["datasource"], "-d", cfg["schema"],
           "-Q", full, "-h", "-1", "-W", "-y", "0", "-Y", "0", "-f", "65001"]
    if cfg["user"]:
        cmd += ["-U", cfg["user"], "-P", cfg["password"]]
    else:
        cmd += ["-E"]  # autenticación integrada
    r = subprocess.run(cmd, capture_output=True, env=os.environ)  # bytes
    out, err = _decode(r.stdout), _decode(r.stderr)
    if r.returncode != 0:
        raise RuntimeError((err or out).strip())
    return out   # texto completo; el troceado en filas lo hace _split_rows (por ROWEND, no por \n)


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


def generate_table_file(table: str, model: dict, cfg: dict, out_dir: Path) -> tuple:
    columns = list(model["tables"][table].get("columns", {}).items())
    col_names = [c for c, _ in columns]
    sql = build_select(table, columns, cfg["schema"], cfg["motor"])

    try:
        if cfg["motor"] == "ORACLE":
            rows_raw = run_query_oracle(sql, cfg)
        else:
            rows_raw = run_query_sqlserver(sql, cfg)
    except Exception as e:
        return ("ERROR", 0, str(e).splitlines()[0] if str(e) else "error desconocido")

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


def main():
    if len(sys.argv) < 4:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> <out_dir> [ORACLE|SQLSERVER]")
        sys.exit(1)

    workspace = sys.argv[1]
    proyecto  = sys.argv[2]
    out_dir   = Path(sys.argv[3])
    motor_override = sys.argv[4].upper() if len(sys.argv) > 4 else ""

    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"
    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)
    with open(model_path, encoding="utf-8-sig") as f:
        model = json.load(f)

    cfg = read_db_config(workspace, model)
    if motor_override:
        cfg["motor"] = motor_override
    if cfg["motor"] not in ("ORACLE", "SQLSERVER"):
        print(f"ERROR: motor no soportado: {cfg['motor']}")
        sys.exit(1)

    tablas, vista, max_paralelo = parametric_tables(model, workspace, proyecto)
    workers = max(1, min(max_paralelo, len(tablas))) if tablas else 1
    print(f"Vista paramétrica: '{vista}' → {len(tablas)} tablas | Motor: {cfg['motor']} | {workers} en paralelo")
    out_dir.mkdir(parents=True, exist_ok=True)

    # Generación en paralelo: cada tabla abre su propia conexión y escribe un fichero distinto
    # (<TABLA>.sql), sin estado compartido mutable → thread-safe. El cap `workers` limita las
    # conexiones BD simultáneas. Los resultados se recolectan y se imprimen en orden de `tablas`
    # para una salida determinista, no entrelazada.
    resultados = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(generate_table_file, t, model, cfg, out_dir): t for t in tablas}
        for fut in concurrent.futures.as_completed(futs):
            resultados[futs[fut]] = fut.result()

    total_rows, errores = 0, []
    for t in tablas:
        status, n, msg = resultados[t]
        if status == "OK":
            total_rows += n
            print(f"  OK  {t}: {n} filas")
        else:
            errores.append((t, msg))
            print(f"  ERR {t}: {msg}")

    print(f"\nResumen: {len(tablas) - len(errores)}/{len(tablas)} tablas OK, "
          f"{total_rows} filas, {len(errores)} errores")
    if errores:
        # No abortar todo el instalador por una tabla; el hook decide con el exit code
        sys.exit(2)


if __name__ == "__main__":
    main()
