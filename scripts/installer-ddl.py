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
# Orden real de la PK y valor DEFAULT: fuente única en scripts/_dbmodel.py, compartida con
# generate-sql.py. Duplicarlas es justo lo que ya hizo divergir el mapeo de tipos.
from _dbmodel import pk_columns, column_default, pk_orden_ambiguo


def generate_create_table(table_name: str, table_def: dict, engine: str, model_engine: str,
                          inline_defaults: bool = True) -> str:
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
        # DEFAULT va ENTRE el tipo y el NOT NULL: es el único orden válido en los dos motores
        # ("COL TIPO NOT NULL DEFAULT x" es error de sintaxis en Oracle y en SQL Server).
        default = column_default(col_def) if inline_defaults else ""
        default_sql = f" DEFAULT {default}" if default else ""
        cdesc = f"  -- {col_def['description']}" if col_def.get('description') else ""
        col_lines.append((f"    {col_name} {col_type}{default_sql}{nullable}", cdesc))

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

    # Un DEFAULT es una EXPRESIÓN del motor de origen (SYSDATE, getdate(), ((0))...), no un
    # tipo: `adapt_type` no lo traduce y no hay traducción automática fiable. Si se genera para
    # un motor distinto al del modelo, inlinearlo produciría un CREATE TABLE que revienta entero
    # en el cliente. En ese caso salen aparte, comentados, para que alguien los porte a mano.
    inline_defaults = (target_engine == model_engine)

    lines = [
        f"-- Creación de tablas — instalación limpia de {proyecto}",
        f"-- Motor: {target_engine}",
        f"-- Fecha: {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        f"-- SIN schema (tabla / PK / índices sin calificar) — ejecutar en el schema destino",
        "",
    ]

    idx_block = []
    def_block = []
    pk_ambiguas = []
    tables = model.get('tables', {})
    n_ddl = 0
    n_def = 0
    for table_name, table_def in tables.items():
        # Saltar tablas huérfanas (existen en modelo pero no en BD real)
        if table_def.get('orphan'):
            continue
        if pk_orden_ambiguo(table_def):
            pk_ambiguas.append(table_name)
        lines.append(generate_create_table(table_name, table_def, target_engine, model_engine,
                                           inline_defaults))
        lines.append("")
        idx_block.extend(generate_index_statements(table_name, table_def))
        for col_name, col_def in table_def.get('columns', {}).items():
            d = column_default(col_def)
            if not d:
                continue
            n_def += 1
            if not inline_defaults:
                def_block.append(f"-- ALTER TABLE {table_name} MODIFY {col_name} DEFAULT {d};")
        n_ddl += 1

    if idx_block:
        lines.append("-- ============================================================")
        lines.append("-- ÍNDICES")
        lines.append("-- ============================================================")
        lines.extend(idx_block)
        lines.append("")

    if def_block:
        lines.append("-- ============================================================")
        lines.append(f"-- VALORES POR DEFECTO — SIN APLICAR ({len(def_block)})")
        lines.append(f"-- El modelo se capturó en {model_engine} y esto se generó para")
        lines.append(f"-- {target_engine}: las expresiones de abajo son sintaxis de {model_engine}")
        lines.append("-- y hay que portarlas a mano antes de descomentarlas.")
        lines.append("-- ============================================================")
        lines.extend(def_block)
        lines.append("")

    with open(out_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    if pk_ambiguas:
        # No se aborta: el DDL es válido y las tablas se crean. Lo que no se puede garantizar
        # es el ORDEN de la clave, y con él los accesos por prefijo. Eso no da error nunca.
        print(f"     AVISO: {len(pk_ambiguas)} tabla(s) mezclan ordinal y booleano en 'pk':")
        print(f"            {', '.join(pk_ambiguas[:8])}{' ...' if len(pk_ambiguas) > 8 else ''}")
        print("            La PK sale en ORDEN DE DECLARACIÓN, que puede no ser el de la clave.")
        print("            Resincroniza el modelo (/rs-erd o sync-from-db.ps1) antes de entregar.")

    print(f"OK — DDL generado: {out_path}")
    print(f"     {n_ddl} tablas | {len(idx_block)} índices | {n_def} defaults | Motor: {target_engine}")
    if n_def == 0:
        # Un modelo sin defaults casi nunca es una BD sin defaults: lo normal es que el
        # model.json se sincronizara antes de que sync-from-db.ps1 los extrajera.
        print("     AVISO: ninguna columna del modelo declara 'default'. Si la BD sí tiene")
        print("            valores por defecto, resincroniza el modelo (/rs-erd o sync-from-db.ps1)")
        print("            antes de entregar: el cliente los perdería.")
    elif not inline_defaults:
        print(f"     AVISO: {n_def} defaults NO inlineados (modelo {model_engine} → destino "
              f"{target_engine}); van comentados al final del fichero.")


if __name__ == '__main__':
    main()
