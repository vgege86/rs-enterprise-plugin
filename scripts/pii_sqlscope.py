"""Extrae de un SQL las tablas consultadas y las columnas usadas como filtro.

No es un parser de SQL. Reconoce las formas habituales en las consultas que generan
los agentes. Lo que no reconoce hace que la columna quede "no resuelta", y una columna
no resuelta se enmascara: la imprecision degrada hacia el lado seguro, nunca al reves.
"""
import re


def _strip_comments(sql):
    """Elimina comentarios SQL (-- y /* */) preservando strings literales.

    Sustituye cada tramo de comentario con un espacio para no unir tokens.
    Los comentarios dentro de strings literales ('...') se preservan intactos.

    Si se alcanza el fin del SQL dentro de un string literal no cerrado (SQL
    malformado), retorna string vacio. El alcance de una consulta malformada es
    indeterminable, y un alcance indeterminable debe retornar cero tablas.
    Falla hacia lo seguro: todas las columnas resultan sin resolver y por tanto
    enmascaradas segun su forma de valor.
    """
    if not sql:
        return sql

    result = []
    i = 0
    in_string = False

    while i < len(sql):
        c = sql[i]

        # Manejar strings literales
        if c == "'":
            # Toggle string state. Maneja '' (escaped single quote)
            result.append(c)
            i += 1
            if in_string and i < len(sql) and sql[i] == "'":
                # Escaped quote ''
                result.append(sql[i])
                i += 1
            else:
                in_string = not in_string
            continue

        # Fuera de strings, buscar comentarios
        if not in_string:
            if i + 1 < len(sql) and sql[i:i+2] == '--':
                # Comentario de linea: hasta el final de linea
                result.append(' ')
                i += 2
                while i < len(sql) and sql[i] not in '\n':
                    i += 1
                if i < len(sql):
                    result.append(sql[i])
                    i += 1
                continue

            if i + 1 < len(sql) and sql[i:i+2] == '/*':
                # Bloque comentado: hasta */
                result.append(' ')
                i += 2
                while i < len(sql):
                    if i + 1 < len(sql) and sql[i:i+2] == '*/':
                        i += 2
                        break
                    i += 1
                continue

        # Caracter normal (dentro de string o fuera de comentario)
        result.append(c)
        i += 1

    # Si terminamos dentro de un string no cerrado, el SQL es malformado.
    # Retornar string vacio para fallar seguro (alcance indeterminable).
    if in_string:
        return ''

    return ''.join(result)


# FROM/JOIN seguido del nombre, admitiendo "ESQUEMA . TABLA". El parentesis de una
# subconsulta no casa (no esta en la clase de caracteres), asi que se ignora y se
# recoge la tabla de dentro en la siguiente coincidencia.
_RE_TABLA = re.compile(
    r"\b(?:FROM|JOIN)\s+([A-Za-z_][\w$#]*(?:\s*\.\s*[A-Za-z_][\w$#]*)?)",
    re.I,
)

# Continuacion de una lista de tablas separadas por comas (join antiguo, la forma habitual
# en el SQL heredado de uCollect: "FROM RDEUDORES d, REXPEDIENTES e WHERE d.ID = e.ID").
# Se aplica repetidamente A PARTIR del final de cada tabla ya reconocida: alias opcional,
# coma, siguiente tabla. Sin esto solo se recogia la PRIMERA tabla y todas las columnas de
# las demas caian a "no resuelta", es decir, decididas por la forma de sus valores.
_RE_TABLA_COMA = re.compile(
    r"\s*(?:(?:AS\s+)?[A-Za-z_][\w$#]*)?\s*,\s*"
    r"([A-Za-z_][\w$#]*(?:\s*\.\s*[A-Za-z_][\w$#]*)?)",
    re.I,
)

# Palabras que nunca son un nombre de tabla. Solo se usan para cortar la lista de comas:
# una clausula como "ORDER BY a, b" no debe colar "b" como tabla.
_PALABRAS_CLAVE = {
    "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "BY", "UNION", "MINUS",
    "INTERSECT", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "ON",
    "AND", "OR", "NOT", "IN", "EXISTS", "CONNECT", "START", "WITH", "AS", "CASE",
    "WHEN", "THEN", "ELSE", "END", "DISTINCT", "FETCH", "OFFSET", "ROWS", "ONLY",
}

# Columna a la izquierda de un comparador dentro del WHERE. Admite el alias delante
# ("d.NOMBRE"), del que solo interesa la parte de la columna.
_RE_PREDICADO = re.compile(
    r"\b(?:[A-Za-z_][\w$#]*\s*\.\s*)?([A-Za-z_][\w$#]*)\s*"
    r"(?:=|<>|!=|<|>|<=|>=|\bLIKE\b|\bIN\b|\bBETWEEN\b)",
    re.I,
)

# Tablas que nunca aportan datos y ensucian el ambito.
_IGNORADAS = {"DUAL"}


def _normalizar(bruto):
    nombre = re.sub(r"\s+", "", bruto)
    if "." in nombre:
        nombre = nombre.rsplit(".", 1)[1]
    return nombre.upper()


def _unicos(seq):
    vistos, salida = set(), []
    for x in seq:
        if x not in vistos:
            vistos.add(x)
            salida.append(x)
    return salida


def tablas(sql):
    """Tablas del FROM/JOIN, en mayusculas, sin esquema, sin duplicados, en orden.

    Reconoce tambien el join antiguo por comas ("FROM A a, B b"), que es la forma
    habitual del SQL heredado de uCollect.
    """
    if not sql:
        return []
    sql = _strip_comments(sql)
    encontradas = []
    for m in _RE_TABLA.finditer(sql):
        encontradas.append(_normalizar(m.group(1)))
        pos = m.end()
        while True:
            cont = _RE_TABLA_COMA.match(sql, pos)
            if not cont:
                break
            nombre = _normalizar(cont.group(1))
            if nombre in _PALABRAS_CLAVE:
                break
            encontradas.append(nombre)
            pos = cont.end()
    return _unicos(t for t in encontradas if t and t not in _IGNORADAS)


def predicados(sql):
    """Columnas usadas como filtro en el WHERE, en mayusculas, sin duplicados.

    Alimenta el aviso pii_predicate_warning: filtrar por una columna PII permite
    inferir su valor aunque la salida vaya enmascarada (ver seccion 5.2c del documento
    docs/proteccion-pii-consultas-bd.md). Se avisa, no se bloquea.
    """
    if not sql:
        return []
    sql = _strip_comments(sql)
    partes = re.split(r"\bWHERE\b", sql, maxsplit=1, flags=re.I)
    if len(partes) < 2:
        return []
    return _unicos(m.group(1).upper() for m in _RE_PREDICADO.finditer(partes[1]))
