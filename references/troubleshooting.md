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