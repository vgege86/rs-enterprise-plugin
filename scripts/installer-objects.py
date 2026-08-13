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

# Inventario del modelo: para CONTRASTAR lo extraído contra lo que el modelo dice que hay.
# El paquete se sigue generando de la BD viva —esa es la garantía de que no entrega código
# viejo—; el contraste solo delata deriva, no cambia lo que viaja.
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
import _dbobjetos as _inv

OBJ_MARK = "##OBJ##"
END_MARK = "##END##"

# Secuencias creadas por Oracle para columnas IDENTITY: no se scriptan (las crea el
# CREATE TABLE de la columna identity; scriptarlas da ORA-32794 al borrar/recrear).
# El `_` no es obligatorio (Oracle nombra ISEQ$$_<id>, pero el filtro SQL usa ISEQ$$%): se
# aceptan las dos formas para que el regex y la WHERE no puedan discrepar entre sí.
IDENTITY_SEQ_RE = re.compile(r"^ISEQ\$\$", re.IGNORECASE)

# Objetos del recycle bin (DROP sin PURGE). ALL_OBJECTS SÍ los cuenta, así que sin excluirlos
# explícitamente el contraste con el diccionario los lee como objetos perdidos.
RECYCLE_RE = re.compile(r"^BIN\$", re.IGNORECASE)

# Infraestructura del PAQUETE, no del proyecto: la tabla RVERSIONES, su secuencia y su índice
# los crea 00-RVERSIONES.sql, que va el PRIMERO del manifiesto y está guardado con
# IF NOT EXISTS. Pero esos objetos existen también en la BD de desarrollo —es donde se
# registran las entregas—, así que la extracción los capturaba como objetos del proyecto y el
# paquete los traía DOS veces: sobre un esquema vacío y recién creado, 00-RVERSIONES.sql creaba
# SEQ_RVERSIONES y acto seguido 01-Secuencias.sql intentaba crearla otra vez -> ORA-00955. El
# error parecía "la BD del cliente ya tenía objetos" y era el paquete chocando consigo mismo.
# Se excluyen DECLARÁNDOLO (no en silencio), para que el contraste de cobertura no lo lea como
# una pérdida de objetos.
INFRA_PAQUETE_RE = re.compile(r"^(RVERSIONES|SEQ_RVERSIONES|IX_RVERSIONES_ENT_SOL|PK_RVERSIONES)$",
                              re.IGNORECASE)

# (número, fichero, título) de las seis etapas. Idénticos en los dos motores por diseño — ver
# etapas_por_motor —, así que viven aquí para que el contraste de cobertura pueda resolver la
# sección del modelo sin necesitar la config de BD.
ETAPAS_NOMBRES = [
    ("01", "Secuencias",     "SECUENCIAS"),
    ("02", "Vistas",         "VISTAS"),
    ("03", "Funciones",      "FUNCIONES"),
    ("04", "Procedimientos", "PROCEDIMIENTOS"),
    ("05", "Triggers",       "TRIGGERS"),
    ("06", "Sinonimos",      "SINÓNIMOS"),
]


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


def cab(titulo: str, proyecto: str, motor: str, extra: list = None,
        contexto: str = "instalación limpia") -> list:
    origen = ("Extraído de la BD viva (diccionario ALL_*), SIN schema."
              if motor == "ORACLE" else
              "Extraído de la BD viva (catálogo sys.*), con su schema (dbo) — en SQL Server el"
              " schema del objeto es estable y lo que se selecciona es la base de datos.")
    l = [
        "-- ============================================================",
        f"-- {titulo} — {contexto} de {proyecto}",
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


# ---------------------------------------------------------------- render de un objeto
# Etiqueta del comentario que precede a cada objeto en el .sql. Las secciones que no están
# (funciones, procedimientos, paquetes) ya llevan el tipo dentro del propio nombre —Oracle lo
# antepone en ALL_SOURCE— y repetirlo daría "-- Procedimiento PROCEDURE X".
_ETIQUETA = {"secuencias": "Secuencia", "vistas": "Vista", "triggers": "Trigger"}
_PLSQL = ("funciones", "procedimientos", "paquetes", "triggers")


def render_objeto(seccion: str, nombre: str, cuerpo: str, motor: str, disabled: bool = False) -> list:
    """Las líneas .sql de UN objeto: comentario, cuerpo y el terminador que le corresponda.

    Es el ÚNICO sitio donde se decide cómo se escribe un objeto en un .sql. Lo usan los
    extractores de aquí (instalación limpia) y `delta-objects.py` (entrega de lo que cambió):
    si cada uno lo maquetara por su cuenta, un script del actualizador podría quedarse sin el
    '/' que cierra un bloque PL/SQL y fallar solo en el cliente.

    El '/' es de sqlplus: en SQL Server los cuerpos ya vienen con sus propios GO desde el
    catálogo, y el `DISABLE TRIGGER` también (lo emite `ss_triggers` dentro del bloque).
    """
    lines = []
    if seccion != "sinonimos":
        etq = _ETIQUETA.get(seccion)
        lines.append(f"-- {etq} {nombre}" if etq else f"-- {nombre}")
    lines.append((cuerpo or "").rstrip())
    if motor == "ORACLE":
        if seccion in _PLSQL:
            lines.append("/")
        # El estado real en origen se preserva: un trigger DISABLED que se instale
        # habilitado cambia el comportamiento de la aplicación en el cliente.
        if seccion == "triggers" and disabled:
            lines.append(f"ALTER TRIGGER {nombre} DISABLE;")
    lines.append("")
    return lines


# ---------------------------------------------------------------- contrato de los extractores
def _resultado(lines, nombres, nstrip=0, disabled=None, bloques=None, excluido=None):
    """Lo que devuelve cada extractor.

    ⛔ Antes eran tuplas de 3 o 4 elementos y `main` adivinaba la forma con `len(res)`. Añadir
    un campo por esa vía es pedir un desempaquetado silenciosamente equivocado, así que el
    contrato pasa a ser un dict con nombres.

    `bloques` es {nombre visible: texto del objeto} — el MISMO texto que acaba en el .sql. Lo
    consume scripts/model-objects.py para firmarlo: que la firma se calcule sobre lo que
    entregaría el instalador, y no sobre otra lectura de la BD, es lo que hace que un cambio
    de firma signifique exactamente "lo que se entregaría ha cambiado".

    `excluido` es {"n": <cuántos>, "motivo": "<por qué>", "nombres": [...]} — lo que el
    extractor descarta A PROPÓSITO. Va en el contrato porque el contraste con el diccionario no
    puede distinguir una exclusión deliberada de una pérdida: sin declararla, una secuencia de
    columna IDENTITY que nunca debió scriptarse aparece como un objeto perdido y la cobertura
    cría un aviso permanente que nadie vuelve a mirar.
    """
    return {"lines": lines, "nombres": nombres, "nstrip": nstrip,
            "disabled": disabled or [], "bloques": bloques or {},
            "excluido": excluido or {"n": 0, "motivo": "", "nombres": []}}


def exclusiones_cobertura(salidas: dict) -> dict:
    """{sección del modelo: {"n": k, "motivo": "..."}} a partir de lo que devolvieron los
    extractores. Lo consumen `_dbobjetos.cobertura` y `scripts/model-objects.py`.

    `salidas` puede venir indexada por número de etapa ("01".."06") —como en el `main` de este
    script— o por nombre de fichero —como en model-objects.py—; se acepta cualquiera de las dos
    porque la sección se resuelve por el nombre de fichero de la etapa, no por la clave.
    """
    res = {}
    for num, fichero, _titulo in ETAPAS_NOMBRES:
        entrada = salidas.get(num, salidas.get(fichero))
        if isinstance(entrada, tuple):
            entrada = entrada[0]
        if not entrada:
            continue
        exc = entrada.get("excluido") or {}
        if not exc.get("n"):
            continue
        seccion = _inv.ETAPA_A_SECCION.get(fichero)
        if seccion:
            res[seccion] = {"n": exc["n"], "motivo": exc.get("motivo", "")}
    return res


# ---------------------------------------------------------------- SECUENCIAS
def gen_secuencias(cfg: dict) -> tuple:
    """Secuencias del esquema, sin las que Oracle crea solo.

    ⛔ TODO atributo va envuelto en NVL. En Oracle, un solo operando NULL anula la cadena `||`
    entera: la fila sale NULL, el marcador nunca se emite y la secuencia DESAPARECE del paquete
    sin error, sin aviso y sin dejar rastro en el conteo. Es un modo de fallo silencioso que
    solo se nota contando contra ALL_OBJECTS — que es exactamente cómo apareció (17 scriptadas
    frente a 18 en el diccionario, en una instalación de cliente). Los defaults elegidos son
    los de un CREATE SEQUENCE sin cláusulas.

    Las exclusiones se DECLARAN (`excluido`) en vez de descartarse en silencio: si no, el
    contraste con el diccionario las cuenta como pérdida y el aviso pasa a ser permanente.
    """
    S = cfg["schema"]
    sql = f"""SELECT '{OBJ_MARK}'||SEQUENCE_NAME||CHR(10)
       ||'CREATE SEQUENCE '||SEQUENCE_NAME
       ||' MINVALUE '||NVL(TO_CHAR(MIN_VALUE), '1')
       ||CASE WHEN NVL(MAX_VALUE, 0) >= 9999999999999999999999999999 THEN ' NOMAXVALUE'
              ELSE ' MAXVALUE '||NVL(TO_CHAR(MAX_VALUE), '9999999999999999999999999999') END
       ||' START WITH '||NVL(TO_CHAR(LAST_NUMBER), '1')
       ||' INCREMENT BY '||NVL(TO_CHAR(INCREMENT_BY), '1')
       ||CASE WHEN NVL(CACHE_SIZE, 0) = 0 THEN ' NOCACHE' ELSE ' CACHE '||CACHE_SIZE END
       ||CASE WHEN NVL(CYCLE_FLAG, 'N') = 'Y' THEN ' CYCLE' ELSE ' NOCYCLE' END
       ||CASE WHEN NVL(ORDER_FLAG, 'N') = 'Y' THEN ' ORDER' ELSE ' NOORDER' END
       ||';'||CHR(10)||'{END_MARK}'
  FROM ALL_SEQUENCES
 WHERE SEQUENCE_OWNER = '{S}'
 ORDER BY SEQUENCE_NAME;
"""
    out = run_sqlplus(cfg, sql)
    bloques = parse_blocks(out)
    lines, nombres, cuerpos = [], [], {}
    excluidas = []
    for nombre, buf in bloques:
        # El filtro ya no está en la WHERE: así el conteo de bloques leídos es el del
        # diccionario y la diferencia es atribuible, en vez de un descuadre sin explicación.
        if IDENTITY_SEQ_RE.match(nombre):
            excluidas.append((nombre, "columna IDENTITY"))
            continue
        if RECYCLE_RE.match(nombre):
            excluidas.append((nombre, "recycle bin"))
            continue
        if INFRA_PAQUETE_RE.match(nombre):
            excluidas.append((nombre, "infraestructura del paquete (la crea 00-RVERSIONES.sql)"))
            continue
        nombres.append(nombre)
        cuerpos[nombre] = "\n".join(buf).strip()
        lines.extend(render_objeto("secuencias", nombre, cuerpos[nombre], cfg["motor"]))

    exc = None
    if excluidas:
        motivos = sorted({m for _n, m in excluidas})
        exc = {"n": len(excluidas), "motivo": " / ".join(motivos),
               "nombres": [n for n, _m in excluidas]}
    return _resultado(lines, nombres, bloques=cuerpos, excluido=exc)


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
    lines, nombres, nstrip, cuerpos = [], [], 0, {}
    for nombre, buf in bloques:
        nombres.append(nombre)
        txt, k = strip_schema("\n".join(buf), S)
        nstrip += k
        cuerpos[nombre] = txt.strip()
        lines.extend(render_objeto("vistas", nombre, cuerpos[nombre], cfg["motor"]))
    return _resultado(lines, nombres, nstrip, bloques=cuerpos)


# ---------------------------------------------------------------- PL/SQL (ALL_SOURCE)
def gen_source(cfg: dict, tipos: list, seccion: str = "procedimientos") -> tuple:
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
    lines, nombres, nstrip, cuerpos = [], [], 0, {}
    for nombre, buf in bloques:
        nombres.append(nombre)
        txt, k = strip_schema("\n".join(buf), S)
        nstrip += k
        cuerpos[nombre] = txt.strip()
        lines.extend(render_objeto(seccion, nombre, cuerpos[nombre], cfg["motor"]))
    return _resultado(lines, nombres, nstrip, bloques=cuerpos)


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
    lines, nombres, nstrip, disabled, cuerpos = [], [], 0, [], {}
    for cabecera, buf in bloques:
        nombre, _, status = cabecera.partition("|")
        nombres.append(nombre)
        txt, k = strip_schema("\n".join(buf), S)
        nstrip += k
        cuerpos[nombre] = txt.strip()
        off = status.strip().upper() == "DISABLED"
        if off:
            disabled.append(nombre)
        lines.extend(render_objeto("triggers", nombre, cuerpos[nombre], cfg["motor"], off))
    return _resultado(lines, nombres, nstrip, disabled, cuerpos)


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
    lines, nombres, cuerpos = [], [], {}
    for nombre, buf in bloques:
        nombres.append(nombre)
        txt, _ = strip_schema("\n".join(buf), S)
        cuerpos[nombre] = txt.strip()
        lines.extend(render_objeto("sinonimos", nombre, cuerpos[nombre], cfg["motor"]))
    return _resultado(lines, nombres, bloques=cuerpos)


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


def ss_modulos(cfg: dict, tipos: list, palabra_drop: str, seccion: str = "procedimientos") -> tuple:
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
    lines, nombres, cuerpos = [], [], {}
    for nombre, buf in parse_blocks(out):
        nombres.append(nombre)
        cuerpos[nombre] = "\n".join(buf).strip()
        lines.extend(render_objeto(seccion, nombre, cuerpos[nombre], cfg["motor"]))
    return _resultado(lines, nombres, bloques=cuerpos)


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
    lines, nombres, cuerpos = [], [], {}
    for nombre, buf in parse_blocks(out):
        nombres.append(nombre)
        cuerpos[nombre] = "\n".join(buf).strip()
        lines.extend(render_objeto("secuencias", nombre, cuerpos[nombre], cfg["motor"]))
    return _resultado(lines, nombres, bloques=cuerpos)


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
    lines, nombres, disabled, cuerpos = [], [], [], {}
    for cabecera, buf in parse_blocks(out):
        nombre, _, status = cabecera.partition("|")
        nombres.append(nombre)
        cuerpos[nombre] = "\n".join(buf).strip()
        off = status.strip().upper() == "DISABLED"
        if off:
            disabled.append(nombre)
        lines.extend(render_objeto("triggers", nombre, cuerpos[nombre], cfg["motor"], off))
    return _resultado(lines, nombres, disabled=disabled, bloques=cuerpos)


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
    lines, nombres, cuerpos = [], [], {}
    for nombre, buf in parse_blocks(out):
        nombres.append(nombre)
        cuerpos[nombre] = "\n".join(buf).strip()
        lines.extend(render_objeto("sinonimos", nombre, cuerpos[nombre], cfg["motor"]))
    return _resultado(lines, nombres, bloques=cuerpos)


# ---------------------------------------------------------------- etapas por motor
def etapas_por_motor(cfg: dict) -> list:
    """(numero, nombre_fichero, titulo, extractor) — mismo orden de dependencias en los dos
    motores, para que el maestro y el manifiesto del paquete no dependan del motor.

    Los tres primeros campos salen de ETAPAS_NOMBRES: aquí solo se elige el extractor. Así el
    contraste de cobertura puede resolver la sección del modelo sin config de BD, y no hay dos
    listas de etapas que puedan desalinearse."""
    if cfg["motor"] == "ORACLE":
        extractores = [
            lambda: gen_secuencias(cfg),
            lambda: gen_vistas(cfg),
            lambda: gen_source(cfg, ["FUNCTION"], "funciones"),
            lambda: gen_source(cfg, ["PROCEDURE", "PACKAGE", "PACKAGE BODY"], "procedimientos"),
            lambda: gen_triggers(cfg),
            lambda: gen_sinonimos(cfg),
        ]
    else:
        extractores = [
            lambda: ss_secuencias(cfg),
            lambda: ss_modulos(cfg, ["V"], "VIEW", "vistas"),
            # FN escalar, IF inline-table, TF table-valued, FS/FT ensambladas (CLR)
            lambda: ss_modulos(cfg, ["FN", "IF", "TF", "FS", "FT"], "FUNCTION", "funciones"),
            lambda: ss_modulos(cfg, ["P", "PC"], "PROCEDURE", "procedimientos"),
            lambda: ss_triggers(cfg),
            lambda: ss_sinonimos(cfg),
        ]
    return [(n, f, t, fn) for (n, f, t), fn in zip(ETAPAS_NOMBRES, extractores)]


# ---------------------------------------------------------------- main
def main():
    if len(sys.argv) < 4:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> <out_dir> [--conexion <id>] [--sin-plsql]")
        sys.exit(1)

    workspace, proyecto, out_dir = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    conexion   = _ins.arg_conexion(sys.argv[4:])
    sin_plsql  = "--sin-plsql" in sys.argv[4:]
    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"
    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)
    with open(model_path, encoding="utf-8-sig") as f:
        model = json.load(f)

    cfg = _ins.read_db_config(workspace, model, conexion)
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
    if cfg.get("conexion"):
        print(f"Conexión: {cfg['conexion']}")

    # ---- GATE: ¿esta cuenta puede ver el PL/SQL siquiera? ----
    # ⛔ Error DURO, no aviso. El PL/SQL de ALL_SOURCE exige GRANT EXECUTE, no SELECT. Con cero
    # grants EXECUTE, ALL_OBJECTS y ALL_SOURCE devuelven CERO procedimientos y CERO paquetes SIN
    # ERROR: el instalador generaba el paquete completo, con sus ficheros de procedimientos
    # vacíos, y lo daba por bueno. Un cliente recibía una instalación limpia sin nada de lógica
    # de servidor y el fallo aparecía en producción, no aquí. Se comprueba ANTES de extraer para
    # no gastar seis sesiones de BD en un paquete que no se va a poder entregar.
    visibilidad = _ins.read_visibilidad(workspace, conexion)
    if visibilidad.get("soportado") and not visibilidad.get("es_dueno"):
        grants = visibilidad.get("grants") or {}
        if not grants.get("EXECUTE"):
            if sin_plsql:
                print("AVISO: 0 grants EXECUTE sobre el esquema. Se continúa por --sin-plsql:")
                print("       el paquete saldrá SIN procedimientos ni paquetes, a propósito.")
            else:
                print(f"ERROR: la cuenta '{visibilidad.get('usuario')}' no es dueña de "
                      f"'{visibilidad.get('esquema')}' y NO tiene ningún GRANT EXECUTE sobre él.")
                print("       Funciones, procedimientos y paquetes saldrían VACÍOS sin dar ningún")
                print("       error: ALL_SOURCE devuelve cero filas por falta de privilegio, no")
                print("       porque no existan. El paquete resultante no sería instalable.")
                print("       Salidas, en orden de preferencia:")
                print("         1. Conceder GRANT EXECUTE sobre los objetos PL/SQL del esquema.")
                print("         2. Repetir con --conexion <id de la conexión dueña del esquema>.")
                print("         3. Si el esquema DE VERDAD no tiene PL/SQL, repetir con --sin-plsql.")
                sys.exit(1)
    elif visibilidad.get("error"):
        print(f"AVISO: no se pudo comprobar la visibilidad del esquema ({visibilidad['error']}).")
        print("       Un fichero de procedimientos vacío puede significar 'sin permiso', no 'no hay'.")

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

        lines    = res["lines"]
        nombres  = res["nombres"]
        nstrip   = res["nstrip"]
        disabled = res["disabled"]

        excluido = res.get("excluido") or {}

        extra = []
        if nstrip:
            extra.append(f"{nstrip} referencias a schema '{cfg['schema']}' eliminadas del DDL")
        if disabled:
            extra.append(f"DISABLED en origen (se replica con ALTER TRIGGER ... DISABLE): {', '.join(disabled)}")
        if excluido.get("n"):
            extra.append(f"{excluido['n']} excluido(s) a propósito ({excluido['motivo']}): "
                         f"{', '.join(excluido.get('nombres') or [])}")
        if not nombres:
            # ⛔ "No se encontró" es una afirmación que esta cuenta no siempre puede hacer.
            extra.append("Ningún objeto de este tipo VISIBLE para esta cuenta en el schema origen."
                         if not visibilidad.get("es_dueno") else
                         "No hay ningún objeto de este tipo en el schema origen.")

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

    # ---- contraste contra el inventario del modelo ----
    # Un objeto que está en la BD y no en el modelo casi siempre significa que alguien lo creó
    # a mano y nadie lo sabe. Uno cuya firma cambió es un cambio que va a viajar al cliente sin
    # que figure en ninguna tarea. Ninguna de las dos cosas bloquea la entrega —el paquete es
    # correcto— pero las dos hay que verlas antes de entregar.
    inventario_modelo = model.get("objetos") or {}
    if inventario_modelo:
        # ⛔ `salidas` va indexada por el NUMERO de etapa ("01".."06"), no por el nombre de
        # fichero. Indexarla por el nombre devolvia siempre None y el contraste habria dado
        # todo el inventario por eliminado, que es justo la alarma falsa que nadie vuelve a mirar.
        # Se reindexa por fichero porque es lo que espera el constructor compartido, el MISMO
        # que usa el sync del modelo: si el contraste construyera el inventario por su cuenta,
        # compararia dos cosas que no se construyen igual.
        por_fichero = {}
        for num, fichero, _t, _fn in etapas:
            res = (salidas.get(num) or (None, None, 0))[0]
            if res:
                por_fichero[fichero] = res
        actual = _inv.construir(por_fichero)

        cambios = _inv.comparar(inventario_modelo, actual)
        if cambios:
            print("\n---- Deriva entre el modelo y la BD ----")
            for sec, c in cambios.items():
                for etiqueta, texto in (("nuevos", "en BD y NO en el modelo"),
                                        ("eliminados", "en el modelo y NO en BD"),
                                        ("modificados", "firma distinta")):
                    if c[etiqueta]:
                        print(f"   {sec:<15} {texto:<24} {', '.join(c[etiqueta][:6])}"
                              f"{' ...' if len(c[etiqueta]) > 6 else ''}")
            print("   El paquete se genera de la BD viva, así que es correcto. Pero conviene")
            print("   resincronizar el modelo (hooks\\sync-model-objects.ps1) y revisar la lista.")
        else:
            print("\nModelo y BD coinciden: sin deriva en el inventario de objetos.")

    # ---- cobertura: lo capturado frente a lo que el diccionario dice que hay ----
    # Es lo que convierte "17 secuencias" en una cifra comprobable. Sin este contraste, un
    # descuadre con ALL_OBJECTS solo se veía contando a mano y sin poder atribuir la causa.
    cobertura = None
    if visibilidad.get("soportado"):
        capturado = {}
        for num, fichero, _t, _fn in etapas:
            seccion = _inv.ETAPA_A_SECCION.get(fichero)
            res = (salidas.get(num) or (None, None, 0))[0]
            if seccion and res:
                capturado[seccion] = len(res["nombres"])
        cobertura = _inv.cobertura(visibilidad, capturado, exclusiones_cobertura(salidas))
        print()
        for ln in _inv.formato_cobertura(cobertura):
            print(ln)

    print("\n---- Resumen objetos (conteo capturado) ----")
    for titulo, n in resumen:
        print(f"   {titulo:<16} {n}")
    print(f"   Maestro: {maestro.name}")
    print(f"   Tiempo:  {time.perf_counter() - t_total:.1f}s")

    # exit 2 = PARCIAL: el paquete está generado y es correcto con lo que se pudo leer, pero no
    # está completo. El hook llamante lo convierte en un aviso visible, no en un éxito.
    if errores or (cobertura and cobertura.get("parcial")):
        sys.exit(2)


if __name__ == "__main__":
    main()
