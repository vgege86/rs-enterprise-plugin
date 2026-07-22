"""
Genera DDL (CREATE TABLE, ALTER TABLE) desde el modelo JSON.
Soporta Oracle y SQL Server con tipos correctos para cada motor.

Uso: python generate-sql.py <workspace> <proyecto> [ORACLE|SQLSERVER]
"""

import sys
import json
from pathlib import Path
from datetime import datetime

# Mapeo de tipos Oracle ⇄ SQL Server: fuente única en scripts/_dbtypes.py (antes duplicado aquí
# y en installer-ddl.py). Los scripts corren con scripts/ en sys.path → import directo.
from _dbtypes import adapt_type, ensure_oracle_char_semantics


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
