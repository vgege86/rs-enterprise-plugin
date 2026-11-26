"""
rs-workspace MCP server — frontal MCP de las herramientas rs-workspace.

Sin logica propia: registra en FastMCP las herramientas de scripts/rs_core.py, que es la
implementacion unica que comparte con la CLI (scripts/rs.py). Nombre, descripcion y firma de
cada tool salen tal cual del nucleo, asi que el schema que ven los agentes no cambia.

Importar este modulo no arranca el servidor: mcp.run() esta bajo `if __name__ == "__main__"`.
"""

import importlib.util
from pathlib import Path

from mcp.server.fastmcp import FastMCP

_CORE = Path(__file__).resolve().parent.parent / "scripts" / "rs_core.py"


def _cargar_nucleo():
    """Carga scripts/rs_core.py por ruta (la carpeta scripts/ no es un paquete importable)."""
    spec = importlib.util.spec_from_file_location("rs_core", _CORE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


core = _cargar_nucleo()

mcp = FastMCP("rs-workspace")
for _tool in core.TOOLS.values():
    mcp.tool(name=_tool.name, description=_tool.description)(_tool.fn)


if __name__ == "__main__":
    mcp.run(transport="stdio")
