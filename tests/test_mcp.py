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


# --- Integracion PII en db_query ---

def test_db_query_expone_el_helper_de_enmascarado():
    # El servidor debe tener cargado pii_mask: sin el, la integracion no aplica.
    assert hasattr(srv, "_pii_mask")
    assert hasattr(srv._pii_mask, "mask_resultset")


# --- _cargar_modelo: ahora toma config (dict con model_path), no el workspace ---
# Reusa el mismo model_path que get_table_schema/search_model/get_model_index en vez
# de buscar el fichero por su cuenta (ver fix round 1, finding 2).

def test_cargar_modelo_sin_model_path_devuelve_vacio_sin_aviso():
    # Config sin model_path (workspace no configurado): caso ordinario, sin aviso.
    assert srv._cargar_modelo({}) == ({}, None)


def test_cargar_modelo_model_path_inexistente_devuelve_vacio_sin_aviso(tmp_path):
    # El fichero no existe: mismo caso ordinario que "no hay modelo", sin aviso.
    config = {"model_path": str(tmp_path / "no-existe-model.json")}
    assert srv._cargar_modelo(config) == ({}, None)


def test_cargar_modelo_lee_el_json_valido(monkeypatch, tmp_path):
    # Cache de _load_model dentro de tmp_path: no tocar el cache real del usuario.
    monkeypatch.setattr(srv, "CACHE_DIR", tmp_path / "cache")
    modelo_path = tmp_path / "Proyecto-model.json"
    modelo_path.write_text(
        '{"pii_policy": {"mode": "enforce"}, "tables": {}}', encoding="utf-8")
    modelo, aviso = srv._cargar_modelo({"model_path": str(modelo_path)})
    assert modelo["pii_policy"]["mode"] == "enforce"
    assert aviso is None


def test_cargar_modelo_raiz_no_es_dict_no_revienta_y_avisa(monkeypatch, tmp_path):
    # Finding 1 (critico): un model.json cuya raiz es una lista rompia pii_policy.
    # cargar_politica (AttributeError: 'list' object has no attribute 'get'). Debe
    # tratarse como modelo no usable, no reventar, y decirlo.
    monkeypatch.setattr(srv, "CACHE_DIR", tmp_path / "cache")
    modelo_path = tmp_path / "Proyecto-model.json"
    modelo_path.write_text('["a", "b"]', encoding="utf-8")
    modelo, aviso = srv._cargar_modelo({"model_path": str(modelo_path)})
    assert modelo == {}
    assert aviso is not None
    assert modelo_path.name in aviso


def test_cargar_modelo_json_invalido_no_revienta_y_avisa(monkeypatch, tmp_path):
    # JSON malformado: _load_model no captura JSONDecodeError, _cargar_modelo si debe.
    monkeypatch.setattr(srv, "CACHE_DIR", tmp_path / "cache")
    modelo_path = tmp_path / "Proyecto-model.json"
    modelo_path.write_text("{esto no es json", encoding="utf-8")
    modelo, aviso = srv._cargar_modelo({"model_path": str(modelo_path)})
    assert modelo == {}
    assert aviso is not None
    assert modelo_path.name in aviso


def test_cargar_modelo_aviso_no_incluye_contenido_del_fichero(monkeypatch, tmp_path):
    # El aviso nombra el fichero y el motivo, nunca su contenido (puede tener datos).
    monkeypatch.setattr(srv, "CACHE_DIR", tmp_path / "cache")
    modelo_path = tmp_path / "Proyecto-model.json"
    modelo_path.write_text('["12345678Z", "Juan Perez"]', encoding="utf-8")
    _, aviso = srv._cargar_modelo({"model_path": str(modelo_path)})
    assert "12345678Z" not in aviso
    assert "Juan Perez" not in aviso


# --- db_query end-to-end: subprocess.run stubado, sin tocar BD ni PowerShell ---
# @mcp.tool(...) de FastMCP devuelve la funcion tal cual (verificado: type(srv.db_query)
# es function, no un wrapper) - se puede llamar directamente en el test.

class _ResultadoFalso:
    """Sustituye subprocess.CompletedProcess en estos tests."""
    def __init__(self, returncode, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def _preparar_db_query(monkeypatch, tmp_path, config, stdout, returncode=0, stderr=""):
    """Aisla db_query de PowerShell/BD/disco real de usuario para el test: config y
    salida del cliente SQL son canned; cache de modelo y clave HMAC caen en tmp_path."""
    monkeypatch.setattr(srv, "_get_config", lambda workspace: config)
    monkeypatch.setattr(srv, "_get_db_password", lambda workspace, conexion_id="": "")
    monkeypatch.setattr(srv.subprocess, "run",
                         lambda *a, **kw: _ResultadoFalso(returncode, stdout, stderr))
    monkeypatch.setattr(srv, "CACHE_DIR", tmp_path / "cache")
    monkeypatch.setattr(srv._pii_mask, "ruta_clave", lambda: tmp_path / "pii.key")


def _config_sqlserver(model_path=""):
    return {
        "conexiones": [{"id": "principal", "motor": "SQLSERVER",
                        "datasource": "DS", "schema": "dbo", "user": "u"}],
        "model_path": model_path,
    }


def test_db_query_sin_modelo_no_enmascara_y_expone_pii_off(monkeypatch, tmp_path):
    sep = srv._SEP_SQLSERVER
    stdout = f"ID{sep}NOMBRE\n1{sep}Ana\n2{sep}Luis\n3{sep}Marta\n"
    _preparar_db_query(monkeypatch, tmp_path, _config_sqlserver(), stdout)

    out = json.loads(srv.db_query(str(tmp_path), "SELECT ID, NOMBRE FROM RDEUDORES"))

    assert out["success"] is True
    assert out["pii"]["mode"] == "off"
    assert "model_error" not in out["pii"]
    assert out["rows"] == [["1", "Ana"], ["2", "Luis"], ["3", "Marta"]]
    assert out["row_count"] == 3
    assert out["rows_truncated"] is False


def test_db_query_enforce_enmascara_columna_texto(monkeypatch, tmp_path):
    sep = srv._SEP_SQLSERVER
    stdout = f"ID{sep}NOMBRE\n1{sep}Ana\n2{sep}Luis\n"
    modelo_path = tmp_path / "Proyecto-model.json"
    modelo_path.write_text('{"pii_policy": {"mode": "enforce"}}', encoding="utf-8")
    _preparar_db_query(monkeypatch, tmp_path, _config_sqlserver(str(modelo_path)), stdout)

    out = json.loads(srv.db_query(str(tmp_path), "SELECT ID, NOMBRE FROM RDEUDORES"))

    assert out["pii"]["mode"] == "enforce"
    assert "NOMBRE" in out["pii"]["masked"]
    assert out["rows"][0][0] == "1"                                    # ID en claro
    assert out["rows"][0][1].startswith(srv._pii_mask.PREFIJO)         # NOMBRE tapado
    assert out["rows"][0][1] != "Ana"


def test_db_query_row_count_y_truncado_reflejan_total_previo_al_recorte(monkeypatch, tmp_path):
    sep = srv._SEP_SQLSERVER
    stdout = f"ID{sep}NOMBRE\n1{sep}Ana\n2{sep}Luis\n3{sep}Marta\n"
    _preparar_db_query(monkeypatch, tmp_path, _config_sqlserver(), stdout)

    out = json.loads(srv.db_query(str(tmp_path), "SELECT ID, NOMBRE FROM RDEUDORES", max_rows=2))

    assert out["row_count"] == 2
    assert out["rows_truncated"] is True
    assert len(out["rows"]) == 2


def test_db_query_modelo_corrupto_no_revienta_y_avisa_en_pii(monkeypatch, tmp_path):
    sep = srv._SEP_SQLSERVER
    stdout = f"ID{sep}NOMBRE\n1{sep}Ana\n"
    modelo_path = tmp_path / "Proyecto-model.json"
    modelo_path.write_text('["a", "b"]', encoding="utf-8")
    _preparar_db_query(monkeypatch, tmp_path, _config_sqlserver(str(modelo_path)), stdout)

    out = json.loads(srv.db_query(str(tmp_path), "SELECT ID, NOMBRE FROM RDEUDORES"))

    assert out["success"] is True                # el error de modelo no tumba la query
    assert out["pii"]["mode"] == "off"            # modelo no usable -> se trata como ausente
    assert "model_error" in out["pii"]
    assert modelo_path.name in out["pii"]["model_error"]


def test_db_query_error_path_no_revienta_devuelve_success_false(monkeypatch, tmp_path):
    _preparar_db_query(monkeypatch, tmp_path, _config_sqlserver(), stdout="",
                        returncode=1, stderr="Msg 207 Invalid column name 'X'.")

    out = json.loads(srv.db_query(str(tmp_path), "SELECT X FROM RDEUDORES"))

    assert out["success"] is False
    assert "Msg 207" in out["error"]
    assert out["rows"] == []
    assert out["pii"]["mode"] == "off"


# --- conexion= selecciona la conexion PERO tambien su modelo (y por tanto su politica) ---

def _config_dos_conexiones(model_desa, model_prod):
    """conexiones[0] = DESA sin politica, conexiones[1] = PROD con politica.

    Los campos planos (model_path incluido) son SIEMPRE los de conexiones[0]:
    asi los publica get-config.ps1.
    """
    return {
        "conexiones": [
            {"id": "desa", "motor": "SQLSERVER", "datasource": "DS1", "schema": "dbo",
             "user": "u", "model_path": model_desa},
            {"id": "prod", "motor": "SQLSERVER", "datasource": "DS2", "schema": "dbo",
             "user": "u", "model_path": model_prod},
        ],
        "model_path": model_desa,
    }


def test_db_query_conexion_usa_el_modelo_de_esa_conexion(monkeypatch, tmp_path):
    # /rs-comparar-entornos se apoya en conexion=. Con conexiones[0] (DESA) sin politica y
    # el modelo de PROD en enforce, db_query(..., conexion="prod") devolvia los datos de
    # produccion EN CLARO y etiquetados pii.mode = "off".
    sep = srv._SEP_SQLSERVER
    stdout = f"ID{sep}NOMBRE\n1{sep}Ana\n"
    desa = tmp_path / "desa-model.json"
    desa.write_text('{"pii_policy": {"mode": "off"}}', encoding="utf-8")
    prod = tmp_path / "prod-model.json"
    prod.write_text('{"pii_policy": {"mode": "enforce"}}', encoding="utf-8")
    _preparar_db_query(monkeypatch, tmp_path, _config_dos_conexiones(str(desa), str(prod)), stdout)

    out = json.loads(srv.db_query(str(tmp_path), "SELECT ID, NOMBRE FROM RDEUDORES", conexion="prod"))

    assert out["pii"]["mode"] == "enforce"
    assert "NOMBRE" in out["pii"]["masked"]
    assert out["rows"][0][1] != "Ana"


def test_db_query_sin_conexion_sigue_usando_la_principal(monkeypatch, tmp_path):
    sep = srv._SEP_SQLSERVER
    stdout = f"ID{sep}NOMBRE\n1{sep}Ana\n"
    desa = tmp_path / "desa-model.json"
    desa.write_text('{"pii_policy": {"mode": "off"}}', encoding="utf-8")
    prod = tmp_path / "prod-model.json"
    prod.write_text('{"pii_policy": {"mode": "enforce"}}', encoding="utf-8")
    _preparar_db_query(monkeypatch, tmp_path, _config_dos_conexiones(str(desa), str(prod)), stdout)

    out = json.loads(srv.db_query(str(tmp_path), "SELECT ID, NOMBRE FROM RDEUDORES"))

    assert out["pii"]["mode"] == "off"
    assert out["rows"][0][1] == "Ana"


# --- El diagnostico de un fallo NUNCA devuelve las filas ya volcadas ---
# La rama de error no pasa por mask_resultset: lo que se devuelva como "error" entra en el
# contexto sin filtrar. sqlplus emite las filas segun las trae, asi que un error a mitad de
# fetch deja datos en lo capturado.

_SALIDA_CON_FILAS = (
    "IDINCIDENCIA,DESCRIPCION,DNI\n"
    "1,error al cobrar,12345678Z\n"
    "2,ERROR de conexion,87654321X\n"
)


def test_diagnostico_no_devuelve_filas_cuando_no_hay_lineas_reconocibles():
    msg = srv._diagnostico(_SALIDA_CON_FILAS, "", 1)
    assert "12345678Z" not in msg
    assert "87654321X" not in msg
    assert "al cobrar" not in msg
    assert "exit 1" in msg


def test_diagnostico_no_casa_la_palabra_error_dentro_de_los_datos():
    # El patron va anclado al principio de linea justo por esto.
    msg = srv._diagnostico(_SALIDA_CON_FILAS + "ORA-01555: snapshot too old\n", "", 1)
    assert msg == "ORA-01555: snapshot too old"


def test_diagnostico_acota_numero_y_longitud_de_lineas():
    muchas = "\n".join("ORA-0060%d: deadlock %s" % (i, "x" * 500) for i in range(30))
    msg = srv._diagnostico(muchas, "", 1)
    assert msg.count("ORA-") == srv._MAX_DIAG_LINEAS
    for parte in msg.split("; "):
        assert len(parte) <= srv._MAX_DIAG_CHARS + 3


def test_db_query_error_a_mitad_de_volcado_no_filtra_las_filas(monkeypatch, tmp_path):
    _preparar_db_query(monkeypatch, tmp_path, _config_sqlserver(),
                       stdout=_SALIDA_CON_FILAS, returncode=1, stderr="")

    out = json.loads(srv.db_query(str(tmp_path), "SELECT * FROM RINCIDENCIAS"))

    assert out["success"] is False
    assert out["rows"] == []
    assert "12345678Z" not in out["error"]
    assert "87654321X" not in out["error"]
