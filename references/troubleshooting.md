# Troubleshooting

---

# ❌ Problemas comunes

---

## Build falla

Causas:

- referencias incorrectas
- tipos incompatibles

---

Solución:

- revisar validator
- corregir errores antes de build

---

## Runtime falla

Causas:

- DLL faltantes
- bin incompleto

---

Solución:

- copiar TODO el bin\Release
- evitar solo copiar .exe

---

## Error de BD

Causas:

- tipo incorrecto
- longitud incorrecta

---

Solución:

- validar con bd.md
- usar CHAR_LENGTH en Oracle

---

## Tabla nueva no aparece en ALL_TABLES/ALL_OBJECTS (Oracle)

Causas:

- dictionary cache de la sesión/pool no refrescado tras un CREATE TABLE reciente
- ALL_TABLES/ALL_OBJECTS/ALL_TAB_COLUMNS quedan desactualizadas mientras la sesión persiste, aunque la tabla ya sea consultable

---

Solución:

- no repetir la consulta a vistas catálogo en bucle (máx 1 intento)
- confirmar con SELECT directo a la tabla (`SELECT * FROM <TABLA> WHERE ROWNUM=1`) — funciona aunque el catálogo no la vea
- tratar `sync_model_tables`/`get_table_schema` como autoritativos; caer a SELECT directo solo si niegan la existencia de una tabla que el usuario confirma que existe

---

## db_query falla: "Modelo BD declarado en docs/.rs-databases.json pero no encontrado"

Causas:

- la conexión de `docs/.rs-databases.json` **declara** su modelo (campo `"model"`) y ese fichero no existe
- o el fichero existe pero no se puede usar: ilegible, JSON inválido, o su raíz no es un objeto (aquí da igual si la ruta es declarada o del convenio)
- nuevo en **3.1.0**: antes la consulta devolvía todas las filas **en claro** etiquetadas `pii.mode = "off"`, indistinguible de un workspace que nunca configuró política. Ahora falla cerrado — `success: false`, cero filas — y en la tool MCP el modelo se carga **antes** de tocar la BD, así que la consulta ni se ejecuta
- ⚠️ no es este caso si la ruta sale del **convenio** (`BD\<proyecto>-model.json`, sin campo `"model"`) y el fichero no está: eso es un workspace que nunca declaró política y sigue corriendo con `pii.mode = "off"`

---

Solución:

- generar el modelo: `/rs-init` en un workspace nuevo, `/rs-erd` para sincronizarlo desde la BD
- si el modelo existe pero en otra ruta, corregir el campo `"model"` de esa conexión en `docs/.rs-databases.json`
- ⛔ no quitar el campo `"model"` para "que deje de fallar": eso devuelve el workspace al comportamiento en claro sin política, que es justo lo que el error existe para evitar

---

## /rs-pii enforce dice que las guardas están registradas, pero los bypass siguen funcionando

Causas:

- Claude Code captura la configuración de hooks **al arrancar**: lo que se escribe en `~/.claude/settings.json` a mitad de sesión no entra en vigor hasta reiniciar
- `check_env` comprueba el **fichero**, no la sesión en curso — `pii.guards_registered = true` significa "escritas", no "vivas" (por eso devuelve además `guards_note`)

---

Solución:

- **reiniciar Claude Code**. Hasta entonces `enforce` solo enmascara lo que pasa por `db_query`: el bypass por `Bash` (`sqlplus`/`sqlcmd` directos) y por `Write`/`Edit` sigue abierto
- no apoyarse en la protección ni reportarla como activa en la misma sesión en que se registraron las guardas
- si las dos guardas ya estaban registradas de antes, no hace falta reinicio: venían cargadas del arranque

---

## Los valores llegan como pii:xxxxxxxxxxxx y se esperaban datos reales

Causas:

- comportamiento normal de `pii_policy.mode = "enforce"`: la columna está clasificada como dato personal y sale como seudónimo
- o clasificación equivocada — para distinguirlo hay que mirar el bloque `pii` de la respuesta de la consulta, no adivinar

---

Solución:

- `pii.mode = "enforce"` y la columna en `pii.masked` → política aplicada. `/rs-pii status` lista las columnas que salen **en claro**; para el veredicto y el **motivo** de una ya enmascarada (`marca_columna`, `patron_nombre`, `parametrica`, `tipo`, `texto`), el clasificador con `--todo`: `python scripts/pii_cli.py --clasificar <model_path> --tablas <TABLA> --todo` — mismas reglas que aplica `db_query`
- la columna en `pii.suspect` → salía en claro y son sus **valores** los que tienen forma de dato personal (ver la entrada siguiente)
- si la clasificación es errónea, la corrección es marcar `"safe": true` en esa columna del modelo BD (`references/json-schema.md` → "Política PII"); si el patrón de nombre sobra para todo el workspace, `pii_policy.patterns_remove`
- si la columna sí es dato personal y aun así se necesita el valor real, la vía no es el agente: consultarla con el cliente de BD, fuera de la conversación
- ⛔ nunca rodear el filtro (`sqlplus`/`sqlcmd` directo, volcado a fichero). Es lo que bloquean las guardas `PreToolUse`, y `docs/proteccion-pii-consultas-bd.md` §5.2b lo describe como guardarraíl, no como frontera de seguridad

---

## Una columna marcada "safe": true sigue saliendo enmascarada

Causas:

- red de seguridad por **forma de valor**: toda columna que iba a salir en claro —incluidas las marcadas `"safe": true`— se reescanea sobre sus valores reales, y si tienen forma de dato personal se enmascara igualmente. Es lo único que revierte una marca explícita, y solo en la dirección segura
- basta **un** valor que case para las formas fuertes: DNI (8 dígitos + letra), NIE, IBAN, correo
- hacen falta **al menos el 50%** de los valores no vacíos para las débiles, que son solo dígitos: teléfono (9 dígitos empezando por 6/7/8/9, `+34` opcional), tarjeta (13-19 dígitos), DNI sin letra (8 dígitos)
- los valores vacíos y los `NULL` no cuentan ni a favor ni en contra

---

Solución:

- primero, **comprobar el contenido real de la columna**: que salte aquí significa que contiene valores con forma de dato personal, y lo probable es que la marca `"safe"` esté mal puesta
- si tras comprobarlo es un falso positivo real (un identificador interno de 8 dígitos, una referencia con forma de IBAN): no devolver esa columna en bruto —proyectar solo lo necesario o agregarla— o asumir el enmascarado
- ⛔ **no existe una marca de "en claro pase lo que pase"**, y es deliberado: el modelo BD lo mantienen personas y una marca equivocada no debe poder abrir un agujero permanente
- la columna aparece en `pii.suspect` de la respuesta; en `audit` se reporta igual, pero los datos siguen saliendo en claro

---

## NullReferenceException

Causas:

- falta de validación

---

Solución:

- añadir null checks
- validar inputs

---

## Resultado incorrecto

Causas:

- lógica incorrecta
- validación incompleta

---

Solución:

- revisar analyzer
- validar flujo principal

---

## MSB4019 en build/test Online (WebForms) vía CLI dotnet

Causas:

- `dotnet build`/`dotnet test`/`mcp__plugin_rs-enterprise-agent_rs-workspace__compile_check`/`run_tests` (CLI `dotnet`) fallan con `MSB4019` (falta `Microsoft.WebApplication.targets`, que el SDK de `dotnet` no trae) en cuanto el build toque el proyecto WebForms — pasa incluso solo restaurando/compilando un proyecto de test con `ProjectReference` al `.csproj` web
- `compile-check.ps1` solo parsea diagnósticos `CS####`: un `MSB####` real puede quedar invisible (`error_count=0` con `exit_code=1`) — no fiarse de ese resultado
- No es fallo del código: es una limitación del SDK `dotnet` con proyectos .NET Framework WebForms

---

Solución:

- Para compilar de verdad: `msbuild.exe` real de Visual Studio (localizar con `vswhere.exe`, no asumir en PATH)
- Para ejecutar tests de verdad: `vstest.console.exe` directo sobre el `.dll` de test ya compilado, no `dotnet test`

---

# ⚠️ Reglas clave

- nunca ignorar errores del validator
- no forzar build con errores
- no confiar en datos sin validar
- no repetir consultas de confirmación (BD o tools) ya respondidas por el usuario o por una llamada previa