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

def _rechazar_argumentos_desconocidos(servidor):
    """Hace que cada tool RECHACE los parametros que no declara, en vez de ignorarlos.

    FastMCP valida con un modelo pydantic que, por defecto, descarta los campos extra en
    silencio. Con eso svn_add(paths=...) llegaba sin ficheros y anadia todo lo no versionado,
    y vcs_revert(dryRun=True) ejecutaba el revert de verdad (3.31.0). Se toca la estructura
    interna de FastMCP (fn_metadata.arg_model): si cambia, el servidor no arranca, porque
    arrancar ignorando parametros es justo el fallo que esto evita.
    """
    for t in servidor._tool_manager.list_tools():
        modelo = getattr(getattr(t, "fn_metadata", None), "arg_model", None)
        if modelo is None or not hasattr(modelo, "model_rebuild"):
            raise RuntimeError(
                f"rs-workspace: esta version de FastMCP no expone fn_metadata.arg_model en "
                f"'{t.name}'; no se puede garantizar el rechazo de parametros desconocidos")
        modelo.model_config["extra"] = "forbid"
        modelo.model_rebuild(force=True)
        # Que el schema lo diga tambien: el agente ve que no admite parametros extra.
        if isinstance(t.parameters, dict):
            t.parameters["additionalProperties"] = False


mcp = FastMCP("rs-workspace")
for _tool in core.TOOLS.values():
    mcp.tool(name=_tool.name, description=_tool.description)(_tool.fn)
_rechazar_argumentos_desconocidos(mcp)


if __name__ == "__main__":
    mcp.run(transport="stdio")
