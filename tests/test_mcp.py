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


# --- guarda read-only: _is_readonly_sql / _strip_sql_comments ---

@pytest.mark.parametrize("sql", [
    "SELECT 1 FROM dual",
    "  select * from RCLIENTES  ",
    "WITH t AS (SELECT 1 FROM dual) SELECT * FROM t",
    "SELECT 1 FROM dual;",                      # ; final permitido
    "SELECT 1 -- ; DROP TABLE x",               # ; dentro de comentario de línea → NO multi-statement
    "/* comentario */ SELECT 1 FROM dual",      # comentario de bloque antes del SELECT
    "SELECT ';' FROM dual",                     # ; dentro de literal
    "SELECT '--' FROM dual",                    # -- dentro de literal (no es comentario)
    "WITH x AS (SELECT 1) /* nota */ SELECT * FROM x",
])
def test_is_readonly_sql_permite(sql):
    ok, motivo = srv._is_readonly_sql(sql)
    assert ok, f"debería permitir: {sql!r} (motivo={motivo})"


@pytest.mark.parametrize("sql,frag", [
    ("SELECT 1; DROP TABLE x", "Multi-statement"),
    ("SELECT 1 FROM dual; DELETE FROM y", "Multi-statement"),
    ("UPDATE x SET a = 1", "Solo se permiten"),
    ("DELETE FROM x", "Solo se permiten"),
    ("DROP TABLE x", "Solo se permiten"),
    ("WITH t AS (SELECT 1) DELETE FROM x", "CTE con verbo"),
    ("WITH t AS (SELECT 1) /* x */ DELETE FROM y", "CTE con verbo"),   # comentario no oculta el verbo
    ("SELECT 1 /* ; */; DROP TABLE x", "Multi-statement"),             # ; real fuera del comentario
])
def test_is_readonly_sql_bloquea(sql, frag):
    ok, motivo = srv._is_readonly_sql(sql)
    assert not ok, f"debería bloquear: {sql!r}"
    assert frag in motivo


# --- cifrado de secretos: _unprotect_secret ---

def test_unprotect_secret_plaintext_passthrough():
    # Un valor sin el prefijo enc: se devuelve tal cual (texto plano legacy) — retrocompatibilidad.
    assert srv._unprotect_secret("secreto") == "secreto"
    assert srv._unprotect_secret("") == ""
    assert srv._unprotect_secret("Password_con_simbolos!@#") == "Password_con_simbolos!@#"


def test_unprotect_secret_enc_no_descifra_fuera_de_windows():
    # Un valor cifrado (enc:) exige DPAPI: en CI (Linux) no hay windll → OSError. En Windows con un
    # blob inválido, CryptUnprotectData también falla → OSError. En ambos casos, degradación controlada.
    with pytest.raises(OSError):
        srv._unprotect_secret("enc:QUJDRA==")


def test_get_db_password_plaintext_pasa_por_unprotect(tmp_path):
    # El password en texto plano sigue funcionando tras introducir _unprotect_secret en el camino.
    _write_db_config(tmp_path, "Data Source=DS;User Id=u;Password=llano")
    assert srv._get_db_password(str(tmp_path)) == "llano"


def test_strip_sql_comments_respeta_literales():
    assert srv._strip_sql_comments("SELECT '-- no comentario' FROM dual").strip() \
        == "SELECT '-- no comentario' FROM dual"
    assert ";" not in srv._strip_sql_comments("SELECT 1 -- ; x\n")
    assert "secreto" not in srv._strip_sql_comments("SELECT 1 /* secreto */ FROM dual")
