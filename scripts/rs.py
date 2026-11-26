"""
rs — CLI de las herramientas rs-workspace (las mismas 51 que expone el servidor MCP).

Misma implementacion que el MCP (scripts/rs_core.py) y misma salida: el JSON que recibiria el
agente. No necesita el paquete `mcp`, asi que sirve tambien cuando el servidor MCP no arranca.

Uso:
    python rs.py list                                  herramientas disponibles
    python rs.py help <herramienta>                    descripcion y parametros
    python rs.py <herramienta> --param valor ...       ejecutar
    python rs.py <herramienta> --args-json '{"p":1}'   parametros en JSON
    python rs.py <herramienta> --args-json -           parametros en JSON por stdin

Los nombres valen con '_' o con '-' (db_query / db-query, --max-rows / --max_rows). Los
booleanos se pasan con valor: --no-restore false. Para SQL, rutas con espacios o textos con
comillas, usar --args-json - : evita el escapado de la shell (Git Bash -> PowerShell en Windows).

Codigo de salida: 0 si la herramienta respondio sin error, 1 si devolvio error (success=false o
"error" no vacio), 2 si la llamada esta mal formada.
"""

import importlib.util
import inspect
import json
import sys
from pathlib import Path

_CORE = Path(__file__).resolve().parent / "rs_core.py"

EXIT_OK, EXIT_ERROR, EXIT_USO = 0, 1, 2


def _cargar_nucleo():
    """Carga scripts/rs_core.py por ruta (scripts/ no es un paquete importable)."""
    spec = importlib.util.spec_from_file_location("rs_core", _CORE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _normalizar(nombre):
    return nombre.strip().lstrip("-").replace("-", "_").lower()


def _tipo_base(anotacion):
    """str/int/bool/float de un parametro, mirando dentro de Annotated[...]."""
    base = getattr(anotacion, "__origin__", None) and getattr(anotacion, "__metadata__", None)
    if base is not None:
        anotacion = anotacion.__origin__
    return anotacion if anotacion in (str, int, bool, float) else str


def parametros(fn):
    """[(nombre, tipo, obligatorio, defecto)] de una herramienta."""
    salida = []
    for p in inspect.signature(fn).parameters.values():
        obligatorio = p.default is inspect.Parameter.empty
        salida.append((p.name, _tipo_base(p.annotation), obligatorio, None if obligatorio else p.default))
    return salida


def _convertir(valor, tipo, nombre):
    """Convierte el texto de la linea de comandos (o el valor JSON) al tipo del parametro."""
    if tipo is bool:
        if isinstance(valor, bool):
            return valor
        texto = str(valor).strip().lower()
        if texto in ("1", "true", "si", "sí", "yes", "y"):
            return True
        if texto in ("0", "false", "no", "n"):
            return False
        raise ValueError(f"--{nombre}: se esperaba true/false, no '{valor}'")
    if tipo is int:
        try:
            return int(valor)
        except (TypeError, ValueError):
            raise ValueError(f"--{nombre}: se esperaba un entero, no '{valor}'") from None
    if tipo is float:
        try:
            return float(valor)
        except (TypeError, ValueError):
            raise ValueError(f"--{nombre}: se esperaba un numero, no '{valor}'") from None
    return "" if valor is None else str(valor)


def construir_argumentos(fn, argv, stdin=None):
    """kwargs para fn a partir de argv (--param valor) y, si se pide, de --args-json.

    --args-json se aplica primero y las opciones sueltas lo sobrescriben. "path" se acepta
    como alias de "workspace", igual que en el MCP.
    """
    params = {n: (t, oblig) for n, t, oblig, _ in parametros(fn)}
    crudos = {}

    i = 0
    while i < len(argv):
        token = argv[i]
        if not token.startswith("--"):
            raise ValueError(f"argumento inesperado '{token}' (las opciones van como --nombre valor)")
        if "=" in token:
            clave, valor = token[2:].split("=", 1)
            i += 1
        else:
            if i + 1 >= len(argv):
                raise ValueError(f"falta el valor de {token}")
            clave, valor = token[2:], argv[i + 1]
            i += 2
        clave = _normalizar(clave)
        if clave == "args_json":
            texto = (stdin.read() if stdin is not None else sys.stdin.read()) if valor == "-" else valor
            # Windows PowerShell 5.1 puede anteponer un BOM al canalizar texto a un ejecutable.
            texto = texto.lstrip("\ufeff")
            try:
                datos = json.loads(texto) if texto.strip() else {}
            except json.JSONDecodeError as exc:
                raise ValueError(f"--args-json no es JSON valido: {exc.msg}") from None
            if not isinstance(datos, dict):
                raise ValueError("--args-json tiene que ser un objeto JSON {\"param\": valor}")
            for k, v in datos.items():
                crudos.setdefault(_normalizar(k), v)
        else:
            crudos[clave] = valor

    if "path" in crudos and "path" not in params and "workspace" in params:
        crudos.setdefault("workspace", crudos.pop("path"))

    desconocidos = sorted(set(crudos) - set(params))
    if desconocidos:
        raise ValueError("parametros desconocidos: " + ", ".join("--" + d.replace("_", "-") for d in desconocidos))

    kwargs = {}
    for nombre, (tipo, obligatorio) in params.items():
        if nombre in crudos:
            kwargs[nombre] = _convertir(crudos[nombre], tipo, nombre.replace("_", "-"))
        elif obligatorio:
            raise ValueError(f"falta --{nombre.replace('_', '-')}")
    return kwargs


def codigo_salida(texto):
    """0/1 segun el JSON devuelto: error si success=false o si trae un 'error' no vacio."""
    try:
        datos = json.loads(texto)
    except (TypeError, ValueError):
        return EXIT_OK
    if isinstance(datos, dict) and (datos.get("success") is False or datos.get("error")):
        return EXIT_ERROR
    return EXIT_OK


def _ayuda(t):
    lineas = [t.name, "", t.description, "", "Parametros:"]
    for nombre, tipo, obligatorio, defecto in parametros(t.fn):
        marca = "obligatorio" if obligatorio else f"defecto: {defecto!r}"
        lineas.append(f"  --{nombre.replace('_', '-'):24} {tipo.__name__:5}  {marca}")
    return "\n".join(lineas)


def main(argv=None, stdin=None, stdout=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    stdout = stdout or sys.stdout
    if not argv or argv[0] in ("-h", "--help"):
        stdout.write(__doc__.strip() + "\n")
        return EXIT_OK if argv else EXIT_USO

    core = _cargar_nucleo()
    herramientas = {_normalizar(n): t for n, t in core.TOOLS.items()}
    orden = _normalizar(argv[0])

    if orden == "list":
        if "--json" in argv[1:]:
            json.dump([{"name": t.name, "description": t.description} for t in core.TOOLS.values()],
                      stdout, ensure_ascii=False)
            stdout.write("\n")
        else:
            for t in core.TOOLS.values():
                resumen = t.description.split(". ")[0].split(" → ")[0]
                stdout.write(f"{t.name:24} {resumen[:100]}\n")
        return EXIT_OK

    if orden == "help":
        if len(argv) < 2 or _normalizar(argv[1]) not in herramientas:
            sys.stderr.write("uso: rs.py help <herramienta>   (ver: rs.py list)\n")
            return EXIT_USO
        stdout.write(_ayuda(herramientas[_normalizar(argv[1])]) + "\n")
        return EXIT_OK

    t = herramientas.get(orden)
    if t is None:
        sys.stderr.write(f"herramienta desconocida: {argv[0]}   (ver: rs.py list)\n")
        return EXIT_USO

    try:
        kwargs = construir_argumentos(t.fn, argv[1:], stdin=stdin)
    except ValueError as exc:
        sys.stderr.write(f"{t.name}: {exc}\n")
        return EXIT_USO

    resultado = t.fn(**kwargs)
    stdout.write(resultado if resultado.endswith("\n") else resultado + "\n")
    return codigo_salida(resultado)


if __name__ == "__main__":
    for _flujo in (sys.stdin, sys.stdout, sys.stderr):
        try:
            _flujo.reconfigure(encoding="utf-8")
        except AttributeError:  # pragma: no cover - flujo sustituido
            pass
    sys.exit(main())
