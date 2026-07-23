"""
Tests de las funciones puras del MCP server (mcp/rs-workspace-server.py).

Solo lógica pura, sin arrancar el server ni tocar BD/VCS/PowerShell: parseo de resultsets,
normalización de workspace, extracción de password de la cadena de conexión, resumen de diff y
derivación del nombre de proyecto.

El módulo tiene un guion en el nombre (no importable con `import`), así que se carga por ruta con
importlib. Importarlo NO arranca el server: `mcp.run()` está bajo `if __name__ == "__main__"`.
Requiere el paquete `mcp` instalado (viene en requirements.txt) porque el módulo importa FastMCP
en la cabecera.
"""
import importlib.util
import json
from pathlib import Path

import pytest

_SERVER = Path(__file__).resolve().parent.parent / "mcp" / "rs-workspace-server.py"


def _load_server():
    spec = importlib.util.spec_from_file_location("rs_workspace_server", _SERVER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


srv = _load_server()


# --- _resolve_workspace: subcarpeta docs/BD/Batch/OnLine → sube al trunk ---

@pytest.mark.parametrize("sub", ["docs", "BD", "Batch", "OnLine"])
def test_resolve_workspace_sube_desde_subcarpeta(sub):
    ws = Path("/x/Proyecto/trunk") / sub
    assert srv._resolve_workspace(ws) == Path("/x/Proyecto/trunk")


def test_resolve_workspace_trunk_sin_cambios():
    ws = Path("/x/Proyecto/trunk")
    assert srv._resolve_workspace(ws) == ws


def test_resolve_workspace_otra_carpeta_sin_cambios():
    ws = Path("/x/Proyecto/trunk/Otra")
    assert srv._resolve_workspace(ws) == ws


# --- _proyecto: carpeta anterior a trunk ---

def test_proyecto_desde_trunk():
    assert srv._proyecto("/svn/RS/RSProcIN/trunk") == "RSProcIN"


# --- _get_db_password: extrae Password= de la cadena de conexión ---

def _write_db_config(tmp_path, cadena, extra=None):
    docs = tmp_path / "docs"
    docs.mkdir(parents=True, exist_ok=True)
    conexion = {"id": "principal", "motor": "ORACLE", "cadena": cadena}
    if extra:
        conexion.update(extra)
    (docs / ".rs-databases.json").write_text(
        json.dumps({"proyecto": "P", "conexiones": [conexion]}), encoding="utf-8"
    )


def test_get_db_password_extrae_password(tmp_path):
    _write_db_config(tmp_path, "Data Source=DS;User Id=u;Password=secreto")
    assert srv._get_db_password(str(tmp_path)) == "secreto"


def test_get_db_password_sin_password_devuelve_vacio(tmp_path):
    _write_db_config(tmp_path, "Data Source=DS;User Id=u")
    assert srv._get_db_password(str(tmp_path)) == ""


def test_get_db_password_sin_config_devuelve_vacio(tmp_path):
    assert srv._get_db_password(str(tmp_path)) == ""


def test_get_db_password_normaliza_subcarpeta(tmp_path):
    # Pasando la subcarpeta docs/ debe subir al trunk y encontrar la config igual.
    _write_db_config(tmp_path, "Data Source=DS;User Id=u;Password=abc")
    assert srv._get_db_password(str(tmp_path / "docs")) == "abc"


# --- _parse_resultset: Oracle (CSV) y SQL Server (separador) ---

def test_parse_resultset_oracle_csv():
    stdout = 'ID,NOMBRE\n1,"Cliente A"\n2,"Cliente, B"\n'
    cols, rows, total = srv._parse_resultset(stdout, "ORACLE")
    assert cols == ["ID", "NOMBRE"]
    assert rows == [["1", "Cliente A"], ["2", "Cliente, B"]]
    assert total == 2


def test_parse_resultset_sqlserver_separador_y_filtra_guiones():
    sep = srv._SEP_SQLSERVER
    stdout = f"ID{sep}NOMBRE\n---{sep}------\n1{sep}Cliente A\n"
    cols, rows, total = srv._parse_resultset(stdout, "SQLSERVER")
    assert cols == ["ID", "NOMBRE"]
    assert rows == [["1", "Cliente A"]]
    assert total == 1


def test_parse_resultset_vacio():
    assert srv._parse_resultset("", "ORACLE") == ([], [], 0)


# --- _diff_summary: resumen sin código a partir de un diff ---

def test_diff_summary_git():
    diff = (
        "diff --git a/Foo.cs b/Foo.cs\n"
        "--- a/Foo.cs\n"
        "+++ b/Foo.cs\n"
        "+public void Nuevo()\n"
        "+    // linea\n"
        "-    vieja();\n"
    )
    out = json.loads(srv._diff_summary(diff, "abc123", r"diff --git a/(.+?) b/"))
    assert out["revisions"] == "abc123"
    assert out["files_changed"] == 1
    s = out["summary"][0]
    assert s["file"] == "Foo.cs"
    assert s["+lines"] == 2
    assert s["-lines"] == 1
