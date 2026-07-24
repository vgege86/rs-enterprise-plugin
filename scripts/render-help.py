"""
Renderiza la guía de usuario del plugin (README.md) a un HTML autónomo y legible.
El HTML (CSS/JS inline, sin dependencias externas) vive en help-template.html; este script
convierte el Markdown del README a HTML y lo inyecta en la plantilla.

A diferencia de render-dashboard.py (que lee history.json del workspace), la fuente es el
README.md del propio plugin: la guía se mantiene sola al día con el README.

Conversor Markdown→HTML minimalista (solo stdlib) para el subconjunto que usa el README:
encabezados con id (anclas GitHub-style), tablas GFM, bloques de código, blockquotes, listas
(con un nivel de anidamiento), reglas horizontales, y en línea **negrita**, `código`, [enlaces](url).

Uso: python render-help.py <readme_path> <out_path>
"""

import html
import re
import sys
from datetime import datetime
from pathlib import Path

TEMPLATE_PATH = Path(__file__).parent / "help-template.html"


def _slug(text: str) -> str:
    """Ancla estilo GitHub: minúsculas, sin puntuación (conserva letras acentuadas y dígitos),
    espacios → guion. Debe coincidir con los enlaces del índice del README."""
    t = text.strip().lower()
    t = re.sub(r"[^\w\s-]", "", t, flags=re.UNICODE)  # \w incluye acentos en Python 3
    t = re.sub(r"\s+", "-", t)
    return t.strip("-")


def _inline(text: str) -> str:
    """Formato en línea: `código`, **negrita**, [texto](url). Escapa HTML sin doble-escapar
    el contenido de los code spans."""
    codes: list[str] = []

    def _stash(m: "re.Match") -> str:
        codes.append(m.group(1))
        return f"\x00{len(codes) - 1}\x00"

    text = re.sub(r"`([^`]+)`", _stash, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)

    def _restore(m: "re.Match") -> str:
        return "<code>" + html.escape(codes[int(m.group(1))], quote=False) + "</code>"

    return re.sub(r"\x00(\d+)\x00", _restore, text)


def _cells(row: str) -> list[str]:
    """Divide una fila de tabla '| a | b |' en celdas, descartando los bordes vacíos."""
    parts = row.strip().split("|")
    if parts and parts[0].strip() == "":
        parts = parts[1:]
    if parts and parts[-1].strip() == "":
        parts = parts[:-1]
    return [c.strip() for c in parts]


def md_to_html(md: str) -> str:
    lines = md.split("\n")
    out: list[str] = []
    i = 0
    n = len(lines)

    while i < n:
        line = lines[i]

        # Bloque de código cercado ```
        if line.lstrip().startswith("```"):
            i += 1
            buf: list[str] = []
            while i < n and not lines[i].lstrip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1  # cierre ```
            code = html.escape("\n".join(buf), quote=False)
            out.append(f"<pre><code>{code}</code></pre>")
            continue

        # Línea en blanco
        if line.strip() == "":
            i += 1
            continue

        # Regla horizontal
        if re.fullmatch(r"(-{3,}|\*{3,})", line.strip()):
            out.append("<hr>")
            i += 1
            continue

        # Encabezado ATX
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            raw = m.group(2).strip()
            out.append(f'<h{level} id="{_slug(raw)}">{_inline(raw)}</h{level}>')
            i += 1
            continue

        # Tabla GFM (fila | ... | seguida de separador |---|)
        if line.lstrip().startswith("|") and i + 1 < n and re.search(r"^\s*\|?[\s:-]*-[\s:|-]*$", lines[i + 1]):
            header = _cells(line)
            i += 2  # saltar cabecera + separador
            body: list[list[str]] = []
            while i < n and lines[i].lstrip().startswith("|"):
                body.append(_cells(lines[i]))
                i += 1
            thead = "".join(f"<th>{_inline(c)}</th>" for c in header)
            rows = []
            for r in body:
                tds = "".join(f"<td>{_inline(c)}</td>" for c in r)
                rows.append(f"<tr>{tds}</tr>")
            out.append(
                '<div class="table-wrap"><table><thead><tr>'
                + thead
                + "</tr></thead><tbody>"
                + "".join(rows)
                + "</tbody></table></div>"
            )
            continue

        # Blockquote
        if line.lstrip().startswith(">"):
            buf = []
            while i < n and lines[i].lstrip().startswith(">"):
                buf.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            out.append(f"<blockquote>{_inline(' '.join(buf))}</blockquote>")
            continue

        # Lista no ordenada (un nivel de anidamiento por indentación)
        if re.match(r"^\s*[-*]\s+", line):
            items: list[tuple[int, str]] = []
            while i < n and re.match(r"^\s*[-*]\s+", lines[i]):
                indent = len(lines[i]) - len(lines[i].lstrip())
                content = re.sub(r"^\s*[-*]\s+", "", lines[i])
                items.append((indent, content))
                i += 1
            out.append(_render_list(items))
            continue

        # Párrafo: acumula líneas hasta blanco o inicio de otro bloque
        buf = [line]
        i += 1
        while i < n and lines[i].strip() != "" and not _is_block_start(lines[i], lines, i):
            buf.append(lines[i])
            i += 1
        out.append(f"<p>{_inline(' '.join(s.strip() for s in buf))}</p>")

    return "\n".join(out)


def _is_block_start(line: str, lines: list[str], i: int) -> bool:
    s = line.lstrip()
    if s.startswith(("#", ">", "```", "|", "- ", "* ")):
        return True
    if re.fullmatch(r"(-{3,}|\*{3,})", line.strip()):
        return True
    return False


def _render_list(items: list[tuple[int, str]]) -> str:
    """Renderiza una lista con un nivel de anidamiento (indentación ≥ 2 → sublista)."""
    base = min(ind for ind, _ in items)
    html_parts: list[str] = ["<ul>"]
    open_sub = False
    for indent, content in items:
        if indent > base:
            if not open_sub:
                html_parts.append("<ul>")
                open_sub = True
            html_parts.append(f"<li>{_inline(content)}</li>")
        else:
            if open_sub:
                html_parts.append("</ul>")
                open_sub = False
            html_parts.append(f"<li>{_inline(content)}</li>")
    if open_sub:
        html_parts.append("</ul>")
    html_parts.append("</ul>")
    return "".join(html_parts)


def main() -> None:
    if len(sys.argv) < 3:
        print("Uso: render-help.py <readme_path> <out_path>")
        sys.exit(1)

    readme_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    if not readme_path.exists():
        print(f"ERROR: README no encontrado: {readme_path}")
        sys.exit(1)
    if not TEMPLATE_PATH.exists():
        print(f"ERROR: Plantilla no encontrada: {TEMPLATE_PATH}")
        sys.exit(1)

    md = readme_path.read_text(encoding="utf-8-sig")

    # Título: primer encabezado H1 del README; si no hay, nombre del fichero.
    title_match = re.search(r"^#\s+(.*)$", md, flags=re.MULTILINE)
    title = title_match.group(1).strip() if title_match else "Guía de usuario"

    content = md_to_html(md)

    html_doc = TEMPLATE_PATH.read_text(encoding="utf-8")
    for placeholder, value in [
        ("{title}", html.escape(title, quote=False)),
        ("{generated_ts}", datetime.now().isoformat(timespec="seconds")),
        ("{content}", content),
    ]:
        html_doc = html_doc.replace(placeholder, value)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(html_doc, encoding="utf-8")

    print(f"OK — guía generada: {out_path}")
    print(f"     fuente: {readme_path} ({len(md.splitlines())} líneas)")


if __name__ == "__main__":
    main()
