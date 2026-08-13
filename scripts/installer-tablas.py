"""
DDL de tablas del instalador de cliente, extraído de la BD VIVA.

    TABLAS · COLUMNAS (tipo y tamaño exactos) · NOT NULL · DEFAULT · IDENTITY
    PK · UNIQUE · CHECK · ÍNDICES · FOREIGN KEY

Sustituye a `installer-ddl.py`, que generaba este mismo fichero a partir de
`BD/<proyecto>-model.json`.

⛔ POR QUÉ CAMBIÓ LA FUENTE

    La traducción BD -> model.json es LOSSY, y el modelo se queda desfasado. Medido en una
    entrega real: 12 FK -> 0, 3 CHECK -> 0, 1 IDENTITY -> una columna NUMBER pelada,
    22 DEFAULT -> 21, y cuatro columnas con el tamaño de hace meses (una VARCHAR2(51) que el
    modelo declaraba (10) habría dado ORA-12899 con los datos reales del cliente).

    Ninguna de esas pérdidas da error al generar. Todas dan error —o algo peor que un error—
    en el servidor del cliente. Y el modelo no puede arreglarse "sincronizándolo mejor": el
    problema no es que esté mal sincronizado hoy, es que puede estarlo cualquier día y nada lo
    delata. La BD, en cambio, ES lo que hay.

    El modelo sigue manteniéndose, pero su papel pasa a ser DOCUMENTACIÓN y POLÍTICA PII
    (descripciones, marcas pii/safe). Aquí se usa solo para CONTRASTAR y reportar deriva; nada
    de lo que diga cambia lo que se entrega, y nada de lo que contiene viaja al cliente.

⛔ POR QUÉ NO SE USA DBMS_METADATA.GET_DDL

    La cuenta de entrega es de solo lectura por diseño de la política PII y no tiene
    SELECT_CATALOG_ROLE. Comprobado contra la BD real:

        SELECT DBMS_METADATA.GET_DDL('TABLE','<tabla>','<esquema>') FROM DUAL;
        ORA-31603: object "<tabla>" of type TABLE not found in schema "<esquema>"

    No es un problema que se resuelva pidiendo el privilegio: la cuenta es de solo lectura a
    propósito. Todo el DDL se reconstruye desde el diccionario ALL_*, que sí es legible con
    GRANT SELECT — el mismo camino que ya usa `installer-objects.py` para los otros seis tipos
    de objeto. La rama SQL Server usa `sys.*` por coherencia.

LONG en el diccionario

    `ALL_TAB_COLUMNS.DATA_DEFAULT` y `ALL_CONSTRAINTS.SEARCH_CONDITION` son LONG: no se pueden
    manipular en SQL (ni TO_CHAR, ni SUBSTR, ni concatenar). Se leen desde un bloque PL/SQL
    anónimo a variables LONG y se emiten con DBMS_OUTPUT. Es el mismo patrón que `gen_vistas`.
    ⛔ Si se intentan leer con un SELECT normal, Oracle no da error: devuelve la columna
    truncada o la consulta falla con ORA-00932 según el contexto, y un DEFAULT truncado es un
    DEFAULT incorrecto que nadie revisa.

EXCLUSIONES

    Declarativas y por NOMBRE EXACTO, en `docs/<proyecto>-instalador.json`. ⛔ Nunca por patrón:
    excluir por patrón borra en silencio tablas de producto que casualmente encajen, y el fallo
    no aparece hasta que algo las usa. Los nombres sospechosos se AVISAN, no se excluyen.

Uso: python installer-tablas.py <workspace> <proyecto> <out.sql> [--conexion <id>]
"""

import sys
import os
import re
import json
from pathlib import Path
from datetime import datetime

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from _dbsql import (OBJ_MARK, run_sqlplus, run_sqlcmd, parse_filas, _ins)
from _dbtypes import falta_tamano

# Infraestructura del PAQUETE, no del proyecto. La tabla de versiones, su secuencia y su índice
# los crea 00-RVERSIONES.sql, que va el PRIMERO del manifiesto. Pero existen también en la BD de
# desarrollo —es donde se registran las entregas—, así que la extracción los captura como
# objetos del proyecto y el paquete los traía DOS veces: sobre un esquema vacío y recién creado,
# 00-RVERSIONES.sql creaba la secuencia y acto seguido este fichero intentaba crearla otra vez
# -> ORA-00955. El error parecía "la BD del cliente ya tenía objetos" y era el paquete chocando
# consigo mismo.
INFRA_PAQUETE = {"RVERSIONES", "SEQ_RVERSIONES", "IX_RVERSIONES_ENT_SOL", "PK_RVERSIONES"}

# Nombres con pinta de copia puntual hecha a mano en desarrollo. ⛔ SOLO AVISAN, nunca excluyen:
# excluir por patrón es el fallo que se quiere evitar en la otra dirección — una tabla de
# producto que se llame con dígitos al final desaparecería del paquete sin que nadie lo note, y
# el error no aparece hasta que algo la usa.
PATRON_SOSPECHOSO = re.compile(r"(_\d{6,8}|_(BAK|BACKUP|COPIA|OLD|TMP|TEMP|PRUEBA|TEST)\d*)$",
                               re.IGNORECASE)

# Tipos cuyo tamaño lo lleva ya el propio DATA_TYPE del diccionario (TIMESTAMP(6),
# INTERVAL DAY(2) TO SECOND(6)...). Añadirles paréntesis produciría TIMESTAMP(6)(6).
TIPO_YA_DIMENSIONADO = re.compile(r"^(TIMESTAMP|INTERVAL)", re.IGNORECASE)


# ============================================================ exclusiones declaradas
def leer_exclusiones(workspace: str, proyecto: str) -> dict:
    """Bloque `exclusiones` de docs/<proyecto>-instalador.json.

    Forma:
        "exclusiones": {
          "tablas":     [{"nombre": "RTRABAJO_20260731", "motivo": "copia CTAS de desarrollo"}],
          "indices":    [...],
          "constraints":[...],
          "tipos_objeto": ["FOREIGN KEY"]
        }

    Se indexa por nombre en MAYÚSCULAS. `tipos_objeto` excluye una categoría entera y existe
    para poder decir "las FK no viajan nunca" como una DECISIÓN DECLARADA, no como un silencio
    del generador. Sin declararla, todo lo que esté en la BD viaja.
    """
    vacio = {"tablas": {}, "indices": {}, "constraints": {}, "tipos_objeto": set()}
    p = Path(workspace) / "docs" / f"{proyecto}-instalador.json"
    if not p.exists():
        return vacio
    try:
        cfg = json.loads(p.read_text(encoding="utf-8-sig"))
    except Exception as e:
        # Un JSON roto NO se ignora: se estaría entregando con las exclusiones sin aplicar, es
        # decir con la tabla que alguien decidió que no viajara.
        raise RuntimeError(f"{p} no es JSON válido ({e}). Las exclusiones no se pueden aplicar.")
    exc = cfg.get("exclusiones") or {}
    res = {"tablas": {}, "indices": {}, "constraints": {}, "tipos_objeto": set()}
    for clave in ("tablas", "indices", "constraints"):
        for e in (exc.get(clave) or []):
            if isinstance(e, str):
                # Sin motivo: se admite, pero se marca. Dentro de seis meses nadie sabrá por qué.
                res[clave][e.upper()] = "sin motivo declarado"
            else:
                nombre = (e.get("nombre") or "").upper()
                if nombre:
                    res[clave][nombre] = (e.get("motivo") or "sin motivo declarado")
    res["tipos_objeto"] = {str(t).upper().strip() for t in (exc.get("tipos_objeto") or [])}
    return res


# ============================================================ tipos
def dimension(valor) -> str:
    """El tamaño, solo si es un tamaño de verdad. "" si no lo es.

    ⛔ Existe para NO fabricar paréntesis vacíos. Con el valor ausente, un
    f"{t}({f['data_length']})" produce `RAW()`: inválido para el motor y —lo que lo hacía
    peligroso— INVISIBLE para `falta_tamano`, que da por bueno todo tipo que lleve paréntesis.
    El gate se saltaba justo el caso que existe para cazar, y el .sql se escribía con un OK
    encima. Sin paréntesis, el tipo sale pelado y el gate lo para.
    """
    s = str(valor or "").strip()
    if not s.isdigit() or int(s) <= 0:
        return ""
    return s


def tipo_oracle(f: dict) -> str:
    """Tipo completo de la columna, como lo escribiría un CREATE TABLE.

    ⛔ El tamaño NO es decorativo. RAW/VARCHAR2/NVARCHAR2/VARCHAR/UROWID sin longitud son
    INVÁLIDOS (ORA-00906); CHAR/NCHAR sin longitud son peor: valen, significan (1) y truncan
    datos sin un solo error.
    """
    t = (f["tipo"] or "").upper()
    if t in ("VARCHAR2", "NVARCHAR2", "CHAR", "NCHAR", "VARCHAR"):
        # CHAR_USED dice si la columna se declaró en caracteres ('C') o en bytes ('B'). Se
        # respeta lo que hay: reinterpretar bytes como caracteres cambia la capacidad real.
        if f["char_used"] == "C":
            n = dimension(f["char_length"])
            return f"{t}({n} CHAR)" if n else t
        n = dimension(f["data_length"])
        return f"{t}({n} BYTE)" if n else t
    if t in ("RAW", "UROWID"):
        # Se miden en BYTES: CHAR_LENGTH vale 0 para RAW y habría generado RAW(0).
        n = dimension(f["data_length"])
        return f"{t}({n})" if n else t
    if t == "NUMBER":
        p = dimension(f["precision"])
        if not p:
            return "NUMBER"                      # NUMBER sin precisión es un tipo válido y distinto
        if f["scale"] and str(f["scale"]).strip().isdigit() and int(f["scale"]) != 0:
            return f"NUMBER({p},{f['scale']})"
        return f"NUMBER({p})"
    if t == "FLOAT":
        p = dimension(f["precision"])
        return f"FLOAT({p})" if p else "FLOAT"
    if TIPO_YA_DIMENSIONADO.match(t):
        return t                                  # el diccionario ya lo devuelve dimensionado
    return t


def tipo_sqlserver(f: dict) -> str:
    t = (f["tipo"] or "").lower()
    if t in ("varchar", "nvarchar", "char", "nchar", "binary", "varbinary"):
        # max_length viene en BYTES; en los tipos Unicode son 2 por carácter. -1 es (MAX).
        if str(f["data_length"]).strip() == "-1":
            return f"{t}(MAX)"
        n = dimension(f["data_length"])
        if not n:
            return t                              # sin tamaño: que lo pare el gate, no lo tape
        if t in ("nvarchar", "nchar"):
            n = str(int(n) // 2)
        return f"{t}({n})"
    if t in ("decimal", "numeric"):
        p = dimension(f["precision"])
        return f"{t}({p},{f['scale']})" if p else t
    if t in ("datetime2", "time", "datetimeoffset"):
        s = str(f["scale"] or "").strip()
        return f"{t}({s})" if s.isdigit() else t
    return t


# ============================================================ extracción ORACLE
def _sql_columnas(schema: str) -> str:
    return f"""
SELECT '{OBJ_MARK}'||c.TABLE_NAME||'|'||c.COLUMN_NAME||'|'||c.COLUMN_ID||'|'||c.DATA_TYPE||'|'||
       NVL(TO_CHAR(c.DATA_LENGTH),'')||'|'||NVL(TO_CHAR(c.CHAR_LENGTH),'')||'|'||
       NVL(TO_CHAR(c.DATA_PRECISION),'')||'|'||NVL(TO_CHAR(c.DATA_SCALE),'')||'|'||
       c.NULLABLE||'|'||NVL(c.CHAR_USED,'')
  FROM ALL_TAB_COLUMNS c
  JOIN ALL_TABLES t ON t.OWNER = c.OWNER AND t.TABLE_NAME = c.TABLE_NAME
 WHERE c.OWNER = '{schema}'
   AND t.NESTED = 'NO' AND t.SECONDARY = 'N'
   AND c.TABLE_NAME NOT LIKE 'BIN'||CHR(36)||'%'
   AND c.TABLE_NAME NOT IN (SELECT MVIEW_NAME FROM ALL_MVIEWS WHERE OWNER = '{schema}')
 ORDER BY c.TABLE_NAME, c.COLUMN_ID;
"""


def _sql_defaults(schema: str) -> str:
    """DATA_DEFAULT es LONG: solo se puede leer a una variable LONG dentro de PL/SQL."""
    return f"""
DECLARE
    v_def LONG;
BEGIN
    FOR r IN (SELECT TABLE_NAME, COLUMN_NAME FROM ALL_TAB_COLUMNS
               WHERE OWNER = '{schema}' AND DEFAULT_LENGTH IS NOT NULL
               ORDER BY TABLE_NAME, COLUMN_ID) LOOP
        SELECT DATA_DEFAULT INTO v_def FROM ALL_TAB_COLUMNS
         WHERE OWNER = '{schema}' AND TABLE_NAME = r.TABLE_NAME AND COLUMN_NAME = r.COLUMN_NAME;
        -- El DEFAULT puede traer saltos de línea; se aplanan para que la fila no se parta.
        v_def := TRIM(REPLACE(REPLACE(v_def, CHR(13), ' '), CHR(10), ' '));
        IF v_def IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('{OBJ_MARK}'||r.TABLE_NAME||'|'||r.COLUMN_NAME||'|'||v_def);
        END IF;
    END LOOP;
END;
/
"""


def _sql_identidad(schema: str) -> str:
    return f"""
SELECT '{OBJ_MARK}'||TABLE_NAME||'|'||COLUMN_NAME||'|'||GENERATION_TYPE
  FROM ALL_TAB_IDENTITY_COLS WHERE OWNER = '{schema}' ORDER BY TABLE_NAME;
"""


def _sql_constraints(schema: str) -> str:
    """PK / UNIQUE / FK con sus columnas en orden. El CHECK va aparte: su condición es LONG."""
    return f"""
SELECT '{OBJ_MARK}'||c.CONSTRAINT_TYPE||'|'||c.TABLE_NAME||'|'||c.CONSTRAINT_NAME||'|'||
       cc.COLUMN_NAME||'|'||cc.POSITION||'|'||NVL(rc.TABLE_NAME,'')||'|'||
       NVL(rcc.COLUMN_NAME,'')||'|'||NVL(c.DELETE_RULE,'')
  FROM ALL_CONSTRAINTS c
  JOIN ALL_CONS_COLUMNS cc ON cc.OWNER = c.OWNER AND cc.CONSTRAINT_NAME = c.CONSTRAINT_NAME
  LEFT JOIN ALL_CONSTRAINTS rc ON rc.OWNER = c.R_OWNER AND rc.CONSTRAINT_NAME = c.R_CONSTRAINT_NAME
  LEFT JOIN ALL_CONS_COLUMNS rcc ON rcc.OWNER = rc.OWNER AND rcc.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                                AND rcc.POSITION = cc.POSITION
 WHERE c.OWNER = '{schema}' AND c.CONSTRAINT_TYPE IN ('P','U','R')
   AND c.TABLE_NAME NOT LIKE 'BIN'||CHR(36)||'%'
 ORDER BY c.TABLE_NAME, c.CONSTRAINT_NAME, cc.POSITION;
"""


def _sql_checks(schema: str) -> str:
    """SEARCH_CONDITION es LONG.

    ⛔ Oracle crea un CHECK por cada NOT NULL de columna ("COL" IS NOT NULL). Emitirlos
    duplicaría el NOT NULL que ya lleva la columna en el CREATE TABLE, con un nombre de
    constraint generado que además chocaría entre entregas. Se descartan aquí.
    """
    return f"""
DECLARE
    v_cond LONG;
BEGIN
    FOR r IN (SELECT CONSTRAINT_NAME, TABLE_NAME FROM ALL_CONSTRAINTS
               WHERE OWNER = '{schema}' AND CONSTRAINT_TYPE = 'C'
                 AND TABLE_NAME NOT LIKE 'BIN'||CHR(36)||'%'
               ORDER BY TABLE_NAME, CONSTRAINT_NAME) LOOP
        SELECT SEARCH_CONDITION INTO v_cond FROM ALL_CONSTRAINTS
         WHERE OWNER = '{schema}' AND CONSTRAINT_NAME = r.CONSTRAINT_NAME;
        v_cond := TRIM(REPLACE(REPLACE(v_cond, CHR(13), ' '), CHR(10), ' '));
        IF v_cond IS NOT NULL
           AND NOT REGEXP_LIKE(v_cond, '^"?[A-Za-z0-9_'||CHR(36)||'#]+"? +IS +NOT +NULL'||CHR(36), 'i') THEN
            DBMS_OUTPUT.PUT_LINE('{OBJ_MARK}'||r.TABLE_NAME||'|'||r.CONSTRAINT_NAME||'|'||v_cond);
        END IF;
    END LOOP;
END;
/
"""


def _sql_indices(schema: str) -> str:
    """Índices que NO respaldan una constraint.

    Un índice creado por Oracle para una PK o una UNIQUE aparece en ALL_INDEXES como cualquier
    otro. Emitirlo daría ORA-00955 al instalar, porque la constraint ya lo crea.
    """
    return f"""
SELECT '{OBJ_MARK}'||i.TABLE_NAME||'|'||i.INDEX_NAME||'|'||i.UNIQUENESS||'|'||
       ic.COLUMN_NAME||'|'||ic.COLUMN_POSITION||'|'||NVL(ic.DESCEND,'ASC')
  FROM ALL_INDEXES i
  JOIN ALL_IND_COLUMNS ic ON ic.INDEX_OWNER = i.OWNER AND ic.INDEX_NAME = i.INDEX_NAME
 WHERE i.OWNER = '{schema}' AND i.TABLE_OWNER = '{schema}'
   AND i.INDEX_TYPE NOT IN ('LOB','IOT - TOP')
   AND i.TABLE_NAME NOT LIKE 'BIN'||CHR(36)||'%'
   AND i.INDEX_NAME NOT LIKE 'BIN'||CHR(36)||'%'
   AND NOT EXISTS (SELECT 1 FROM ALL_CONSTRAINTS c
                    WHERE c.OWNER = i.OWNER AND c.INDEX_NAME = i.INDEX_NAME
                      AND c.CONSTRAINT_TYPE IN ('P','U'))
 ORDER BY i.TABLE_NAME, i.INDEX_NAME, ic.COLUMN_POSITION;
"""


def _sql_conteo(schema: str) -> str:
    """Conteo del diccionario, para contrastar contra lo capturado.

    ⛔ Sin esto no se puede afirmar que el paquete está completo: Oracle no permite distinguir
    "no existe" de "no lo veo", y una cuenta que no es dueña ve por GRANT per-object.
    """
    return f"""
SELECT '{OBJ_MARK}TABLAS|'||COUNT(*)||'||||||' FROM ALL_TABLES
 WHERE OWNER='{schema}' AND NESTED='NO' AND SECONDARY='N'
   AND TABLE_NAME NOT LIKE 'BIN'||CHR(36)||'%'
   AND TABLE_NAME NOT IN (SELECT MVIEW_NAME FROM ALL_MVIEWS WHERE OWNER='{schema}');
"""


def extraer_oracle(cfg: dict) -> dict:
    """Todo el diccionario que hace falta, en seis lecturas. Cada una asertada por _dbsql."""
    s = cfg["schema"].upper()
    datos = {}

    filas = parse_filas(run_sqlplus(cfg, _sql_columnas(s)), 10)
    datos["columnas"] = [dict(tabla=f[0], columna=f[1], orden=int(f[2] or 0), tipo=f[3],
                              data_length=f[4], char_length=f[5], precision=f[6], scale=f[7],
                              nullable=f[8], char_used=f[9]) for f in filas]

    datos["defaults"] = {(f[0], f[1]): f[2] for f in parse_filas(run_sqlplus(cfg, _sql_defaults(s)), 3)}

    # ALL_TAB_IDENTITY_COLS no existe antes de 12c. Si la vista no está, NO hay columnas
    # IDENTITY que capturar —la funcionalidad tampoco existe en esa versión—, así que el hueco
    # es real y no una pérdida. Se dice en voz alta igualmente: callarlo sería indistinguible
    # de haberlas perdido.
    datos["identidad"] = {}
    datos["aviso_identidad"] = ""
    try:
        for f in parse_filas(run_sqlplus(cfg, _sql_identidad(s)), 3):
            datos["identidad"][(f[0], f[1])] = f[2]
    except RuntimeError as e:
        if "ORA-00942" in str(e):
            datos["aviso_identidad"] = ("ALL_TAB_IDENTITY_COLS no existe en esta BD (Oracle < 12c): "
                                        "no hay columnas IDENTITY que capturar.")
        else:
            raise

    datos["constraints"] = [dict(tipo=f[0], tabla=f[1], nombre=f[2], columna=f[3],
                                 posicion=int(f[4] or 0), tabla_ref=f[5], columna_ref=f[6],
                                 delete_rule=f[7])
                            for f in parse_filas(run_sqlplus(cfg, _sql_constraints(s)), 8)]

    datos["checks"] = [dict(tabla=f[0], nombre=f[1], condicion=f[2])
                       for f in parse_filas(run_sqlplus(cfg, _sql_checks(s)), 3)]

    datos["indices"] = [dict(tabla=f[0], nombre=f[1], unico=(f[2] == "UNIQUE"), columna=f[3],
                             posicion=int(f[4] or 0), descend=f[5])
                        for f in parse_filas(run_sqlplus(cfg, _sql_indices(s)), 6)]

    conteo = parse_filas(run_sqlplus(cfg, _sql_conteo(s)), 8)
    datos["n_tablas_diccionario"] = int(conteo[0][1]) if conteo else None
    return datos


# ============================================================ extracción SQL SERVER
def extraer_sqlserver(cfg: dict) -> dict:
    m = OBJ_MARK
    datos = {}

    q_col = f"""
SELECT '{m}'+t.name+'|'+c.name+'|'+CONVERT(varchar,c.column_id)+'|'+ty.name+'|'+
       CONVERT(varchar,c.max_length)+'|'+CONVERT(varchar,c.max_length)+'|'+
       CONVERT(varchar,c.precision)+'|'+CONVERT(varchar,c.scale)+'|'+
       CASE WHEN c.is_nullable=1 THEN 'Y' ELSE 'N' END+'|'+
       CASE WHEN c.is_identity=1 THEN 'IDENTITY' ELSE '' END
  FROM sys.tables t
  JOIN sys.columns c ON c.object_id=t.object_id
  JOIN sys.types ty ON ty.user_type_id=c.user_type_id
 WHERE t.is_ms_shipped=0 ORDER BY t.name, c.column_id;"""
    filas = parse_filas(run_sqlcmd(cfg, q_col), 10)
    datos["columnas"] = [dict(tabla=f[0], columna=f[1], orden=int(f[2] or 0), tipo=f[3],
                              data_length=f[4], char_length=f[5], precision=f[6], scale=f[7],
                              nullable=f[8], char_used="") for f in filas]
    datos["identidad"] = {(f[0], f[1]): "IDENTITY" for f in filas if f[9] == "IDENTITY"}
    datos["aviso_identidad"] = ""

    q_def = f"""
SELECT '{m}'+t.name+'|'+c.name+'|'+d.definition
  FROM sys.default_constraints d
  JOIN sys.columns c ON c.object_id=d.parent_object_id AND c.column_id=d.parent_column_id
  JOIN sys.tables t ON t.object_id=d.parent_object_id
 WHERE t.is_ms_shipped=0 ORDER BY t.name;"""
    # SQL Server envuelve el default en paréntesis redundantes: ((0)) -> 0.
    datos["defaults"] = {(f[0], f[1]): re.sub(r"^\((.*)\)$", r"\1", f[2]).strip()
                         for f in parse_filas(run_sqlcmd(cfg, q_def), 3)}

    q_cons = f"""
SELECT '{m}'+CASE WHEN k.type='PK' THEN 'P' ELSE 'U' END+'|'+t.name+'|'+k.name+'|'+c.name+'|'+
       CONVERT(varchar,ic.key_ordinal)+'|||'
  FROM sys.key_constraints k
  JOIN sys.tables t ON t.object_id=k.parent_object_id
  JOIN sys.index_columns ic ON ic.object_id=k.parent_object_id AND ic.index_id=k.unique_index_id
  JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
 WHERE t.is_ms_shipped=0
UNION ALL
SELECT '{m}R|'+t.name+'|'+f.name+'|'+pc.name+'|'+CONVERT(varchar,fc.constraint_column_id)+'|'+
       rt.name+'|'+rc.name+'|'+REPLACE(f.delete_referential_action_desc,'_',' ')
  FROM sys.foreign_keys f
  JOIN sys.tables t ON t.object_id=f.parent_object_id
  JOIN sys.tables rt ON rt.object_id=f.referenced_object_id
  JOIN sys.foreign_key_columns fc ON fc.constraint_object_id=f.object_id
  JOIN sys.columns pc ON pc.object_id=fc.parent_object_id AND pc.column_id=fc.parent_column_id
  JOIN sys.columns rc ON rc.object_id=fc.referenced_object_id AND rc.column_id=fc.referenced_column_id
 WHERE t.is_ms_shipped=0;"""
    datos["constraints"] = [dict(tipo=f[0], tabla=f[1], nombre=f[2], columna=f[3],
                                 posicion=int(f[4] or 0), tabla_ref=f[5], columna_ref=f[6],
                                 delete_rule=f[7])
                            for f in parse_filas(run_sqlcmd(cfg, q_cons), 8)]

    q_chk = f"""
SELECT '{m}'+t.name+'|'+ck.name+'|'+ck.definition
  FROM sys.check_constraints ck
  JOIN sys.tables t ON t.object_id=ck.parent_object_id
 WHERE t.is_ms_shipped=0 ORDER BY t.name;"""
    datos["checks"] = [dict(tabla=f[0], nombre=f[1], condicion=f[2])
                       for f in parse_filas(run_sqlcmd(cfg, q_chk), 3)]

    q_idx = f"""
SELECT '{m}'+t.name+'|'+i.name+'|'+CASE WHEN i.is_unique=1 THEN 'UNIQUE' ELSE 'NONUNIQUE' END+'|'+
       c.name+'|'+CONVERT(varchar,ic.key_ordinal)+'|'+
       CASE WHEN ic.is_descending_key=1 THEN 'DESC' ELSE 'ASC' END
  FROM sys.indexes i
  JOIN sys.tables t ON t.object_id=i.object_id
  JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id
  JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
 WHERE t.is_ms_shipped=0 AND i.is_primary_key=0 AND i.is_unique_constraint=0
   AND i.type>0 AND ic.is_included_column=0
 ORDER BY t.name, i.name, ic.key_ordinal;"""
    datos["indices"] = [dict(tabla=f[0], nombre=f[1], unico=(f[2] == "UNIQUE"), columna=f[3],
                             posicion=int(f[4] or 0), descend=f[5])
                        for f in parse_filas(run_sqlcmd(cfg, q_idx), 6)]

    q_cnt = f"SELECT '{m}TABLAS|'+CONVERT(varchar,COUNT(*))+'||||||' FROM sys.tables WHERE is_ms_shipped=0;"
    conteo = parse_filas(run_sqlcmd(cfg, q_cnt), 8)
    datos["n_tablas_diccionario"] = int(conteo[0][1]) if conteo else None
    return datos


# ============================================================ agrupación y emisión
def agrupar(datos: dict, motor: str) -> dict:
    """Del diccionario plano a {tabla: {columnas, pk, unique, check, indices}} + fks aparte."""
    tablas = {}
    for c in datos["columnas"]:
        t = tablas.setdefault(c["tabla"], {"columnas": [], "pk": [], "pk_nombre": "",
                                           "unique": {}, "check": [], "indices": {}})
        c = dict(c)
        c["default"] = datos["defaults"].get((c["tabla"], c["columna"]), "")
        c["identidad"] = datos["identidad"].get((c["tabla"], c["columna"]), "")
        c["tipo_sql"] = tipo_oracle(c) if motor == "ORACLE" else tipo_sqlserver(c)
        t["columnas"].append(c)

    fks = {}
    for k in datos["constraints"]:
        t = tablas.get(k["tabla"])
        if t is None:
            continue
        if k["tipo"] == "P":
            t["pk"].append((k["posicion"], k["columna"]))
            t["pk_nombre"] = k["nombre"]
        elif k["tipo"] == "U":
            t["unique"].setdefault(k["nombre"], []).append((k["posicion"], k["columna"]))
        elif k["tipo"] == "R":
            f = fks.setdefault(k["nombre"], {"tabla": k["tabla"], "nombre": k["nombre"],
                                             "columnas": [], "tabla_ref": k["tabla_ref"],
                                             "columnas_ref": [], "delete_rule": k["delete_rule"]})
            f["columnas"].append((k["posicion"], k["columna"]))
            f["columnas_ref"].append((k["posicion"], k["columna_ref"]))

    for ch in datos["checks"]:
        if ch["tabla"] in tablas:
            tablas[ch["tabla"]]["check"].append(ch)

    for i in datos["indices"]:
        if i["tabla"] not in tablas:
            continue
        idx = tablas[i["tabla"]]["indices"].setdefault(i["nombre"],
                                                       {"unico": i["unico"], "columnas": []})
        idx["columnas"].append((i["posicion"], i["columna"], i["descend"]))

    for t in tablas.values():
        t["pk"] = [c for _, c in sorted(t["pk"])]
        t["unique"] = {n: [c for _, c in sorted(v)] for n, v in t["unique"].items()}
        for idx in t["indices"].values():
            idx["columnas"] = [(c, d) for _, c, d in sorted(idx["columnas"])]
    for f in fks.values():
        f["columnas"] = [c for _, c in sorted(f["columnas"])]
        f["columnas_ref"] = [c for _, c in sorted(f["columnas_ref"])]
    return {"tablas": tablas, "fks": fks}


def render_tabla(nombre: str, t: dict, motor: str) -> list:
    """CREATE TABLE con columnas, DEFAULT, IDENTITY, NOT NULL y PK inline. SIN schema.

    ⛔ No se emite ninguna descripción. Las descripciones viven en el model.json, que es
    documentación de desarrollo y NO viaja al cliente. El generador anterior las inlineaba como
    comentarios del .sql.
    """
    lineas = [f"CREATE TABLE {nombre} ("]
    defs = []
    for c in t["columnas"]:
        col = f"    {c['columna']} {c['tipo_sql']}"
        if c["identidad"]:
            col += (" GENERATED BY DEFAULT AS IDENTITY" if motor == "ORACLE" else " IDENTITY(1,1)")
        elif c["default"]:
            # DEFAULT va ENTRE el tipo y el NOT NULL: es el único orden válido en los dos
            # motores ("COL TIPO NOT NULL DEFAULT x" es error de sintaxis en ambos).
            col += f" DEFAULT {c['default']}"
        if c["nullable"] != "Y":
            col += " NOT NULL"
        defs.append(col)
    if t["pk"]:
        defs.append(f"    CONSTRAINT {t['pk_nombre'] or ('PK_' + nombre)} PRIMARY KEY ({', '.join(t['pk'])})")
    lineas.append(",\n".join(defs))
    lineas.append(");")
    return lineas


def render_extras(nombre: str, t: dict, excl: dict) -> tuple:
    """UNIQUE, CHECK e índices de una tabla. Devuelve (uniques, checks, indices)."""
    uq, ck, ix = [], [], []
    for n, cols in sorted(t["unique"].items()):
        if n.upper() in excl["constraints"] or n.upper() in INFRA_PAQUETE:
            continue
        uq.append(f"ALTER TABLE {nombre} ADD CONSTRAINT {n} UNIQUE ({', '.join(cols)});")
    for c in sorted(t["check"], key=lambda x: x["nombre"]):
        if c["nombre"].upper() in excl["constraints"]:
            continue
        # Un CHECK con nombre generado por el sistema (SYS_Cnnnnnn) no se reemite con su
        # nombre: entre dos bases de datos el número no coincide y el nombre no significa nada.
        n = c["nombre"]
        nom = "" if re.match(r"^SYS_C\d+$", n, re.IGNORECASE) else f"CONSTRAINT {n} "
        ck.append(f"ALTER TABLE {nombre} ADD {nom}CHECK ({c['condicion']});")
    for n, idx in sorted(t["indices"].items()):
        if n.upper() in excl["indices"] or n.upper() in INFRA_PAQUETE:
            continue
        cols = ", ".join(c if d.upper() == "ASC" else f"{c} DESC" for c, d in idx["columnas"])
        ix.append(f"CREATE {'UNIQUE ' if idx['unico'] else ''}INDEX {n} ON {nombre} ({cols});")
    return uq, ck, ix


def render_fk(f: dict) -> str:
    regla = ""
    r = (f["delete_rule"] or "").upper()
    if r and r != "NO ACTION":
        regla = f" ON DELETE {r}"
    return (f"ALTER TABLE {f['tabla']} ADD CONSTRAINT {f['nombre']} "
            f"FOREIGN KEY ({', '.join(f['columnas'])}) "
            f"REFERENCES {f['tabla_ref']} ({', '.join(f['columnas_ref'])}){regla};")


# ============================================================ deriva contra el modelo
def deriva_modelo(tablas: dict, model: dict) -> list:
    """Qué dice el modelo que no cuadra con la BD. Solo INFORMA: el modelo nunca manda.

    Se reporta porque una tabla que está en la BD y no en el modelo suele significar que
    alguien la creó a mano y nadie lo sabe, y una columna con tipo distinto significa que el
    DDL que se habría entregado antes de este cambio era incorrecto.
    """
    if not model or not model.get("tables"):
        return []
    en_modelo = {k.upper(): v for k, v in model["tables"].items() if not v.get("orphan")}
    en_bd = {k.upper() for k in tablas}
    l = []
    solo_bd = sorted(en_bd - set(en_modelo))
    solo_mod = sorted(set(en_modelo) - en_bd)
    if solo_bd:
        l.append(f"{len(solo_bd)} tabla(s) en BD que el modelo no conoce: {', '.join(solo_bd[:10])}"
                 + (" ..." if len(solo_bd) > 10 else ""))
    if solo_mod:
        l.append(f"{len(solo_mod)} tabla(s) en el modelo que NO están en BD: {', '.join(solo_mod[:10])}"
                 + (" ..." if len(solo_mod) > 10 else ""))
    difs = []
    for t, td in tablas.items():
        md = en_modelo.get(t.upper())
        if not md:
            continue
        mcols = {k.upper(): v for k, v in (md.get("columns") or {}).items()}
        for c in td["columnas"]:
            mc = mcols.get(c["columna"].upper())
            if not mc:
                difs.append(f"{t}.{c['columna']} (en BD, no en el modelo)")
            elif (mc.get("type") or "").replace(" ", "").upper() != c["tipo_sql"].replace(" ", "").upper():
                difs.append(f"{t}.{c['columna']}: modelo {mc.get('type')} vs BD {c['tipo_sql']}")
    if difs:
        l.append(f"{len(difs)} columna(s) con diferencias modelo/BD: " + " · ".join(difs[:8])
                 + (" ..." if len(difs) > 8 else ""))
    return l


# ============================================================ main
def main():
    if len(sys.argv) < 4:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> <out.sql> [--conexion <id>]")
        sys.exit(1)

    workspace, proyecto, out_path = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    conexion = _ins.arg_conexion(sys.argv[4:])

    # El modelo es OPCIONAL y solo se usa para contrastar. Que falte no impide entregar: la BD
    # es la fuente. Antes su ausencia paraba la generación, porque era la fuente.
    model = {}
    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"
    if model_path.exists():
        try:
            model = json.loads(model_path.read_text(encoding="utf-8-sig"))
        except Exception as e:
            print(f"AVISO: {model_path} no se pudo leer ({e}); no habrá contraste de deriva.")

    try:
        excl = leer_exclusiones(workspace, proyecto)
    except RuntimeError as e:
        print(f"ERROR: {e}")
        sys.exit(1)

    cfg = _ins.read_db_config(workspace, model, conexion)
    motor = cfg["motor"]
    if motor not in ("ORACLE", "SQLSERVER"):
        print(f"ERROR: motor no soportado: {motor}")
        sys.exit(1)

    print(f"Fuente: BD VIVA — {motor}, esquema {cfg['schema']}, usuario {cfg['user']}")
    print("        (el model.json NO es origen de DDL; solo se usa para contrastar deriva)")

    # ⛔ Cualquier fallo de lectura aborta SIN escribir. `_dbsql` revienta ante un ORA-/Msg en
    # la salida, así que aquí no hay forma de llegar con datos a medias creyendo que están bien.
    try:
        datos = extraer_oracle(cfg) if motor == "ORACLE" else extraer_sqlserver(cfg)
    except Exception as e:
        print(f"ERROR: fallo leyendo el diccionario de la BD: {e}")
        print("       NO se ha escrito ningún fichero. El paquete no es entregable.")
        sys.exit(1)

    if not datos["columnas"]:
        print("ERROR: el diccionario no devolvió ni una sola columna.")
        print("       Un esquema sin columnas no es un esquema vacío: es una lectura que no ha")
        print("       funcionado o una cuenta que no ve nada. NO se ha escrito ningún fichero.")
        sys.exit(1)

    agr = agrupar(datos, motor)
    todas, fks = agr["tablas"], agr["fks"]

    # --- exclusiones, aplicadas sobre el inventario LEÍDO DE LA BD -------------------
    excluidas, sospechosas = [], []
    tablas = {}
    for nombre, t in sorted(todas.items()):
        u = nombre.upper()
        if u in INFRA_PAQUETE:
            excluidas.append((nombre, "infraestructura del paquete (la crea 00-RVERSIONES.sql)"))
            continue
        if u in excl["tablas"]:
            excluidas.append((nombre, excl["tablas"][u]))
            continue
        if PATRON_SOSPECHOSO.search(nombre):
            sospechosas.append(nombre)
        tablas[nombre] = t

    fk_excluidas_tipo = "FOREIGN KEY" in excl["tipos_objeto"] or "FK" in excl["tipos_objeto"]

    # --- gate: tipos sin tamaño -----------------------------------------------------
    sin_tamano = []
    for nombre, t in tablas.items():
        for c in t["columnas"]:
            clase = falta_tamano(c["tipo_sql"], motor)
            if clase:
                sin_tamano.append((nombre, c["columna"], c["tipo_sql"], clase))
    if sin_tamano:
        inval = [x for x in sin_tamano if x[3] == "invalido"]
        silen = [x for x in sin_tamano if x[3] == "silencioso"]
        print(f"ERROR: {len(sin_tamano)} columna(s) con un tipo que exige tamaño y no lo trae.")
        print(f"       NO se ha escrito {out_path}.")
        for etiqueta, grupo, nota in (("INVÁLIDA(S)", inval, "el motor rechaza el DDL (Oracle: ORA-00906)"),
                                      ("SILENCIOSA(S)", silen, "el DDL vale y significa (1): truncan datos sin error")):
            if grupo:
                print(f"  {len(grupo)} {etiqueta} — {nota}:")
                for t_, c_, ty_, _ in grupo[:20]:
                    print(f"       {t_}.{c_}  ->  {ty_}")
                if len(grupo) > 20:
                    print(f"       ... y {len(grupo) - 20} más")
        print("       Esto ya no puede venir de un modelo desfasado: sale del diccionario. Revisa")
        print("       la columna en la BD de desarrollo antes de entregar.")
        sys.exit(2)

    # --- gate: FK que apunta a una tabla que no viaja --------------------------------
    fks_vivas = {}
    fks_colgantes = []
    if not fk_excluidas_tipo:
        for n, f in sorted(fks.items()):
            if f["tabla"] not in tablas:
                continue                      # la tabla origen no viaja: su FK tampoco
            if f["tabla_ref"] not in tablas:
                fks_colgantes.append((n, f["tabla"], f["tabla_ref"]))
            else:
                fks_vivas[n] = f
    if fks_colgantes:
        print(f"ERROR: {len(fks_colgantes)} FOREIGN KEY apuntan a una tabla que NO viaja en el paquete.")
        for n, t_, r_ in fks_colgantes:
            print(f"       {n}: {t_} -> {r_} (excluida o ausente)")
        print("       En el cliente daría ORA-00942/ORA-02270 y la instalación se pararía ahí.")
        print("       Salidas: no excluir la tabla referenciada, o declarar la FK en")
        print(f"       docs\\{proyecto}-instalador.json -> exclusiones.constraints.")
        print(f"       NO se ha escrito {out_path}.")
        sys.exit(1)

    # --- emisión ---------------------------------------------------------------------
    lineas = [
        "-- ============================================================",
        f"-- Creación de tablas — instalación limpia de {proyecto}",
        f"-- Motor: {motor} | Generado: {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        "-- Extraído de la BD VIVA (diccionario ALL_*/sys.*), SIN schema.",
        "-- El modelo JSON no interviene: es documentación de desarrollo.",
        "-- ============================================================",
    ]
    if excluidas:
        lineas.append(f"-- EXCLUIDO A PROPÓSITO ({len(excluidas)}):")
        for n, motivo in excluidas:
            lineas.append(f"--   {n}: {motivo}")
    if fk_excluidas_tipo:
        lineas.append(f"-- EXCLUIDO A PROPÓSITO: FOREIGN KEY ({len(fks)} en la BD de desarrollo),")
        lineas.append("--   por exclusión declarada de tipo de objeto.")
    lineas += ["-- ============================================================", ""]
    if motor == "ORACLE":
        lineas += ["SET DEFINE OFF", ""]

    bloque_uq, bloque_ck, bloque_ix = [], [], []
    n_def = n_ident = 0
    for nombre, t in sorted(tablas.items()):
        lineas += render_tabla(nombre, t, motor)
        lineas.append("")
        uq, ck, ix = render_extras(nombre, t, excl)
        bloque_uq += uq
        bloque_ck += ck
        bloque_ix += ix
        n_def += sum(1 for c in t["columnas"] if c["default"])
        n_ident += sum(1 for c in t["columnas"] if c["identidad"])

    for titulo, bloque in (("RESTRICCIONES UNIQUE", bloque_uq),
                           ("RESTRICCIONES CHECK", bloque_ck),
                           ("ÍNDICES", bloque_ix)):
        if bloque:
            lineas += ["-- ============================================================",
                       f"-- {titulo} ({len(bloque)})",
                       "-- ============================================================"] + bloque + [""]

    if fks_vivas:
        lineas += ["-- ============================================================",
                   f"-- CLAVES AJENAS ({len(fks_vivas)})",
                   "-- Van al final, cuando ya existen TODAS las tablas: una FK emitida junto a su",
                   "-- tabla fallaría si la referenciada aún no se ha creado.",
                   "-- ============================================================"]
        lineas += [render_fk(f) for _, f in sorted(fks_vivas.items())] + [""]

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lineas), encoding="utf-8")

    # --- informe ---------------------------------------------------------------------
    print(f"OK — DDL generado: {out_path}")
    print(f"     {len(tablas)} tablas | {len(bloque_ix)} índices | {len(bloque_uq)} unique | "
          f"{len(bloque_ck)} check | {n_def} defaults | {n_ident} identity | {len(fks_vivas)} FK")

    dicc = datos.get("n_tablas_diccionario")
    if dicc is not None:
        capturado = len(todas)
        hueco = dicc - capturado
        print(f"     Cobertura tablas: diccionario {dicc} · capturado {capturado} · "
              f"excluidas {len(excluidas)}" + (f"  << HUECO {hueco}" if hueco > 0 else ""))
        if hueco > 0:
            print("     AVISO: el diccionario ve tablas que la extracción no capturó. El paquete")
            print("            iría INCOMPLETO — no des la entrega por buena.")
    if datos.get("aviso_identidad"):
        print(f"     {datos['aviso_identidad']}")
    if excluidas:
        print(f"     {len(excluidas)} tabla(s) excluidas, NO viajan al cliente:")
        for n, motivo in excluidas:
            print(f"            {n}: {motivo}")
    if sospechosas:
        print(f"     AVISO: {len(sospechosas)} tabla(s) con nombre de copia puntual que SÍ se entregan.")
        print(f"            Si son restos de desarrollo, decláralas en")
        print(f"            docs\\{proyecto}-instalador.json -> exclusiones.tablas (con motivo):")
        for n in sospechosas[:10]:
            print(f"            {n}")
    if fk_excluidas_tipo and fks:
        print(f"     {len(fks)} FOREIGN KEY existen en desarrollo y NO viajan (exclusión de tipo declarada).")

    for l in deriva_modelo(tablas, model):
        print(f"     DERIVA modelo/BD: {l}")
    print("     (la deriva no bloquea: lo entregado sale de la BD, que es la fuente)")


if __name__ == "__main__":
    main()
