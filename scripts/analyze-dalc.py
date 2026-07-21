"""
Analiza ficheros DALC de proyectos uCollect/RS para inferir relaciones entre tablas.
Actualiza BD/<proyecto>-model.json con las relaciones encontradas.

Uso: python analyze-dalc.py <workspace> <proyecto> <model_path> [solution_path]
"""

import sys
import os
import re
import json
from pathlib import Path

SQL_KEYWORDS = {
    'SELECT', 'FROM', 'WHERE', 'JOIN', 'ON', 'AND', 'OR', 'NOT', 'IN',
    'EXISTS', 'BETWEEN', 'LIKE', 'IS', 'NULL', 'ORDER', 'GROUP', 'BY',
    'HAVING', 'UNION', 'ALL', 'DISTINCT', 'AS', 'SET', 'INTO', 'VALUES',
    'INSERT', 'UPDATE', 'DELETE', 'INNER', 'LEFT', 'RIGHT', 'OUTER',
    'FULL', 'CROSS', 'DUAL', 'TOP', 'ROWNUM', 'FETCH', 'NEXT', 'ROWS',
    'ONLY', 'OFFSET', 'LIMIT', 'WITH', 'CASE', 'WHEN', 'THEN', 'ELSE',
    'END', 'CAST', 'CONVERT', 'COALESCE', 'NVL', 'ISNULL', 'COUNT',
    'SUM', 'MAX', 'MIN', 'AVG', 'TRIM', 'UPPER', 'LOWER', 'SUBSTR',
    'SUBSTRING', 'DECODE', 'IIF', 'OVER', 'PARTITION', 'ROW_NUMBER'
}


def find_dalc_files(workspace: str) -> list[Path]:
    """Localiza todos los ficheros DALC en Online y Batch."""
    ws = Path(workspace)
    dalc_files = []

    # Online: proyectos RSDalc y RSJudiDalc
    for pattern in ["OnLine/**/RSDalc/*.cs", "OnLine/**/RSJudiDalc/*.cs"]:
        dalc_files.extend(ws.glob(pattern))

    # Batch: proyectos Bus* con clases *Dalc.cs
    for pattern in ["Batch/**/Bus*/*Dalc.cs"]:
        dalc_files.extend(ws.glob(pattern))

    return list(set(dalc_files))


def extract_sql_strings(cs_content: str) -> list[str]:
    """Extrae strings que contienen SQL de un fichero C#."""
    sql_fragments = []

    # String literals simples y verbatim (@"...")
    patterns = [
        r'@"((?:[^""]|"""")*)"',   # verbatim @"..."
        r'"((?:[^"\\]|\\.)*)"',    # string normal "..."
    ]

    for pat in patterns:
        for m in re.finditer(pat, cs_content, re.DOTALL):
            s = m.group(1).replace('""', '"')
            if re.search(r'\b(SELECT|INSERT|UPDATE|DELETE|FROM|JOIN)\b', s, re.I):
                sql_fragments.append(s)

    # StringBuilder: concatenar AppendX del mismo metodo
    sb_blocks = re.findall(
        r'(?:StringBuilder|sb)\s*\w*\s*=\s*new\s+StringBuilder[^;]*;(.*?)(?=new\s+StringBuilder|$)',
        cs_content, re.DOTALL | re.I
    )
    for block in sb_blocks:
        parts = re.findall(r'\.Append(?:Line|Format)?\s*\(\s*(?:@?")(.*?)(?:")\s*\)', block, re.DOTALL)
        combined = ' '.join(parts)
        if re.search(r'\b(SELECT|FROM|JOIN)\b', combined, re.I):
            sql_fragments.append(combined)

    return sql_fragments


def parse_alias_map(sql: str) -> dict[str, str]:
    """Construye mapa alias -> tabla_real de una query SQL."""
    alias_map = {}
    # FROM tabla alias, FROM tabla AS alias
    for m in re.finditer(r'\bFROM\s+([A-Z_][A-Z0-9_#]+)(?:\s+(?:AS\s+)?([A-Z_][A-Z0-9_]*))?', sql, re.I):
        table = m.group(1).upper()
        alias = (m.group(2) or table).upper()
        if table not in SQL_KEYWORDS:
            alias_map[alias] = table
            alias_map[table] = table
    # JOIN tabla alias
    for m in re.finditer(r'\bJOIN\s+([A-Z_][A-Z0-9_#]+)(?:\s+(?:AS\s+)?([A-Z_][A-Z0-9_]*))?', sql, re.I):
        table = m.group(1).upper()
        alias = (m.group(2) or table).upper()
        if table not in SQL_KEYWORDS:
            alias_map[alias] = table
            alias_map[table] = table
    return alias_map


def extract_relations(sql: str, alias_map: dict, source_file: str) -> list[dict]:
    """Infiere relaciones desde JOINs y WHERE de una query."""
    relations = []
    sql_upper = sql.upper()

    # --- JOIN ... ON a.col = b.col (confianza HIGH) ---
    join_pattern = re.compile(
        r'\bJOIN\s+([A-Z_][A-Z0-9_#]+)(?:\s+(?:AS\s+)?([A-Z_][A-Z0-9_]*))?\s+ON\s+'
        r'([A-Z_][A-Z0-9_]*)\.([A-Z_][A-Z0-9_]*)\s*=\s*([A-Z_][A-Z0-9_]*)\.([A-Z_][A-Z0-9_]*)',
        re.I
    )
    for m in join_pattern.finditer(sql):
        join_table  = m.group(1).upper()
        join_alias  = (m.group(2) or join_table).upper()
        a1, c1 = m.group(3).upper(), m.group(4).upper()
        a2, c2 = m.group(5).upper(), m.group(6).upper()

        t1 = alias_map.get(a1)
        t2 = alias_map.get(a2)

        if not t1 or not t2 or t1 == t2:
            continue
        if t1 in SQL_KEYWORDS or t2 in SQL_KEYWORDS:
            continue

        relations.append({
            "source_table": t1, "source_column": c1,
            "target_table": t2, "target_column": c2,
            "inferred_from": "JoinClause", "confidence": "high",
            "source_file": source_file, "source": "dalc"
        })

    # --- WHERE a.col = b.col (confianza MEDIUM) ---
    where_match = re.search(r'\bWHERE\b(.+?)(?:\bORDER\b|\bGROUP\b|\bHAVING\b|$)', sql_upper, re.DOTALL)
    if where_match:
        where_body = where_match.group(1)
        where_cond = re.compile(
            r'([A-Z_][A-Z0-9_]*)\.([A-Z_][A-Z0-9_]*)\s*=\s*([A-Z_][A-Z0-9_]*)\.([A-Z_][A-Z0-9_]*)',
            re.I
        )
        for m in where_cond.finditer(where_body):
            a1, c1 = m.group(1).upper(), m.group(2).upper()
            a2, c2 = m.group(3).upper(), m.group(4).upper()
            t1 = alias_map.get(a1)
            t2 = alias_map.get(a2)
            if not t1 or not t2 or t1 == t2:
                continue
            if t1 in SQL_KEYWORDS or t2 in SQL_KEYWORDS:
                continue
            relations.append({
                "source_table": t1, "source_column": c1,
                "target_table": t2, "target_column": c2,
                "inferred_from": "WhereClause", "confidence": "medium",
                "source_file": source_file, "source": "dalc"
            })

    return relations


def extract_tables_from_sql(sql: str) -> list[str]:
    """Extrae nombres de tabla del SQL (FROM, JOIN, INTO, UPDATE)."""
    tables = set()
    for pat in [r'\bFROM\s+([A-Z_][A-Z0-9_#]+)', r'\bJOIN\s+([A-Z_][A-Z0-9_#]+)',
                r'\bINTO\s+([A-Z_][A-Z0-9_#]+)', r'\bUPDATE\s+([A-Z_][A-Z0-9_#]+)']:
        for m in re.finditer(pat, sql, re.I):
            name = m.group(1).upper()
            if name not in SQL_KEYWORDS:
                tables.add(name)
    return list(tables)


def dedup_relations(existing: list, new_rels: list) -> list:
    """Fusiona relaciones evitando duplicados. Preserva source:manual."""
    key = lambda r: (r.get('source_table',''), r.get('source_column',''),
                     r.get('target_table',''), r.get('target_column',''))
    manual = [r for r in existing if r.get('source') == 'manual']
    manual_keys = {key(r) for r in manual}
    dalc_map = {}
    for r in existing:
        if r.get('source') != 'manual':
            dalc_map[key(r)] = r
    for r in new_rels:
        k = key(r)
        if k not in manual_keys:
            dalc_map[k] = r
    return manual + list(dalc_map.values())


def main():
    if len(sys.argv) < 4:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> <model_path>")
        sys.exit(1)

    workspace   = sys.argv[1]
    proyecto    = sys.argv[2]
    model_path  = sys.argv[3]

    # utf-8-sig: los hooks PowerShell (PS5.1) escriben model.json con Set-Content -Encoding
    # UTF8, que SIEMPRE antepone BOM — utf-8-sig lo tolera (y funciona igual sin BOM).
    with open(model_path, 'r', encoding='utf-8-sig') as f:
        model = json.load(f)

    known_tables = set(model.get('tables', {}).keys())
    dalc_files = find_dalc_files(workspace)

    if not dalc_files:
        print(f"WARN: No se encontraron ficheros DALC en {workspace}")
        sys.exit(0)

    print(f"Analizando {len(dalc_files)} ficheros DALC...")

    all_relations: dict[str, list] = {}  # source_table -> [relations]
    tables_found_total = set()

    for cs_file in dalc_files:
        rel_path = str(cs_file.relative_to(workspace))
        try:
            content = cs_file.read_text(encoding='utf-8', errors='replace')
        except Exception as e:
            print(f"WARN: No se puede leer {rel_path}: {e}")
            continue

        sql_strings = extract_sql_strings(content)
        for sql in sql_strings:
            alias_map = parse_alias_map(sql)
            tables_found_total.update(alias_map.values())
            rels = extract_relations(sql, alias_map, rel_path)
            for r in rels:
                src = r['source_table']
                all_relations.setdefault(src, []).append(r)

    # Añadir tablas descubiertas al modelo si no existen
    new_tables = 0
    for tname in tables_found_total:
        if tname in SQL_KEYWORDS:
            continue
        if tname not in model['tables']:
            model['tables'][tname] = {
                "description": "", "source": "dalc",
                "columns": {}, "relations": []
            }
            new_tables += 1

    # Merge relaciones al modelo
    total_rels = 0
    for src_table, rels in all_relations.items():
        if src_table not in model['tables']:
            continue
        existing = model['tables'][src_table].get('relations', [])
        merged = dedup_relations(existing, rels)
        model['tables'][src_table]['relations'] = merged
        total_rels += len([r for r in merged if r.get('source') == 'dalc'])

    model['updated_at'] = __import__('datetime').datetime.now().isoformat()

    with open(model_path, 'w', encoding='utf-8') as f:
        json.dump(model, f, ensure_ascii=False, indent=2)

    print(f"OK — {len(dalc_files)} ficheros analizados")
    print(f"     {new_tables} tablas nuevas detectadas en DALCs")
    print(f"     {total_rels} relaciones DALC en modelo")
    print(f"Modelo: {model_path}")


if __name__ == '__main__':
    main()
