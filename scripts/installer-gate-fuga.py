"""
Gate de fuga de metadatos de desarrollo en el paquete del cliente.

Recorre los artefactos que se entregan (`<destino>\\Scripts\\**`) y FALLA si encuentra algo que
solo tiene sentido dentro del equipo:

    · descripciones del modelo JSON (`description` de tabla o columna)
    · marcas de política PII (`"pii"`, `"safe"`, `pii:`, `clasificacion`)
    · referencias a tickets internos (JIRA-1234, Mantis #1234, "ticket 1234")
    · rutas del workspace de desarrollo y nombres de conexión del .rs-databases.json

⛔ POR QUÉ ES UN GATE Y NO UNA CONVENCIÓN

    Hasta la 3.25.0 el generador de DDL inlineaba las `description` del modelo como comentarios
    del `.sql` que se copia al servidor del cliente:

        -- Cabecera de expedientes de reclamación
        CREATE TABLE ...
            OGESTADOINI VARCHAR2(10 CHAR),  -- Estado inicial, ver documento funcional

    Nadie lo había decidido: era un efecto de que la fuente del DDL fuera el mismo fichero
    donde se documenta para desarrollo. En cuanto la fuente pasa a ser la BD el problema
    desaparece por construcción, pero "desaparece por construcción" es justo el tipo de
    afirmación que hay que comprobar en vez de suponer — y el modelo sigue existiendo, con sus
    descripciones y sus marcas PII, a un `import` de distancia.

    El gate no confía en que el generador se porte bien: mira el artefacto que se entrega.

⛔ FALLA CERRADO. Si encuentra una fuga devuelve exit 1 y el paquete NO es entregable. No
"limpia" el fichero: borrar la línea dejaría el generador que la produjo intacto, y la
siguiente generación la traería otra vez.

Uso: python installer-gate-fuga.py <carpeta> [--modelo <ruta model.json>]
"""

import sys
import re
import json
from pathlib import Path

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# Extensiones que se revisan: todo lo que se copia al servidor del cliente y es texto.
EXTENSIONES = {".sql", ".json", ".txt", ".ps1", ".md", ".config", ".xml"}

# Marcas de la política PII y del esquema del modelo. Ancladas a la forma en que aparecen en el
# JSON para no disparar con una columna que se llame SAFE o con la palabra suelta en un
# comentario legítimo.
PATRONES = [
    ("marca PII del modelo",
     re.compile(r'"(pii|safe|clasificacion|clasificación)"\s*:', re.IGNORECASE)),
    ("marca PII del modelo",
     re.compile(r'\bpii\s*[:=]\s*(true|false|"|\')', re.IGNORECASE)),
    ("campo 'description' del modelo",
     re.compile(r'"description"\s*:', re.IGNORECASE)),
    ("referencia a ticket interno",
     re.compile(r'\b(?:[A-Z][A-Z0-9]{1,9}-\d{1,6}\b|mantis\s*#?\s*\d+|ticket\s*#?\s*\d+|issue\s*#\s*\d+)',
                re.IGNORECASE)),
    ("ruta del workspace de desarrollo",
     re.compile(r'[A-Za-z]:\\(?:SVN|GIT)\\', re.IGNORECASE)),
    ("fichero de conexiones de desarrollo",
     re.compile(r'\.rs-databases\.json', re.IGNORECASE)),
]

# Falsos positivos conocidos del patrón de ticket: códigos que SÍ pertenecen al producto o al
# motor y que se parecen a un identificador de incidencia. Sin esta lista el gate cría avisos
# que nadie vuelve a mirar, que es la forma más rápida de que un gate deje de servir.
NO_ES_TICKET = re.compile(
    r'^(?:ORA-\d+|SP2-\d+|PLS-\d+|TNS-\d+|IMP-\d+|EXP-\d+|UTF-8|ISO-\d+|SHA-\d+|RFC-\d+'
    r'|AL32UTF8|NLS-\d+|W\d+-\d+)$', re.IGNORECASE)


def descripciones_del_modelo(model_path: Path) -> list:
    """Textos de `description` del modelo, para buscarlos LITERALMENTE en los artefactos.

    Los patrones genéricos de arriba cazan la forma JSON; esto caza el texto ya inlineado como
    comentario SQL, que es como se filtraba de verdad y no lleva ninguna marca que lo delate.
    """
    if not model_path or not model_path.exists():
        return []
    try:
        model = json.loads(model_path.read_text(encoding="utf-8-sig"))
    except Exception:
        return []
    textos = set()
    for t in (model.get("tables") or {}).values():
        d = (t.get("description") or "").strip()
        # Menos de 12 caracteres no identifica nada: una descripción "Estado" coincidiría con
        # media docena de comentarios legítimos del propio DDL.
        if len(d) >= 12:
            textos.add(d)
        for c in (t.get("columns") or {}).values():
            d = (c.get("description") or "").strip()
            if len(d) >= 12:
                textos.add(d)
    return sorted(textos)


def revisar(carpeta: Path, descripciones: list) -> list:
    """[(fichero, linea, motivo, fragmento)] de todo lo que no debería viajar."""
    hallazgos = []
    for f in sorted(carpeta.rglob("*")):
        if not f.is_file() or f.suffix.lower() not in EXTENSIONES:
            continue
        try:
            texto = f.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        rel = f.relative_to(carpeta)
        for n, linea in enumerate(texto.splitlines(), 1):
            for motivo, patron in PATRONES:
                m = patron.search(linea)
                if not m:
                    continue
                if motivo == "referencia a ticket interno" and NO_ES_TICKET.match(m.group(0)):
                    continue
                hallazgos.append((str(rel), n, motivo, linea.strip()[:120]))
            for d in descripciones:
                # Menos de 12 caracteres no identifica nada: una descripción "Estado"
                # coincidiría con media docena de comentarios legítimos del propio DDL, y un
                # gate que cría falsos positivos deja de leerse. El filtro se repite aquí y no
                # solo en `descripciones_del_modelo` porque es ESTA función la que decide.
                if len(d) >= 12 and d in linea:
                    hallazgos.append((str(rel), n, "descripción del modelo (texto literal)",
                                      linea.strip()[:120]))
    return hallazgos


def main():
    if len(sys.argv) < 2:
        print(f"Uso: {sys.argv[0]} <carpeta> [--modelo <ruta model.json>]")
        sys.exit(1)

    carpeta = Path(sys.argv[1])
    if not carpeta.is_dir():
        print(f"ERROR: no es una carpeta: {carpeta}")
        sys.exit(1)

    modelo = None
    if "--modelo" in sys.argv:
        i = sys.argv.index("--modelo")
        if i + 1 < len(sys.argv):
            modelo = Path(sys.argv[i + 1])

    descripciones = descripciones_del_modelo(modelo) if modelo else []
    hallazgos = revisar(carpeta, descripciones)

    if not hallazgos:
        print(f"OK — sin fugas de metadatos de desarrollo en {carpeta}")
        print(f"     ({len(descripciones)} descripción(es) del modelo contrastadas literalmente)")
        sys.exit(0)

    print(f"ERROR: {len(hallazgos)} fuga(s) de metadatos de desarrollo en el paquete del cliente.")
    print(f"       Carpeta: {carpeta}")
    for fichero, linea, motivo, frag in hallazgos[:40]:
        print(f"       {fichero}:{linea}  [{motivo}]")
        print(f"           {frag}")
    if len(hallazgos) > 40:
        print(f"       ... y {len(hallazgos) - 40} más")
    print("")
    print("       El paquete NO es entregable. Corrige el GENERADOR que produce esa línea, no el")
    print("       .sql: editarlo a mano deja el generador intacto y la siguiente generación lo")
    print("       vuelve a meter.")
    sys.exit(1)


if __name__ == "__main__":
    main()
