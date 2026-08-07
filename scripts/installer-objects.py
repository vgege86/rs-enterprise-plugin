"""
Extrae de la BD viva el DDL de los objetos que NO están en el model.json y que hacen falta
para una instalación limpia, además de las tablas/índices (que genera installer-ddl.py):

    SECUENCIAS · VISTAS · FUNCIONES · PROCEDIMIENTOS (y PACKAGES) · TRIGGERS · SINÓNIMOS

Genera un fichero por tipo en <out_dir> y un maestro que los encadena en ORDEN DE
DEPENDENCIAS:

    <proyecto>-01-Secuencias.sql
    <proyecto>-02-Vistas.sql
    <proyecto>-03-Funciones.sql
    <proyecto>-04-Procedimientos.sql
    <proyecto>-05-Triggers.sql
    <proyecto>-06-Sinonimos.sql
    <proyecto>-CreacionObjetos.sql   (maestro: secuencias → tablas+índices → vistas →
                                      funciones → procedimientos → triggers → sinónimos)

MOTORES
    ORACLE     diccionario ALL_* (ver más abajo).
    SQLSERVER  catálogo sys.* — `sys.sql_modules.definition` ya trae el CREATE completo, así
               que no hay que reconstruir nada: solo se antepone un DROP condicional y se
               separa en lotes con GO (CREATE VIEW/FUNCTION/PROCEDURE/TRIGGER tienen que ser
               la primera sentencia de su lote). Se usa DROP + CREATE y no CREATE OR ALTER
               porque CREATE OR ALTER es de SQL Server 2016 SP1 en adelante y el parque de
               clientes no está garantizado ahí.

POR QUÉ NO SE USA DBMS_METADATA.GET_DDL
    El usuario de consulta del proyecto no tiene SELECT_CATALOG_ROLE: cualquier
    GET_DDL sobre objetos de otro schema devuelve ORA-31603 "object not found".
    El DDL se reconstruye por tanto desde el diccionario ALL_* (ALL_SEQUENCES,
    ALL_VIEWS, ALL_SOURCE, ALL_TRIGGERS, ALL_SYNONYMS).

LONG vs CLOB
    ALL_VIEWS.TEXT y ALL_TRIGGERS.DESCRIPTION/TRIGGER_BODY son LONG: no se pueden
    manipular en SQL (ni TO_CLOB, ni SUBSTR, ni concatenar). Se leen desde un bloque
    PL/SQL anónimo a variables LONG (hasta 32760 bytes) y se emiten con DBMS_OUTPUT,
    delimitados por marcadores ##OBJ##/##END## que este script parsea.

SIN schema
    Igual que installer-ddl.py, se elimina el prefijo de schema (`<ESQUEMA>.` y
    `"<ESQUEMA>".`) de todo el DDL emitido: el instalador se ejecuta ya dentro del
    schema destino del cliente.

RENDIMIENTO
    Los 6 tipos de objeto son independientes entre sí y cada uno escribe su propio fichero,
    así que se extraen EN PARALELO: en serie se pagaban 6 spawns de sqlplus + 6 logins uno
    detrás de otro, y el reloj lo dominaba eso, no la consulta. El cap de sesiones simultáneas
    es el mismo `parametricas.max_paralelo` del JSON de config que usan los inserts — una sola
    palanca para el Oracle del cliente. Las consultas van en paralelo pero la escritura de
    ficheros y todo el log se hacen después, en el orden de las etapas: la salida sigue siendo
    determinista y comparable entre ejecuciones.

Uso: python installer-objects.py <workspace> <proyecto> <out_dir>
"""

import sys
import os
import re
import json
import time
import subprocess
import tempfile
import importlib.util
import concurrent.futures
from pathlib import Path
from datetime import datetime

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# Reutiliza la lectura de config/credenciales de installer-inserts.py (mismo parser que db_query).
# El módulo tiene guion en el nombre -> no es importable con `import`; se carga por ruta.
_INS_PATH = Path(__file__).resolve().parent / "installer-inserts.py"
_spec = importlib.util.spec_from_file_location("_installer_inserts", _INS_PATH)
_ins = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_ins)

OBJ_MARK = "##OBJ##"
END_MARK = "##END##"

# Secuencias creadas por Oracle para columnas IDENTITY: no se scriptan (las crea el
# CREATE TABLE de la columna identity; scriptarlas da ORA-32794 al borrar/recrear).
IDENTITY_SEQ_RE = re.compile(r"^ISEQ\$\$_", re.IGNORECASE)


# ---------------------------------------------------------------- ejecución sqlplus
def run_sqlplus(cfg: dict, body: str) -> str:
    """Ejecuta un script sqlplus TAL CUAL (no añade ';' — el body trae sus propios
    terminadores, incluido '/' para los bloques PL/SQL)."""
    connect = f"CONNECT {cfg['user']}/{cfg['password']}@{cfg['datasource']}\n" if cfg["password"] else ""
    conn_arg = "/nolog" if cfg["password"] else f"{cfg['user']}/@{cfg['datasource']}"
    schema_line = (f"ALTER SESSION SET CURRENT_SCHEMA = {cfg['schema']};\n"
                   if cfg["schema"] and cfg["schema"] != cfg["user"] else "")
    script = (
        "SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON TRIMOUT ON TERMOUT ON VERIFY OFF\n"
        "SET LINESIZE 32767 LONG 2000000 LONGCHUNKSIZE 2000000 WRAP ON\n"
        "SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED\n"
        "SET SQLBLANKLINES ON\n"
        f"{connect}{schema_line}{body}\nEXIT;\n"
    )
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".sql", delete=False, encoding="utf-8")
    tmp.write(script)
    tmp.close()
    env = dict(os.environ, NLS_LANG="AMERICAN_AMERICA.AL32UTF8")
    try:
        r = subprocess.run(["sqlplus", "-S", conn_arg, f"@{tmp.name}"], capture_output=True, env=env)
    finally:
        os.unlink(tmp.name)
    out, err = _ins._decode(r.stdout), _ins._decode(r.stderr)
    if r.returncode != 0:
        # Mismo criterio que los inserts: la 1ª línea de stdout es el banner de sqlplus, no el error
        raise RuntimeError(_ins._mensaje_fallo(err, out))
    for ln in out.splitlines():
        s = ln.strip()
        if s.startswith("ORA-") or s.startswith("SP2-") or s.startswith("PLS-"):
            raise RuntimeError(s[:300])
    # El fuente almacenado trae CRLF y sqlplus vuelve a convertir el LF en CRLF: cada
    # salto acaba como '\r\r\n' y splitlines() lo cuenta como DOS líneas, metiendo una
    # línea en blanco entre cada par. No es cosmético: una línea en blanco dentro de un
    # CREATE TRIGGER/VIEW hace que sqlplus dé por terminada la sentencia (SP2-0042).
    return out.replace("\r\r\n", "\n")


# ---------------------------------------------------------------- ejecución sqlcmd
def run_sqlcmd(cfg: dict, body: str) -> str:
    """Ejecuta un script sqlcmd y devuelve su salida.

    ⛔ Los marcadores viajan DENTRO del propio result set (concatenados en el SELECT), nunca
    con PRINT: dentro de un lote el flujo de mensajes y el de resultados no llegan
    necesariamente intercalados en orden, y el marcador dejaría de identificar su objeto.
    Es el mismo motivo por el que installer-inserts.py mete un GO por tabla."""
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".sql", delete=False, encoding="utf-8")
    tmp.write("SET NOCOUNT ON;\nGO\n" + body + "\nGO\n")
    tmp.close()
    # -y 0 / -Y 0: sin esto sqlcmd trunca la columna al ancho de pantalla y las definiciones
    # largas llegarían cortadas — un CREATE PROCEDURE partido por la mitad.
    cmd = ["sqlcmd", "-S", cfg["datasource"], "-d", cfg["schema"], "-i", tmp.name,
           "-h", "-1", "-W", "-y", "0", "-Y", "0", "-w", "65535", "-f", "65001"]
    entorno = os.environ
    if cfg["user"]:
        cmd += ["-U", cfg["user"]]
        entorno = {**os.environ, "SQLCMDPASSWORD": cfg["password"]}
    else:
        cmd += ["-E"]   # autenticación integrada
    try:
        r = subprocess.run(cmd, capture_output=True, env=entorno)
    finally:
        os.unlink(tmp.name)
    out, err = _ins._decode(r.stdout), _ins._decode(r.stderr)
    if r.returncode != 0:
        raise RuntimeError(_ins._mensaje_fallo(err, out))
    for ln in out.splitlines():
        s = ln.strip()
        if re.match(r"^Msg\s+\d+,\s*Level", s) or s.startswith("Sqlcmd:"):
            raise RuntimeError(s[:300])
    return out.replace("\r\n", "\n")


def parse_blocks(out: str) -> list:
    """Parsea la salida marcada: [(nombre, [líneas]), ...]"""
    bloques, nombre, buf = [], None, []
    for ln in out.splitlines():
        s = ln.strip()
        if s.startswith(OBJ_MARK):
            if nombre is not None:
                bloques.append((nombre, buf))
            nombre, buf = s[len(OBJ_MARK):].strip(), []
        elif s == END_MARK:
            if nombre is not None:
                bloques.append((nombre, buf))
            nombre, buf = None, []
        elif nombre is not None:
            buf.append(ln.rstrip())
    if nombre is not None:
        bloques.append((nombre, buf))
    return bloques


# ---------------------------------------------------------------- limpieza de schema
def strip_schema(texto: str, schema: str) -> tuple:
    """Quita el prefijo de schema (con y sin comillas). Devuelve (texto, nº sustituciones)."""
    if not schema:
        return texto, 0
    n = 0
    pat_q = re.compile(r'"%s"\s*\.\s*' % re.escape(schema), re.IGNORECASE)
    texto, k = pat_q.subn("", texto)
    n += k
    pat = re.compile(r'\b%s\s*\.\s*' % re.escape(schema), re.IGNORECASE)
    texto, k = pat.subn("", texto)
    n += k
    return texto, n


def cab(titulo: str, proyecto: str, motor: str, extra: list = None) -> list:
    origen = ("Extraído de la BD viva (diccionario ALL_*), SIN schema."
              if motor == "ORACLE" else
              "Extraído de la BD viva (catálogo sys.*), con su schema (dbo) — en SQL Server el"
              " schema del objeto es estable y lo que se selecciona es la base de datos.")
    l = [
        "-- ============================================================",
        f"-- {titulo} — instalación limpia de {proyecto}",
        f"-- Motor: {motor} | Generado: {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        f"-- {origen}",
    ]
    if extra:
        l += [f"-- {e}" for e in extra]
    l += [
        "-- ============================================================",
        "",
    ]
    if motor == "ORACLE":
        # ⛔ Directivas de sqlplus: en un fichero que va a correr sqlcmd son error de sintaxis.
        l += [
            "-- DEFINE OFF: un '&' dentro de un literal del DDL no debe tomarse por variable de sustitución.",
            "SET DEFINE OFF",
            "-- SQLBLANKLINES ON: hay cuerpos PL/SQL con líneas en blanco intencionadas.",
            "SET SQLBLANKLINES ON",
            "",
        ]
    return l


# ---------------------------------------------------------------- SECUENCIAS
def gen_secuencias(cfg: dict) -> tuple:
    S = cfg["schema"]
    sql = f"""SELECT '{OBJ_MARK}'||SEQUENCE_NAME||CHR(10)
       ||'CREATE SEQUENCE '||SEQUENCE_NAME
       ||' MINVALUE '||MIN_VALUE
       ||CASE WHEN MAX_VALUE >= 9999999999999999999999999999 THEN ' NOMAXVALUE'
              ELSE ' MAXVALUE '||MAX_VALUE END
       ||' START WITH '||LAST_NUMBER
       ||' INCREMENT BY '||INCREMENT_BY
       ||CASE WHEN CACHE_SIZE = 0 THEN ' NOCACHE' ELSE ' CACHE '||CACHE_SIZE END
       ||CASE WHEN CYCLE_FLAG = 'Y' THEN ' CYCLE' ELSE ' NOCYCLE' END
       ||CASE WHEN ORDER_FLAG = 'Y' THEN ' ORDER' ELSE ' NOORDER' END
       ||';'||CHR(10)||'{END_MARK}'
  FROM ALL_SEQUENCES
 WHERE SEQUENCE_OWNER = '{S}'
   AND SEQUENCE_NAME NOT LIKE 'ISEQ$$%'
 ORDER BY SEQUENCE_NAME;
"""
    out = run_sqlplus(cfg, sql)
    bloques = parse_blocks(out)
    lines, nombres = [], []
    for nombre, buf in bloques:
        if IDENTITY_SEQ_RE.match(nombre):
            continue
        nombres.append(nombre)
        lines.append(f"-- Secuencia {nombre}")
        lines.extend(buf)
        lines.append("")
    return lines, nombres, 0


# ---------------------------------------------------------------- VISTAS
def gen_vistas(cfg: dict) -> tuple:
    """CREATE OR REPLACE FORCE VIEW: FORCE evita que el orden entre vistas que se
    referencian entre sí rompa la instalación (se recompilan solas al final)."""
    S = cfg["schema"]
    blk = f"""DECLARE
  l_txt LONG;
BEGIN
  FOR r IN (SELECT VIEW_NAME FROM ALL_VIEWS WHERE OWNER='{S}' ORDER BY VIEW_NAME) LOOP
    SELECT TEXT INTO l_txt FROM ALL_VIEWS WHERE OWNER='{S}' AND VIEW_NAME=r.VIEW_NAME;
    DBMS_OUTPUT.PUT_LINE('{OBJ_MARK}'||r.VIEW_NAME);
    DBMS_OUTPUT.PUT_LINE('CREATE OR REPLACE FORCE VIEW '||r.VIEW_NAME||' AS');
    FOR i IN 1 .. CEIL(LENGTH(l_txt)/3000) LOOP
      DBMS_OUTPUT.PUT_LINE(SUBSTR(l_txt, (i-1)*3000+1, 3000));
    END LOOP;
    DBMS_OUTPUT.PUT_LINE(';');
    DBMS_OUTPUT.PUT_LINE('{END_MARK}');
  END LOOP;
END;
/
"""
    out = run_sqlplus(cfg, blk)
    bloques = parse_blocks(out)
    lines, nombres, nstrip = [], [], 0
    for nombre, buf in bloques:
        nombres.append(nombre)
        txt, k = strip_schema("\n".join(buf), S)
        nstrip += k
        lines.append(f"-- Vista {nombre}")
        lines.append(txt)
        lines.append("")
    return lines, nombres, nstrip


# ---------------------------------------------------------------- PL/SQL (ALL_SOURCE)
def gen_source(cfg: dict, tipos: list) -> tuple:
    """FUNCTION / PROCEDURE / PACKAGE / PACKAGE BODY desde ALL_SOURCE (TEXT es VARCHAR2)."""
    S = cfg["schema"]
    in_tipos = ", ".join(f"'{t}'" for t in tipos)
    sql = f"""SELECT CASE WHEN LINE = 1 THEN '{OBJ_MARK}'||TYPE||' '||NAME||CHR(10)||'CREATE OR REPLACE '||RTRIM(TEXT, CHR(10))
                 ELSE RTRIM(TEXT, CHR(10)) END
  FROM ALL_SOURCE
 WHERE OWNER = '{S}' AND TYPE IN ({in_tipos})
 ORDER BY TYPE, NAME, LINE;
"""
    out = run_sqlplus(cfg, sql)
    # Sin END_MARK por línea: cada nuevo OBJ_MARK cierra el anterior (parse_blocks lo maneja)
    bloques = parse_blocks(out)
    lines, nombres, nstrip = [], [], 0
    for nombre, buf in bloques:
        nombres.append(nombre)
        txt, k = strip_schema("\n".join(buf), S)
        nstrip += k
        lines.append(f"-- {nombre}")
        lines.append(txt.rstrip())
        lines.append("/")
        lines.append("")
    return lines, nombres, nstrip


# ---------------------------------------------------------------- TRIGGERS
def gen_triggers(cfg: dict) -> tuple:
    S = cfg["schema"]
    blk = f"""DECLARE
  l_desc LONG; l_body LONG; l_status VARCHAR2(30);
BEGIN
  FOR r IN (SELECT TRIGGER_NAME FROM ALL_TRIGGERS WHERE OWNER='{S}' ORDER BY TRIGGER_NAME) LOOP
    SELECT DESCRIPTION, TRIGGER_BODY, STATUS INTO l_desc, l_body, l_status
      FROM ALL_TRIGGERS WHERE OWNER='{S}' AND TRIGGER_NAME=r.TRIGGER_NAME;
    DBMS_OUTPUT.PUT_LINE('{OBJ_MARK}'||r.TRIGGER_NAME||'|'||l_status);
    DBMS_OUTPUT.PUT_LINE('CREATE OR REPLACE TRIGGER '||RTRIM(l_desc, CHR(10)||CHR(32)));
    FOR i IN 1 .. CEIL(LENGTH(l_body)/3000) LOOP
      DBMS_OUTPUT.PUT_LINE(SUBSTR(l_body, (i-1)*3000+1, 3000));
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('{END_MARK}');
  END LOOP;
END;
/
"""
    out = run_sqlplus(cfg, blk)
    bloques = parse_blocks(out)
    lines, nombres, nstrip, disabled = [], [], 0, []
    for cabecera, buf in bloques:
        nombre, _, status = cabecera.partition("|")
        nombres.append(nombre)
        txt, k = strip_schema("\n".join(buf), S)
        nstrip += k
        lines.append(f"-- Trigger {nombre}")
        lines.append(txt.rstrip())
        lines.append("/")
        # El estado real en origen se preserva: un trigger DISABLED que se instale
        # habilitado cambia el comportamiento de la aplicación en el cliente.
        if status.strip().upper() == "DISABLED":
            disabled.append(nombre)
            lines.append(f"ALTER TRIGGER {nombre} DISABLE;")
        lines.append("")
    return lines, nombres, nstrip, disabled


# ---------------------------------------------------------------- SINÓNIMOS
def gen_sinonimos(cfg: dict) -> tuple:
    """Sinónimos del schema + sinónimos PUBLIC que apuntan a objetos del schema."""
    S = cfg["schema"]
    sql = f"""SELECT '{OBJ_MARK}'||OWNER||'.'||SYNONYM_NAME||CHR(10)
       ||'CREATE OR REPLACE '||CASE WHEN OWNER='PUBLIC' THEN 'PUBLIC ' END||'SYNONYM '||SYNONYM_NAME
       ||' FOR '||TABLE_NAME||CASE WHEN DB_LINK IS NOT NULL THEN '@'||DB_LINK END||';'
       ||CHR(10)||'{END_MARK}'
  FROM ALL_SYNONYMS
 WHERE OWNER = '{S}'
    OR (OWNER = 'PUBLIC' AND TABLE_OWNER = '{S}')
 ORDER BY OWNER, SYNONYM_NAME;
"""
    out = run_sqlplus(cfg, sql)
    bloques = parse_blocks(out)
    lines, nombres = [], []
    for nombre, buf in bloques:
        nombres.append(nombre)
        txt, _ = strip_schema("\n".join(buf), S)
        lines.append(txt)
        lines.append("")
    return lines, nombres, 0


# ================================================================ SQL SERVER
# El DDL no se reconstruye: sys.sql_modules.definition ya trae el CREATE literal. Lo único
# que se añade es un DROP condicional delante y los GO que separan lotes.
#
# ⛔ A diferencia de Oracle, aquí NO se quita el prefijo de schema: en SQL Server el schema
# del objeto (dbo casi siempre) es estable entre origen y destino y forma parte del nombre
# real. Lo que se selecciona en el cliente es la BASE DE DATOS (sqlcmd -d), no el schema.

def _ss_nombre(alias_schema: str, alias_obj: str) -> str:
    """Fragmento T-SQL: QUOTENAME(schema) + '.' + QUOTENAME(objeto)."""
    return f"QUOTENAME({alias_schema}) + '.' + QUOTENAME({alias_obj})"


def _ss_drop(alias_schema: str, alias_obj: str, palabra: str) -> str:
    """Fragmento T-SQL que produce `IF OBJECT_ID(N'esq.obj') IS NOT NULL DROP <palabra> [esq].[obj];`"""
    return ("'IF OBJECT_ID(N''' + " + alias_schema + " + '.' + " + alias_obj +
            f" + ''') IS NOT NULL DROP {palabra} ' + " + _ss_nombre(alias_schema, alias_obj) + " + ';'")


def ss_modulos(cfg: dict, tipos: list, palabra_drop: str) -> tuple:
    """Vistas / funciones / procedimientos: todo sale de sys.sql_modules."""
    in_tipos = ", ".join(f"'{t}'" for t in tipos)
    sql = f"""SELECT '{OBJ_MARK}' + s.name + '.' + o.name + CHAR(10)
     + {_ss_drop('s.name', 'o.name', palabra_drop)} + CHAR(10)
     + 'GO' + CHAR(10)
     + m.definition + CHAR(10)
     + 'GO' + CHAR(10)
     + '{END_MARK}'
FROM sys.sql_modules m
JOIN sys.objects o ON o.object_id = m.object_id
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type IN ({in_tipos}) AND o.is_ms_shipped = 0
ORDER BY s.name, o.name;"""
    out = run_sqlcmd(cfg, sql)
    lines, nombres = [], []
    for nombre, buf in parse_blocks(out):
        nombres.append(nombre)
        lines.append(f"-- {nombre}")
        lines.append("\n".join(buf).rstrip())
        lines.append("")
    return lines, nombres, 0


def ss_secuencias(cfg: dict) -> tuple:
    sql = f"""SELECT '{OBJ_MARK}' + s.name + '.' + q.name + CHAR(10)
     + {_ss_drop('s.name', 'q.name', 'SEQUENCE')} + CHAR(10)
     + 'CREATE SEQUENCE ' + {_ss_nombre('s.name', 'q.name')}
     + ' AS ' + t.name
     + ' START WITH ' + CONVERT(varchar(40), q.current_value)
     + ' INCREMENT BY ' + CONVERT(varchar(40), q.increment)
     + CASE WHEN q.minimum_value IS NULL THEN ' NO MINVALUE'
            ELSE ' MINVALUE ' + CONVERT(varchar(40), q.minimum_value) END
     + CASE WHEN q.maximum_value IS NULL THEN ' NO MAXVALUE'
            ELSE ' MAXVALUE ' + CONVERT(varchar(40), q.maximum_value) END
     + CASE WHEN q.is_cycling = 1 THEN ' CYCLE' ELSE ' NO CYCLE' END
     + CASE WHEN q.is_cached  = 1 THEN ' CACHE' ELSE ' NO CACHE' END
     + ';' + CHAR(10)
     + 'GO' + CHAR(10)
     + '{END_MARK}'
FROM sys.sequences q
JOIN sys.schemas s ON s.schema_id = q.schema_id
JOIN sys.types   t ON t.user_type_id = q.user_type_id
ORDER BY s.name, q.name;"""
    out = run_sqlcmd(cfg, sql)
    lines, nombres = [], []
    for nombre, buf in parse_blocks(out):
        nombres.append(nombre)
        lines.append(f"-- Secuencia {nombre}")
        lines.extend(buf)
        lines.append("")
    return lines, nombres, 0


def ss_triggers(cfg: dict) -> tuple:
    """Triggers DML (parent_class = 1). El estado DISABLED del origen se replica: un trigger
    deshabilitado que se instale activo cambia el comportamiento de la aplicación en el cliente."""
    nombre_tr  = _ss_nombre('s.name', 'tr.name')
    nombre_tab = _ss_nombre('s.name', 'o.name')
    sql = f"""SELECT '{OBJ_MARK}' + s.name + '.' + tr.name + '|'
     + CASE WHEN tr.is_disabled = 1 THEN 'DISABLED' ELSE 'ENABLED' END + CHAR(10)
     + {_ss_drop('s.name', 'tr.name', 'TRIGGER')} + CHAR(10)
     + 'GO' + CHAR(10)
     + m.definition + CHAR(10)
     + 'GO' + CHAR(10)
     + CASE WHEN tr.is_disabled = 1
            THEN 'DISABLE TRIGGER ' + {nombre_tr} + ' ON ' + {nombre_tab} + ';' + CHAR(10) + 'GO' + CHAR(10)
            ELSE '' END
     + '{END_MARK}'
FROM sys.triggers tr
JOIN sys.sql_modules m ON m.object_id = tr.object_id
JOIN sys.objects     o ON o.object_id = tr.parent_id
JOIN sys.schemas     s ON s.schema_id = o.schema_id
WHERE tr.is_ms_shipped = 0 AND tr.parent_class = 1
ORDER BY s.name, tr.name;"""
    out = run_sqlcmd(cfg, sql)
    lines, nombres, disabled = [], [], []
    for cabecera, buf in parse_blocks(out):
        nombre, _, status = cabecera.partition("|")
        nombres.append(nombre)
        if status.strip().upper() == "DISABLED":
            disabled.append(nombre)
        lines.append(f"-- Trigger {nombre}")
        lines.append("\n".join(buf).rstrip())
        lines.append("")
    return lines, nombres, 0, disabled


def ss_sinonimos(cfg: dict) -> tuple:
    sql = f"""SELECT '{OBJ_MARK}' + s.name + '.' + sy.name + CHAR(10)
     + {_ss_drop('s.name', 'sy.name', 'SYNONYM')} + CHAR(10)
     + 'CREATE SYNONYM ' + {_ss_nombre('s.name', 'sy.name')} + ' FOR ' + sy.base_object_name + ';' + CHAR(10)
     + 'GO' + CHAR(10)
     + '{END_MARK}'
FROM sys.synonyms sy
JOIN sys.schemas s ON s.schema_id = sy.schema_id
ORDER BY s.name, sy.name;"""
    out = run_sqlcmd(cfg, sql)
    lines, nombres = [], []
    for nombre, buf in parse_blocks(out):
        nombres.append(nombre)
        lines.extend(buf)
        lines.append("")
    return lines, nombres, 0


# ---------------------------------------------------------------- etapas por motor
def etapas_por_motor(cfg: dict) -> list:
    """(numero, nombre_fichero, titulo, extractor) — mismo orden de dependencias en los dos
    motores, para que el maestro y el manifiesto del paquete no dependan del motor."""
    if cfg["motor"] == "ORACLE":
        return [
            ("01", "Secuencias",     "SECUENCIAS",     lambda: gen_secuencias(cfg)),
            ("02", "Vistas",         "VISTAS",         lambda: gen_vistas(cfg)),
            ("03", "Funciones",      "FUNCIONES",      lambda: gen_source(cfg, ["FUNCTION"])),
            ("04", "Procedimientos", "PROCEDIMIENTOS", lambda: gen_source(cfg, ["PROCEDURE", "PACKAGE", "PACKAGE BODY"])),
            ("05", "Triggers",       "TRIGGERS",       lambda: gen_triggers(cfg)),
            ("06", "Sinonimos",      "SINÓNIMOS",      lambda: gen_sinonimos(cfg)),
        ]
    return [
        ("01", "Secuencias",     "SECUENCIAS",     lambda: ss_secuencias(cfg)),
        ("02", "Vistas",         "VISTAS",         lambda: ss_modulos(cfg, ["V"], "VIEW")),
        # FN escalar, IF inline-table, TF table-valued, FS/FT ensambladas (CLR)
        ("03", "Funciones",      "FUNCIONES",      lambda: ss_modulos(cfg, ["FN", "IF", "TF", "FS", "FT"], "FUNCTION")),
        ("04", "Procedimientos", "PROCEDIMIENTOS", lambda: ss_modulos(cfg, ["P", "PC"], "PROCEDURE")),
        ("05", "Triggers",       "TRIGGERS",       lambda: ss_triggers(cfg)),
        ("06", "Sinonimos",      "SINÓNIMOS",      lambda: ss_sinonimos(cfg)),
    ]


# ---------------------------------------------------------------- main
def main():
    if len(sys.argv) < 4:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> <out_dir>")
        sys.exit(1)

    workspace, proyecto, out_dir = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"
    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)
    with open(model_path, encoding="utf-8-sig") as f:
        model = json.load(f)

    cfg = _ins.read_db_config(workspace, model)
    if cfg["motor"] not in ("ORACLE", "SQLSERVER"):
        print(f"ERROR: motor no soportado para la extracción de objetos: {cfg['motor']}")
        sys.exit(1)

    out_dir.mkdir(parents=True, exist_ok=True)
    if cfg["motor"] == "ORACLE":
        print(f"Schema origen: {cfg['schema']} | usuario: {cfg['user']}")
        print("Fuente: diccionario ALL_* (DBMS_METADATA.GET_DDL no disponible: sin SELECT_CATALOG_ROLE)")
    else:
        print(f"Base de datos origen: {cfg['schema']} | usuario: {cfg['user'] or '(autenticación integrada)'}")
        print("Fuente: catálogo sys.* (sys.sql_modules trae el CREATE literal)")

    resumen, errores = [], []

    etapas = etapas_por_motor(cfg)

    # --- extracción en paralelo (una sesión sqlplus por tipo de objeto) ---
    workers = max(1, min(len(etapas), _ins.read_max_paralelo(workspace, proyecto)))
    print(f"Extracción: {len(etapas)} tipos de objeto, hasta {workers} sesión(es) sqlplus en paralelo")
    t_total = time.perf_counter()

    def _extraer(etapa):
        """Solo consulta — no escribe ficheros ni imprime (eso va después, en orden)."""
        t0 = time.perf_counter()
        try:
            return etapa[0], etapa[3](), "", time.perf_counter() - t0
        except Exception as e:
            return etapa[0], None, (str(e).splitlines()[0] if str(e) else "error desconocido"), \
                   time.perf_counter() - t0

    salidas = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for fut in concurrent.futures.as_completed([ex.submit(_extraer, e) for e in etapas]):
            num, res, err, segs = fut.result()
            salidas[num] = (res, err, segs)

    ficheros = []
    for num, fname, titulo, fn in etapas:
        res, err, segs = salidas[num]
        print(f"\n== {titulo} == ({segs:.1f}s)")
        if res is None:
            print(f"   ERROR: {err}")
            errores.append((titulo, err))
            resumen.append((titulo, "ERROR"))
            continue

        disabled = []
        if len(res) == 4:
            lines, nombres, nstrip, disabled = res
        else:
            lines, nombres, nstrip = res

        extra = []
        if nstrip:
            extra.append(f"{nstrip} referencias a schema '{cfg['schema']}' eliminadas del DDL")
        if disabled:
            extra.append(f"DISABLED en origen (se replica con ALTER TRIGGER ... DISABLE): {', '.join(disabled)}")
        if not nombres:
            extra.append("No se encontró ningún objeto de este tipo en el schema origen.")

        out_path = out_dir / f"{proyecto}-{num}-{fname}.sql"
        contenido = cab(titulo, proyecto, cfg["motor"], extra) + lines
        out_path.write_text("\n".join(contenido) + "\n", encoding="utf-8")
        ficheros.append(out_path.name)
        print(f"   {len(nombres)} objeto(s) → {out_path.name}")
        for n in nombres[:5]:
            print(f"     - {n}")
        if len(nombres) > 5:
            print(f"     ... y {len(nombres) - 5} más")
        resumen.append((titulo, len(nombres)))

    # ---- maestro en orden de dependencias ----
    # ⛔ Es una AYUDA para lanzarlo a mano desde sqlplus/sqlcmd, NO lo que ejecuta el paquete:
    # Ejecutar-Scripts.ps1 va por el manifiesto Scripts\scripts.json, que lista los ficheros
    # uno a uno. Si el maestro se ejecutara además, cada objeto se crearía dos veces.
    orden = [f"{proyecto}-01-Secuencias.sql",
             f"{proyecto}-CreacionTablas.sql",
             f"{proyecto}-02-Vistas.sql",
             f"{proyecto}-03-Funciones.sql",
             f"{proyecto}-04-Procedimientos.sql",
             f"{proyecto}-05-Triggers.sql",
             f"{proyecto}-06-Sinonimos.sql"]

    maestro = out_dir / f"{proyecto}-CreacionObjetos.sql"
    ml = [
        "-- ============================================================",
        f"-- {proyecto} — INSTALACIÓN LIMPIA: creación completa de objetos",
        f"-- Generado: {datetime.now().strftime('%Y-%m-%d %H:%M')} | Motor: {cfg['motor']}",
        "-- Orden de dependencias: secuencias → tablas+índices → vistas →",
        "--                        funciones → procedimientos → triggers → sinónimos",
        "--",
        "-- ⛔ NO lo ejecuta Ejecutar-Scripts.ps1 (lo excluye el manifiesto scripts.json, que",
        "--    lanza estos mismos ficheros uno a uno). Está aquí para poder lanzar la creación",
        "--    completa a mano desde una sola sesión.",
        "-- ============================================================",
        "",
    ]
    if cfg["motor"] == "ORACLE":
        ml += [
            "-- Ejecutar CONECTADO AL SCHEMA DESTINO (el DDL va sin calificar).",
            "SET DEFINE OFF",
            "SET SQLBLANKLINES ON",
            "",
        ] + [f"@@{f}" for f in orden]
    else:
        # sqlcmd incluye con ':r', no con '@@' — y necesita un GO tras cada fichero para
        # cerrar el lote antes de que el siguiente abra con su CREATE.
        ml += [
            "-- Ejecutar con: sqlcmd -S <servidor> -d <base de datos> -i este-fichero.sql",
            ":setvar SQLCMDERRORLEVEL 1",
            "",
        ]
        for f in orden:
            ml += [f":r {f}", "GO"]
    ml += [
        "",
        "-- Datos paramétricos: ejecutar después los ficheros de Inserts\\",
        "",
    ]
    maestro.write_text("\n".join(ml), encoding="utf-8")

    print("\n---- Resumen objetos (conteo real en BD) ----")
    for titulo, n in resumen:
        print(f"   {titulo:<16} {n}")
    print(f"   Maestro: {maestro.name}")
    print(f"   Tiempo:  {time.perf_counter() - t_total:.1f}s")

    if errores:
        sys.exit(2)


if __name__ == "__main__":
    main()
