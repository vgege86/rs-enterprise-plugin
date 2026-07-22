"""
rs-workspace MCP server — herramientas nativas para soluciones uCollect/RS.
Cada tool llama al hook PowerShell correspondiente y devuelve JSON estructurado.
"""

import csv
import hashlib
import io
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

from mcp.server.fastmcp import FastMCP

SERVER_PATH = Path(__file__).resolve()
PLUGIN_ROOT = SERVER_PATH.parent.parent
HOOKS_DIR  = PLUGIN_ROOT / "hooks"
CACHE_DIR  = Path.home() / ".claude" / "cache" / "rs-models"


def _plugin_version() -> str:
    """Versión del plugin al que pertenece ESTE server. Permite detectar que se está
    ejecutando una copia obsoleta vendorizada en vez del plugin instalado."""
    try:
        manifest = PLUGIN_ROOT / ".claude-plugin" / "plugin.json"
        return json.loads(manifest.read_text(encoding="utf-8-sig")).get("version", "?")
    except Exception:
        return "?"

mcp = FastMCP("rs-workspace")

_model_cache:  dict[str, tuple[float, dict]] = {}  # path → (mtime, model) — en proceso
_config_cache: dict[str, tuple[float, dict]] = {}  # workspace → (mtime, config) — en proceso
_scope_cache:  dict[str, tuple[float, dict]] = {}  # sln_path → (mtime, scope) — en proceso
_svn_cli: bool | None = None                        # None = no comprobado aún
_git_cli: bool | None = None                        # None = no comprobado aún


def _resolve_workspace(ws: Path) -> Path:
    """Equivalente Python de Resolve-RsWorkspace (hooks/lib-dbconfig.ps1): si la ruta apunta a
    una subcarpeta del trunk, sube al trunk."""
    if ws.name in ("docs", "BD", "Batch", "OnLine"):
        return ws.parent
    return ws


def _get_config(workspace: str) -> dict:
    """get-config.ps1 con cache mtime — igual patrón que _get_scope/_load_model.
    Nunca cachea errores: si el workspace no está migrado (o el JSON es inválido), cada
    llamada vuelve a intentarlo — necesario para que convert-config.ps1 se note sin
    reiniciar el proceso MCP. Se invalida si docs\\.rs-databases.json cambia de mtime,
    para que una edición manual (ej. añadir una conexión) se recoja en la siguiente llamada."""
    cfg_path = _resolve_workspace(Path(workspace)) / "docs" / ".rs-databases.json"
    try:
        mtime = cfg_path.stat().st_mtime
    except OSError:
        mtime = None

    cached = _config_cache.get(workspace)
    if cached and mtime is not None and cached[0] == mtime:
        return cached[1]

    result = _run_ps("get-config.ps1", workspace)
    if "error" not in result and mtime is not None:
        _config_cache[workspace] = (mtime, result)
    return result


def _get_scope(sln_path: str) -> dict:
    """parse-sln.ps1 con cache mtime — el .sln no cambia durante una sesión."""
    try:
        mtime = Path(sln_path).stat().st_mtime
    except OSError:
        mtime = 0.0
    cached = _scope_cache.get(sln_path)
    if cached and cached[0] == mtime:
        return cached[1]
    result = _run_ps("parse-sln.ps1", sln_path)
    _scope_cache[sln_path] = (mtime, result)
    return result


def _load_model(model_path: Path) -> dict | None:
    """Carga model.json con cache en disco (mtime) — sobrevive reinicios del MCP server."""
    try:
        mtime = model_path.stat().st_mtime
    except FileNotFoundError:
        return None

    # 1. Cache en proceso (más rápido)
    cached = _model_cache.get(str(model_path))
    if cached and cached[0] == mtime:
        return cached[1]

    # 2. Cache en disco
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_key  = hashlib.md5(str(model_path).encode()).hexdigest()
    cache_file = CACHE_DIR / f"{cache_key}.json"
    if cache_file.exists():
        try:
            with open(cache_file, encoding="utf-8") as f:
                disk = json.load(f)
            if disk.get("mtime") == mtime:
                model = disk["model"]
                _model_cache[str(model_path)] = (mtime, model)
                return model
        except Exception:
            pass

    # 3. Leer model.json original y escribir cache
    # utf-8-sig: los hooks PowerShell (PS5.1) escriben model.json con Set-Content -Encoding
    # UTF8, que SIEMPRE antepone BOM — utf-8-sig lo tolera (y funciona igual sin BOM).
    with open(model_path, encoding="utf-8-sig") as f:
        model = json.load(f)
    _model_cache[str(model_path)] = (mtime, model)
    try:
        with open(cache_file, "w", encoding="utf-8") as f:
            json.dump({"mtime": mtime, "model": model}, f, ensure_ascii=False)
    except Exception:
        pass  # fallo de escritura no es fatal
    return model


def _run_ps(script: str, *args: str) -> dict:
    ps_path = HOOKS_DIR / script
    cmd = ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(ps_path), *args]
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    output = (result.stdout or "").strip()
    if not output:
        stderr = (result.stderr or "").strip()
        return {
            "error": stderr or f"No output from {script}",
            "exit_code": result.returncode,
            "script": script,
        }
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return {"raw": output, "exit_code": result.returncode, "script": script}


def _proyecto(workspace: str) -> str:
    """Infiere nombre de proyecto desde ruta workspace (carpeta anterior a trunk/)."""
    return Path(workspace).parent.name


def _get_db_password(workspace: str, conexion_id: str = "") -> str:
    """Lee password directo de docs/.rs-databases.json — NUNCA pasar por _get_config()/get-config.ps1,
    cuyo dict se devuelve tal cual por la tool get_db_config (no debe filtrar el password al agente).
    conexion_id vacío → conexión principal (conexiones[0]).
    Normaliza el workspace igual que Resolve-RsWorkspace (PowerShell): si apunta a una
    subcarpeta docs/BD/Batch/OnLine, sube al trunk — si no, la password sale vacía aunque
    motor/datasource/schema/user ya vengan correctos vía _get_config()/get-config.ps1."""
    cfg_path = _resolve_workspace(Path(workspace)) / "docs" / ".rs-databases.json"
    if not cfg_path.exists():
        return ""
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8-sig"))
        conexiones = cfg.get("conexiones") or []
        if not conexiones:
            return ""
        sel = None
        if conexion_id:
            sel = next((c for c in conexiones if str(c.get("id", "")).lower() == conexion_id.lower()), None)
        if sel is None:
            # Con conexion_id no vacío que no matchea ninguna conexión, este fallback es
            # inalcanzable hoy: el único caller (db_query) ya valida el id y devuelve error
            # antes de llegar a llamar a esta función, así que sel siempre matchea cuando
            # conexion_id no está vacío. Se mantiene por robustez si aparece otro caller.
            sel = conexiones[0]
        for part in str(sel.get("cadena", "")).split(";"):
            part = part.strip()
            if part.lower().startswith("password="):
                return part.split("=", 1)[1].strip()
        return ""
    except Exception:
        return ""


def _check_workspace(workspace: str) -> dict | None:
    """Devuelve dict de error si el workspace no existe, None si es válido."""
    if not Path(workspace).exists():
        return {"error": f"Workspace no encontrado: {workspace}", "success": False}
    return None


def _check_svn_cli() -> bool:
    global _svn_cli
    if _svn_cli is None:
        try:
            r = subprocess.run(["svn", "--version", "--quiet"], capture_output=True, timeout=5)
            _svn_cli = r.returncode == 0
        except (FileNotFoundError, subprocess.TimeoutExpired):
            _svn_cli = False
    return _svn_cli


def _check_git_cli() -> bool:
    global _git_cli
    if _git_cli is None:
        try:
            r = subprocess.run(["git", "--version"], capture_output=True, timeout=5)
            _git_cli = r.returncode == 0
        except (FileNotFoundError, subprocess.TimeoutExpired):
            _git_cli = False
    return _git_cli


@mcp.tool(description="Parsea .sln → scope_dirs, tipo (Batch/Online), workspace. Usar al inicio de cada tarea (paso 1b). Resultado cacheado en proceso.")
def get_scope(sln_path: str) -> str:
    return json.dumps(_get_scope(sln_path), ensure_ascii=False, indent=2)


@mcp.tool(description="Confirma que la .sln existe y es accesible. Usar en paso 2 del pipeline antes de parse-sln.")
def validate_solution(sln_path: str) -> str:
    return json.dumps(_run_ps("validate-solution.ps1", sln_path), ensure_ascii=False, indent=2)


@mcp.tool(description="Detecta qué VCS hay bajo el workspace subiendo por las carpetas: 'svn', 'git' o 'none'. Llamar antes de cualquier tool svn_*/git_* para saber cuál usar — no hay forma de saberlo sin esto.")
def detect_vcs(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("detect-vcs.ps1", workspace), ensure_ascii=False, indent=2)


@mcp.tool(description="Lee .rs-databases.json → motor, datasource, schema, model_path de la conexión principal, más conexiones[] y motores[]. Usar antes de operaciones BD.")
def get_db_config(workspace: str) -> str:
    return json.dumps(_get_config(workspace), ensure_ascii=False, indent=2)


@mcp.tool(description="Localiza clase/método/propiedad/interfaz/enum en scope_dirs. symbol_type: class|method|property|interface|enum|any. max_results limita matches (default 50).")
def find_symbol(symbol: str, scope_dirs: str, symbol_type: str = "any", max_results: int = 50) -> str:
    result = _run_ps("find-symbol.ps1", symbol, scope_dirs, "-Type", symbol_type)
    if isinstance(result.get("matches"), list) and len(result["matches"]) > max_results:
        result["matches_total"] = len(result["matches"])
        result["matches"] = result["matches"][:max_results]
        result["matches_truncated"] = True
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool(description="Build real con dotnet → errors[], warnings[], success. no_restore=True omite NuGet restore. max_errors limita lista de errores en contexto (default 20).")
def compile_check(sln_path: str, no_restore: bool = True, max_errors: int = 20) -> str:
    args = [sln_path]
    if no_restore:
        args.append("-NoRestore")
    result = _run_ps("compile-check.ps1", *args)
    if isinstance(result.get("errors"), list) and len(result["errors"]) > max_errors:
        result["errors_total"] = len(result["errors"])
        result["errors"] = result["errors"][:max_errors]
        result["errors_truncated"] = True
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool(description="dotnet test → has_test_project (bool: existe proyecto de test), passed/failed/failures[], skipped (conteo de tests skippeados, no ausencia de proyecto). Si no hay proyecto de test → solo has_test_project=false (sin success/passed). max_failures limita detalles de fallo en contexto (default 10).")
def run_tests(sln_path: str, no_build: bool = True, max_failures: int = 10) -> str:
    args = [sln_path]
    if no_build:
        args.append("-NoBuild")
    result = _run_ps("test-runner-check.ps1", *args)
    if isinstance(result.get("failures"), list) and len(result["failures"]) > max_failures:
        result["failures_total"] = len(result["failures"])
        result["failures"] = result["failures"][:max_failures]
        result["failures_truncated"] = True
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool(description="Estado SVN del workspace: modificados, añadidos, eliminados, ? sin versionar. Usar para commit/diff.")
def svn_status(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("svn-diff.ps1", workspace), ensure_ascii=False, indent=2)


@mcp.tool(description="Estado Git del workspace: modificados, staged, sin trackear (??), conflictos (U). Equivalente Git de svn_status — usar detect_vcs primero para saber cuál llamar.")
def git_status(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    if not _check_git_cli():
        return json.dumps({"error": "git CLI no disponible en PATH", "workspace": workspace}, ensure_ascii=False)
    return json.dumps(_run_ps("git-status.ps1", workspace), ensure_ascii=False, indent=2)


@mcp.tool(description="Crea proyecto de test y lo añade a la .sln. framework: xunit|mstest|nunit. Usar cuando run_tests devuelve has_test_project=false.")
def create_test_project(sln_path: str, framework: str = "xunit", project_name: str = "") -> str:
    args = [sln_path, "-Framework", framework]
    if project_name:
        args += ["-ProjectName", project_name]
    return json.dumps(_run_ps("create-test-project.ps1", *args), ensure_ascii=False, indent=2)


_SEP_SQLSERVER = "|~|"   # separador de columnas para sqlcmd: improbable dentro de un valor real


def _parse_resultset(stdout: str, motor: str) -> tuple[list, list, int]:
    """Salida del cliente SQL → (columns, rows, total). rows son listas de valores en el orden de
    columns — los nombres van una sola vez, no repetidos por fila.
    Oracle llega como CSV entrecomillado (SET MARKUP CSV); SQL Server, separado por _SEP_SQLSERVER."""
    lineas = [l for l in (stdout or "").splitlines() if l.strip()]
    if not lineas:
        return [], [], 0

    if motor == "ORACLE":
        campos = list(csv.reader(io.StringIO("\n".join(lineas))))
    else:
        campos = [l.split(_SEP_SQLSERVER) for l in lineas]
        # sqlcmd separa cabecera de datos con una fila de guiones — no es un dato
        campos = [f for f in campos
                  if not all(c.strip() and set(c.strip()) == {"-"} for c in f)]

    if not campos:
        return [], [], 0

    columns = [c.strip() for c in campos[0]]
    rows    = [[v.strip() for v in f] for f in campos[1:]]
    return columns, rows, len(rows)


@mcp.tool(description="SELECT directo a una BD de .rs-databases.json (SQL Server u Oracle). SOLO SELECT. conexion = id de conexión; si se omite, la principal. Devuelve columns[] (nombres, una vez) y rows[] (listas de valores en ese mismo orden). max_rows limita filas devueltas en contexto (default 200).")
def db_query(workspace: str, sql: str, max_rows: int = 200, conexion: str = "") -> str:
    sql_clean = sql.strip().upper()
    if not sql_clean.startswith("SELECT"):
        return json.dumps({"success": False, "error": "Solo se permiten consultas SELECT"}, ensure_ascii=False)
    # Bloquea multi-statement: "SELECT 1; DROP TABLE x"
    # Elimina ; trailing (habitual en SQL) y cuenta ; fuera de literales de string
    sql_norm = sql.strip().rstrip(";")
    in_str, semi_count = False, 0
    for ch in sql_norm:
        if ch == "'":
            in_str = not in_str
        elif ch == ";" and not in_str:
            semi_count += 1
    if semi_count > 0:
        return json.dumps({"success": False, "error": "Multi-statement SQL no permitido"}, ensure_ascii=False)

    config = _get_config(workspace)
    if "error" in config:
        return json.dumps(config, ensure_ascii=False)

    conexiones = config.get("conexiones") or []
    if conexion:
        sel = next((c for c in conexiones if str(c.get("id", "")).lower() == conexion.lower()), None)
        if sel is None:
            validas = ", ".join(str(c.get("id", "")) for c in conexiones)
            return json.dumps({"success": False, "error": f"Conexión '{conexion}' no existe. Válidas: {validas}"}, ensure_ascii=False)
    else:
        sel = conexiones[0] if conexiones else config

    motor      = sel.get("motor", "")
    datasource = sel.get("datasource", "")
    schema     = sel.get("schema", "")
    user       = sel.get("user", "")
    password   = _get_db_password(workspace, str(sel.get("id", "")))

    if motor == "SQLSERVER":
        # -s con separador improbable: sqlcmd no entrecomilla, así que un valor que contenga el
        # separador partiría la fila en silencio. Sin -h -1 para que emita la cabecera: es la única
        # forma de saber los nombres reales de las columnas.
        # SET NOCOUNT ON: sin esto sqlcmd añade un pie "(N rows affected)" que no lleva separador y
        # se colaba como una fila más — en un escalar de 1 columna encaja en longitud y pasaba
        # desapercibido, inflando row_count igual que hacía la cabecera repetida en Oracle.
        cmd = ["sqlcmd", "-S", datasource, "-d", schema, "-Q", f"SET NOCOUNT ON; {sql_norm}",
               "-W", "-s", _SEP_SQLSERVER]
        entorno = None
        if password:
            # Password por variable de entorno, no en argv: -P queda visible en la lista de procesos
            # durante toda la ejecución. Misma razón por la que la rama Oracle usa fichero temporal.
            cmd += ["-U", user]
            entorno = {**os.environ, "SQLCMDPASSWORD": password}
        result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                                errors="replace", env=entorno)
    elif motor == "ORACLE":
        # Credenciales en fichero SQL, no en línea de comando (no exponer en lista de procesos)
        if password:
            connect_line = f"CONNECT {user}/{password}@{datasource}\n"
            sqlplus_conn = "/nolog"
        else:
            connect_line = ""
            sqlplus_conn = f"{user}/@{datasource}"
        # El usuario de conexión puede no ser el owner de las tablas (ej. usuario de solo-consulta
        # cross-schema) — fijar el schema por default de la sesión para que SELECTs sin calificar
        # (ej. "SELECT * FROM RIDIOMA") resuelvan contra el owner real, no contra $user.
        schema_line = f"ALTER SESSION SET CURRENT_SCHEMA = {schema};\n" if schema and schema != user else ""
        # MARKUP CSV (sqlplus 12.2+) en vez de salida tabular: con la tabular sqlplus trunca la
        # cabecera al ancho del campo (una columna IDIOMA con valores 'ES' se anunciaba como 'ID')
        # y repite la cabecera cada PAGESIZE filas, que acababan contadas como datos.
        # WHENEVER SQLERROR: sin esto sqlplus sale con código 0 ante un ORA-, y un error de consulta
        # se devolvía como success=true con 0 filas — indistinguible de "la tabla está vacía".
        script = (f"SET MARKUP CSV ON DELIMITER , QUOTE ON\nSET PAGESIZE 0\nSET FEEDBACK OFF\n"
                  f"WHENEVER SQLERROR EXIT SQL.SQLCODE\n"
                  f"{connect_line}{schema_line}{sql_norm};\nEXIT;\n")
        tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".sql", delete=False, encoding="utf-8")
        tmp.write(script); tmp.close()
        cmd = ["sqlplus", "-S", sqlplus_conn, f"@{tmp.name}"]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
        finally:
            os.unlink(tmp.name)
    else:
        return json.dumps({"success": False, "error": f"Motor no soportado: {motor}"}, ensure_ascii=False)

    ok = result.returncode == 0
    if ok:
        columns, rows, total = _parse_resultset(result.stdout, motor)
        error = None
    else:
        # sqlplus escribe los ORA-/SP2- en stdout, no en stderr; sqlcmd usa stderr. Mirar ambos,
        # y quedarse con las líneas de diagnóstico en vez de volcar la salida entera.
        salida = ((result.stdout or "") + "\n" + (result.stderr or "")).splitlines()
        diag = [l.strip() for l in salida if re.search(r"ORA-|SP2-|Sqlcmd|Msg \d+", l)]
        columns, rows, total = [], [], 0
        error = "; ".join(diag).strip() or "\n".join(l for l in salida if l.strip()).strip()

    return json.dumps({
        "success": ok,
        "motor": motor,
        "columns": columns,
        "rows": rows[:max_rows],
        "row_count": min(total, max_rows),
        "rows_truncated": total > max_rows,
        "error": error,
    }, ensure_ascii=False, indent=2)


@mcp.tool(description="Compara model.json con esquema real BD → tablas nuevas/eliminadas, columnas añadidas/eliminadas y columnas con tipo o nullable distinto (modified_columns). Usar para detectar drift completo.")
def compare_model(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("compare-model.ps1", workspace), ensure_ascii=False, indent=2)


@mcp.tool(description="Extrae controles AIS de .aspx con textos para registrar en RIDIOMA y RCONTROLES.")
def scan_aspx(sln_path: str) -> str:
    return json.dumps(_run_ps("scan-aspx.ps1", "-SlnPath", sln_path), ensure_ascii=False, indent=2)


@mcp.tool(description="Registra ejecución del pipeline en executions/history.json. status: success|fail|partial. Llamar al final del pipeline.")
def log_execution(workspace: str, solution: str, task: str, status: str = "success", agents: str = "") -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("log-execution.ps1", workspace, solution, task, "-Status", status, "-Agents", agents), ensure_ascii=False, indent=2)


@mcp.tool(description="Scripts SQL migración desde drift modelo→BD: CREATE TABLE+PK+FK+INDEX (tablas nuevas), ALTER TABLE ADD (columnas nuevas), ALTER TABLE MODIFY (tipo/nullable distinto), DROP COLUMN comentado (columnas en BD no en modelo).")
def generate_migration(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("generate-migration.ps1", workspace), ensure_ascii=False, indent=2)


@mcp.tool(description="Historial commits SVN → revisión, autor, fecha, mensaje. solution filtra por texto en mensaje.")
def svn_log(workspace: str, solution: str = "", limit: int = 10) -> str:
    if not _check_svn_cli():
        return json.dumps({
            "error": "svn CLI no disponible en PATH",
            "fallback": "Ver historial en TortoiseSVN → clic derecho en workspace → Show Log",
            "workspace": workspace,
        }, ensure_ascii=False)
    args = [workspace]
    if solution:
        args += ["-Solution", solution]
    args += ["-Limit", str(limit)]
    return json.dumps(_run_ps("svn-log.ps1", *args), ensure_ascii=False, indent=2)


@mcp.tool(description="Historial commits Git → revision (hash corto), autor, fecha, mensaje. solution filtra por texto en mensaje. Equivalente Git de svn_log.")
def git_log(workspace: str, solution: str = "", limit: int = 10) -> str:
    if not _check_git_cli():
        return json.dumps({"error": "git CLI no disponible en PATH", "workspace": workspace}, ensure_ascii=False)
    args = [workspace]
    if solution:
        args += ["-Solution", solution]
    args += ["-Limit", str(limit)]
    return json.dumps(_run_ps("git-log.ps1", *args), ensure_ascii=False, indent=2)


@mcp.tool(description="Busca en docs funcionales secciones relacionadas con keyword → archivo, heading, línea, fragmento.")
def find_doc_section(workspace: str, keyword: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("find-doc-section.ps1", workspace, keyword), ensure_ascii=False, indent=2)


# Firma de miembro C# en una línea añadida del diff — captura el nombre del símbolo (método/clase).
_DIFF_SYMBOL_RE = re.compile(
    r'(?:public|private|protected|internal)\s+(?:static\s+)?(?:override\s+)?(?:async\s+)?(?:\w+\s+)+(\w+)\s*[\(\{]')


def _diff_summary(diff_text: str, revisions: str, file_header_re: str) -> str:
    """Post-proceso común de svn_diff_revision/git_diff_revision: resumen estructurado sin código
    (~500 tokens en vez de ~4K). Las dos VCS difieren SOLO en el marcador de fichero del diff
    (SVN 'Index: <file>' vs Git 'diff --git a/<file> b/<file>'), que llega como file_header_re."""
    header_re = re.compile(file_header_re)
    file_stats: dict = {}
    current_file = None
    for line in (diff_text or "").splitlines():
        m = header_re.match(line)
        if m:
            current_file = m.group(1).strip()
            file_stats.setdefault(current_file, {"added": 0, "removed": 0, "op": "M", "symbols": []})
            continue
        if current_file is None:
            continue
        if line.startswith('+') and not line.startswith('+++'):
            file_stats[current_file]["added"] += 1
            sym = _DIFF_SYMBOL_RE.search(line)
            if sym and sym.group(1) not in file_stats[current_file]["symbols"]:
                file_stats[current_file]["symbols"].append(sym.group(1))
        elif line.startswith('-') and not line.startswith('---'):
            file_stats[current_file]["removed"] += 1

    summary = [
        {"file": f, "op": s["op"], "+lines": s["added"], "-lines": s["removed"], "symbols": s["symbols"][:10]}
        for f, s in file_stats.items()
    ]
    return json.dumps({
        "revisions": revisions,
        "files_changed": len(summary),
        "summary": summary,
        "note": "summary_only=True — usar summary_only=False para obtener código completo",
    }, ensure_ascii=False, indent=2)


@mcp.tool(description="Diff de revisiones SVN (coma-separadas). summary_only=True → [{file, op, +lines, -lines, symbols[]}] sin código (~500 tokens). summary_only=False → combined_diff completo (~4K tokens). Usar full para rs-validar-req, summary para planificación/historial.")
def svn_diff_revision(workspace: str, revisions: str, max_diff_chars: int = 15000, summary_only: bool = False) -> str:
    if not _check_svn_cli():
        return json.dumps({
            "error": "svn CLI no disponible en PATH",
            "fallback": "Ver diff en TortoiseSVN → Show Log → seleccionar revisión → Show Changes",
            "revisions": revisions,
            "workspace": workspace,
        }, ensure_ascii=False)
    raw = _run_ps("svn-diff-revision.ps1", workspace, revisions, "-MaxDiffChars", str(max_diff_chars))
    if not summary_only:
        return json.dumps(raw, ensure_ascii=False, indent=2)
    # SVN marca cada fichero del diff con 'Index: <file>'.
    return _diff_summary(raw.get("combined_diff") or "", revisions, r'^Index:\s+(.+)')


@mcp.tool(description="Diff de commits Git (hashes coma-separados). summary_only=True → [{file, op, +lines, -lines, symbols[]}] sin código (~500 tokens). summary_only=False → combined_diff completo (~4K tokens). Equivalente Git de svn_diff_revision — usar full para rs-validar-req, summary para planificación/historial.")
def git_diff_revision(workspace: str, revisions: str, max_diff_chars: int = 15000, summary_only: bool = False) -> str:
    if not _check_git_cli():
        return json.dumps({"error": "git CLI no disponible en PATH", "revisions": revisions, "workspace": workspace}, ensure_ascii=False)
    raw = _run_ps("git-diff-revision.ps1", workspace, revisions, "-MaxDiffChars", str(max_diff_chars))
    if not summary_only:
        return json.dumps(raw, ensure_ascii=False, indent=2)
    # Git marca cada fichero del diff con 'diff --git a/<file> b/<file>'.
    return _diff_summary(raw.get("combined_diff") or "", revisions, r'^diff --git a/.+ b/(.+)')


@mcp.tool(description="Añade ficheros ? a SVN: CLI → TortoiseProc → instrucciones manuales. files vacío = auto-detectar todos los ? del workspace.")
def svn_add(workspace: str, files: str = "") -> str:
    args = [workspace]
    if files:
        args += ["-Files", files]
    return json.dumps(_run_ps("svn-add.ps1", *args), ensure_ascii=False, indent=2)


@mcp.tool(description="Añade ficheros ?? (sin trackear) a Git: CLI → TortoiseGitProc → instrucciones manuales. files vacío = auto-detectar todos los ?? del workspace. Equivalente Git de svn_add.")
def git_add(workspace: str, files: str = "") -> str:
    args = [workspace]
    if files:
        args += ["-Files", files]
    return json.dumps(_run_ps("git-add.ps1", *args), ensure_ascii=False, indent=2)


@mcp.tool(description="Escanea código → SQL injection, credenciales hardcodeadas, XSS, input sin validar. Findings con severidad y archivo:línea.")
def security_scan(sln_path: str) -> str:
    return json.dumps(_run_ps("security-scan.ps1", sln_path), ensure_ascii=False, indent=2)


@mcp.tool(description="Actualiza tablas específicas de model.json desde BD real. Llamar post-migración. tables = coma-separadas.")
def sync_model_tables(workspace: str, tables: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("sync-model-tables.ps1", workspace, tables), ensure_ascii=False, indent=2)


@mcp.tool(description="Mapa dependencias entre soluciones: proyectos compartidos (impacto), conflictos versión NuGet.")
def map_dependencies(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("map-dependencies.ps1", workspace), ensure_ascii=False, indent=2)


@mcp.tool(description="Valida el entorno de trabajo: .rs-databases.json, ruta AIS, dotnet SDK, SVN, modelo BD, docs agentic. Devuelve checks[] con status OK/WARN/FAIL.")
def check_env(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("check-env.ps1", workspace, _proyecto(workspace)), ensure_ascii=False, indent=2)


@mcp.tool(description="Genera DDL SQL desde el modelo BD → escribe C:\\AIS\\<proyecto>\\scripts\\<proyecto>-ddl-<motor>.sql. Con motor vacío usa motores[] de .rs-databases.json: si hay más de uno, genera un fichero por motor y devuelve {motores, resultados[]}; si el resultado es único (un motor), devuelve el objeto {path, motor, line_count} sin envolver. El SQL no entra en contexto.")
def generate_sql(workspace: str, motor: str = "") -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    proyecto = _proyecto(workspace)

    if motor:
        motores = [motor]
    else:
        config = _get_config(workspace)
        if "error" in config:
            return json.dumps(config, ensure_ascii=False)
        motores = config.get("motores") or []
        if not motores:
            return json.dumps({"error": "Sin motores declarados en .rs-databases.json"}, ensure_ascii=False)

    resultados = [
        _run_ps("generate-sql.ps1", workspace, "-Proyecto", proyecto, "-Motor", m)
        for m in motores
    ]
    if len(resultados) == 1:
        return json.dumps(resultados[0], ensure_ascii=False, indent=2)
    return json.dumps({"motores": motores, "resultados": resultados}, ensure_ascii=False, indent=2)


@mcp.tool(description="Exporta modelo BD a Oracle Data Modeler (.dmd) → escribe BD/<proyecto>.dmd. Devuelve ruta y nº tablas — el XML no entra en contexto.")
def export_dmd(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("export-dmd.ps1", workspace, "-Proyecto", _proyecto(workspace)), ensure_ascii=False, indent=2)


@mcp.tool(description="Sincroniza tablas y columnas del modelo BD desde el esquema real de la BD. No toca relaciones. Devuelve nº tablas sincronizadas.")
def sync_from_db(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("sync-from-db.ps1", workspace, _proyecto(workspace)), ensure_ascii=False, indent=2)


@mcp.tool(description="Sincroniza índices Oracle (ALL_INDEXES) al modelo BD JSON. Reemplaza source='db', preserva source='manual'. Solo Oracle. Devuelve index_count y table_count.")
def sync_indexes(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("sync-indexes.ps1", workspace, _proyecto(workspace)), ensure_ascii=False, indent=2)


@mcp.tool(description="Infiere relaciones entre tablas analizando código DALC (JOINs, WHERE cruzados). Actualiza el modelo JSON. sln_path opcional para limitar scope.")
def analyze_dalc(workspace: str, sln_path: str = "") -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    args = [workspace, _proyecto(workspace)]
    if sln_path:
        args += ["-SolutionPath", sln_path]
    return json.dumps(_run_ps("analyze-dalc.ps1", *args), ensure_ascii=False, indent=2)


@mcp.tool(description="Genera ERD HTML del modelo BD y lo abre en el navegador. Devuelve ruta y nº de tablas — no carga el modelo en contexto.")
def render_erd(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("render-erd.ps1", workspace, "-Proyecto", _proyecto(workspace)), ensure_ascii=False, indent=2)


@mcp.tool(description="Esquema completo (columnas con tipo/nullable/pk, relaciones, índices) de tablas específicas del modelo BD. Evita cargar model.json completo (~180K tokens). tables = coma-separadas.")
def get_table_schema(workspace: str, tables: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    config = _get_config(workspace)
    if "error" in config: return json.dumps(config, ensure_ascii=False)

    model_path = Path(config.get("model_path", ""))
    table_list = [t.strip().upper() for t in tables.split(",") if t.strip()]

    model = _load_model(model_path)
    if model is None:
        return json.dumps({"error": f"Modelo BD no encontrado: {model_path}"}, ensure_ascii=False)

    raw = model.get("tables", {})
    if isinstance(raw, dict):
        index = {k.upper(): v for k, v in raw.items()}
    else:
        index = {(t.get("name") or t.get("tableName", "?")).upper(): t for t in raw}

    result: dict = {}
    not_found: list = []
    for tname in table_list:
        tdef = index.get(tname)
        if not tdef:
            not_found.append(tname)
            continue
        cols = tdef.get("columns", {})
        if isinstance(cols, dict):
            col_list = [{"name": k, **v} for k, v in cols.items()]
        else:
            col_list = list(cols)
        result[tname] = {
            "description": tdef.get("description", ""),
            "columns": col_list,
            "relations": tdef.get("relations", []),
            "indexes": tdef.get("indexes", []),
        }

    return json.dumps({
        "workspace": workspace,
        "motor": config.get("motor"),
        "schema": config.get("schema"),
        "tables": result,
        "not_found": not_found,
    }, ensure_ascii=False, indent=2)


@mcp.tool(description="Localiza N símbolos en una sola llamada (equivale a N×find_symbol). symbols = coma-separados. Usar en impact analysis y refactor para evitar N round-trips.")
def batch_find_symbols(symbols: str, scope_dirs: str, symbol_type: str = "any", max_per_symbol: int = 20) -> str:
    symbol_list = [s.strip() for s in symbols.split(",") if s.strip()]
    out: dict = {}
    for sym in symbol_list:
        r = _run_ps("find-symbol.ps1", sym, scope_dirs, "-Type", symbol_type)
        matches = r.get("matches", [])
        if len(matches) > max_per_symbol:
            matches = matches[:max_per_symbol]
        out[sym] = {"found": len(matches) > 0, "count": len(matches), "matches": matches}
    return json.dumps({"symbols": out, "total_symbols": len(symbol_list)}, ensure_ascii=False, indent=2)


@mcp.tool(description="Busca patrón regex en archivos del scope de una solución. Reemplaza 3-8× Grep con garantía de scope_dirs. Devuelve [{file,line,match,context}].")
def search_code(workspace: str, sln_path: str, pattern: str, file_glob: str = "*.cs", context_lines: int = 2, max_results: int = 50) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(
        _run_ps("search-code.ps1", workspace, sln_path, pattern, "-Glob", file_glob, "-Context", str(context_lines), "-MaxResults", str(max_results)),
        ensure_ascii=False, indent=2
    )


@mcp.tool(description="Compara solo tablas específicas del modelo con BD real. Usar post-migración cuando se conocen las tablas modificadas. Evita comparar las 362 tablas completas. tables = coma-separadas.")
def compare_model_tables(workspace: str, tables: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    return json.dumps(_run_ps("compare-model.ps1", workspace, "-Tables", tables), ensure_ascii=False, indent=2)


@mcp.tool(description="Índice ligero del modelo BD: {TABLA: [COL1, COL2, ...]}. ~15K tokens vs 180K del modelo completo. Usar para impact analysis, búsqueda de columnas, verificar qué tablas existen.")
def get_model_index(workspace: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    config = _get_config(workspace)
    if "error" in config: return json.dumps(config, ensure_ascii=False)

    model = _load_model(Path(config.get("model_path", "")))
    if model is None:
        return json.dumps({"error": "Modelo BD no encontrado"}, ensure_ascii=False)

    raw = model.get("tables", {})
    items = raw.items() if isinstance(raw, dict) else \
            [(t.get("name", t.get("tableName", "?")), t) for t in raw]

    index = {}
    for name, tdef in items:
        cols = tdef.get("columns", {})
        col_names = list(cols.keys()) if isinstance(cols, dict) else \
                    [c.get("name", c.get("columnName", "?")) for c in cols]
        index[name] = col_names

    return json.dumps({
        "workspace": workspace,
        "table_count": len(index),
        "index": index,
    }, ensure_ascii=False, indent=2)


@mcp.tool(description="Busca keyword en nombres de tablas, columnas y descripciones del modelo BD. Alternativa a cargar model.json completo cuando se busca dónde vive un concepto. Devuelve tablas/columnas que hacen match.")
def search_model(workspace: str, keyword: str) -> str:
    if err := _check_workspace(workspace): return json.dumps(err, ensure_ascii=False)
    config = _get_config(workspace)
    if "error" in config: return json.dumps(config, ensure_ascii=False)

    model = _load_model(Path(config.get("model_path", "")))
    if model is None:
        return json.dumps({"error": "Modelo BD no encontrado"}, ensure_ascii=False)

    kw = keyword.upper()
    raw = model.get("tables", {})
    items = raw.items() if isinstance(raw, dict) else \
            [(t.get("name", t.get("tableName", "?")), t) for t in raw]

    results = []
    for tname, tdef in items:
        matching_cols = []
        cols = tdef.get("columns", {})
        col_items = cols.items() if isinstance(cols, dict) else \
                    [(c.get("name", "?"), c) for c in cols]
        for cname, cdef in col_items:
            if kw in cname.upper() or kw in (cdef.get("description") or "").upper():
                matching_cols.append({"name": cname, "type": cdef.get("type", "")})

        hit_table = kw in tname.upper() or kw in (tdef.get("description") or "").upper()
        if hit_table or matching_cols:
            results.append({
                "table":            tname,
                "match_table_name": kw in tname.upper(),
                "description":      tdef.get("description", ""),
                "matching_columns": matching_cols,
            })

    return json.dumps({
        "keyword":        keyword,
        "tables_matched": len(results),
        "results":        results,
    }, ensure_ascii=False, indent=2)


@mcp.tool(description="Adjunta ficheros (ej. scripts .sql) a una issue de Jira Cloud. Cubre el hueco del MCP Atlassian Rovo (no expone attachment). Lee credenciales de ~/.claude/rs-jira-credentials.json. files = rutas coma-separadas. Usado por la skill rs-jira (Fase 4).")
def jira_attach(issue_key: str, files: str) -> str:
    return json.dumps(_run_ps("jira-attach.ps1", "-IssueKey", issue_key, "-Files", files), ensure_ascii=False, indent=2)


@mcp.tool(description="Health check: verifica que el servidor MCP está activo y devuelve hooks_dir, nº hooks disponibles y versión Python.")
def ping() -> str:
    import sys as _sys
    hooks = list(HOOKS_DIR.glob("*.ps1")) if HOOKS_DIR.exists() else []
    return json.dumps({
        "ok": True,
        "version": _plugin_version(),
        "server_path": str(SERVER_PATH),
        "hooks_dir": str(HOOKS_DIR),
        "hooks_found": len(hooks),
        "svn_cli": _check_svn_cli(),
        "git_cli": _check_git_cli(),
        "python": _sys.version.split()[0],
    }, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    mcp.run(transport="stdio")
