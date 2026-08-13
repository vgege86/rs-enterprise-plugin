"""Ejecución de SQL contra la BD viva y parseo de su salida — fuente única.

Vivía dentro de `installer-objects.py`, que era su único consumidor. Al añadir
`installer-tablas.py` —que extrae de la BD lo que antes salía del `model.json`— pasaron a ser
dos, y duplicar esto es exactamente lo que ya hizo divergir el mapeo de tipos entre
`generate-sql.py` e `installer-ddl.py` (las copias se separaron en `RAW` y hubo que unificarlas
en `_dbtypes.py`). Aquí el riesgo es peor: lo que se duplicaría no es una tabla de conversión
sino la detección de errores, y una copia que se olvide de mirar la salida convierte un fallo
de consulta en un fichero vacío que nadie cuestiona.

⛔ NINGUNA LECTURA SE DA POR BUENA SIN MIRARLA. `run_sqlplus` y `run_sqlcmd` revientan si el
cliente devolvió código distinto de 0 **o** si la salida trae una línea de diagnóstico. Es el
equivalente Python de `Assert-RsLecturaBd` (hooks/sync-from-db.ps1) y existe por el mismo caso
real: una consulta rechazada no devuelve filas, y sin comprobarlo "cero filas" se lee como
"este esquema no tiene nada" en vez de como "no se ha podido leer".

POR QUÉ NO SE USA DBMS_METADATA.GET_DDL — La cuenta de entrega no tiene SELECT_CATALOG_ROLE:
cualquier GET_DDL sobre objetos de otro schema devuelve ORA-31603 "object not found". Todo el
DDL se reconstruye desde el diccionario ALL_*, que sí es legible con GRANT SELECT.
"""

import os
import re
import subprocess
import tempfile
import importlib.util
from pathlib import Path

# Lectura de config/credenciales: mismo parser que `db_query`. El módulo tiene guion en el
# nombre -> no es importable con `import`; se carga por ruta.
_INS_PATH = Path(__file__).resolve().parent / "installer-inserts.py"
_spec = importlib.util.spec_from_file_location("_installer_inserts", _INS_PATH)
_ins = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_ins)

# Delimitadores de bloque. Viajan DENTRO del result set, nunca por un canal aparte.
OBJ_MARK = "##OBJ##"
END_MARK = "##END##"

# Diagnóstico anclado a principio de línea. Anclarlo importa: un 'ORA-' dentro de un dato o de
# un comentario del propio DDL no es un error, y tratarlo como tal abortaría extracciones
# buenas.
_DIAG_ORACLE = re.compile(r"^(?:ORA-\d{3,6}|SP2-\d{3,6}|PLS-\d{3,6})\b")
_DIAG_SQLSERVER = re.compile(r"^(?:Msg\s+\d+,\s*Level|Sqlcmd:)")


def assert_sin_diagnostico(salida: str, motor: str) -> None:
    """Aborta si la salida del cliente trae una línea de error del motor.

    Se separa de los `run_*` para poder aplicarla también a una salida ya capturada, y para
    que el criterio de "qué es un error" tenga un solo sitio donde cambiar.
    """
    patron = _DIAG_SQLSERVER if motor == "SQLSERVER" else _DIAG_ORACLE
    for ln in salida.splitlines():
        s = ln.strip()
        if patron.match(s):
            raise RuntimeError(s[:300])


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
    assert_sin_diagnostico(out, "ORACLE")
    # El fuente almacenado trae CRLF y sqlplus vuelve a convertir el LF en CRLF: cada
    # salto acaba como '\r\r\n' y splitlines() lo cuenta como DOS líneas, metiendo una
    # línea en blanco entre cada par. No es cosmético: una línea en blanco dentro de un
    # CREATE TRIGGER/VIEW hace que sqlplus dé por terminada la sentencia (SP2-0042).
    return out.replace("\r\r\n", "\n")


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
    assert_sin_diagnostico(out, "SQLSERVER")
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


def parse_filas(out: str, ncampos: int) -> list:
    """Filas '##OBJ##campo|campo|...' -> [[campo, ...]], descartando lo que no cuadre.

    Los campos van pegados al marcador porque una consulta de diccionario devuelve MUCHAS
    filas y abrir/cerrar bloque por cada una multiplicaría por tres el tamaño de la salida.
    El marcador sigue haciendo falta: sqlplus intercala banners, líneas en blanco y avisos, y
    sin él habría que adivinar qué línea es un dato.

    ⛔ `ncampos` es un contrato, no una comodidad: una fila con menos campos de los esperados
    significa que algo se truncó (LINESIZE, un salto dentro de un valor), y colarla produciría
    una columna sin tipo o un índice sin columnas. Se devuelven solo las filas completas y el
    llamante contrasta el total contra el diccionario.
    """
    filas = []
    for ln in out.splitlines():
        s = ln.strip()
        if not s.startswith(OBJ_MARK):
            continue
        campos = s[len(OBJ_MARK):].split("|")
        if len(campos) < ncampos:
            continue
        # El último campo absorbe los '|' sobrantes: un DEFAULT o un CHECK pueden contener el
        # separador, y partirlos ahí destrozaría la expresión.
        if len(campos) > ncampos:
            campos = campos[:ncampos - 1] + ["|".join(campos[ncampos - 1:])]
        filas.append([c.strip() for c in campos])
    return filas


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
