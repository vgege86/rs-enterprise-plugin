"""
Funciones puras del generador de inserts paramétricos del instalador de cliente
(`scripts/installer-inserts.py`), sin BD y sin Windows: nada aquí abre una conexión ni lanza
sqlplus/sqlcmd, solo se ejercita la lógica que decide QUÉ se pide y cómo se interpreta la
respuesta.

⛔ Por qué existe este fichero. Esa etapa pide varias tablas en UNA sola sesión SQL (el coste
real es el login, no la consulta) y eso apoya el resultado en tres propiedades que antes solo
estaban escritas en un comentario:

  1. **Aislamiento de error dentro de la sesión compartida.** Un `ORA-`/`Msg` de una tabla no
     debe contaminar a las vecinas del mismo chunk. Si se rompe, el instalador NO falla: genera
     los ficheros igual, con tablas de menos o marcadas OK sin datos. Un fallo silencioso que
     solo se ve en el servidor del cliente, cargando paramétricas incompletas.
  2. **El troceo por marcador, no por línea.** Un valor de texto puede llevar saltos de línea;
     si el troceo se hiciera por `\\n` las filas se partirían y se perderían.
  3. **La estimación de ancho que evita `TO_CLOB`.** Es una optimización que solo es legítima
     porque un error de estimación se reintenta (`ORA-01489`) en vez de producir un fichero
     incorrecto. La red de seguridad se apoya en reconocer ese código de error.

Y una cuarta, de diagnóstico: cuando el proceso del cliente SQL falla, el mensaje se atribuye a
TODAS las tablas de la sesión. La primera línea de stdout es el banner (`SQL*Plus: Release...`),
así que reportarla multiplicada por 12 tablas no es diagnosticable.

Portabilidad: no toca BD, ni DPAPI, ni el registro. Corre igual en Windows y en el CI.
Higiene: todo el fixture es sintético (`RTIPO`, `T0..Tn`) — ningún nombre real de cliente.
"""
import importlib.util
from pathlib import Path

import pytest

_RAIZ = Path(__file__).resolve().parent.parent
_INSTALADOR = _RAIZ / "scripts" / "installer-inserts.py"

# El módulo tiene guion en el nombre -> no es importable con `import`; se carga por ruta.
# Mismo patrón que installer-objects.py en producción y que tests/test_dpapi_paridad.py.
_spec = importlib.util.spec_from_file_location("_installer_inserts", _INSTALADOR)
ins = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ins)


# --------------------------------------------------------------- reparto en sesiones SQL
def test_chunks_pocas_tablas_una_sesion_cada_una():
    """Con menos tablas que workers no se agrupa: el paralelismo ya cubre el coste."""
    assert ins.split_chunks(["T0", "T1", "T2"], 8) == [["T0"], ["T1"], ["T2"]]


def test_chunks_agrupa_para_ahorrar_logins():
    """60 tablas con 8 workers no deben ser 60 sesiones (que es lo que se pagaba antes)."""
    chunks = ins.split_chunks([f"T{i}" for i in range(60)], 8)
    assert len(chunks) == 8
    assert sum(len(c) for c in chunks) == 60


def test_chunks_respeta_el_tope_por_sesion():
    """El tope acota el pico de memoria: la salida de un chunk se retiene entera."""
    chunks = ins.split_chunks([f"T{i}" for i in range(200)], 8)
    assert max(len(c) for c in chunks) == ins.CHUNK_MAX
    assert sum(len(c) for c in chunks) == 200


def test_chunks_sin_tablas():
    assert ins.split_chunks([], 8) == []


def test_chunks_no_pierde_ni_duplica_ninguna_tabla():
    tablas = [f"T{i}" for i in range(37)]
    repartidas = [t for c in ins.split_chunks(tablas, 5) for t in c]
    assert repartidas == tablas


# --------------------------------------------------------------- estimación de ancho de fila
_ESTRECHA = [("CODIGO", {"type": "VARCHAR2(10)"}),
             ("DESCRIPCION", {"type": "VARCHAR2(100)"}),
             ("IMPORTE", {"type": "NUMBER"}),
             ("ALTA", {"type": "DATE"})]
_ANCHA = [(f"C{i}", {"type": "VARCHAR2(500)"}) for i in range(20)]


@pytest.mark.parametrize("tipo, esperado", [
    ("RAW(16)", 32),                       # se extrae en hexadecimal: 2 chars por byte
    ("BLOB", len(ins.NULLTOK)),            # no inlineable: se emite el centinela
    ("CLOB", ins.ANCHO_ILIMITADO),         # sin longitud acotada -> CLOB obligatorio
    ("VARCHAR2", ins.ANCHO_ILIMITADO),     # tipo sin longitud declarada: ante la duda, CLOB
    ("VARCHAR2(30)", 30),
])
def test_ancho_por_tipo_de_columna(tipo, esperado):
    assert ins._col_width({"type": tipo}) == esperado


def test_ancho_fila_estrecha_por_debajo_del_umbral():
    assert ins._est_row_width(_ESTRECHA) < ins.VARCHAR_SAFE_WIDTH


def test_ancho_fila_ancha_por_encima_del_umbral():
    assert ins._est_row_width(_ANCHA) > ins.VARCHAR_SAFE_WIDTH


def test_ancho_una_columna_ilimitada_contamina_la_fila():
    """Basta un CLOB para que toda la concatenación tenga que ser CLOB."""
    columnas = _ESTRECHA + [("OBS", {"type": "CLOB"})]
    assert ins._est_row_width(columnas) >= ins.ANCHO_ILIMITADO


# --------------------------------------------------------------- construcción del SELECT
def test_select_estrecho_evita_to_clob():
    """La optimización: concatenar en VARCHAR2 cuando la fila cabe."""
    assert "TO_CLOB" not in ins.build_select("RTIPO", _ESTRECHA, "ESQ", "ORACLE")


def test_select_ancho_usa_to_clob():
    """Sin TO_CLOB una tabla ancha daría ORA-01489 y perdería la tabla entera."""
    assert "TO_CLOB" in ins.build_select("RTIPO", _ANCHA, "ESQ", "ORACLE")


def test_select_force_clob_es_la_red_de_seguridad():
    """Lo que usa el reintento tras un ORA-01489: fuerza CLOB aunque se estimara estrecha."""
    assert "TO_CLOB" in ins.build_select("RTIPO", _ESTRECHA, "ESQ", "ORACLE", True)


def test_select_califica_con_el_schema_y_marca_los_nulos():
    sql = ins.build_select("RTIPO", _ESTRECHA, "ESQ", "ORACLE")
    assert "FROM ESQ.RTIPO" in sql
    assert ins.NULLTOK in sql        # distingue NULL de cadena vacía
    assert ins.ROWEND in sql         # terminador de fila
    assert ins.LFTOK in sql and ins.CRTOK in sql   # CR/LF codificados: 1 fila = 1 línea física


def test_select_sqlserver_no_deja_columnas_sin_convertir():
    sql = ins.build_select("RTIPO", _ESTRECHA, "dbo", "SQLSERVER")
    assert sql.count("CONVERT") == len(_ESTRECHA)
    assert "[dbo].[RTIPO]" in sql


# --------------------------------------------------------------- troceo de la sesión multi-tabla
def _salida_de_sesion():
    """Salida sintética de una sesión con 3 tablas, donde la segunda falla."""
    return (
        "Session altered.\n"
        f"{ins.TBLMARK}RTABLA1{ins.TBLMARK_FIN}\n"
        f"1{ins.DELIM}uno{ins.ROWEND}\n"
        f"2{ins.DELIM}dos{ins.ROWEND}\n"
        f"{ins.TBLMARK}RTABLA2{ins.TBLMARK_FIN}\n"
        "ORA-00942: table or view does not exist\n"
        f"{ins.TBLMARK}RTABLA3{ins.TBLMARK_FIN}\n"
        f"9{ins.DELIM}nueve{ins.ROWEND}\n"
    )


def test_split_tables_separa_un_bloque_por_tabla():
    _, bloques = ins._split_tables(_salida_de_sesion())
    assert sorted(bloques) == ["RTABLA1", "RTABLA2", "RTABLA3"]


def test_split_tables_aisla_el_preambulo():
    """Lo de antes del primer marcador es del CONNECT/ALTER SESSION, no de ninguna tabla."""
    preambulo, _ = ins._split_tables(_salida_de_sesion())
    assert "Session altered" in preambulo
    assert ins.TBLMARK not in preambulo


def test_el_error_de_una_tabla_no_contamina_a_las_vecinas():
    """La propiedad que hace legítimo compartir sesión entre tablas."""
    _, bloques = ins._split_tables(_salida_de_sesion())
    assert ins._find_error(bloques["RTABLA2"]).startswith("ORA-00942")
    assert ins._find_error(bloques["RTABLA1"]) == ""
    assert ins._find_error(bloques["RTABLA3"]) == ""


def test_las_filas_sobreviven_al_marcador():
    _, bloques = ins._split_tables(_salida_de_sesion())
    assert len(ins._split_rows(bloques["RTABLA1"])) == 2
    assert len(ins._split_rows(bloques["RTABLA3"])) == 1


def test_una_fila_con_salto_de_linea_interno_sigue_siendo_una_fila():
    """Si se troceara por '\\n' esta fila se partiría en dos y se perdería."""
    fila = f"1{ins.DELIM}linea1{ins.LFTOK}linea2{ins.ROWEND}\n"
    assert len(ins._split_rows(fila)) == 1


def test_error_de_sqlserver_adjunta_el_mensaje_legible():
    """El `Msg NNN, Level...` no dice qué pasó; el texto va en la línea siguiente."""
    msg = ins._find_error("Msg 208, Level 16, State 1, Server X, Line 1\n"
                          "Invalid object name 'RTIPO'.\n")
    assert "Msg 208" in msg and "Invalid object name" in msg


def test_una_salida_sana_no_se_confunde_con_un_error():
    assert ins._find_error(f"1{ins.DELIM}hola{ins.ROWEND}\n") == ""


# --------------------------------------------------------------- mensaje de fallo del proceso
_BANNER = ("SQL*Plus: Release 19.0.0.0.0 - Production on Thu Aug 6 10:00:00 2026\n"
           "Version 19.3.0.0.0\n\nCopyright (c) 1982, 2019, Oracle.  All rights reserved.\n\n")


@pytest.mark.parametrize("cola, esperado", [
    ("ERROR:\nORA-01017: invalid username/password; logon denied\n\n"
     "SP2-0751: Unable to connect to Oracle.  Exiting SQL*Plus\n", "ORA-01017"),
    ("ERROR:\nORA-12154: TNS:could not resolve the connect identifier specified\n", "ORA-12154"),
])
def test_mensaje_de_fallo_prefiere_el_error_al_banner(cola, esperado):
    """Un fallo de proceso se atribuye a TODAS las tablas de la sesión: el banner no sirve."""
    assert ins._mensaje_fallo("", _BANNER + cola).startswith(esperado)


def test_mensaje_de_fallo_usa_stderr_si_no_hay_salida():
    """Cliente ausente del PATH: el sistema operativo se queja por stderr."""
    assert "sqlplus" in ins._mensaje_fallo("'sqlplus' no se reconoce como un comando", "")


def test_mensaje_de_fallo_sin_ninguna_salida_es_explicito():
    assert ins._mensaje_fallo("", "") == "el cliente SQL terminó con error y sin salida"


# --------------------------------------------------------------- la sesión SQL, con cliente falso
# `run_chunk_*` es lo único de este módulo que lanza un proceso. Sustituyendo `subprocess.run` se
# prueba sin cliente instalado lo que de verdad importa de esas funciones: el script que ENVÍAN
# (un marcador y un SELECT por tabla, en UNA sola sesión) y el mensaje que reportan al fallar.
# Sin esto, quien revierta el call site a la primera línea de stdout deja la suite en verde.
_CFG_SESION = {"motor": "ORACLE", "schema": "ESQ", "user": "USR", "password": "",
               "datasource": "ALIAS"}


class _ClienteFalso:
    """Sustituto de subprocess.run: captura el script recibido y devuelve una salida canónica."""

    def __init__(self, returncode=0, stdout=b"", stderr=b""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr
        self.script = ""
        self.argv = []

    def __call__(self, cmd, **kwargs):
        self.argv = list(cmd)
        for i, arg in enumerate(cmd):
            ruta = arg[1:] if arg.startswith("@") else (cmd[i + 1] if arg == "-i" else None)
            if ruta and Path(ruta).exists():
                # Se lee AQUÍ: la función borra el temporal en su `finally`.
                self.script = Path(ruta).read_text(encoding="utf-8")
                break
        return self


def test_run_chunk_oracle_pide_todas_las_tablas_en_una_sola_sesion(monkeypatch):
    falso = _ClienteFalso(stdout=b"ok")
    monkeypatch.setattr(ins.subprocess, "run", falso)
    chunk = [("RTIPO", "SELECT 1 FROM ESQ.RTIPO"), ("RESTADO", "SELECT 2 FROM ESQ.RESTADO")]

    ins.run_chunk_oracle(chunk, _CFG_SESION)

    assert falso.script.count(ins.TBLMARK) == 2          # un marcador por tabla
    assert f"PROMPT {ins.TBLMARK}RTIPO{ins.TBLMARK_FIN}" in falso.script
    assert f"SET ARRAYSIZE {ins.ARRAYSIZE}" in falso.script
    # ⛔ Con esto puesto, el error de una tabla abortaría la sesión y se perderían las siguientes.
    assert "WHENEVER SQLERROR EXIT" not in falso.script
    assert falso.argv.count("-S") == 1                   # una sola invocación del cliente


def test_run_chunk_oracle_reporta_el_error_real_no_el_banner(monkeypatch):
    salida = (_BANNER + "ERROR:\nORA-01017: invalid username/password; logon denied\n").encode()
    monkeypatch.setattr(ins.subprocess, "run", _ClienteFalso(returncode=1, stdout=salida))

    with pytest.raises(RuntimeError) as e:
        ins.run_chunk_oracle([("RTIPO", "SELECT 1 FROM RTIPO")], _CFG_SESION)
    assert str(e.value).startswith("ORA-01017")


def test_run_chunk_sqlserver_cierra_un_lote_por_tabla(monkeypatch):
    """El GO por tabla es lo que mantiene PRINT y resultados en orden, y aísla el error."""
    falso = _ClienteFalso(stdout=b"ok")
    monkeypatch.setattr(ins.subprocess, "run", falso)
    cfg = dict(_CFG_SESION, motor="SQLSERVER", schema="BD", user="")
    chunk = [("RTIPO", "SELECT 1"), ("RESTADO", "SELECT 2")]

    ins.run_chunk_sqlserver(chunk, cfg)

    assert falso.script.count(f"PRINT '{ins.TBLMARK}") == 2
    assert falso.script.count("\nGO") == 3               # SET NOCOUNT + una por tabla
    assert "-E" in falso.argv                            # sin usuario -> autenticación integrada


def test_run_chunk_sqlserver_no_pasa_la_password_por_la_linea_de_comandos(monkeypatch):
    """La password va por SQLCMDPASSWORD: en argv sería visible para todo el sistema."""
    capturado = {}
    falso = _ClienteFalso(stdout=b"ok")

    def espia(cmd, **kwargs):
        capturado["env"] = kwargs.get("env") or {}
        return falso(cmd, **kwargs)

    monkeypatch.setattr(ins.subprocess, "run", espia)
    cfg = dict(_CFG_SESION, motor="SQLSERVER", schema="BD", user="USR",
               password="valor-inventado-de-test")

    ins.run_chunk_sqlserver([("RTIPO", "SELECT 1")], cfg)

    assert "-P" not in falso.argv
    assert not any(cfg["password"] in str(a) for a in falso.argv)
    assert capturado["env"].get("SQLCMDPASSWORD") == cfg["password"]


# --------------------------------------------------------------- formateo del fichero .sql
_COLS = [("ID", {"type": "NUMBER"}),
         ("TXT", {"type": "VARCHAR2(50)"}),
         ("ALTA", {"type": "DATE"})]
_CFG_ORACLE = {"motor": "ORACLE", "schema": "ESQ"}


def _generar(tmp_path, cuerpo, cols=None, cfg=None):
    tabla = "RTIPO"
    status, filas, msg = ins.write_table_file(tabla, cols or _COLS, cuerpo,
                                              cfg or _CFG_ORACLE, tmp_path)
    return status, filas, msg, (tmp_path / f"{tabla}.sql").read_text(encoding="utf-8-sig")


def test_write_genera_un_insert_por_fila(tmp_path):
    cuerpo = (f"1{ins.DELIM}uno{ins.DELIM}2026-01-02 03:04:05{ins.ROWEND}\n"
              f"2{ins.DELIM}dos{ins.DELIM}2026-01-03 00:00:00{ins.ROWEND}\n")
    status, filas, _, sql = _generar(tmp_path, cuerpo)
    assert (status, filas) == ("OK", 2)
    assert sql.count("INSERT INTO RTIPO") == 2


def test_write_dobla_la_comilla_simple(tmp_path):
    """Sin doblarla, un apóstrofo en los datos rompe el script en el cliente."""
    cuerpo = f"1{ins.DELIM}o'hara{ins.DELIM}{ins.NULLTOK}{ins.ROWEND}\n"
    _, _, _, sql = _generar(tmp_path, cuerpo)
    assert "'o''hara'" in sql


def test_write_distingue_null_de_cadena_vacia(tmp_path):
    cuerpo = (f"1{ins.DELIM}{ins.NULLTOK}{ins.DELIM}{ins.NULLTOK}{ins.ROWEND}\n"
              f"2{ins.DELIM}{ins.DELIM}{ins.NULLTOK}{ins.ROWEND}\n")
    _, filas, _, sql = _generar(tmp_path, cuerpo)
    assert filas == 2
    assert "VALUES (1, NULL, NULL);" in sql
    assert "VALUES (2, '', NULL);" in sql


def test_write_no_entrecomilla_los_numericos(tmp_path):
    cuerpo = f"42{ins.DELIM}x{ins.DELIM}{ins.NULLTOK}{ins.ROWEND}\n"
    _, _, _, sql = _generar(tmp_path, cuerpo)
    assert "VALUES (42, 'x', NULL);" in sql


def test_write_revierte_los_tokens_de_salto_de_linea(tmp_path):
    """El literal SQL vuelve a ser multilínea: el dato original llevaba un salto."""
    cuerpo = f"1{ins.DELIM}linea1{ins.LFTOK}linea2{ins.DELIM}{ins.NULLTOK}{ins.ROWEND}\n"
    _, _, _, sql = _generar(tmp_path, cuerpo)
    assert "'linea1\nlinea2'" in sql
    assert ins.LFTOK not in sql


def test_write_cierra_con_commit_en_oracle(tmp_path):
    """sqlplus no auto-commitea: sin esto los inserts se perderían al cerrar sesión."""
    cuerpo = f"1{ins.DELIM}x{ins.DELIM}{ins.NULLTOK}{ins.ROWEND}\n"
    _, _, _, sql = _generar(tmp_path, cuerpo)
    assert sql.rstrip().endswith("commit;")
    assert "SET DEFINE OFF;" in sql          # un '&' en los datos no es variable de sustitución


def test_write_tabla_vacia_es_exito_no_error(tmp_path):
    """Una paramétrica sin filas es un caso legítimo, no un fallo de la etapa."""
    status, filas, _, sql = _generar(tmp_path, "")
    assert (status, filas) == ("OK", 0)
    assert "-- (sin filas)" in sql


def test_write_omite_la_fila_con_numero_de_campos_distinto(tmp_path):
    """Fila corrupta: se descarta con aviso en el .sql, no se emite un INSERT inválido."""
    cuerpo = (f"1{ins.DELIM}uno{ins.DELIM}{ins.NULLTOK}{ins.ROWEND}\n"
              f"2{ins.DELIM}faltan-campos{ins.ROWEND}\n")
    _, filas, _, sql = _generar(tmp_path, cuerpo)
    assert filas == 1
    assert "-- AVISO fila omitida" in sql


def test_write_avisa_de_los_binarios_grandes_no_inlineables(tmp_path):
    """El contenido de un BLOB se pierde: tiene que quedar dicho en el propio fichero."""
    cols = [("ID", {"type": "NUMBER"}), ("FOTO", {"type": "BLOB"})]
    cuerpo = f"1{ins.DELIM}{ins.NULLTOK}{ins.ROWEND}\n"
    _, _, _, sql = _generar(tmp_path, cuerpo, cols=cols)
    assert "AVISO" in sql and "FOTO" in sql


def test_write_reconstruye_el_binario_corto_desde_hexadecimal(tmp_path):
    cols = [("ID", {"type": "NUMBER"}), ("HUELLA", {"type": "RAW(4)"})]
    cuerpo = f"1{ins.DELIM}DEADBEEF{ins.ROWEND}\n"
    _, _, _, sql = _generar(tmp_path, cuerpo, cols=cols)
    assert "HEXTORAW('DEADBEEF')" in sql


def test_write_master_script_encadena_las_tablas_con_fail_fast(tmp_path):
    """El maestro aborta si una tabla falla: no deja una carga a medias en silencio."""
    master = ins.write_master_script(tmp_path, ["RTIPO", "RESTADO"], "ORACLE", "Proy")
    contenido = master.read_text(encoding="utf-8-sig")
    assert master.name == "_run_all.sql"
    assert "WHENEVER SQLERROR EXIT SQL.SQLCODE" in contenido
    assert "@@RTIPO.sql" in contenido and "@@RESTADO.sql" in contenido
