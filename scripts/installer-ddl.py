"""
Genera el DDL de creación de TODAS las tablas del modelo, SIN schema en ningún sitio
(ni en la tabla, ni en la PK, ni en los índices). Para el instalador de cliente
(carpeta Instalador\\Scripts) — instalación limpia en el servidor destino.

Reutiliza la lógica de tipos de scripts/_dbtypes.py (adapt_type / semántica CHAR Oracle),
compartida con generate-sql.py, pero a diferencia de aquél escribe el fichero en la ruta
indicada y omite el prefijo de schema de los índices (generate-sql.py sí lo pone).

Uso: python installer-ddl.py <workspace> <proyecto> <out.sql> [ORACLE|SQLSERVER]
"""

import sys
import json
from pathlib import Path
from datetime import datetime

# Salida siempre UTF-8 (la consola Windows por defecto es cp1252 y rompe con é, —, etc.)
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# Mapeo de tipos Oracle ⇄ SQL Server: fuente única en scripts/_dbtypes.py (antes duplicado aquí
# y en generate-sql.py; las copias ya habían divergido en 'RAW'). scripts/ está en sys.path.
from _dbtypes import adapt_type, ensure_oracle_char_semantics


def pk_columns(table_def: dict) -> list:
    """Columnas de la PK en su orden real.

    `pk` admite dos formas en el modelo: booleano (orden = el de declaración de las
    columnas) o entero con la posición dentro de la PK (1, 2, 3...). El orden importa:
    es el del índice que respalda la PK, y con el orden cambiado se pierden los accesos
    por prefijo de clave.
    """
    cols = [(c, d.get('pk')) for c, d in table_def.get('columns', {}).items() if d.get('pk')]

    def pos(v):
        # bool es subclase de int: hay que descartarlo antes de tratarlo como ordinal
        return v if isinstance(v, int) and not isinstance(v, bool) else 0

    if any(pos(v) for _, v in cols):
        # sort estable: las que no declaran ordinal mantienen su orden relativo al final
        cols.sort(key=lambda cv: (pos(cv[1]) == 0, pos(cv[1])))
    return [c for c, _ in cols]


def generate_create_table(table_name: str, table_def: dict, engine: str, model_engine: str) -> str:
    lines = []
    desc = (table_def.get('description') or '').strip()
    if desc:
        lines.append(f"-- {desc}")
    lines.append(f"CREATE TABLE {table_name} (")

    cols = table_def.get('columns', {})
    pk_cols = pk_columns(table_def)
    # (definición, comentario) — el comentario NUNCA se concatena antes de la coma:
    # "COL TIPO NOT NULL -- texto," dejaría la coma dentro del comentario y el
    # CREATE TABLE se queda sin separador de columnas (ORA-00907).
    col_lines = []

    for col_name, col_def in cols.items():
        col_type = adapt_type(col_def.get('type', 'VARCHAR2(100)'), model_engine, engine)
        if engine == 'ORACLE':
            col_type = ensure_oracle_char_semantics(col_type)
        nullable = "" if col_def.get('nullable', True) else " NOT NULL"
        cdesc = f"  -- {col_def['description']}" if col_def.get('description') else ""
        col_lines.append((f"    {col_name} {col_type}{nullable}", cdesc))

    # PK inline, SIN schema (PK_<tabla>)
    if pk_cols:
        col_lines.append((f"    CONSTRAINT PK_{table_name} PRIMARY KEY ({', '.join(pk_cols)})", ""))

    ultimo = len(col_lines) - 1
    lines.append('\n'.join(f"{defn}{'' if i == ultimo else ','}{comment}"
                           for i, (defn, comment) in enumerate(col_lines)))
    lines.append(');')
    return '\n'.join(lines)


def generate_index_statements(table_name: str, table_def: dict) -> list:
    """Índices SIN schema — ni en el nombre del índice ni en la tabla."""
    stmts = []
    pk_cols = pk_columns(table_def)
    pk_name = f"PK_{table_name}"
    for idx in table_def.get('indexes', []):
        idx_name = idx.get('name', '')
        cols     = idx.get('columns', [])
        unique   = idx.get('unique', False)
        if not idx_name or not cols:
            continue
        # No emitir índice que dé soporte a la PK (ya creada inline como constraint).
        # Se compara por CONJUNTO de columnas, no por lista: el modelo puede traer el
        # índice con las columnas en otro orden y entonces se colaba un CREATE INDEX
        # duplicado. Y si además coincide el nombre -> ORA-00955 al instalar.
        if idx_name.upper() == pk_name.upper():
            continue
        if unique and pk_cols and set(cols) == set(pk_cols):
            continue
        unique_kw = 'UNIQUE ' if unique else ''
        cols_str  = ', '.join(cols)
        stmts.append(f"CREATE {unique_kw}INDEX {idx_name} ON {table_name} ({cols_str});")
    return stmts


def main():
    if len(sys.argv) < 4:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> <out.sql> [ORACLE|SQLSERVER]")
        sys.exit(1)

    workspace = sys.argv[1]
    proyecto  = sys.argv[2]
    out_path  = Path(sys.argv[3])
    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"

    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)

    with open(model_path, encoding='utf-8-sig') as f:
        model = json.load(f)

    model_engine  = (model.get('engine') or 'ORACLE').upper()
    target_engine = sys.argv[4].upper() if len(sys.argv) > 4 else model_engine

    out_path.parent.mkdir(parents=True, exist_ok=True)

    lines = [
        f"-- Creación de tablas — instalación limpia de {proyecto}",
        f"-- Motor: {target_engine}",
        f"-- Fecha: {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        f"-- SIN schema (tabla / PK / índices sin calificar) — ejecutar en el schema destino",
        "",
    ]

    idx_block = []
    tables = model.get('tables', {})
    n_ddl = 0
    for table_name, table_def in tables.items():
        # Saltar tablas huérfanas (existen en modelo pero no en BD real)
        if table_def.get('orphan'):
            continue
        lines.append(generate_create_table(table_name, table_def, target_engine, model_engine))
        lines.append("")
        idx_block.extend(generate_index_statements(table_name, table_def))
        n_ddl += 1

    if idx_block:
        lines.append("-- ============================================================")
        lines.append("-- ÍNDICES")
        lines.append("-- ============================================================")
        lines.extend(idx_block)
        lines.append("")

    with open(out_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    print(f"OK — DDL generado: {out_path}")
    print(f"     {n_ddl} tablas | {len(idx_block)} índices | Motor: {target_engine}")


if __name__ == '__main__':
    main()
