"""Mapeo de tipos entre motores (Oracle ⇄ SQL Server) — fuente única.

Antes estaba duplicado literalmente en generate-sql.py e installer-ddl.py; las dos copias ya
habían divergido (installer-ddl.py se dejó `RAW` sin mapear), que es justo el fallo que centralizar
aquí evita. Los scripts se ejecutan con su propia carpeta (`scripts/`) en `sys.path`, así que
`import _dbtypes` resuelve sin trucos aunque el nombre de los otros scripts lleve guion.
"""

import re

# Mapeo de tipos Oracle → SQL Server
ORACLE_TO_SS = {
    'NUMBER': 'DECIMAL', 'VARCHAR2': 'VARCHAR', 'NVARCHAR2': 'NVARCHAR',
    'DATE': 'DATETIME2', 'TIMESTAMP': 'DATETIME2', 'CLOB': 'NVARCHAR(MAX)',
    'BLOB': 'VARBINARY(MAX)', 'CHAR': 'CHAR', 'NCHAR': 'NCHAR',
    'INTEGER': 'INT', 'FLOAT': 'FLOAT', 'BINARY_FLOAT': 'FLOAT',
    'BINARY_DOUBLE': 'FLOAT', 'RAW': 'VARBINARY',
}

# Mapeo SQL Server → Oracle
SS_TO_ORACLE = {
    'INT': 'NUMBER(10)', 'BIGINT': 'NUMBER(19)', 'SMALLINT': 'NUMBER(5)',
    'TINYINT': 'NUMBER(3)', 'BIT': 'NUMBER(1)', 'FLOAT': 'BINARY_DOUBLE',
    'REAL': 'BINARY_FLOAT', 'DECIMAL': 'NUMBER', 'NUMERIC': 'NUMBER',
    'VARCHAR': 'VARCHAR2', 'NVARCHAR': 'NVARCHAR2', 'CHAR': 'CHAR',
    'NCHAR': 'NCHAR', 'TEXT': 'CLOB', 'NTEXT': 'NCLOB',
    'DATETIME': 'DATE', 'DATETIME2': 'TIMESTAMP', 'DATE': 'DATE',
    'VARBINARY': 'BLOB',
}


def adapt_type(col_type: str, from_engine: str, to_engine: str) -> str:
    if from_engine == to_engine:
        return col_type
    base = col_type.split('(')[0].upper()
    suffix = col_type[len(base):]
    if from_engine == 'ORACLE' and to_engine == 'SQLSERVER':
        mapped = ORACLE_TO_SS.get(base, base)
        if base == 'NUMBER' and not suffix:
            return 'DECIMAL(18,2)'
        return mapped + suffix
    elif from_engine == 'SQLSERVER' and to_engine == 'ORACLE':
        mapped = SS_TO_ORACLE.get(base, base)
        return mapped + suffix
    return col_type


def ensure_oracle_char_semantics(col_type: str) -> str:
    """Añade semántica CHAR a VARCHAR2/NVARCHAR2/CHAR en Oracle.
    Sin CHAR, Oracle usa semántica de bytes por defecto, lo que puede truncar
    strings con caracteres multibyte (UTF-8). VARCHAR2(n) → VARCHAR2(n CHAR).
    """
    def add_char(m):
        type_name, size = m.group(1), m.group(2)
        if 'CHAR' in size.upper() or 'BYTE' in size.upper():
            return m.group(0)  # ya tiene calificador explícito
        return f"{type_name}({size} CHAR)"
    return re.sub(r'(VARCHAR2|NVARCHAR2|CHAR)\((\d+)\)', add_char, col_type, flags=re.IGNORECASE)


# ---------------------------------------------------------------------------------------
# Tipos que NO pueden emitirse sin tamaño.
#
# Dos categorías, y la segunda es la peligrosa:
#   - INVALIDOS: el motor rechaza el DDL. RAW sin longitud da ORA-00906 ("missing left
#     parenthesis") y la instalación del cliente se para en seco. Ruidoso, pero honesto.
#   - SILENCIOSOS: el DDL es válido y significa (1). CHAR/NCHAR/binary/varbinary sin longitud
#     crean una columna de 1 carácter/byte: la instalación termina OK y los datos se truncan
#     después, sin un solo error. Este es el que hay que cazar aquí, porque en el cliente ya
#     no se caza.
#
# El chequeo vive junto al mapeo de tipos a propósito: `adapt_type` con from==to devuelve la
# cadena TAL CUAL, así que un tipo mal capturado en el modelo llega intacto al .sql. Sin este
# gate el generador imprime "OK — DDL generado" sobre 241 KB de DDL que no compila.
# ---------------------------------------------------------------------------------------
TIPOS_EXIGEN_TAMANO_INVALIDO = {
    'ORACLE':    {'RAW', 'VARCHAR2', 'NVARCHAR2', 'VARCHAR'},
    'SQLSERVER': set(),
}
TIPOS_EXIGEN_TAMANO_SILENCIOSO = {
    'ORACLE':    {'CHAR', 'NCHAR'},
    'SQLSERVER': {'CHAR', 'NCHAR', 'VARCHAR', 'NVARCHAR', 'BINARY', 'VARBINARY'},
}


def falta_tamano(col_type: str, engine: str):
    """¿Este tipo necesita un tamaño explícito y viene sin él?

    Devuelve None si está bien, o 'invalido' / 'silencioso' según qué pase en el cliente.
    Un tipo con paréntesis —incluido (MAX)— se da por bueno: aquí solo se comprueba que el
    tamaño esté, no que sea razonable.
    """
    if not col_type:
        return None
    t = col_type.strip()
    if '(' in t:
        return None
    base = t.split()[0].upper() if t.split() else t.upper()
    eng = (engine or '').upper()
    if base in TIPOS_EXIGEN_TAMANO_INVALIDO.get(eng, set()):
        return 'invalido'
    if base in TIPOS_EXIGEN_TAMANO_SILENCIOSO.get(eng, set()):
        return 'silencioso'
    return None
