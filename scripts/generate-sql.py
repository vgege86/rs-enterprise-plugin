"""
Genera DDL (CREATE TABLE, ALTER TABLE) desde el modelo JSON.
Soporta Oracle y SQL Server con tipos correctos para cada motor.

Uso: python generate-sql.py <workspace> <proyecto> [ORACLE|SQLSERVER]
"""

import sys
import json
from pathlib import Path
from datetime import datetime

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
    import re
    def add_char(m):
        type_name, size = m.group(1), m.group(2)
        if 'CHAR' in size.upper() or 'BYTE' in size.upper():
            return m.group(0)  # ya tiene calificador explícito
        return f"{type_name}({size} CHAR)"
    return re.sub(r'(VARCHAR2|NVARCHAR2|CHAR)\((\d+)\)', add_char, col_type, flags=re.IGNORECASE)


def generate_create_table(table_name: str, table_def: dict, engine: str, model_engine: str) -> str:
    lines = []
    lines.append(f"-- {table_def.get('description', '')}".strip())
    lines.append(f"CREATE TABLE {table_name} (")

    cols = table_def.get('columns', {})
    pk_cols = [c for c, d in cols.items() if d.get('pk')]
    # (definicion, comentario) — el comentario NUNCA se concatena antes de la coma:
    # "COL TIPO NOT NULL -- texto," deja la coma dentro del comentario y el CREATE TABLE
    # se queda sin separador de columnas (ORA-00907 en Oracle; error de sintaxis en SQL Server).
    col_lines = []

    for col_name, col_def in cols.items():
        col_type = adapt_type(col_def.get('type', 'VARCHAR2(100)'), model_engine, engine)
        if engine == 'ORACLE':
            col_type = ensure_oracle_char_semantics(col_type)
        nullable = "" if col_def.get('nullable', True) else " NOT NULL"
        desc = f"  -- {col_def['description']}" if col_def.get('description') else ""
        col_lines.append((f"    {col_name} {col_type}{nullable}", desc))

    if pk_cols:
        col_lines.append((f"    CONSTRAINT PK_{table_name} PRIMARY KEY ({', '.join(pk_cols)})", ""))

    ultimo = len(col_lines) - 1
    lines.append('\n'.join(
        f"{defn}{'' if i == ultimo else ','}{comment}"
        for i, (defn, comment) in enumerate(col_lines)
    ))
    lines.append(');')

    return '\n'.join(lines)


def generate_index_statements(table_name: str, table_def: dict, engine: str, schema: str) -> list[str]:
    stmts = []
    for idx in table_def.get('indexes', []):
        idx_name = idx.get('name', '')
        cols     = idx.get('columns', [])
        unique   = idx.get('unique', False)
        if not idx_name or not cols:
            continue
        unique_kw = 'UNIQUE ' if unique else ''
        cols_str  = ', '.join(cols)
        if engine == 'ORACLE':
            prefix = f"{schema}." if schema else ""
            stmts.append(f"CREATE {unique_kw}INDEX {prefix}{idx_name} ON {prefix}{table_name} ({cols_str});")
        else:
            stmts.append(f"CREATE {unique_kw}INDEX {idx_name} ON dbo.{table_name} ({cols_str});")
    return stmts


def generate_fk_statements(table_name: str, table_def: dict, engine: str) -> list[str]:
    stmts = []
    for rel in table_def.get('relations', []):
        if rel.get('type') in ('N:1', '1:1') and rel.get('confidence') in ('high', 'medium'):
            src_col = rel['source_column']
            tgt_tab = rel['target_table']
            tgt_col = rel['target_column']
            fk_name = f"FK_{table_name}_{tgt_tab}"[:30]
            stmts.append(
                f"-- Relacion inferida desde {rel.get('source_file','DALC')} (confianza: {rel.get('confidence','')})\n"
                f"-- ALTER TABLE {table_name} ADD CONSTRAINT {fk_name}\n"
                f"--     FOREIGN KEY ({src_col}) REFERENCES {tgt_tab}({tgt_col});"
            )
    return stmts


def main():
    if len(sys.argv) < 3:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> [ORACLE|SQLSERVER]")
        sys.exit(1)

    workspace = sys.argv[1]
    proyecto  = sys.argv[2]
    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"

    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)

    # utf-8-sig: los hooks PowerShell (PS5.1) escriben model.json con Set-Content -Encoding
    # UTF8, que SIEMPRE antepone BOM — utf-8-sig lo tolera (y funciona igual sin BOM).
    with open(model_path, encoding='utf-8-sig') as f:
        model = json.load(f)

    model_engine = model.get('engine', 'ORACLE')
    target_engine = sys.argv[3].upper() if len(sys.argv) > 3 else model_engine

    out_dir = Path("C:/AIS") / proyecto.lower() / "scripts"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{proyecto}-ddl-{target_engine.lower()}.sql"

    lines = [
        f"-- DDL generado desde modelo {proyecto}",
        f"-- Motor: {target_engine}",
        f"-- Fecha: {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        f"-- Relaciones comentadas (BD sin FKs declaradas — solo referencia)",
        "",
    ]

    # Sin default hardcodeado: un modelo sin 'schema' no debe quedar calificado con el
    # esquema de otro proyecto (ver informe de diagnostico). Si falta, no se califica.
    schema    = (model.get('schema') or '').upper()
    fk_block  = []
    idx_block = []
    for table_name, table_def in model.get('tables', {}).items():
        lines.append(generate_create_table(table_name, table_def, target_engine, model_engine))
        lines.append("")
        fk_block.extend(generate_fk_statements(table_name, table_def, target_engine))
        idx_block.extend(generate_index_statements(table_name, table_def, target_engine, schema))

    if idx_block:
        lines.append("-- ============================================================")
        lines.append("-- ÍNDICES")
        lines.append("-- ============================================================")
        lines.extend(idx_block)
        lines.append("")

    if fk_block:
        lines.append("-- ============================================================")
        lines.append("-- RELACIONES INFERIDAS (comentadas — para referencia)")
        lines.append("-- ============================================================")
        lines.extend(fk_block)

    with open(out_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    print(f"OK — DDL generado: {out_path}")
    print(f"     {len(model.get('tables', {}))} tablas | Motor: {target_engine}")


if __name__ == '__main__':
    main()
