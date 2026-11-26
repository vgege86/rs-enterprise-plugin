"""Excepcion de catalogo del enmascarado PII: las consultas que SOLO leen estructura.

POR QUE EXISTE. `db_query` enmascara toda columna que no resuelve contra el modelo y cuyos
valores son texto. Las vistas del catalogo del sistema (ALL_TAB_COLUMNS, ALL_TRIGGERS,
ALL_SOURCE, INFORMATION_SCHEMA.COLUMNS, sys.sql_modules...) no estan en el modelo, asi que
nombres de columna y cuerpos de trigger volvian como `pii:xxxx`. Eso no protegia nada --un
nombre de columna no es un dato personal-- y empujaba al agente a sortear el filtro
(mapear nombres a numeros con CASE), que es un habito peor que la excepcion que se queria
evitar. Hasta la 3.27.0 la regla era "no abrir excepcion"; desde la 3.28.0 se abre, acotada.

LA EXCEPCION SOLO APLICA SI SE CUMPLE TODO:

  1. Todas las tablas del FROM/JOIN (incluidas las de subconsultas y literales) son vistas
     de una lista CERRADA de vistas de estructura (VISTAS_ORACLE / VISTAS_SQLSERVER). Si
     una sola es de negocio, la consulta entera sigue las reglas normales.
  2. Ninguna de esas tablas esta en el modelo: si un workspace tiene una tabla propia que se
     llama como una vista de catalogo, gana el modelo.
  3. La lista del SELECT de la consulta principal es "simple": `*`, `alias.*` o columnas
     sueltas (con alias opcional) cuyo nombre esta en COLUMNAS_CATALOGO. Nada de funciones,
     expresiones, concatenaciones, literales, CASE, subconsultas escalares, WITH ni
     UNION/MINUS/INTERSECT: por ahi se podrian sacar datos de negocio con un FROM de catalogo
     (`SELECT PKG.GET_NIF(1) FROM ALL_TABLES`). Oracle admite llamar a una funcion sin
     parentesis, por eso tambien el nombre de la columna fuente tiene que estar en la lista.
  4. Columna a columna: solo sale en claro una cabecera que este en COLUMNAS_CATALOGO.

QUE NO ENTRA, A PROPOSITO, aunque sea catalogo: LOW_VALUE / HIGH_VALUE de ALL_TAB_COLUMNS
(son el minimo y el maximo REALES de la columna en bruto: el DNI mas bajo de RDEUDORES),
los histogramas (ALL_TAB_HISTOGRAMS.ENDPOINT_ACTUAL_VALUE) y V$SQL (SQL_TEXT con literales).
No estan en las listas, asi que siguen las reglas normales.

Y la red de seguridad por forma de valor de pii_mask sigue activa sobre lo que sale en claro:
un trigger con un DNI, IBAN o correo escrito a mano sale con esa columna enmascarada.
"""
import re

# Vistas de Oracle: se aceptan con prefijo ALL_, USER_ o DBA_, sin esquema o con SYS.
_SUFIJOS_ORACLE = {
    "TABLES", "TAB_COLUMNS", "TAB_COLS", "COL_COMMENTS", "TAB_COMMENTS",
    "TRIGGERS", "TRIGGER_COLS", "SOURCE", "OBJECTS",
    "CONSTRAINTS", "CONS_COLUMNS", "INDEXES", "IND_COLUMNS", "IND_EXPRESSIONS",
    "VIEWS", "SEQUENCES", "SYNONYMS", "DEPENDENCIES", "ARGUMENTS", "PROCEDURES",
    "ERRORS", "TAB_PRIVS",
}
VISTAS_ORACLE = {f"{p}_{s}" for p in ("ALL", "USER", "DBA") for s in _SUFIJOS_ORACLE}

# Vistas de SQL Server: SOLO calificadas (INFORMATION_SCHEMA.X / SYS.X). Sin calificar,
# "COLUMNS" u "OBJECTS" podrian ser tablas de negocio.
VISTAS_SQLSERVER = {
    "INFORMATION_SCHEMA": {
        "TABLES", "COLUMNS", "VIEWS", "ROUTINES", "PARAMETERS", "TABLE_CONSTRAINTS",
        "KEY_COLUMN_USAGE", "REFERENTIAL_CONSTRAINTS", "CONSTRAINT_COLUMN_USAGE",
        "CHECK_CONSTRAINTS",
    },
    "SYS": {
        "TABLES", "COLUMNS", "OBJECTS", "ALL_OBJECTS", "TRIGGERS", "SQL_MODULES", "INDEXES",
        "INDEX_COLUMNS", "FOREIGN_KEYS", "FOREIGN_KEY_COLUMNS", "KEY_CONSTRAINTS",
        "DEFAULT_CONSTRAINTS", "CHECK_CONSTRAINTS", "TYPES", "SCHEMAS", "VIEWS",
        "PROCEDURES", "PARAMETERS", "SEQUENCES", "SYNONYMS",
    },
}

# Columnas de estructura que pueden salir en claro. Lista cerrada: lo que no esta aqui sigue
# las reglas normales (LOW_VALUE, HIGH_VALUE y ENDPOINT_* NO estan, a proposito).
COLUMNAS_CATALOGO = {
    # --- Oracle ---
    "OWNER", "TABLE_OWNER", "TABLE_NAME", "COLUMN_NAME", "COLUMN_ID", "DATA_TYPE",
    "DATA_TYPE_MOD", "DATA_TYPE_OWNER", "DATA_LENGTH", "DATA_PRECISION", "DATA_SCALE",
    "NULLABLE", "DATA_DEFAULT", "DEFAULT_LENGTH", "CHAR_LENGTH", "CHAR_USED",
    "CHAR_COL_DECL_LENGTH", "VIRTUAL_COLUMN", "HIDDEN_COLUMN", "IDENTITY_COLUMN",
    "COMMENTS", "TABLE_TYPE", "TABLESPACE_NAME", "STATUS", "NUM_ROWS", "LAST_ANALYZED",
    "TEMPORARY", "PARTITIONED", "IOT_TYPE",
    "TRIGGER_NAME", "TRIGGER_TYPE", "TRIGGERING_EVENT", "BASE_OBJECT_TYPE",
    "REFERENCING_NAMES", "WHEN_CLAUSE", "DESCRIPTION", "ACTION_TYPE", "TRIGGER_BODY",
    "COLUMN_USAGE", "CROSSEDITION", "FIRE_ONCE", "BEFORE_STATEMENT", "BEFORE_ROW",
    "AFTER_ROW", "AFTER_STATEMENT", "INSTEAD_OF_ROW",
    "NAME", "TYPE", "LINE", "TEXT", "ORIGIN_CON_ID",
    "OBJECT_NAME", "SUBOBJECT_NAME", "OBJECT_ID", "DATA_OBJECT_ID", "OBJECT_TYPE",
    "CREATED", "LAST_DDL_TIME", "TIMESTAMP", "GENERATED", "SECONDARY", "EDITIONABLE",
    "CONSTRAINT_NAME", "CONSTRAINT_TYPE", "SEARCH_CONDITION", "SEARCH_CONDITION_VC",
    "R_OWNER", "R_CONSTRAINT_NAME", "DELETE_RULE", "DEFERRABLE", "DEFERRED", "VALIDATED",
    "RELY", "INVALID", "VIEW_RELATED", "LAST_CHANGE",
    "INDEX_NAME", "INDEX_TYPE", "INDEX_OWNER", "UNIQUENESS", "COLUMN_POSITION",
    "COLUMN_EXPRESSION", "DESCEND", "POSITION", "VISIBILITY",
    "VIEW_NAME", "TEXT_LENGTH", "TEXT_VC", "READ_ONLY",
    "SEQUENCE_OWNER", "SEQUENCE_NAME", "MIN_VALUE", "MAX_VALUE", "INCREMENT_BY",
    "CYCLE_FLAG", "ORDER_FLAG", "CACHE_SIZE", "LAST_NUMBER",
    "SYNONYM_NAME", "DB_LINK",
    "REFERENCED_OWNER", "REFERENCED_NAME", "REFERENCED_TYPE", "REFERENCED_LINK_NAME",
    "DEPENDENCY_TYPE",
    "PACKAGE_NAME", "ARGUMENT_NAME", "SEQUENCE", "OVERLOAD", "SUBPROGRAM_ID", "IN_OUT",
    "DATA_LEVEL", "DEFAULTED", "PLS_TYPE", "PROCEDURE_NAME", "AGGREGATE", "PIPELINED",
    "IMPLTYPEOWNER", "IMPLTYPENAME", "PARALLEL", "INTERFACE", "DETERMINISTIC", "AUTHID",
    "ATTRIBUTE", "MESSAGE_NUMBER",
    "GRANTOR", "GRANTEE", "PRIVILEGE", "GRANTABLE", "HIERARCHY", "COMMON", "INHERITED",
    # --- SQL Server: INFORMATION_SCHEMA ---
    "TABLE_CATALOG", "TABLE_SCHEMA", "ORDINAL_POSITION", "COLUMN_DEFAULT", "IS_NULLABLE",
    "CHARACTER_MAXIMUM_LENGTH", "CHARACTER_OCTET_LENGTH", "NUMERIC_PRECISION",
    "NUMERIC_PRECISION_RADIX", "NUMERIC_SCALE", "DATETIME_PRECISION",
    "CHARACTER_SET_NAME", "COLLATION_NAME", "VIEW_CATALOG", "VIEW_SCHEMA",
    "VIEW_DEFINITION", "CHECK_OPTION", "IS_UPDATABLE",
    "ROUTINE_CATALOG", "ROUTINE_SCHEMA", "ROUTINE_NAME", "ROUTINE_TYPE",
    "ROUTINE_DEFINITION", "ROUTINE_BODY", "SPECIFIC_CATALOG", "SPECIFIC_SCHEMA",
    "SPECIFIC_NAME", "PARAMETER_NAME", "PARAMETER_MODE", "IS_RESULT",
    "CONSTRAINT_CATALOG", "CONSTRAINT_SCHEMA", "UNIQUE_CONSTRAINT_CATALOG",
    "UNIQUE_CONSTRAINT_SCHEMA", "UNIQUE_CONSTRAINT_NAME", "MATCH_OPTION", "UPDATE_RULE",
    "CHECK_CLAUSE", "IS_DEFERRABLE", "INITIALLY_DEFERRED", "LAST_ALTERED",
    # --- SQL Server: sys.* ---
    "SCHEMA_ID", "PRINCIPAL_ID", "PARENT_OBJECT_ID", "TYPE_DESC", "CREATE_DATE",
    "MODIFY_DATE", "IS_MS_SHIPPED", "IS_PUBLISHED", "IS_SCHEMA_PUBLISHED",
    "SYSTEM_TYPE_ID", "USER_TYPE_ID", "MAX_LENGTH", "PRECISION", "SCALE",
    "IS_IDENTITY", "IS_COMPUTED", "IS_ANSI_PADDED", "IS_ROWGUIDCOL", "IS_FILESTREAM",
    "IS_SPARSE", "IS_COLUMN_SET", "DEFAULT_OBJECT_ID", "RULE_OBJECT_ID",
    "DEFINITION", "USES_ANSI_NULLS", "USES_QUOTED_IDENTIFIER", "IS_SCHEMA_BOUND",
    "PARENT_ID", "PARENT_CLASS", "PARENT_CLASS_DESC", "IS_DISABLED",
    "IS_NOT_FOR_REPLICATION", "IS_INSTEAD_OF_TRIGGER",
    "INDEX_ID", "IS_UNIQUE", "IS_PRIMARY_KEY", "IS_UNIQUE_CONSTRAINT", "KEY_ORDINAL",
    "PARTITION_ORDINAL", "IS_DESCENDING_KEY", "IS_INCLUDED_COLUMN", "INDEX_COLUMN_ID",
    "REFERENCED_OBJECT_ID", "KEY_INDEX_ID", "DELETE_REFERENTIAL_ACTION_DESC",
    "UPDATE_REFERENTIAL_ACTION_DESC", "CONSTRAINT_OBJECT_ID", "CONSTRAINT_COLUMN_ID",
    "PARENT_COLUMN_ID", "REFERENCED_COLUMN_ID", "UNIQUE_INDEX_ID",
    "PARAMETER_ID", "IS_OUTPUT", "IS_READONLY", "HAS_DEFAULT_VALUE", "IS_USER_DEFINED",
    "BASE_OBJECT_NAME",
}

# FROM/JOIN con el nombre CALIFICADO (no se quita el esquema, a diferencia de
# pii_sqlscope.tablas: aqui el esquema decide si "COLUMNS" es catalogo o no).
_RE_TABLA = re.compile(
    r"\b(?:FROM|JOIN)\s+([A-Za-z_][\w$#]*(?:\s*\.\s*[A-Za-z_][\w$#]*)?)",
    re.I,
)
_RE_TABLA_COMA = re.compile(
    r"\s*(?:(?:AS\s+)?[A-Za-z_][\w$#]*)?\s*,\s*"
    r"([A-Za-z_][\w$#]*(?:\s*\.\s*[A-Za-z_][\w$#]*)?)",
    re.I,
)
_PALABRAS_CLAVE = {
    "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "BY", "UNION", "MINUS",
    "INTERSECT", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "ON",
    "AND", "OR", "NOT", "IN", "EXISTS", "CONNECT", "START", "WITH", "AS", "CASE",
    "WHEN", "THEN", "ELSE", "END", "DISTINCT", "FETCH", "OFFSET", "ROWS", "ONLY",
}

# Elemento simple de la lista del SELECT: [alias.]COLUMNA [[AS] ALIAS], o [alias.]*
_RE_ITEM = re.compile(
    r"^(?:(?P<q>[A-Za-z_][\w$#]*)\s*\.\s*)?(?P<col>[A-Za-z_][\w$#]*|\*)"
    r"(?:\s+(?:AS\s+)?(?P<alias>[A-Za-z_][\w$#]*))?$",
    re.I,
)


def _tablas_calificadas(sql):
    encontradas = []
    for m in _RE_TABLA.finditer(sql):
        encontradas.append(re.sub(r"\s+", "", m.group(1)).upper())
        pos = m.end()
        while True:
            cont = _RE_TABLA_COMA.match(sql, pos)
            if not cont:
                break
            nombre = re.sub(r"\s+", "", cont.group(1)).upper()
            if nombre in _PALABRAS_CLAVE:
                break
            encontradas.append(nombre)
            pos = cont.end()
    return [t for t in encontradas if t and t != "DUAL"]


def es_vista_catalogo(nombre_calificado):
    """True si "ESQUEMA.VISTA" o "VISTA" es una vista de estructura de la lista cerrada."""
    partes = nombre_calificado.upper().split(".")
    if len(partes) == 1:
        return partes[0] in VISTAS_ORACLE
    esquema, vista = partes[0], partes[1]
    if esquema == "SYS" and vista in VISTAS_ORACLE:
        return True
    return vista in VISTAS_SQLSERVER.get(esquema, set())


def _lista_select(sql):
    """Elementos de la lista del SELECT principal, o None si no es una consulta simple."""
    s = sql.strip()
    if not re.match(r"(?is)^SELECT\b", s):
        return None  # WITH ..., parentesis delante, etc.
    if re.search(r"(?i)\b(UNION|MINUS|INTERSECT|EXCEPT)\b", s):
        return None
    cuerpo = re.sub(r"(?is)^SELECT\s+(?:DISTINCT\s+|ALL\s+)?(?:TOP\s+\d+\s+)?", "", s)
    m = re.search(r"(?i)\bFROM\b", cuerpo)
    if not m:
        return None
    lista = cuerpo[:m.start()]
    # Cualquier parentesis, comilla, operador o concatenacion = expresion: fuera.
    if re.search(r"[()'\"|+\-/%<>=:@;]", lista):
        return None
    items = [i.strip() for i in lista.split(",")]
    if not items or any(not i for i in items):
        return None
    return items


def es_consulta_catalogo(sql, modelo, strip_comments=None):
    """True si la consulta SOLO lee vistas de estructura con una lista de SELECT simple.

    strip_comments: funcion de pii_sqlscope para quitar comentarios (se inyecta para no
    duplicarla). Si el SQL esta malformado (devuelve ''), no hay excepcion.
    """
    if not sql:
        return False
    limpio = strip_comments(sql) if strip_comments else sql
    if not limpio or not limpio.strip():
        return False

    # Literales vaciados para buscar tablas: "WHERE TEXT LIKE '%FROM RCARTERA%'" es la busqueda
    # tipica en ALL_SOURCE y no lee RCARTERA. Un literal solo podria EJECUTARSE como SQL dentro
    # de una funcion, y en la lista del SELECT no se admiten ni funciones ni comillas; en el
    # WHERE solo daria inferencia por filtro, que es el riesgo ya aceptado (predicate_warning).
    sin_literales = re.sub(r"'(?:[^']|'')*'", "''", limpio)
    tablas = _tablas_calificadas(sin_literales)
    if not tablas or not all(es_vista_catalogo(t) for t in tablas):
        return False

    # Gana el modelo: una tabla propia que se llame como una vista de catalogo es de negocio.
    bruto = (modelo or {}).get("tables") or {}
    if isinstance(bruto, dict):
        en_modelo = {str(k).upper() for k in bruto}
    else:
        en_modelo = {str(t.get("name") or t.get("tableName", "")).upper()
                     for t in bruto if isinstance(t, dict)}
    if any(t.split(".")[-1] in en_modelo for t in tablas):
        return False

    items = _lista_select(limpio)
    if items is None:
        return False
    for item in items:
        m = _RE_ITEM.match(item)
        if not m:
            return False
        col = m.group("col").upper()
        if col != "*" and col not in COLUMNAS_CATALOGO:
            return False
    return True


def columna_de_catalogo(columna):
    return str(columna).strip().upper() in COLUMNAS_CATALOGO


# ---------------------------------------------------------------------------------------------
# Columnas que contienen CODIGO o texto libre (cuerpos de trigger, fuentes, definiciones de
# vista, DEFAULT, CHECK, comentarios). La red de seguridad de pii_detect mira el valor ENTERO,
# asi que un DNI dentro de "IF :NEW.NIF = '12345678Z' THEN" se le escaparia. En estas columnas
# se busca el dato DENTRO del texto y se sustituye solo ese trozo: el codigo sigue legible.
#
# Solo formas FUERTES (DNI/NIE con letra de control valida, IBAN, correo): las debiles (9
# digitos) casarian con constantes numericas del codigo.
# ---------------------------------------------------------------------------------------------
COLUMNAS_CODIGO = {
    "TEXT", "TEXT_VC", "TRIGGER_BODY", "WHEN_CLAUSE", "DESCRIPTION", "DATA_DEFAULT",
    "SEARCH_CONDITION", "SEARCH_CONDITION_VC", "COLUMN_EXPRESSION", "COMMENTS",
    "VIEW_DEFINITION", "ROUTINE_DEFINITION", "CHECK_CLAUSE", "COLUMN_DEFAULT", "DEFINITION",
}

_LETRAS_DNI = "TRWAGMYFPDXBNJZSQVHLCKE"

_RX_EN_TEXTO = [
    ("dni",   re.compile(r"(?<![\w])(\d{8})([A-Za-z])(?![\w])")),
    ("nie",   re.compile(r"(?<![\w])([XYZxyz])(\d{7})([A-Za-z])(?![\w])")),
    ("iban",  re.compile(r"(?<![\w])[A-Z]{2}\d{2}(?: ?\d{4}){4,7}(?: ?\d{1,4})?(?![\w])")),
    ("email", re.compile(r"(?<![\w.+-])[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}(?![\w])")),
]


def _letra_ok(numero, letra):
    return _LETRAS_DNI[int(numero) % 23] == letra.upper()


def buscar_en_texto(texto):
    """[(inicio, fin, forma)] de datos personales DENTRO de un texto, sin solapes."""
    if texto is None:
        return []
    t = str(texto)
    hallados = []
    for forma, rx in _RX_EN_TEXTO:
        for m in rx.finditer(t):
            if forma == "dni" and not _letra_ok(m.group(1), m.group(2)):
                continue
            if forma == "nie":
                num = "XYZ".index(m.group(1).upper())
                if not _letra_ok(f"{num}{m.group(2)}", m.group(3)):
                    continue
            hallados.append((m.start(), m.end(), forma))
    hallados.sort()
    sin_solape, fin = [], -1
    for h in hallados:
        if h[0] >= fin:
            sin_solape.append(h)
            fin = h[1]
    return sin_solape


def redactar_texto(texto, sustituir):
    """Texto con cada dato personal sustituido por sustituir(trozo). (texto, n_sustituciones)."""
    trozos = buscar_en_texto(texto)
    if not trozos:
        return texto, 0
    t = str(texto)
    salida, pos = [], 0
    for ini, fin, _ in trozos:
        salida.append(t[pos:ini])
        salida.append(sustituir(t[ini:fin]))
        pos = fin
    salida.append(t[pos:])
    return "".join(salida), len(trozos)


def columna_de_codigo(columna):
    return str(columna).strip().upper() in COLUMNAS_CODIGO
