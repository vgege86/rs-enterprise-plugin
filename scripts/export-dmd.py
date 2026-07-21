"""
Exporta el modelo JSON a formato Oracle Data Modeler (.dmd).
Preserva posiciones visuales si existe un .dmd previo.

Uso: python export-dmd.py <workspace> <proyecto>
"""

import sys
import json
import uuid
import re
from pathlib import Path
from datetime import datetime
from xml.etree import ElementTree as ET
from xml.dom import minidom

# Tipos Oracle Data Modeler por tipo de dato
ORACLE_DM_TYPES = {
    'VARCHAR2': ('VARCHAR2', 'CHARACTER VARYING'),
    'NVARCHAR2': ('NVARCHAR2', 'NATIONAL CHARACTER VARYING'),
    'CHAR': ('CHAR', 'CHARACTER'),
    'NCHAR': ('NCHAR', 'NATIONAL CHARACTER'),
    'NUMBER': ('NUMBER', 'NUMBER'),
    'INTEGER': ('INTEGER', 'INTEGER'),
    'FLOAT': ('FLOAT', 'FLOAT'),
    'DATE': ('DATE', 'DATE'),
    'TIMESTAMP': ('TIMESTAMP', 'TIMESTAMP'),
    'CLOB': ('CLOB', 'CHARACTER LARGE OBJECT'),
    'BLOB': ('BLOB', 'BINARY LARGE OBJECT'),
    'VARCHAR': ('VARCHAR2', 'CHARACTER VARYING'),
    'DECIMAL': ('NUMBER', 'NUMBER'),
    'INT': ('INTEGER', 'INTEGER'),
    'BIGINT': ('NUMBER', 'NUMBER'),
    'DATETIME': ('DATE', 'DATE'),
    'DATETIME2': ('TIMESTAMP', 'TIMESTAMP'),
    'NVARCHAR': ('NVARCHAR2', 'NATIONAL CHARACTER VARYING'),
    'BIT': ('NUMBER', 'NUMBER'),
}

def new_id():
    return str(uuid.uuid4()).upper()

def parse_type(full_type: str) -> tuple[str, str, str]:
    """Devuelve (base_type, precision, scale) de un tipo como NUMBER(10,2) o VARCHAR2(100)."""
    m = re.match(r'([A-Z0-9_]+)\s*\((\d+)(?:,(\d+))?\)', full_type.upper().strip())
    if m:
        return m.group(1), m.group(2), m.group(3) or '0'
    return full_type.upper().strip(), '', '0'

def get_existing_positions(dmd_path: Path) -> dict:
    """Extrae posiciones x,y de tablas desde un .dmd existente."""
    positions = {}
    if not dmd_path.exists():
        return positions
    try:
        tree = ET.parse(dmd_path)
        root = tree.getroot()
        # Buscar posiciones en diagramas
        for item in root.iter('graphicTable'):
            ref = item.get('tableRef', '')
            x = item.get('x', '')
            y = item.get('y', '')
            if ref and x and y:
                positions[ref] = (x, y)
    except Exception:
        pass
    return positions

def build_dmd(model: dict, existing_positions: dict) -> str:
    """Construye el XML .dmd desde el modelo JSON."""
    now = datetime.now().strftime('%Y-%m-%dT%H:%M:%S')
    project = model.get('project', 'Project')
    model_id = new_id()

    # Mapas de IDs para referencias cruzadas
    table_ids = {}   # table_name -> id
    column_ids = {}  # (table_name, col_name) -> id
    pk_ids = {}      # table_name -> pk_constraint_id

    tables_xml = []
    fk_xml = []
    fk_id = 1

    for table_name, table_def in model.get('tables', {}).items():
        t_id = new_id()
        table_ids[table_name] = t_id
        pk_id = new_id()
        pk_ids[table_name] = pk_id

        cols_xml = []
        pk_col_refs = []
        for col_name, col_def in table_def.get('columns', {}).items():
            c_id = new_id()
            column_ids[(table_name, col_name)] = c_id

            base, prec, scale = parse_type(col_def.get('type', 'VARCHAR2(100)'))
            dm_type, _ = ORACLE_DM_TYPES.get(base, ('VARCHAR2', 'CHARACTER VARYING'))
            mandatory = 'true' if not col_def.get('nullable', True) else 'false'
            is_pk = 'true' if col_def.get('pk') else 'false'
            comment = col_def.get('description', '') or ''

            type_params = ''
            if prec:
                type_params = f' dataTypeParameters="{prec}"' if scale == '0' else f' dataTypeParameters="{prec},{scale}"'

            cols_xml.append(f'''      <column id="{c_id}" name="{col_name}"
               dataTypeID="1" dataTypeName="{dm_type}"{type_params}
               mandatory="{mandatory}" primaryKey="{is_pk}" identity="false"
               autofillDate="false" foreignKey="false">
        <comment>{comment}</comment>
      </column>''')

            if col_def.get('pk'):
                pk_col_refs.append(f'        <primaryKeyColumn columnID="{c_id}"/>')

        pk_block = ''
        if pk_col_refs:
            pk_block = f'''    <primaryKey id="{pk_id}" name="PK_{table_name}">
{chr(10).join(pk_col_refs)}
    </primaryKey>'''

        table_comment = table_def.get('description', '') or ''
        tables_xml.append(f'''  <table id="{t_id}" name="{table_name}">
    <createdTime>{now}</createdTime>
    <modifiedTime>{now}</modifiedTime>
    <columns>
{chr(10).join(cols_xml)}
    </columns>
{pk_block}
    <comment>{table_comment}</comment>
  </table>''')

        # FK associations desde relaciones (solo manual o high confidence)
        for rel in table_def.get('relations', []):
            if rel.get('confidence') not in ('high', None) and rel.get('source') != 'manual':
                continue
            if rel.get('type') not in ('N:1', '1:1'):
                continue
            tgt = rel.get('target_table', '')
            src_col = rel.get('source_column', '')
            tgt_col = rel.get('target_column', '')
            if tgt not in model.get('tables', {}):
                continue
            fk_assoc_id = new_id()
            fk_col_id = new_id()
            src_col_id = column_ids.get((table_name, src_col), '')
            tgt_col_id = column_ids.get((tgt, tgt_col), '')
            if not src_col_id or not tgt_col_id:
                continue
            fk_name = f'FK_{table_name}_{tgt}'[:30]
            fk_xml.append(f'''  <fkAssociation id="{fk_assoc_id}" name="{fk_name}"
               referredTableID="{table_ids.get(tgt, '')}"
               referringTableID="{t_id}"
               deleteRule="NO_ACTION" updateRule="NO_ACTION">
    <comment>{rel.get("inferred_from","")}</comment>
    <fkAssociationColumns>
      <fkAssociationColumn id="{fk_col_id}"
                           referredColumnID="{tgt_col_id}"
                           referringColumnID="{src_col_id}"/>
    </fkAssociationColumns>
  </fkAssociation>''')

    tables_block = '\n'.join(tables_xml)
    fk_block = '\n'.join(fk_xml)

    dmd = f'''<?xml version="1.0" encoding="UTF-8" ?>
<model version="19.1.0.094" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <relationalModels>
    <relationalModel id="{model_id}" name="{project}" createdTime="{now}">
      <tables>
{tables_block}
      </tables>
      <fkAssociations>
{fk_block}
      </fkAssociations>
    </relationalModel>
  </relationalModels>
</model>'''
    return dmd


def main():
    if len(sys.argv) < 3:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto>")
        sys.exit(1)

    workspace  = sys.argv[1]
    proyecto   = sys.argv[2]
    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"
    dmd_path   = Path(workspace) / "BD" / f"{proyecto}.dmd"

    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)

    # utf-8-sig: los hooks PowerShell (PS5.1) escriben model.json con Set-Content -Encoding
    # UTF8, que SIEMPRE antepone BOM — utf-8-sig lo tolera (y funciona igual sin BOM).
    with open(model_path, encoding='utf-8-sig') as f:
        model = json.load(f)

    existing_positions = get_existing_positions(dmd_path)
    dmd_xml = build_dmd(model, existing_positions)

    with open(dmd_path, 'w', encoding='utf-8') as f:
        f.write(dmd_xml)

    table_count = len(model.get('tables', {}))
    print(f"OK — .dmd generado: {dmd_path}")
    print(f"     {table_count} tablas exportadas")
    if existing_positions:
        print(f"     Posiciones visuales preservadas: {len(existing_positions)}")


if __name__ == '__main__':
    main()
