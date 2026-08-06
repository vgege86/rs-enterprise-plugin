# Configuración centralizada de los batch .NET Framework

Convención de compilación de los procesos batch (.NET 4.8 / 4.8.1) de un workspace uCollect/RS.
Sustituye al `app.config` por proyecto. Lo que aquí se describe gobierna **qué es fuente y qué es
artefacto**, y por tanto **qué puede viajar en una entrega** — ver `references/actualizador.md`.

Estado de un workspace concreto: `check_batch_config(workspace)` (tool MCP, solo lectura) o
`hooks/batch-centralizar.ps1 <workspace>`. Para adoptarla: `-Aplicar`.

---

## Los dos ficheros

Ambos viven en `Batch\`, la carpeta raíz de los proyectos batch:

| Fichero | Qué hace |
|---------|----------|
| `Batch\App.Batch.config` | Configuración **común**: `configSections` de ODP.NET, `system.data/DbProviderFactories`, `startup`. ⛔ **Sin bloque `<runtime>`** |
| `Batch\Directory.Build.targets` | Asigna `<AppConfig>` a ese fichero, activa `AutoGenerateBindingRedirects` y declara las dependencias de ODP.NET con `HintPath` y `<Private>true</Private>` |

MSBuild importa `Directory.Build.targets` automáticamente en todo proyecto que cuelgue de esa
carpeta: no hay que tocar ningún `.csproj` para que aplique.

---

## ⛔ Qué es fuente y qué es artefacto

Esta es la parte que cambia respecto al mecanismo anterior, y la que decide qué se empaqueta.

**`<Exe>.exe.config` ya NO existe como fuente.** Lo **genera MSBuild en cada build**, a partir de
`App.Batch.config` más los `bindingRedirect` que calcula `AutoGenerateBindingRedirects`. La única
copia válida es la de `bin\<Config>\`.

- ⛔ Nunca reconstruirlo a mano.
- ⛔ Nunca copiarlo desde el árbol de fuentes: ahí no hay ninguno, y el que se encuentre es un
  residuo del mecanismo viejo.
- ✅ En una entrega viaja **siempre** junto a su binario. Separarlos deja en el destino un config
  viejo con redirects que apuntan a versiones que ya no están → `FileLoadException` en bucle →
  `StackOverflow` al arrancar. Lo vigila el gate de binding redirects de `hooks/installer-batch.ps1`.

**`Batch\App.Batch.config` NO es desplegable.** Es fuente de compilación. No debe aparecer nunca en
un paquete de entrega — no lo lee nadie en ejecución.

**Los `<proyecto>.dll.config` ya no se generan** (`Comun.dll.config`, `BusComun.dll.config`, …). El
CLR no los lee para binding: eran ruido. Los que queden en las carpetas de despliegue son residuos
de builds anteriores. `installer-batch.ps1` los lista como aviso y, con `-LimpiarDllConfig`, los
barre.

---

## ⛔ Excepción por proyecto: los que conservan su `app.config`

`Directory.Build.targets` asigna `<AppConfig>` **solo si NO existe `app.config` en la carpeta del
proyecto**:

```xml
<AppConfig Condition="'$(AppConfig)' == '' And !Exists('$(MSBuildProjectDirectory)\app.config')">$(MSBuildThisFileDirectory)App.Batch.config</AppConfig>
```

Los procesos que **hospedan un AppDomain hijo** conservan el suyo — típicamente el motor
(`RSCore.exe`) y el host de incidencias (`RSActBD.exe`). Llevan tres cosas que MSBuild **no puede
autogenerar**:

- `<probing privatePath="…">` — rutas de sondeo de los módulos que carga el AppDomain hijo.
- `loadFromRemoteSources` — necesario para cargar ensamblados desde recurso de red.
- Los `bindingRedirect` propios de ese AppDomain hijo.

⛔ **No unificarlos.** Perderían esos tres bloques y dejarían de arrancar. `batch-centralizar.ps1`
los detecta por esos marcadores y los clasifica como `excepcion`: nunca los retira.

Un tercer caso, `revisar`: un `app.config` con secciones propias (`appSettings`,
`connectionStrings`, …) que se perderían al retirarlo. El hook tampoco los toca y los reporta para
decisión humana.

---

## ⛔ Por qué el `Directory.Build.targets` declara las dependencias de ODP.NET

`Comun.dll` **no referencia** `System.Text.Json` y compañía en su IL — quien las usa es
`Oracle.ManagedDataAccess.dll`. Al compilar un EXE, MSBuild sigue la cadena

```
Comun.dll → Oracle.ManagedDataAccess.dll → System.Text.Json <versión>
```

no encuentra esa versión en `packages` y **descarta la referencia sin ningún warning**. El `bin`
queda sin esas DLL, el proceso arranca con normalidad y muere en el **primer acceso a BD** con:

```
Se produjo una excepción en el inicializador de tipo de
'Oracle.ManagedDataAccess.Client.OracleCommand'
```

Fallo silencioso en build y explosivo en ejecución. Por eso se declaran explícitamente con
`HintPath` y `<Private>true</Private>`, y por eso `installer-batch.ps1` tiene un **gate de
dependencias ODP.NET** que exige su presencia física junto a `Oracle.ManagedDataAccess.dll` en cada
carpeta de despliegue:

`System.Text.Json` · `System.Diagnostics.DiagnosticSource` · `System.Text.Encodings.Web` ·
`System.Collections.Immutable` · `System.IO.Pipelines` · `System.Formats.Asn1` ·
`Microsoft.Bcl.AsyncInterfaces`

La lista del gate se puede ampliar por proyecto con `odpDependencies` en
`docs\<proyecto>-instalador.json`.

---

## Compilación

`hooks/batch-build.ps1` usa `dotnet build`. **Verificado**: aplica correctamente el
`Directory.Build.targets` y genera el `.exe.config` completo, con su bloque `<runtime>` y los
redirects al día. No hace falta cambiarlo.

`hooks/installer-batch.ps1` usa `msbuild /t:Rebuild` sobre los csproj-exe (no la `.sln`), por los
motivos de coherencia de build documentados en `hooks/README.md`. También aplica el
`Directory.Build.targets`.

---

## Adopción en un workspace

`hooks/batch-centralizar.ps1 <workspace> [-Aplicar]` — sin `-Aplicar` solo informa, no escribe nada.

Con `-Aplicar`:

1. Genera los dos ficheros desde `assets/batch/*.tpl`. La versión y el `PublicKeyToken` de ODP.NET
   y el `TargetFrameworkVersion` se leen del propio workspace, no se hardcodean.
2. Los `HintPath` del `.targets` se derivan de los `<Reference><HintPath>` que ya existen en los
   `.csproj`. ⛔ Si alguna dependencia requerida no se puede resolver, **no escribe nada** y
   devuelve `BLOCKED`: un `.targets` a medias no arregla el descarte silencioso de referencias.
3. Retira el `app.config` de los proyectos `centralizable` y su `<None Include="app.config"/>` del
   `.csproj`. Respeta los `excepcion` y los `revisar`.
4. Es idempotente: no pisa lo que ya exista.

Después hay que **recompilar** para que MSBuild regenere cada `bin\<Config>\<Exe>.exe.config`.

Quién lo propone, y cuándo:

- `/rs-instalador` y `/rs-actualizador` — PASO 0, antes de compilar nada: cambia qué lleva el paquete.
- Pipeline de desarrollo — la etapa `build` lo detecta en soluciones Batch y devuelve `BATCH_CONFIG`;
  el orquestador surface la propuesta y solo aplica tras confirmación explícita.

En los dos casos la centralización **la confirma una persona**: escribe en el workspace.
