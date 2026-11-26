"""
CLI rs (scripts/rs.py) y su relacion con el servidor MCP.

POR QUE EXISTE. Desde la 3.30.0 hay una sola implementacion de las herramientas
(scripts/rs_core.py) con dos frontales: el servidor MCP y esta CLI. Lo que se fija aqui:

  1. La CLI convierte bien la linea de comandos en los argumentos de la herramienta: nombres
     con '-' o '_', alias "path", booleanos con valor, enteros, y --args-json por stdin (que
     es por donde hooks/db-query.ps1 le pasa el SQL sin pelearse con el escapado).
  2. El codigo de salida distingue "la herramienta dijo error" (1) de "llamada mal hecha" (2).
  3. El nucleo no necesita ni `mcp` ni pydantic: la CLI tiene que funcionar justo cuando el
     servidor MCP no arranca.
  4. El servidor MCP expone exactamente las herramientas del nucleo, con su descripcion.
"""
import importlib.util
import io
import json
import subprocess
import sys
from pathlib import Path

import pytest

_RAIZ = Path(__file__).resolve().parent.parent
_CLI = _RAIZ / "scripts" / "rs.py"
_CORE = _RAIZ / "scripts" / "rs_core.py"
_SERVER = _RAIZ / "mcp" / "rs-workspace-server.py"


def _cargar(nombre, ruta):
    spec = importlib.util.spec_from_file_location(nombre, ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cli = _cargar("rs_cli", _CLI)
core = _cargar("rs_core_cli", _CORE)


def _ejecutar(*argv, stdin=""):
    """(codigo, salida) de cli.main sin lanzar un proceso."""
    salida = io.StringIO()
    codigo = cli.main(list(argv), stdin=io.StringIO(stdin), stdout=salida)
    return codigo, salida.getvalue()


# ---------------------------------------------------------------------------------------------
# list / help
# ---------------------------------------------------------------------------------------------
def test_list_enumera_todas_las_herramientas_del_nucleo():
    codigo, salida = _ejecutar("list", "--json")
    assert codigo == 0
    nombres = [t["name"] for t in json.loads(salida)]
    assert nombres == list(core.TOOLS)
    assert len(nombres) == 51


def test_help_muestra_parametros_con_obligatoriedad_y_defecto():
    codigo, salida = _ejecutar("help", "db-query")
    assert codigo == 0
    assert "--sql" in salida and "obligatorio" in salida
    assert "--max-rows" in salida and "200" in salida


def test_herramienta_desconocida_es_error_de_uso():
    assert _ejecutar("no_existe")[0] == cli.EXIT_USO


# ---------------------------------------------------------------------------------------------
# Construccion de argumentos
# ---------------------------------------------------------------------------------------------
def test_guiones_y_guiones_bajos_valen_igual():
    a = cli.construir_argumentos(core.db_query, ["--workspace", "W", "--sql", "S", "--max-rows", "5"])
    b = cli.construir_argumentos(core.db_query, ["--workspace=W", "--sql=S", "--max_rows=5"])
    assert a == b == {"workspace": "W", "sql": "S", "max_rows": 5}


def test_path_es_alias_de_workspace_como_en_el_mcp():
    kw = cli.construir_argumentos(core.detect_vcs, ["--path", "C:/ws"])
    assert kw == {"workspace": "C:/ws"}


@pytest.mark.parametrize("texto,esperado", [("true", True), ("false", False), ("1", True), ("no", False)])
def test_booleanos_con_valor(texto, esperado):
    kw = cli.construir_argumentos(core.compile_check, ["--sln-path", "x.sln", "--no-restore", texto])
    assert kw["no_restore"] is esperado


def test_booleano_invalido_es_error():
    with pytest.raises(ValueError, match="true/false"):
        cli.construir_argumentos(core.compile_check, ["--sln-path", "x", "--no-restore", "quizas"])


def test_entero_invalido_es_error():
    with pytest.raises(ValueError, match="entero"):
        cli.construir_argumentos(core.db_query, ["--workspace", "W", "--sql", "S", "--max-rows", "mucho"])


def test_falta_obligatorio_y_parametro_desconocido():
    with pytest.raises(ValueError, match="falta --sql"):
        cli.construir_argumentos(core.db_query, ["--workspace", "W"])
    with pytest.raises(ValueError, match="--inventado"):
        cli.construir_argumentos(core.db_query, ["--workspace", "W", "--sql", "S", "--inventado", "1"])


def test_args_json_por_stdin_conserva_el_sql_intacto():
    sql = "SELECT 'O''Brien $HOME \"x\"'\nFROM dual"
    kw = cli.construir_argumentos(core.db_query, ["--args-json", "-"],
                                  stdin=io.StringIO(json.dumps({"workspace": "W", "sql": sql})))
    assert kw["sql"] == sql


def test_args_json_tolera_el_bom_de_windows_powershell():
    entrada = "\ufeff" + json.dumps({"workspace": "W", "sql": "SELECT 1 FROM dual"})
    kw = cli.construir_argumentos(core.db_query, ["--args-json", "-"], stdin=io.StringIO(entrada))
    assert kw["workspace"] == "W"


def test_opcion_suelta_gana_a_args_json():
    kw = cli.construir_argumentos(core.db_query, ["--args-json", '{"workspace":"W","sql":"A"}', "--sql", "B"])
    assert kw["sql"] == "B"


def test_args_json_que_no_es_objeto_es_error():
    with pytest.raises(ValueError, match="objeto JSON"):
        cli.construir_argumentos(core.db_query, ["--args-json", "[1,2]"])


# ---------------------------------------------------------------------------------------------
# Codigo de salida
# ---------------------------------------------------------------------------------------------
def test_guarda_de_solo_lectura_por_la_cli_da_exit_1():
    codigo, salida = _ejecutar("db_query", "--args-json", "-",
                               stdin=json.dumps({"workspace": "W", "sql": "DELETE FROM x"}))
    assert codigo == cli.EXIT_ERROR
    assert json.loads(salida)["error"].startswith("Solo se permiten")


def test_ping_da_exit_0():
    codigo, salida = _ejecutar("ping")
    assert codigo == 0 and json.loads(salida)["ok"] is True


@pytest.mark.parametrize("texto,esperado", [
    ('{"success": true}', 0), ('{"success": false}', 1), ('{"error": "x"}', 1),
    ('{"error": null, "rows": []}', 0), ('[1, 2]', 0), ("no es json", 0),
])
def test_codigo_salida(texto, esperado):
    assert cli.codigo_salida(texto) == esperado


# ---------------------------------------------------------------------------------------------
# El nucleo no depende de mcp ni de pydantic
# ---------------------------------------------------------------------------------------------
def test_la_cli_funciona_sin_mcp_ni_pydantic():
    # Proceso aparte con mcp y pydantic bloqueados: es el entorno en el que la CLI tiene que
    # servir de respaldo (servidor MCP que no arranca por el paquete mcp).
    codigo = (
        "import sys, runpy\n"
        "sys.modules['mcp'] = None\n"
        "sys.modules['pydantic'] = None\n"
        f"sys.argv = ['rs.py', 'ping']\n"
        f"runpy.run_path({str(_CLI)!r}, run_name='__main__')\n"
    )
    r = subprocess.run([sys.executable, "-I", "-c", codigo], capture_output=True, text=True, encoding="utf-8")
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout)["ok"] is True


# ---------------------------------------------------------------------------------------------
# El servidor MCP expone exactamente el nucleo
# ---------------------------------------------------------------------------------------------
def test_el_servidor_mcp_registra_las_herramientas_del_nucleo():
    try:
        from mcp.server.fastmcp import FastMCP  # noqa: F401
    except ImportError:
        pytest.skip("paquete mcp 1.x no instalado (requirements.txt fija mcp<2)")
    import asyncio

    srv = _cargar("rs_server_cli", _SERVER)
    expuestas = asyncio.run(srv.mcp.list_tools())
    assert [t.name for t in expuestas] == list(srv.core.TOOLS)
    assert all(t.description == srv.core.TOOLS[t.name].description for t in expuestas)
    # El alias "path" de workspace solo existe en el schema si pydantic aporto sus metadatos.
    detect = next(t for t in expuestas if t.name == "detect_vcs")
    assert "workspace" in detect.inputSchema["properties"]


# ---------------------------------------------------------------------------------------------
# Parametros desconocidos: se RECHAZAN (3.31.0)
#
# FastMCP descartaba en silencio los campos que no declara la tool. svn_add(paths=...) llegaba
# sin ficheros y anadia todo lo no versionado del working copy; vcs_revert(dryRun=True)
# ejecutaba el revert de verdad. Ahora la llamada falla y el hook no llega a ejecutarse.
# ---------------------------------------------------------------------------------------------
def _servidor_con_run_ps_espia():
    try:
        from mcp.server.fastmcp import FastMCP  # noqa: F401
    except ImportError:
        pytest.skip("paquete mcp 1.x no instalado (requirements.txt fija mcp<2)")
    srv = _cargar("rs_server_extra", _SERVER)
    llamadas = []
    srv.core._run_ps = lambda script, *a, **k: llamadas.append((script, a)) or {"success": True}
    srv.core._check_workspace = lambda w: None
    return srv, llamadas


@pytest.mark.parametrize("tool,args", [
    ("svn_add", {"workspace": "W", "paths": "a.cs;b.md"}),
    ("git_add", {"workspace": "W", "paths": "a.cs"}),
    ("vcs_revert", {"workspace": "W", "files": "a.cs", "dryRun": True}),
    ("vcs_revert", {"workspace": "W", "files": "a.cs", "dry-run": True}),
])
def test_parametro_desconocido_falla_y_no_ejecuta_el_hook(tool, args):
    import asyncio
    srv, llamadas = _servidor_con_run_ps_espia()
    with pytest.raises(Exception, match="(?i)extra|not permitted|validation"):
        asyncio.run(srv.mcp.call_tool(tool, args))
    assert llamadas == []


def test_el_alias_path_de_workspace_sigue_valiendo():
    import asyncio
    srv, llamadas = _servidor_con_run_ps_espia()
    asyncio.run(srv.mcp.call_tool("svn_add", {"path": "W", "files": "a.cs"}))
    assert llamadas and llamadas[0][0] == "svn-add.ps1"


def test_todas_las_tools_declaran_que_no_admiten_parametros_extra():
    import asyncio
    srv, _ = _servidor_con_run_ps_espia()
    expuestas = asyncio.run(srv.mcp.list_tools())
    sin_cerrar = [t.name for t in expuestas if t.inputSchema.get("additionalProperties") is not False]
    assert sin_cerrar == []


@pytest.mark.parametrize("tool", ["svn_add", "git_add", "vcs_revert"])
def test_files_es_obligatorio_en_las_tools_de_vcs(tool):
    # Con `files` opcional y vacio por defecto, olvidarlo equivalia a "anadir todo".
    params = {n: oblig for n, _, oblig, _ in cli.parametros(core.TOOLS[tool].fn)}
    assert params["files"] is True


def test_svn_add_pasa_files_y_max_files_al_hook():
    llamadas = []
    original = core._run_ps
    core._run_ps = lambda script, *a, **k: llamadas.append((script, a)) or {"success": True}
    try:
        core.svn_add("W", "a.cs;b.cs")
        core.git_add("W", "a.cs", max_files=10)
    finally:
        core._run_ps = original
    assert llamadas[0] == ("svn-add.ps1", ("W", "-Files", "a.cs;b.cs", "-MaxFiles", "50"))
    assert llamadas[1] == ("git-add.ps1", ("W", "-Files", "a.cs", "-MaxFiles", "10"))
