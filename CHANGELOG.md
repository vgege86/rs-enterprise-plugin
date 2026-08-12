# RS Enterprise Agent — Changelog

## 3.23.0 — 2026-08-12

### La regla de "sin nombres de cliente" ya no depende de que alguien se acuerde

La 3.22.2 limpió tres identificadores reales de `references/jira.md`. Lo que no arregló es el
motivo por el que llegaron ahí: `docs/plugin-architecture.md` §10 prohíbe los nombres de cliente
desde hace versiones, pero una regla que solo vive en un documento se salta sin enterarse. Ahora hay
una guarda que la ejecuta.

`hooks/cliente-guard-write.ps1`, `PreToolUse` sobre `Write`/`Edit`, junto a la guarda de PII.

#### Solo dentro del repo del plugin

Sube desde la ruta destino buscando un `.claude-plugin/plugin.json` con
`"name": "rs-enterprise-agent"`. Fuera de ahí sale por 0 sin mirar nada.

⛔ Esto no es una excepción cómoda, es la condición para que la guarda sobreviva: en el workspace
del cliente los nombres propios son **legítimos y necesarios** —lo dice la propia regla del §10— y
una guarda que bloquease ahí sería un estorbo diario. Las guardas que estorban se acaban apagando, y
entonces no protegen nada.

#### Dos capas, y solo una bloquea

| Capa | Origen | Falsos positivos | Acción |
|---|---|---|---|
| 1 | lista declarada en `~/.claude/rs-clientes.json` | ninguno | **bloquea** (exit 2) |
| 2 | heurística estructural | algunos | **avisa** |

La capa 1 casa `nombres`, `dominios` y `esquemas`, insensible a mayúsculas, **en el contenido y en
la ruta** —un `informe-<cliente>.md` es tan fuga como el texto de dentro—. Los tokens de menos de 3
caracteres se ignoran: uno de dos letras casaría con medio repo y convertiría la guarda en un
bloqueo permanente.

La capa 2 mira formas, no nombres: rutas `X:\SVN|GIT\RS\<segmento>\` con un segmento que no sea del
propio autor, `https://<algo>.atlassian.net` con un site concreto, `User Id=` y `"schema"` con valor
real. Avisa por stdout y deja pasar. Bloquear aquí era la otra opción y se descartó por lo mismo que
`pii-guard-write.ps1` exige letra de control válida al DNI en vez de conformarse con la forma.

#### La lista no puede vivir aquí

`~/.claude/rs-clientes.json`, fuera de cualquier repo, mismo criterio que
`rs-jira-credentials.json`:

```json
{ "nombres": ["<cliente>"], "dominios": ["<dominio>"], "esquemas": ["RS<CLIENTE>"] }
```

Un fichero versionado con la lista de clientes **sería exactamente la fuga que la guarda persigue**.
Sin ese fichero la capa 1 queda inactiva y no se bloquea nada: es una decisión consciente, no un
fallo silencioso — hay que poblarlo una vez. Si el JSON está roto, avisa y deja pasar, pero lo dice;
callarse haría desaparecer la protección sin que nadie lo notara.

#### Independiente del modo PII

No cuelga de `Get-RsPiiEstadoGuarda`. PII protege datos personales según lo que declare cada
workspace; esto protege identidad de cliente en un único repo. Un `off` de PII no debe abrir este
agujero — y de hecho es la razón por la que el correo de `references/jira.md` pasó sin más: en este
repo la guarda de PII está inactiva.

#### Lo que el test destapó

La frontera de palabra incluía el guion (`[\w-]`), así que `informe-<cliente>.md` y
`<cliente>-config.json` se colaban — dos de las formas más habituales en que el nombre acaba en el
repo. Fuera de la clase, `<cliente>ter` sigue sin casar, que era lo que se quería evitar.

`tests/ClienteGuard.Tests.ps1`: **22 tests, todos en verde**, con nombres inventados (un test que
usara uno real sería la fuga que persigue). `tests/PiiGuard.Tests.ps1` (90) y
`tests/Encoding.Tests.ps1` (409) siguen pasando.

#### Lo que NO cubre

El matcher es `Write|Edit`: un `echo ... > fichero` por Bash no pasa por aquí. Se ha dejado fuera a
propósito —duplicar el hook para `Bash` multiplica los falsos positivos— y en este repo casi todo se
escribe con Write/Edit. Fue así como entró la fuga de 3.22.2.

## 3.22.2 — 2026-08-12

### La regla de "sin nombres propios" no se aplicaba a sí misma

`docs/plugin-architecture.md` §10 lleva tiempo diciendo que en este repo no van identificadores
reales. Y en `references/jira.md`, en los dos bloques JSON de ejemplo, iban tres: un dominio
Atlassian concreto y un email de usuario, repetido. Ese fichero **sí viaja** en el plugin instalado,
así que el ejemplo que ve cualquiera que abra la reference llevaba datos de una organización real.

Sustituidos por marcadores, sin cambiar la estructura de los JSON:

| antes | ahora |
|---|---|
| `https://<org>.atlassian.net` | `https://<tu-site>.atlassian.net` |
| email real (×2) | `desarrollador@empresa.com` |

También se han limpiado los informes de trabajo bajo `.superpowers/sdd/`, que arrastraban un nombre
de proyecto de cliente, su esquema Oracle, su usuario de conexión y una ruta de instalación (14
ocurrencias → `<PROYECTO>`, `<ESQUEMA>`, `<USUARIO_CONEXION>`, `<workspace>`). ⚠️ Esa carpeta está en
`.gitignore` desde siempre y **nunca se commiteó**: no llegó al repo remoto ni al plugin instalado.
Se corrige igual porque estaba en el árbol de trabajo.

⚠️ Lo que **no** se ha tocado: `vgege86` en las URLs del repo y en el ejemplo de `/rs-review`. Es la
cuenta propietaria del plugin, no un cliente — es la fuente canónica y tiene que poder citarse.

## 3.22.1 — 2026-08-12

### El plugin cargaba de golpe lo que solo hacía falta en la fase 4

Medición del arranque de `/rs-tarea` sobre 171 sesiones reales (`usage` del primer turno en los
transcripts): **67 659 tokens**. El comando no tenía la culpa —el mismo día, un prompt normal
`<Solucion>.sln - ...` costaba 68 572 y 68 847—, pero la traza sí enseñó dónde se iba lo que **sí**
es nuestro:

```
[19] IN=67 659   baseline (system prompt + tools + frontmatter de plugins)
[24] IN=68 119   (+  460)  config del gestor
[30] IN=76 332   (+8 213)  ← skills/rs-jira/SKILL.md entero
```

Ese `SKILL.md` traía dentro cosas que ya estaban escritas en `references/jira.md` —la precedencia de
campos al crear, la blocklist de la réplica, el procedimiento de descarga de adjuntos— y el aviso del
FP de CrowdStrike repetido en cuatro sitios. Todo eso se leía **siempre**, incluso en la ruta más
común, que es coger una issue existente y lanzar el pipeline sin crear nada ni descargar nada.

Ahora el `SKILL.md` se queda con el procedimiento y los gates, y el detalle vive en la reference, que
se lee **cuando la fase lo pide**:

| fichero | antes | ahora |
|---|---|---|
| `skills/rs-jira/SKILL.md` | 4 958 tok | **3 301 tok** |
| `skills/rs-mantis/SKILL.md` | 5 518 tok | **4 107 tok** |

⛔ No se ha tocado ni un gate: siguen ahí las confirmaciones antes de cada escritura, la prohibición
de analizar código en la Fase 2, el "preguntar siempre la `.sln`", el orden estricto de la Fase 4 de
Mantis (confirmar estado **antes** de adjuntar) y la regla de no llamar nunca a `ping` al arranque.

### Las etapas del pipeline se presentaban con un currículum

Las ocho `rs-editor-*` no las elige nunca el usuario: las despacha el orquestador por nombre. Aun
así, sus `description` explicaban en tres líneas por qué corren en el modelo que corren —información
que ya está en el campo `model:` de al lado— y esas tres líneas viajan en el system prompt de **todas**
las sesiones. Recortadas a una línea: qué etapa es y quién la invoca.

`rs-editor-db-modeler` conserva sus triggers completos porque sí tiene modo directo (`/rs-erd`).

### Cuánto se ahorra de verdad

- **Baseline de toda sesión** (frontmatter de agentes + skills): **−336 tok**.
- **Al lanzar `/rs-tarea`**: **−1 656 tok** en la ruta Jira, **−1 411 tok** en la ruta Mantis.

Es poco comparado con los 67 659 del arranque, y conviene decirlo: de esos, ~52k son núcleo de
Claude Code y schemas de tools built-in, y solo ~11,5k eran frontmatter de este plugin. Capar
integraciones MCP no ayuda —van *deferred*, cuestan el nombre (~13 tok) y no el schema: las 87 de una
sesión real suman 1 164 tok en total, de los cuales 870 son las 49 tools de este propio plugin.

## 3.22.0 — 2026-08-12

### El actualizador ya no solo detecta los objetos de BD que cambiaron: escribe su script

La 3.10.0 puso los objetos de BD en el modelo y con eso el actualizador **supo** qué había
cambiado. Pero el script seguía escribiéndolo alguien a mano, que es exactamente el paso donde se
olvidaba. Ahora lo genera:

```
.\hooks\actualizador-objetos.ps1 "<trunk>" "<destino>\scripts" [-DryRun]
```

Compara la BD contra el inventario `objetos` del `model.json` —la línea base es la última
entrega— y escribe `90-ObjetosBD.sql` con lo nuevo, lo modificado y lo que cambió de estado, en
orden de dependencias y con **el mismo texto que emitiría el instalador**. El prefijo cae en la
franja 90-98: después de los scripts de las tareas —un procedimiento nuevo puede leer una columna
que crea uno de ellos— y antes del `99-RVERSIONES`, que cierra la entrega.

`-DryRun` lista sin escribir, y `/rs-actualizador` lo usa así: presenta la lista, **pide
confirmación** y solo entonces genera. La línea base solo avanza cuando se pide
(`-Sincronizar`): un delta generado y luego descartado no puede dejar el modelo diciendo que eso
ya se entregó.

#### Dos cosas que NO decide solo, y no por prudencia decorativa

- ⛔ **Una secuencia modificada no viaja.** Su DDL es `CREATE` —y en SQL Server el bloque trae un
  `DROP` delante—, así que contra un cliente que ya la tiene o falla (ORA-00955) o la recrea en la
  posición de *nuestra* base de datos y empieza a repartir IDs ya usados. Una secuencia nueva sí
  viaja; una que cambió de `INCREMENT BY`/`CACHE`/`CYCLE` sale listada aparte para resolverla con
  un `ALTER` a mano.
- ⛔ **De lo eliminado no se emite ningún `DROP` activo.** Un objeto que falta puede ser un
  borrado real o una extracción incompleta, y desde aquí las dos cosas se parecen mucho; la
  diferencia es que equivocarse borra código en producción. Los `DROP` van **comentados** al final
  del fichero, para descomentar lo que uno sepa que se borró de verdad.

Y una sección cuya extracción falla queda **fuera** del delta, no vacía: vacía, el diff la habría
leído como "se ha eliminado todo".

Por lo mismo, con **hueco de cobertura** (la 3.18.0 lo mide: la cuenta ve menos objetos de los que
el diccionario dice que hay, porque el PL/SQL exige `GRANT EXECUTE` y con cero grants el
diccionario devuelve cero **sin error**) esto **no escribe nada**. Donde el sync del modelo avisa,
el delta para: su salida no es un modelo que alguien revisa después, es un `.sql` que alguien
ejecuta contra la BD de un cliente. `-SinCobertura` lo fuerza cuando se sabe que el hueco es
legítimo.

### La firma de las secuencias cambiaba sola

El DDL de una secuencia lleva su posición actual (`START WITH LAST_NUMBER` en Oracle,
`START WITH current_value` en SQL Server), y esa posición avanza **cada vez que alguien consume un
valor**. Firmando el texto tal cual, toda secuencia salía como "modificada" en cada
sincronización. Como ruido en el diff ya era malo; con el generador de scripts encima habría
significado proponer reentregar todas las secuencias en cada entrega — justo lo único que una
secuencia no admite. Se descuenta antes de firmar (`_dbobjetos.firma_objeto`), así que un cambio
real sí se detecta y el mero avance del contador no.

⚠️ Efecto de una vez al actualizar: la primera sincronización tras instalar la 3.22.0 marcará las
secuencias como modificadas, porque su firma se calcula distinto. A partir de ahí, estables.

### Y todo paquete salía como "firma distinta" en cada instalador

El contraste de deriva de `installer-objects.py` construía su inventario **por su cuenta**, y al
plegar los paquetes la especificación y el cuerpo se pisaban entre sí bajo la misma clave —son dos
entradas de `ALL_SOURCE` y una sola ficha en el modelo—, así que su firma nunca coincidía con la
del sync. Una alarma que salta siempre es una alarma que nadie lee. El constructor pasa a vivir en
`_dbobjetos.construir` y lo usan los dos: si el contraste construyera el inventario a su manera,
compararía dos cosas que no se construyen igual.

### Leer el cuerpo de un objeto sin abrir un cliente de BD

El modelo guarda la ficha y la firma, **nunca el cuerpo** —el instalador tiene que seguir
extrayendo de la BD viva o un modelo desactualizado entregaría código viejo—, y eso dejaba al
desarrollo con el inventario pero sin el código:

```
.\hooks\ddl-objeto.ps1 "<trunk>" P_ALTA_CLIENTE
```

Lo lee de la BD viva, con los mismos extractores y el mismo maquetado que el instalador (así que
es literalmente lo que viajaría al cliente), dice si la firma de la BD ya **no** coincide con la
del modelo —alguien lo tocó tras el último sync— y **no lo guarda en ninguna parte**.

Va también como tool MCP `get_object_ddl`, y ahí está lo que de verdad cambia el día a día:
`/rs-impacto` ya sabía, desde la 3.10.0, qué procedimientos nombran una tabla; ahora puede
**leerlos** antes de afirmar nada sobre ellos. `tablas_usadas` se deriva por coincidencia de
texto, así que descartar un falso positivo exigía justamente lo que no había.

En el ERD, el panel de cada objeto muestra ese comando con botón de copiar. No lo ejecuta: el ERD
es un HTML estático y no tiene —ni debe tener— credenciales ni conexión a la BD.

### Un solo maquetador de objetos

`installer-objects.render_objeto` pasa a ser el único sitio donde se decide cómo se escribe un
objeto en un `.sql`, y lo usan los seis extractores de cada motor, el generador del delta y el
lector de DDL. Si cada uno lo maquetara por su cuenta, un script del actualizador podría quedarse
sin el `/` que cierra un bloque PL/SQL — y eso falla en el cliente, no aquí.

Ficheros: `scripts/delta-objects.py` y `scripts/object-ddl.py` (nuevos),
`hooks/actualizador-objetos.ps1` y `hooks/ddl-objeto.ps1` (nuevos), `scripts/_dbobjetos.py`,
`scripts/installer-objects.py`, `scripts/model-objects.py`, `scripts/erd-template.html`,
`mcp/rs-workspace-server.py`, `agents/rs-actualizador.md`, `agents/rs-impacto.md`,
`agents/rs-validacion-bd.md`, `tests/test_delta_objetos.py` (nuevo, 31 casos), `tests/test_mcp.py`,
`README.md`, `docs/plugin-architecture.md`, `references/hooks.md`, `references/mcp.md`,
`references/actualizador.md`, `hooks/README.md`.

## 3.21.0 — 2026-08-11

### El validador compilaba con .NET Core la mitad de las soluciones, que son .NET Framework

`compile_check` llamaba **siempre** a `dotnet build`, y `run_tests` **siempre** a `dotnet test`. En un
workspace mixto —web y procesos batch en .NET Framework, servicio y sus módulos en .NET moderno— eso
falla en cuanto el build toca un proyecto WebForms o con COM: el SDK de `dotnet` no trae
`Microsoft.WebApplication.targets` y devuelve `MSB4019` sobre código que compila sin una queja en
Visual Studio.

Encima el resultado salía **mudo**. El parser de diagnósticos solo reconocía `CS####`, así que el
`MSB4019` real no aparecía en ningún sitio: el JSON decía `error_count: 0` con `exit_code: 1`. El
efecto operativo era una advertencia crónica —"plan-check OK · validator OK, pero su compile_check
falló por entorno, la compilación no está verificada"— y un humano compilando a mano con el MSBuild
de Visual Studio antes de poder seguir. La solución ya vivía en el repo (`service-build.ps1`,
`actualizador-build.ps1` localizan msbuild con vswhere desde hace versiones); lo que faltaba era que
llegara al camino que usa el pipeline en cada iteración.

#### El compilador se decide leyendo los `.csproj`, no una lista de nombres

Librería nueva `hooks/lib-msbuild.ps1`. `Get-RsBuildToolchain` recorre los proyectos de la `.sln` y
exige MSBuild de Visual Studio si alguno es legacy (no SDK-style), declara un TFM `net4x`/`v4.x`, es
web (import de `Microsoft.WebApplication.targets` o su ProjectTypeGuid) o lleva `COMReference`; si
todos son SDK-style con TFM moderno, CLI `dotnet`.

⛔ Deliberadamente **no hay nombres de solución, de proyecto ni de ruta** en la regla. El plugin es
genérico: no sabe cómo se llaman los procesos de cada cliente y una lista blanca queda obsoleta con
el primer proyecto nuevo. La distinción de TFM se apoya en la nomenclatura oficial —`net5+` siempre
lleva versión menor (`net8.0`), .NET Framework nunca (`net48`)—, así que "sin punto = Framework".

Ante la duda, MSBuild: compila también los proyectos SDK-style, mientras que el CLI `dotnet` no
compila .NET Framework. Sobre-detectar cuesta unos segundos de arranque; infra-detectar devuelve un
falso "no compila" sobre código correcto. Por eso una solución mixta se resuelve entera con MSBuild.

#### "No verificado" y "no compila" dejan de confundirse

Si el compilador que hace falta no está instalado, el hook **falla cerrado**: `builder_error` (o
`runner_error` en los tests) con el mensaje de qué instalar, en vez de caer al otro compilador en
silencio. `rs-editor-validator` y `rs-editor-fixer` llevan la instrucción explícita de no tratarlo
como error de compilación ni intentar corregir nada — no hay nada que corregir.

#### `MSB####`, `NU####` y demás dejan de ser invisibles

El parser de `compile-check.ps1` acepta ahora cualquier código `[A-Za-z]+\d+`, con o sin posición
`(línea,columna)` —los fallos de infraestructura del build salen sin ella—. El caso que originó todo
esto (`error_count: 0` con `exit_code: 1`) ya no se puede dar callando.

#### `vswhere -latest` elegía SSMS en vez de Visual Studio

Cazado al probar contra la máquina real. `-products *` —necesario para que valga una instalación de
solo Build Tools— mete en el saco a todo lo que se instala sobre el shell de Visual Studio, y `-latest`
se queda con **una** instancia: la de versión más alta. En una máquina con SQL Server Management
Studio 22 y Visual Studio 2022, `-latest` devolvía SSMS, que no trae `vstest.console.exe`, y el hook
concluía "no está instalado" con Visual Studio delante. Los dos buscadores usan `-sort` (todas las
instancias, de más nueva a más antigua) y se quedan con la primera que **tiene** el fichero. El
buscador de MSBuild se libraba de casualidad, por el `-requires Microsoft.Component.MSBuild`.

#### Tests también

`test-runner-check.ps1` usa el mismo veredicto: `dotnet test` donde procede, y MSBuild +
`vstest.console.exe` sobre el `.dll` compilado en las soluciones .NET Framework, donde `dotnet test`
no llegaba a ejecutar ni una prueba. Se mantienen intactas las reglas de la 3.15.0/3.16.0: sin
resumen legible o con 0 pruebas, `success: false` — ausencia de evidencia nunca es verde.

**Gate**: `tests/MsBuild.Tests.ps1` (26 casos) ejercita el detector con `.csproj` de prueba en un
temp, sin Visual Studio y sin workspace de cliente, para que corra en CI. Incluye la invariante del
fallo cerrado: si hace falta MSBuild y no está, el resultado trae `error`, no un fallback silencioso.

**Ficheros**: `hooks/lib-msbuild.ps1` (nuevo), `hooks/compile-check.ps1`, `hooks/test-runner-check.ps1`,
`tests/MsBuild.Tests.ps1` (nuevo), `mcp/rs-workspace-server.py`, `agents/rs-editor-validator.md`,
`agents/rs-editor-fixer.md`, `agents/rs-editor-build.md`, `references/hooks.md`, `references/mcp.md`,
`references/troubleshooting.md`, `hooks/README.md`, `docs/plugin-architecture.md` §7.1.

### Los agentes no sabían que los datos enmascarados sí se pueden cruzar

El pseudónimo de la política PII es `HMAC(clave, NOMBRE_COLUMNA + valor)`: determinista, así que el
mismo valor devuelve el mismo `pii:xxxxxxxx` en cualquier consulta y en cualquier tabla donde la
columna se llame igual. Es una propiedad de diseño —está en el docstring de `scripts/pii_mask.py`
desde que existe— pero las references que leen los agentes solo decían "no reproduzcas el
pseudónimo". Resultado: se trataba el resultset enmascarado como inservible y se dejaban de hacer
cruces perfectamente legítimos (unir las filas de una misma persona entre tablas, contar distintos,
detectar duplicados, verificar integridad referencial) que no requieren ver ningún dato personal.

Documentado en `references/bd.md` (sección nueva "Los pseudónimos SÍ se pueden cruzar entre
tablas"), en la tabla del bloque `pii` de `references/mcp.md` y en `docs/proteccion-pii-consultas-bd.md`
§4.1, con los cuatro límites que hacen falta para no sacar conclusiones falsas:

- **El dominio es el nombre de la columna de salida, no la tabla.** `A.DNI` ↔ `B.DNI` cruzan;
  `A.DNI` ↔ `B.NIF` no, salvo que se alineen con un alias. Y dos columnas homónimas con
  significados distintos comparten dominio: un pseudónimo repetido dice "mismo texto", no "misma
  entidad".
- El cruce es por coincidencia **exacta** del valor normalizado (solo se colapsan espacios): que
  dos no cuadren no prueba que sean personas distintas.
- Con `transform: "suppress"` no hay correlación posible.
- La clave es local al perfil del usuario: un `pii:xxxxxxxx` **no** es comparable entre máquinas y
  no vale como identificador en un ticket, un commit ni un informe.

**Ficheros**: `references/bd.md`, `references/mcp.md`, `docs/proteccion-pii-consultas-bd.md`.

---

## 3.20.0 — 2026-08-11

### Un log con 2.544 errores se reportaba como "1 error, de infraestructura"

`parse_web_log` (hook `hooks/parse-weblog.ps1`, base de `/rs-log-errores`) no reconocía el formato
propio de la AgendaWeb uCollect/RS. Sobre un log real de 55.494 líneas devolvía `total_events: 1`,
`distinct_signatures: 1` y `format_detected: "stacktrace-plano"` — **con `success: true`**. Nada en
la respuesta delataba el fallo, así que el triaje leía ese "1 error" como incidencia aislada de
infraestructura y no se abría ninguna tarea. Es el mismo patrón silencioso que la 3.15.0 con el
parser de `dotnet test`: salida sintácticamente correcta, JSON sano, recuento inventado.

El formato abre cada evento con una cabecera propia y sigue con el stack:

```
Error: (11/08/2026 13:45) - Codigo error: -2147467259 Codigo error sql: 0 Descripción error: ORA-12899: ...
   en Comun.cConexion.EjecutarQuery(String sQuery)
```

Fallaba por dos motivos encadenados. `$rxStamp` exigía `[` y `HH:mm:ss`, y aquí la fecha va entre
**paréntesis** y **sin segundos**: ninguna línea abría evento por timestamp, así que la rama
NLog/log4net nunca entraba y ningún evento tenía ventana temporal. Al caer al volcado plano, el gate
era `$rxExcepcion`, que pide al menos un carácter antes de `Error`
(`[A-Za-z_][\w.]*(?:Exception|Error)`) y **no casa el literal `Error:` a secas**: el único evento
que se abrió en todo el log fue el de la única línea que contenía un token tipo
`InternalServerError`.

#### Formato `rs-cerrores` reconocido

Cabecera propia detectada antes que `$rxStamp`, con la etiqueta variable (`Error`, `cErrores`,
`Fail`…) de la que se **deriva el nivel**, para que `-Niveles` siga filtrando. La hora se acepta con
**una o dos cifras** y con los segundos opcionales: en el log de referencia el 20% de los eventos
llevan hora de un dígito (`(20/02/2026 8:41)`), y exigir `HH` no solo los pierde — los pega como
continuación del evento anterior, falseando también la firma de ese otro evento. Mientras un evento
de este formato está abierto solo lo cierra otra cabecera suya: dentro del SQL del mensaje hay
fechas que sí casarían `$rxStamp`.

El stamp se normaliza a `yyyy-MM-dd HH:mm:ss`. `first_seen`/`last_seen` se calculan comparando
cadenas, y `dd/MM/yyyy` como texto ordena por el día.

#### La firma va por CÓDIGO, no por token `*Exception`

En este formato la excepción útil es el código. Se toma, por este orden: el `ORA-xxxxx` del texto →
el `Codigo error: <n>` de la cabecera (descartando el `0`, que no discrimina) → la excepción .NET.
Sin esto todas las firmas colapsan en `SinExcepcion` y el dedup queda inservible. Un mismo
`ORA-12899` sobre dos columnas distintas sigue siendo dos firmas.

#### El frame propio ya no se ancla a inicio de línea

`$rxFrame` buscaba `^\s*(?:at|en)\s+…`. En este formato el frame **más profundo** viene pegado al
final del texto del mensaje (`… ) )     en Comun.cConexionOracle.EjecutarQuery(…)`), y el que abre
línea es el de la capa de arriba: anclando a `^` se atribuía el fallo a la capa equivocada. Ahora se
busca también embebido, en todos los formatos.

#### Campo nuevo `pantalla`

Cada firma trae la página `.aspx.cs` (o el control `.ascx.cs`) más cercana a la cima del stack —
`FrmDetalleClie`, `FrmLogin`…—, que es lo que permite triar sin abrir el código: dos errores
idénticos en dos pantallas distintas son dos tareas distintas. Es el **único** cambio del contrato
de salida; el resto de campos no se toca.

#### PII: el dato viaja dentro del SQL

El mensaje trae la query entera y los datos personales van **dentro de los literales entre comillas
simples**, donde ninguna detección por forma llega (un nombre o un número de lote no tienen forma
reconocible). `Remove-RsPii` seguía cubriendo correo, IBAN y DNI/NIE fuera de comillas; ahora
`message` y `samples` pasan además por una redacción de literales (`'…'` → `'<val>'`).
⛔ Solo en la **salida**, nunca en la clave de firma: el hash es el marcador `[log:<hash>]` con el
que `/rs-log-errores` deduplica contra los tickets ya abiertos, y cambiarlo los recrearía todos.

#### Dos correcciones que salieron por el camino

- **Codificación**: `[IO.File]::ReadLines` sin argumento asume UTF-8 y los logs de una web .NET en
  Windows salen en la codepage ANSI. Cada acento se convertía en `U+FFFD`, lo que no solo afea el
  texto que acaba en el ticket: `Descripción error:` dejaba de casar y el mensaje salía con la
  cabecera pegada delante. Ahora se detecta la codificación (BOM, y si no, UTF-8 estricto sobre los
  primeros 64 KB).
- **Eventos descartados**: al filtrar una cabecera por nivel o por `-Desde`, sus líneas de stack
  quedaban sueltas y una que contuviera `…Exception` abría un evento nuevo por el camino del volcado
  plano — el recuento devolvía justo lo que se acababa de filtrar. Ahora se descarta el evento
  entero.

#### Cobertura

`tests/WebLogParser.Tests.ps1` (24 aserciones) sobre `tests/fixtures/weblog-rs.log`, un fixture de
12 eventos recortados y anonimizados: recuento, firmas distintas, hora de una cifra, segundos,
código como excepción, frame embebido, `pantalla`, ventana ordenable, redacción de PII, filtros
`-Niveles`/`-Desde`, lectura de un log ANSI y no regresión de NLog/log4net, volcado plano y log sin
errores. `hooks/parse-weblog.ps1` estaba además **sin BOM** desde su alta, incumpliendo la
convención de §7 del doc de arquitectura; se ha corregido.

Contra el log de referencia (55.494 líneas): de `1` evento y `1` firma a **2.544 eventos y 271
firmas**, con la ventana poblada (`2026-02-20` → `2026-08-11`).

## 3.19.0 — 2026-08-11

### Los scripts de idiomas inventaban los idiomas y tiraban los IDTEXTO al final del montón

Tres cosas mal en la misma zona —la de mayor historial de bugs del plugin—, y las tres afectaban
igual al gate del pipeline (`rs-editor-tester`) y al modo directo (`/rs-idiomas`), porque las reglas
están **duplicadas a propósito**: un subagente no puede invocar a otro, así que cada uno lleva su
copia. Se han corregido las dos a la vez.

#### Los idiomas salen del catálogo 32, no de una constante

Los dos agentes decían *"idiomas activos (por defecto `ESP`, `POR` — confirmar si el proyecto tiene
otros)"*. Un valor por defecto que hay que confirmar cada vez no es un valor por defecto: es una
suposición esperando a colarse en un script. Y el dato está en la BD desde siempre.

Ahora se resuelve con `SELECT TBCODE, TBTEXT FROM RTABL WHERE TBNUME = 32 ORDER BY TBCODE` —
`TBCODE` es el id de idioma, `TBTEXT` su descripción—, y se emite una fila `RIDIOMA` por cada
`TBCODE` devuelto. `TBCODE` se usa **tal cual** como `RIDIOMA.IDIDIOMA`, sin traducirlo ni
normalizarlo, contrastando tipo y casing contra filas existentes antes de emitir (la misma cautela
que ya existía para `ICFORM`). Sin filas → se para y se reporta; no se inventan idiomas. Los
placeholders pasan de `[TEXTO_ESP]`/`[TEXTO_POR]` fijos a `[TEXTO_<TBCODE>]`.

#### IDTEXTO por rangos, según el tipo de texto

No existía la noción de rango: **todo** se asignaba desde 3000, daba igual que fuera un error, un
mensaje o un label.

| Tipo | Cómo se reconoce | Rango |
|---|---|---|
| Errores | `Idm.Texto(coerr.eXXXX, ...)` | 1000–1999 |
| Mensajes en pantalla | `Idm.Texto(coMens.mXXXX, ...)` | 2000–2999 |
| Textos de pantalla | `LabelText`/`Text`/`GroupingText`/`Titulo`, headers de grid, `ErrorMessage` de validadores | ≥ 3000, sin techo |

El rango lo decide el **tipo de texto**, nunca el IDTEXTO que tenga otro texto cercano.

De rebote se tapa un hueco de cobertura: el gate solo miraba `Idm.Texto(coerr.eXXXX, ...)`, así que
un `coMens.mXXXX` nuevo o editado —texto igual de visible— no disparaba nada. Ahora dispara igual.

#### Rellenar huecos de verdad

La query de asignación era
`SELECT MIN(r1.IDTEXTO + 1) ... WHERE r1.IDTEXTO >= 3000 AND NOT EXISTS (... = r1.IDTEXTO + 1)`,
y fallaba en dos sitios:

- **No devolvía el suelo del rango.** Con un solo 3005 en RIDIOMA devolvía 3007, dejando 3000–3004
  libres para siempre. Ese es el relleno de huecos que se había perdido.
- **No tenía techo**, así que no podía saber cuándo un rango se agotaba.

La regla nueva son tres pasos, portables entre SQL Server y Oracle (sin generadores de filas):

1. `SELECT COUNT(*) FROM RIDIOMA WHERE IDTEXTO = <MIN>` → si es 0, el id es el suelo del rango.
2. Si no, la misma query de huecos pero **acotada**: `... WHERE r1.IDTEXTO >= <MIN> AND r1.IDTEXTO < <MAX> AND NOT EXISTS (...)`.
3. `NULL` o `> <MAX>` → **rango agotado** → primer hueco a partir de 3000 (la única región sin
   techo), **declarándolo** en la cabecera del `.sql` y en el `SUMMARY` de la etapa. Fuera de su
   rango el id ya no identifica el tipo por su número, y eso no puede pasar en silencio.

Para los ids sucesivos de una misma tanda se repite el proceso: se siguen rellenando huecos, no se
incrementa a ciegas desde el primero — el número siguiente puede estar ocupado.

El ⛔ de siempre se amplía: los huecos se buscan contra `RIDIOMA`, nunca en `coerr.cs` **ni en
`coMens.cs`** (hay IDTEXTO sin constante).

#### Ficheros

- `agents/rs-editor-tester.md` — gate scripts-idiomas: `coMens` entre los disparadores, query del
  catálogo 32, tabla de rangos, asignación por huecos acotada al rango, cabecera del `.sql` con
  idiomas y rangos reales, y el aviso de rango agotado en el contrato `SUMMARY`.
- `agents/rs-idiomas-standalone.md` — misma actualización (pasos 4/4b/7, reglas de generación y
  ejemplo de output). Copia deliberada, no compartida.
- `references/arquitectura.md` — § "Convenciones web Online": el catálogo 32 y la tabla de rangos
  pasan a ser convención canónica. Antes solo decía que `coerr`/`coMens` mapean 1:1 a
  `RIDIOMA.IDTEXTO`, sin decir a qué números.
- `README.md` — sección 8 (nota de idiomas y rangos) y regla clave de idiomas.

## 3.18.0 — 2026-08-11

### El log de errores de la web sabía qué estaba roto y nadie lo leía

Un log de producción es la mejor lista de tareas que hay: dice qué falla, dónde y cuántas veces. El
problema es su forma. El mismo `NullReferenceException` sale 400 veces, entre miles de líneas de
`INFO`, y revisarlo a mano cuesta lo suficiente como para no hacerlo. Convertirlo en tareas era
trabajo manual, así que no se hacía, y los errores seguían ahí.

#### `/rs-log-errores` — del log a las tareas

Comando nuevo (`skills/rs-log-errores/SKILL.md`, orquestador de main thread como `rs-jira`/
`rs-mantis` — crea tickets y lanza el pipeline, y ninguna de las dos cosas la puede hacer un
subagente). Fases:

| Fase | Qué hace |
|---|---|
| F0 | Fuente del log (ruta del argumento; ⛔ nunca se adivina) |
| F1 | Parseo + deduplicación → tabla de firmas con recuento y ventana temporal |
| F2 | Triaje: código / dato / configuración / infra / **ruido**, y propuesta de una tarea por firma accionable — ⛔ **gate**: nada existe en el gestor hasta que el usuario aprueba la lista |
| F3 | Alta en el gestor del proyecto (Jira o Mantis, detectado igual que `/rs-tarea`), aplicando `defaults` y etiquetas |
| F4 | Propone lanzar el pipeline **de una en una** — ⛔ nunca en lote, nunca sin que lo pida |

**La deduplicación no la hace el modelo.** La hace el hook nuevo `hooks/parse-weblog.ps1` (tool
`parse_web_log`, la nº 49), que agrupa las ocurrencias por **firma**: `SHA1(tipo de excepción +
frame más profundo de código propio + mensaje normalizado)`. El mensaje se normaliza antes de
hashear —números, GUIDs, fechas, rutas y hex pasan a marcadores—, así que "Cliente 4711 no existe" y
"Cliente 8322 no existe" son la misma firma y no dos tareas. Reconoce NLog/log4net, ELMAH XML y
volcados planos de stack .NET.

Dos consecuencias de que el recuento lo haga el hook y no el modelo: es determinista, y **el log no
entra en contexto**. La tool devuelve solo el agregado acotado (top-N firmas con muestras), nunca las
líneas. Un log de cientos de MB se resume sin leerlo. Además, mensajes y muestras pasan por
`Remove-RsPii` antes de salir: un log de una web lleva datos reales de usuario y esos textos acaban
copiados literalmente en un ticket.

**Reabrir la misma tarea en cada pasada** era el otro riesgo obvio. El resumen de cada tarea lleva el
marcador `[log:<firma>]`, y F3 lo busca entre las issues abiertas antes de crear nada: si ya existe,
no duplica — ofrece añadir una nota con las nuevas ocurrencias y la nueva ventana.

F3 y F4 **delegan** en `rs-jira`/`rs-mantis` (Fase 1b/1 para el alta, Fase 2 en adelante para el
desarrollo). Esta skill no reimplementa ni Jira ni Mantis, y no toca el pipeline.

#### Valores por defecto y etiquetas del proyecto en el config del gestor

Hasta ahora, al crear una issue, los campos "de siempre" del proyecto se adivinaban **copiándolos de
la última tarea creada**. Funciona hasta que la última tarea es una excepción, y entonces propaga el
error a la siguiente. Ese dato es declarable, no deducible.

`docs\.jira-dev-config.json` acepta un bloque `defaults` que se vuelca en `additional_fields` de
`createJiraIssue`: `issueTypeName`, `priority`, `components`, **`labels`** (las etiquetas), `versions`,
`duedate`, cualquier `customfield_*`. `docs\.mantis-dev-config.json` acepta su espejo con lo que
expone la REST de Mantis: `category`, `priority`, `severity` y **`tags`**.

Precedencia, en este orden: **usuario → `defaults` → réplica de la última tarea**. La réplica no
desaparece, baja a fallback para los campos que nadie declaró, y se apaga con
`defaults.replicarUltimaTarea: false`. Las etiquetas son la excepción a "el primero gana": se
**acumulan** (las de `defaults` + las del usuario + las que aporte quien llame al alta — así
`/rs-log-errores` puede añadir `log-<firma>` sin pisar nada).

Todo aditivo: un config sin `defaults` se comporta exactamente como en 3.17.0, y `defaultCategory`
de Mantis sigue funcionando (solo cede ante `defaults.category`).

#### Ficheros

- `hooks/parse-weblog.ps1` — **nuevo**. Parser + deduplicador por firma, con redacción PII vía
  `lib-pii.ps1`. Tope de líneas (`-MaxLines`) y de firmas (`-MaxSignatures`), ambos reportados en la
  salida: un recuento truncado se declara truncado.
- `mcp/rs-workspace-server.py` — tool `parse_web_log` (48 → **49 tools**).
- `skills/rs-log-errores/SKILL.md`, `commands/rs-log-errores.md` — **nuevos**.
- `hooks/mantis-cli.ps1` — `create` acepta `-Priority`, `-Severity`, `-Tags`. Aditivos: sin ellos, el
  body del `POST /issues` es el de antes.
- `skills/rs-jira/SKILL.md` — `defaults` en el config; Fase 1b gana un paso de precedencia explícita
  y la confirmación indica de dónde sale cada valor.
- `skills/rs-mantis/SKILL.md` — `defaults` en el config, precedencia en la Fase 1 rama b, nuevos
  flags de `create`, `init` propone `defaults`.
- `references/jira.md`, `references/mantis.md` — esquema de config con `defaults` y tabla de
  precedencia.
- `references/mcp.md`, `references/hooks.md`, `hooks/README.md` — alta de la tool y del hook.
- `README.md` — sección 14 del catálogo ("Errores de producción → tareas"), nota de `defaults` en la
  sección de tareas, nº de comandos (49 → 50) y de tools.
- `docs/plugin-architecture.md` — §1 árbol de skills, §6 y §8 el nº de tools.

## 3.17.0 — 2026-08-11

### `/rs-tarea` preguntaba siempre a Jira, aunque el proyecto se gestionara en Mantis

El plugin ya tenía las dos mitades: `rs-jira` (F1–F4, MCP Atlassian Rovo) y `rs-mantis` (F0–F4,
cliente REST `hooks/mantis-cli.ps1`). Lo que no tenía era el conmutador. `/rs-tarea` estaba cableado
a Jira, así que en un workspace gestionado con Mantis el comando natural —"trabaja la tarea"— llevaba
al gestor equivocado, y había que acordarse de teclear `/rs-mantis`. Acordarse no es un mecanismo:
el dato de qué gestor usa el proyecto ya está en disco.

#### `/rs-tarea` pasa a ser un router

Detecta qué config existe en `docs\` del workspace y despacha a la skill que toque:

| Estado del workspace | Destino |
|---|---|
| solo `.jira-dev-config.json` | `rs-jira` |
| solo `.mantis-dev-config.json` | `rs-mantis` |
| los dos | desambigua por la forma del argumento (`PROJ-123` → Jira, `1234` → Mantis); si no basta, **pregunta** |
| ninguno | pregunta el gestor y ofrece crear su config (`/rs-tarea init`) |

Los argumentos se reenvían tal cual, y el gestor detectado se anuncia en una línea **antes** de tocar
ningún ticket — el enrutado se corrige antes de la primera escritura outward-facing, no después.
`/rs-mantis` sigue siendo la puerta explícita de Mantis, y la invocación en lenguaje natural de cada
skill no cambia. En un workspace solo-Jira el comportamiento es idéntico al de 3.16.0.

La regla de detección vive **en el comando**, no en las skills: ninguna de las dos necesita saber que
la otra existe. Fundirlas en una sola skill se descartó — son dos integraciones distintas (MCP con
OAuth interactivo frente a REST por token; transiciones por endpoint frente a la cadena `advance`),
y unirlas habría duplicado el riesgo sin ganar nada.

#### Ficheros

- `commands/rs-tarea.md` — reescrito como router (detección, desambiguación, anuncio del destino).
- `commands/rs-mantis.md` — se declara puerta explícita.
- `skills/rs-jira/SKILL.md`, `skills/rs-mantis/SKILL.md` — `description`: el trigger `/rs-tarea` pasa
  a ser condicional al config presente.
- `docs/plugin-architecture.md` — §1: faltaba `rs-mantis` en el árbol de skills. §5.1: las formas de
  comando pasan de dos a tres, con las reglas de la forma **router** (detección en el comando,
  ambigüedad se pregunta, anuncio previo, puerta explícita conservada).
- `README.md` — sección 12 pasa a "Tareas (Jira / Mantis)" con la tabla de detección.

## 3.16.0 — 2026-08-10

### El verificador de tests hablaba inglés y la máquina hablaba español, así que nadie contó nada

Síntoma reportado: `run_tests` devolvía `passed=0, failed=0, success=true` y `raw_summary` vacío en
**cualquier** solución del entorno. No en una: en todas.

#### Por qué salía verde

`hooks/test-runner-check.ps1` ejecutaba `dotnet test` y leía el resultado del **texto de consola**,
con tres expresiones en inglés:

```powershell
if ($line -match 'Passed:\s*(\d+)')  { $passed = [int]$Matches[1] }
if ($line -match 'Failed:\s*(\d+)')  { $failed = [int]$Matches[1] }
if ($line -match 'Skipped:\s*(\d+)') { $skipped = [int]$Matches[1] }
```

Con el CLI localizado, la salida real es `Pruebas totales: 84` / `Correcto: 84`. Ninguna expresión
encontraba número, los contadores se quedaban en su valor inicial —cero— y el veredicto se calculaba
aparte, `success = ($exitCode -eq 0)`. El filtro de `raw_summary` buscaba esas mismas palabras
inglesas, así que también salía vacío: ni cifras, ni evidencia con la que sospechar.

El fallo no es el número mal. Es que **un fallo de lectura se presentaba como un éxito de
ejecución**. Toda etapa que se fiara de la tool —el `tester` del pipeline, `/rs-test`,
`/rs-validar-req`— concluía "los tests pasan" sin que se hubiera contado una sola prueba. Y como el
JSON salía bien formado y coherente consigo mismo, ninguna revisión posterior tenía de qué tirar.

Lo cazó el tester porque se negó a leer 0/0/0 como verde.

#### Dos arreglos, no uno

**Que el conteo no dependa del idioma.** El resultado pasa a leerse del **`.trx`** (`--logger trx`
sobre una carpeta temporal por ejecución): es XML y los conteos son atributos, no frases, así que no
hay traducción que los rompa. El texto de consola queda como último recurso —el `.trx` no llega a
escribirse si el build revienta antes— y para ese camino se fuerza además
`DOTNET_CLI_UI_LANGUAGE=en` + `VSLANG=1033` y se reconocen los rótulos en ambos idiomas. La lógica
vive en el hook nuevo `hooks/lib-trx.ps1` (`Get-TrxSummary`, `Get-DotnetConsoleSummary`,
`Get-RsLineasResumen`).

**Que un cero no pueda volver a leerse como verde.** Es la mitad importante: forzar el idioma
arregla *este* fallo, pero cualquier formato futuro que el parser no entienda reproduciría el mismo
falso verde. Ahora los parsers devuelven `$null` cuando no pueden contar —nunca cero— y el hook lo
traduce a estado explícito:

| Situación | Salida |
|---|---|
| Ni `.trx` ni resumen en consola | `success=false`, `parse_failed=true`, `error`, `raw_summary` con la cola de la salida |
| Proyecto de test presente y 0 pruebas ejecutadas | `success=false`, `no_tests_ran=true`, `error` |
| Cifras de consola que no cuadran con el total | `counts_inconsistent=true` + `warning` |

Además `success` ya exige `failed = 0`, no solo `exitCode = 0`. Se añaden `total` y `source`
(`trx`/`console`/`none`) para que el agente sepa de dónde salen las cifras que está leyendo.

#### Dos fallos más que aparecieron al probarlo de verdad

Con una solución de prueba real (2 pasan, 1 falla, 1 saltado) salieron a la luz:

- ⛔ **El hook moría sin emitir JSON en cuanto un test fallaba.** Con `$ErrorActionPreference =
  "Stop"`, el stderr de un comando **nativo** es un error terminante: el runner escribía `[FAIL]` y
  el script reventaba ahí. Es decir, el único caso que de verdad importa —hay tests rojos— era
  justamente el que no se podía reportar. El veredicto se juzga por `$LASTEXITCODE` y el `.trx`, así
  que la preferencia baja a `Continue` solo durante esa llamada (también en `compile-check.ps1`,
  donde el mismo patrón estaba latente).
- **Los saltados se perdían.** VSTest escribe el resultado con `outcome="NotExecuted"` y aun así
  deja `notExecuted="0"` en los contadores. Se toman como `max(notExecuted+inconclusive,
  total-executed)`.

#### El mismo bug, latente, en el compilador

`hooks/compile-check.ps1` parseaba `(error|warning)\s+(CS\w+)`. En español el compilador emite
`advertencia CS0168`: **todos los warnings desaparecían del JSON** sin que nada fallara. Los errores
colaban por casualidad, porque "error" se escribe igual en los dos idiomas. Ahora fija las mismas
variables de entorno y acepta `advertencia`/`aviso` normalizando a `warning`, por si un SDK antiguo
ignora el env var. Verificado: sobre un `CS0168` real pasa de 0 warnings a 2.

#### Gate ejecutable

`tests/TrxParser.Tests.ps1` (18 tests, sin dependencia de `dotnet`) fija el contrato: un resumen en
español devuelve 84 y no 0, una salida sin resumen devuelve `$null` y no cero, el `.trx` manda sobre
el texto, y el hook conserva el idioma forzado, el logger `trx` y los dos caminos de no-falso-verde.
Una convención que solo vive en un comentario no la comprueba nadie.

**Ficheros**: `hooks/lib-trx.ps1` (nuevo), `hooks/test-runner-check.ps1`, `hooks/compile-check.ps1`,
`tests/TrxParser.Tests.ps1` (nuevo), `mcp/rs-workspace-server.py` (contrato de `run_tests`),
`agents/rs-editor-tester.md` (condición 0: sin evidencia → FAIL), `agents/rs-test.md`,
`references/hooks.md`, `references/mcp.md`, `docs/plugin-architecture.md`, `README.md`,
`docs/crowdstrike-fp-justification.md` (la fila de `Invoke-Expression` ya no describía el código).

## 3.15.0 — 2026-08-10

### Una red de seguridad que salta siempre no es una red de seguridad, es una etapa mal declarada

Síntoma reportado: la nota `⚠️ Nota: plan-check no venía en STAGES → lo ejecuto igualmente (red de
seguridad). Va en paralelo con validator.` aparecía en **todas** las ejecuciones del pipeline.

#### Por qué salía siempre

`plan-check` entró como etapa en 2.18.0 y se cableó en el orquestador (`SKILL.md`), pero **nunca se
añadió al vocabulario de `STAGES` del planner**. La tabla "Etapas disponibles" de
`agents/rs-editor-planner.md` listaba `core`, `validator`, `tester`, `build`, `db-modeler` y
`documentar` — y nada más. Con dos reglas del propio agente encima ("incluir solo las necesarias",
"no asumir etapas sin justificación"), un token que no está en la tabla no se emite jamás.

Resultado: durante diecisiete versiones menores el planner fue **incapaz** de declarar `plan-check`,
la red de seguridad del orquestador se disparó en el 100% de las ejecuciones, y `SKILL.md` afirmaba
—falsamente— que "el planner coloca `plan-check` justo después" de `core`. El contrato documentado
y el implementado describían cosas distintas.

El daño no era solo el ruido. Un aviso que aparece siempre deja de leerse: si un día el planner
hubiera omitido la etapa por un motivo real, nadie lo habría notado entre el resto de notas.

#### La corrección no es "que lo emita siempre"

`plan-check` cuesta tokens (lee `FILES_CHANGED` y busca evidencia de cada ítem del PLAN) y en un
cambio de un literal no aporta: verificar la cobertura de un plan de un solo ítem es trabajo que
`validator` y el gate final ya cubren. Así que la etapa pasa a ser **condicional**, con criterios
contables en `agents/rs-editor-planner.md` § "Criterios para incluir `plan-check`":

- **≥3 ítems accionables** en el plan
- toca **≥2 proyectos/capas**
- lleva cambio de esquema BD o SQL nuevo (`db-modeler` en `STAGES`)
- es una **fase** de un desarrollo por fases
- introduce funcionalidad nueva (`documentar` en `STAGES`)

Umbrales contables a propósito: un criterio cualitativo ("si el cambio es grande") lo resuelve el
planner incluyendo la etapa siempre por prudencia, y entonces no se ahorra nada.

#### La red de seguridad cambia de señal

Con la etapa condicional, la red anterior (`core` corrió → `plan-check`) habría seguido disparando
en todos los cambios simples, que es justo el ruido que se quería quitar. Nueva señal:

> `plan-check` no estaba en `STAGES` **y** `core` devuelve `FILES_CHANGED` de ≥3 ficheros o ≥2
> proyectos → ejecutarlo igualmente y anotarlo.

Ahora sí encaja con la forma canónica de las tres redes de seguridad —un dato empírico que el
planner no podía conocer al planificar—, porque el tamaño real del cambio solo se sabe al
escribirlo. Y la nota pasa a decir algo útil: `⚠️ El cambio salió mayor de lo planificado (N
ficheros, M proyecto(s)) → ejecuto plan-check aunque no venía en STAGES`, es decir, el planner
subestimó. Por debajo del umbral no se ejecuta.

#### Riesgo asumido

En un cambio clasificado como simple, un `core` que implemente medio plan ya no se detecta por
cobertura; queda en manos de `validator` (compila + revisión lógica) y del Gate B. Aceptable para
un plan de un único ítem localizado — por eso el umbral está en 3 ítems y no más arriba.

Ficheros: `agents/rs-editor-planner.md` (fila `plan-check` en la tabla de vocabulario + sección de
criterios + ejemplos de `STAGES típico` + ejemplo de output) ·
`skills/rs-enterprise-agent/SKILL.md` (paso 2, control de flujo y tabla § Redes de seguridad) ·
`README.md` · `docs/plugin-architecture.md`.

## 3.14.0 — 2026-08-07

### Buscar en el árbol tenía tres implementaciones, y dos bugs que solo estaban en una

Continuación de 3.13.0 con los cuatro puntos que quedaban del análisis de rendimiento. Al medir el
camino de búsqueda aparecieron dos defectos silenciosos que llevaban ahí desde el principio.

#### 1. Un solo motor de búsqueda: `hooks/lib-buscar.ps1`

`find-symbol.ps1`, `search-code.ps1` y `security-scan.ps1` recorrían el árbol cada uno por su
cuenta con `Get-ChildItem` + `Get-Content` + `-match`: un objeto por línea y una recompilación del
regex por comparación. Medido sobre 3200 ficheros `.cs` de 65 líneas, buscando un símbolo:

| | ms |
|---|---|
| `Get-ChildItem` + `Get-Content` + `-match` | 6650 |
| `EnumerateFiles` + `ReadAllLines` + regex compilado | 2836 |
| `EnumerateFiles` + `ReadAllText` + `Matches` | 2969 |
| **`Select-String` multi-patrón** | **1480** |

Suelo: 121 ms enumerar + 468 ms leer los 3200 ficheros. Gana `Select-String` porque el bucle de
líneas y el motor de regex viven dentro del cmdlet, en C#.

⛔ **No se usa ripgrep**, aunque el análisis inicial lo daba por hecho con una medida de 0,22 s.
Esa medida era inalcanzable: `rg` está disponible dentro de la herramienta Bash del agente, pero
como **función del shell**, no como `rg.exe` en el PATH. Los hooks PowerShell —que es como Claude
Code ejecuta esto— no lo alcanzan; se comprobó recorriendo el PATH y buscando el binario en el
árbol. Un camino "usa rg si está" habría sido código muerto que ninguna prueba cubre.

End-to-end sobre 3200 ficheros: **7785 ms → 2291 ms (3,4×)**.

#### 2. `batch_find_symbols` no batcheaba nada

Era un bucle que lanzaba un proceso PowerShell **por símbolo**, y cada uno recorría el scope
entero de nuevo. `find-symbol.ps1` acepta ahora `-Symbols "A,B,C"` y resuelve los N en una pasada;
la tool baja al hook una sola vez. El truncado `max_per_symbol` se queda en Python, que es donde
se sabe cuánto contexto cabe.

Con 10 símbolos sobre 3200 ficheros: **74 471 ms → 13 657 ms (5,5×)**.

#### 3. Dos bugs que el recorrido viejo escondía

Los dos estaban solo en `find-symbol.ps1` y ninguno daba error: devolvían un resultado plausible.

**Una sola coincidencia se contaba como cuatro.** `Sort-Object -Unique` con un único elemento
devuelve el objeto, no un array de uno, y `.Count` sobre un hashtable cuenta sus **claves**
(`file`, `line`, `content`, `match`). Así que `find_symbol` respondía `found: 4` y `matches` como
objeto en vez de lista, y `batch_find_symbols` propagaba `count: 4`. Justo el caso más común en
análisis de impacto: el símbolo que aparece una vez.

**Un fichero de una sola línea no casaba nunca.** `Get-Content` sobre un fichero de una línea
devuelve `String`, no `String[]`; el bucle indexaba `$lines[0]` y obtenía el primer **carácter**.
Cualquier `.cs` de una línea se escaneaba letra a letra y se declaraba sin coincidencias.

Los dos quedan fijados en `tests/Search.Tests.ps1`.

#### 4. `security-scan.ps1` leía cada fichero una vez por regla

Hasta 8 lecturas del mismo `.cs` para descartar casi todas. Ahora el árbol se enumera una vez y
cada regla trabaja sobre el subconjunto de extensiones que le toca. ⚠️ Sigue haciendo **una
búsqueda por patrón**, no una sola con todos: una línea que dispara dos reglas son dos hallazgos
con `id` distinto, y el motor por defecto se queda con el primer patrón que casa. Hay un test que
se pone en rojo si alguien lo "optimiza" a una sola llamada.

Verificado con prueba diferencial contra la implementación anterior: salida **idéntica**.

⚠️ **Cambio de comportamiento deliberado en `search_code`:** ahora excluye `bin\` y `obj\`. Antes
no excluía nada —los otros dos hooks sí— y los `.cs` generados en `obj\` gastaban parte del
presupuesto de 50 resultados con duplicados del código real.

#### 5. El pipeline estaba escrito dos veces, y las copias ya divergían

`commands/rs-enterprise-agent.md` repetía las etapas, los handoffs y el control de flujo de
`SKILL.md`. Se escribió en 2.14.0 y no se volvió a tocar salvo para arreglar su frontmatter,
mientras que la etapa `plan-check` entró en 2.18.0: durante diez versiones menores los dos
documentos describían pipelines distintos **en el mismo contexto**, y el comando omitía
precisamente la etapa que verifica que el código cubre el PLAN aprobado.

El comando pasa a ser un wrapper fino que apunta a `SKILL.md`. Una definición, un dueño.

En el mismo sitio, `SKILL.md` se contradecía: la red de seguridad de `db-modeler` se describía como
"única corrección empírica permitida sobre `STAGES`" mientras el propio fichero define otras dos
(`plan-check` y `documentar`). Ahora hay una sección **§ Redes de seguridad** que enumera las tres
con su señal y su motivo, y dice explícitamente que añadir cualquier otra etapa no es una red de
seguridad, es re-planificar.

#### 6. Etapas que pueden solaparse

Nueva sección **§ Etapas que pueden solaparse** en `SKILL.md`. El orden de `STAGES` es secuencial
porque encadena el contrato, no por ceremonia: `db-modeler` ∥ `documentar` no se leen entre sí, y
`plan-check` ∥ `validator` son independientes (uno mira cobertura del PLAN, el otro compila). Se
lanzan en el mismo turno con varias llamadas Task. `build` no solapa con nada, y tras un ciclo de
`fixer` se vuelve a serializar.

## 3.13.0 — 2026-08-07

### El plugin cobraba peaje en sitios donde no hacía trabajo

Cinco derroches medidos con cronómetro sobre esta máquina, ninguno de ellos visible desde el
código: los cinco son caminos que se recorren *antes* de decidir si hay algo que hacer. Ninguno
cambia lo que el plugin decide — solo lo que cuesta llegar a la decisión.

#### 1. `Get-Command` sobre un nombre inexistente: 1,7 s en cada Bash y cada Write

`hooks/lib-pii.ps1` comprobaba con `Get-Command Get-RsModelPath -ErrorAction SilentlyContinue`
si quien le dot-sourcea traía ya la resolución del modelo. Con un nombre que **todavía no
existe** —el caso normal— Windows PowerShell 5.1 no se limita a mirar su tabla de comandos:
recorre `PSModulePath` entero analizando módulos por si alguno lo exporta.

Lo caro no es el fichero, es esa línea. Medido, tres ejecuciones cada uno:

| | ms |
|---|---|
| `powershell -NoProfile exit 0` (suelo) | 228 |
| dot-source de `lib-dbmodel.ps1` | 260 |
| `Get-Command <inexistente> -EA SilentlyContinue` | **1763** |
| `Test-Path Function:\<inexistente>` | 291 |

Y se pagaba en **cada llamada a Bash, Write y Edit**, porque las dos guardas `PreToolUse`
dot-sourcean `lib-pii.ps1` antes de mirar siquiera si el workspace tiene la protección activa —
también fuera de un workspace uCollect/RS, donde la guarda no llega a hacer nada.

Ahora la comprobación va por el proveedor `Function:`, que resuelve por la cadena de scopes
igual que la invocación. Las guardas completas, extremo a extremo:

| guarda | antes | ahora |
|---|---|---|
| `pii-guard-bash.ps1` | 2021 ms | **477 ms** |
| `pii-guard-write.ps1` | 1932 ms | **487 ms** |

En una sesión de 150 operaciones de fichero son unos **4 minutos** que antes se iban en un
escaneo de módulos. `tests/PiiGuard.Tests.ps1` sigue en verde sin tocar (450 aserciones).

#### 2. El runner del `Stop` hook parseaba el transcript entero en cada turno

`runner/runner.ps1` corre al final de **cada** turno, y solo tres agentes (`rs-editor-build`,
`rs-instalador`, `rs-actualizador`) llegan a emitir el contrato `TYPE:`/`COMMAND:` que busca.
Para quedarse con el último mensaje leía el transcript completo —una línea JSON por mensaje,
creciendo toda la sesión— y hacía `ConvertFrom-Json` de cada una.

Ahora lee la cola (`-Tail 400`) y la recorre hacia atrás, cortando en el primer `assistant`;
si en esas líneas no hubiera ninguno, **cae a la lectura completa de antes**, así que el camino
rápido no puede perder nada. Se devuelve el texto del último `assistant` aunque venga vacío, sin
seguir buscando hacia atrás: un texto anterior puede llevar un `COMMAND:` ya ejecutado en un
turno previo, y reejecutarlo sería lanzar un build a espaldas del usuario.

| transcript | antes | ahora |
|---|---|---|
| 1 500 líneas (0,7 MB) | 588 ms | 488 ms |
| 15 000 líneas (7,9 MB) | 1709 ms | **478 ms** |

Verificado con una prueba diferencial contra la versión anterior sobre cuatro transcripts
(normal, `assistant` fuera de la cola → fallback, contrato `TYPE:`/`COMMAND:`, y uno largo):
salida **idéntica byte a byte** en los cuatro.

#### 3. Diez comandos de solo lectura dejan de cargar la skill entera

`skills/rs-enterprise-agent/SKILL.md` son ~7k tokens. Un `/rs-stats` los cargaba para acabar
despachando a un subagente Haiku que lee un JSON. Esos comandos ya llevaban inline lo único que
necesitan (`workspace` = cwd, y la regla de `plugin_root` glosada en la propia frase); la skill
no aportaba nada.

Dejan de invocarla: `rs-stats`, `rs-dashboard`, `rs-help`, `rs-deps`, `rs-env`, `rs-schema`,
`rs-word`, `rs-comparar-modelo`, `rs-comparar-entornos`, `rs-historial`. Cada uno declara ahora
`⛔ Self-contained — do NOT invoke the skill` y trae la regla de `plugin_root` escrita entera en
vez de citada.

**Fuera del lote a propósito**, porque el contexto de la skill sale más barato que un fallo:
los que escriben o tienen gate (`rs-init`, `rs-pii`, `rs-cifrar`, `rs-erd`, `rs-sync-indexes`),
los que resuelven una `.sln` (~25 comandos: la resolución de solución vive en la skill y sacarla
a un dueño compartido es un cambio de diseño aparte), y los que enrutan a otra skill.

`hooks/skill-trigger.ps1` deja de disparar por `^/rs-` y se queda solo con la `.sln` explícita.
Ese disparo era redundante —cuando hay comando, Claude Code ya carga `commands/rs-<x>.md`, que
dice a qué subagente despachar— y desde este cambio además **contradecía** al comando: inyectaba
"OBLIGATORIO invocar la skill" justo encima de un fichero que declara lo contrario. Los comandos
que sí necesitan la skill la piden en su propio texto.

#### 4. Las 48 tools MCP respondían con JSON indentado

La salida de una tool no la lee una persona, la lee el modelo: la indentación son tokens que no
dicen nada. Medido sobre un resultado típico de `find_symbol` (40 coincidencias con ruta
absoluta): **7901 caracteres con `indent=2` contra 6213 compactos, un 21% menos**, en cada
respuesta de cada etapa del pipeline.

Las 53 llamadas `json.dumps(..., indent=2)` del server pasan a `separators=(",", ":")` vía la
constante `_JSON_SEP`. ⛔ No aplica a lo que se escribe en disco: el `model.json` lo sigue
formateando `scripts/_modeljson.py` (§7.1 de `docs/plugin-architecture.md`) y la caché de
`_load_model` ya iba sin indentar. `tests/test_mcp.py` en verde (61) y la suite Python completa
también (311).

#### 5. `agents/rs-instalador.md` no tenía frontmatter válido

Era el único `.md` con BOM UTF-8 de los ~100 de `agents/`, `commands/`, `skills/` y
`references/`. Los tres bytes antes del `---` impedían parsear el frontmatter, así que el agente
perdía su `description` (peor selección) y su allowlist `tools:` — y se exponía con **todas** las
tools en vez de con las 7 que declara.

⚠️ Esto **no** contradice la convención de `hooks/README.md` § Convención de codificación: el
BOM es obligatorio en los `.ps1` (sin él, 5.1 no parsea el fichero) y solo en ellos.
`tests/Encoding.Tests.ps1` filtra `*.ps1, *.psm1`, así que ni antes cubría este caso ni ahora
entra en conflicto.

## 3.12.0 — 2026-08-07

### "No lo veo" no es "no existe", y el modelo se escribe de una sola forma

Cinco defectos del modelado de BD detectados en una sesión real sobre una instalación de cliente
(Oracle 19c, cuenta de solo-consulta que **no** es dueña del esquema). Comparten raíz: el plugin
concluía la ausencia de lo que no podía ver, y escribía el `model.json` en dos formatos que
destrozaban el diff del control de versiones.

#### 1. Un único escritor canónico del `model.json`

Había **cinco** puntos de escritura y todos lo rompían, de dos maneras distintas:

- Los scripts Python (`model-objects.py`, `analyze-dalc.py`) serializaban con
  `ensure_ascii=False` y sin BOM. Medido: BOM ausente y 12 bytes no-ASCII.
- Los hooks PowerShell (`sync-from-db.ps1`, `sync-indexes.ps1`, `sync-model-tables.ps1`) usaban
  `ConvertTo-Json`. El de PS 5.1 no indenta con dos espacios por nivel: **alinea cada valor a la
  columna de la clave padre**. El fichero pasaba de 1,1 MB a 3,5 MB (x3,2) y cambiaba el sangrado
  de todas las líneas, así que el diff quedaba inservible **aunque el BOM y los CRLF fueran
  correctos**. Es el peor de los dos porque el JSON es válido y el contenido idéntico: solo se ve
  al abrir el diff, cuando ya está subido.

Ahora hay uno solo. **`scripts/_modeljson.py`** impone el formato canónico del repositorio
—`indent=2`, `separators=(',', ': ')`, `ensure_ascii=True`, CRLF y UTF-8 **con** BOM—, escribe de
forma atómica y **verifica lo escrito antes de sustituir el modelo bueno**: BOM presente, cero LF
sueltos, cero bytes no-ASCII, reparseo correcto y comparación con el objeto que se quería
escribir. Si algo no cuadra, el modelo anterior no se toca y la escritura falla.

**`hooks/lib-modeljson.ps1`** (`Save-RsModelJson`) **no serializa**: transporta la estructura con
`ConvertTo-Json -Compress` —donde el bug de indentación ni llega a manifestarse— y delega en el
escritor de Python. Reimplementar el formato en PowerShell habría dejado dos escritores otra vez,
que es el camino que ya recorrió el mapeo de tipos antes de `scripts/_dbtypes.py`. Verificado:
un modelo escrito por Python, leído y reescrito por PowerShell, sale **byte a byte idéntico**.

⛔ `pk` sigue siendo **ordinal** (1, 2, 3…) y todo-o-nada, según manda
`scripts/_dbmodel.py::pk_columns`. No se ha tocado.

#### 2. Ceguera por permisos tratada como ausencia — el fallo más caro

Una cuenta que no es dueña del esquema ve por GRANT per-object, y **Oracle no permite distinguir
"no existe" de "no lo veo"**: ORA-00942 es deliberadamente ambiguo y `ALL_TABLES`, `ALL_OBJECTS` y
`ALL_SOURCE` están todas filtradas por privilegio. Lo medido:

- `sync_from_db` daba 323 tablas; tras conceder los GRANT que faltaban, 329. Seis tablas reales
  figuraban como inexistentes y estuvieron a punto de borrarse del modelo.
- Peor: `sync-indexes.ps1` recorría **todas** las tablas del modelo y les reescribía `indexes` con
  lo que hubiera en la lectura — que para una tabla sin GRANT está vacío. Esas seis tablas se
  quedaron con **0 índices**: el modelo salía de la sincronización peor de como entró, en silencio.
- El PL/SQL exige GRANT **EXECUTE**, no SELECT. Con 0 grants EXECUTE, `ALL_OBJECTS` y `ALL_SOURCE`
  devuelven cero procedimientos y cero paquetes **sin error**. Tras conceder 13, aparecieron 12
  procedimientos y 1 paquete.

La regla nueva es que **si no se puede distinguir, no se concluye**:

- Una tabla que no sale en la lectura **se conserva entera** —columnas, relaciones e índices— y se
  marca `visible: false` + `visible_check` con la fecha. La marca desaparece sola cuando vuelve a
  verse. `sync-indexes.ps1` solo toca las tablas que la lectura ve.
- **`hooks/lib-dbvisibilidad.ps1`** + **`hooks/db-visibilidad.ps1`** diagnostican lo que sí es
  distinguible: si la cuenta es dueña, qué GRANTs tiene por privilegio y cuántos objetos de cada
  tipo ve el diccionario. `0 EXECUTE` explica un 0 de procedimientos sin ninguna ambigüedad.
- **Bloque de cobertura automático** (`_cobertura` en el modelo y en el log): conteo real por tipo
  frente a lo capturado, con las exclusiones deliberadas declaradas aparte para que no cuenten
  como hueco. Sustituye a escribirlo a mano.
- **exit 2 = parcial** cuando queda hueco. `_run_ps` lo propaga como `parcial: true` en el JSON;
  no es un fallo, es "el modelo está incompleto" — que no es lo mismo que "esos objetos no están".

El hook existe además de la librería para que los scripts Python usen **la misma**
implementación por subproceso (cacheada en `RS_DB_VISIBILIDAD_JSON`), en vez de reescribir las
consultas por su cuenta.

#### 3. El instalador entregaba sin PL/SQL, en silencio

`scripts/installer-objects.py` lee de `ALL_SOURCE`. Con la cuenta sin EXECUTE, `/rs-instalador` y
`/rs-actualizador` generaban el paquete con los ficheros de procedimientos **vacíos** y lo daban
por bueno: el cliente recibía una instalación limpia sin nada de lógica de servidor y el fallo
aparecía en producción.

Ahora es **error duro** (exit 1), comprobado **antes** de extraer para no gastar seis sesiones de
BD en un paquete que no se va a poder entregar. El mensaje da las tres salidas en orden: conceder
los GRANT, repetir con `--conexion <dueño>`, o confirmar con `--sin-plsql` que el esquema de
verdad no tiene PL/SQL. `hooks/installer-scripts.ps1` lo propaga y lo nombra en el resumen.

Además, un tipo de objeto vacío ya no se reporta como "no se encontró ninguno" cuando la cuenta no
es dueña, sino como "ninguno **visible para esta cuenta**".

#### 4. Se puede elegir la conexión: `-Conexion <id>`

`read_db_config` y `_read_password` usaban siempre `conexiones[0]`. Leer como dueño —única forma
de ver los sinónimos **privados**, que ningún GRANT expone: 1 visible de 7— obligaba a **editar a
mano el fichero de credenciales**, que es estrictamente peor: es persistente, es invisible en
todas las salidas, y arrastra consigo la política PII (el `model_path` se resuelve por conexión).

`-Conexion <id>` / `--conexion <id>` / `conexion=` llega a `sync-from-db`, `sync-indexes`,
`sync-model-tables`, `sync-model-objects`, `compare-model`, `get-config`, `installer-scripts`,
`installer-objects.py`, `installer-inserts.py`, `model-objects.py` y a las tools MCP
`sync_from_db`, `sync_indexes`, `sync_model_tables`, `compare_model` y `compare_model_tables`
—mismo contrato que ya tenía `db_query`—, con tres guardarraíles en `Select-RsConexion`
(`hooks/lib-dbconfig.ps1`), que es el único sitio que resuelve el id:

1. Sin `-Conexion`, **siempre** `conexiones[0]`. No se infiere, no se prueba otra si la primera
   falla, no se "elige la mejor". Esa elección la hizo una persona al escribir el fichero.
2. Un id que no existe **corta** con la lista de válidas. ⛔ Nunca cae a `conexiones[0]`:
   seleccionar en silencio una conexión distinta de la pedida es como se acaba leyendo —o
   escribiendo— contra el entorno equivocado.
3. La conexión usada **se publica** en la salida de todo hook y script que la acepte. Sin eso, una
   lectura hecha con una cuenta privilegiada es indistinguible de una hecha con la de consulta.

#### 5. El conteo de secuencias ahora se explica solo

17 secuencias reportadas frente a 18 en `ALL_OBJECTS`, sin forma de saber por qué. Tres causas
posibles y ninguna descartable sin la BD delante, así que se han cerrado las tres y el script pasa
a **nombrar la razón** en vez de dejar el descuadre:

- **Concatenación con NULL**: un solo atributo nulo (`MIN_VALUE`, `MAX_VALUE`, `LAST_NUMBER`,
  `CACHE_SIZE`…) anulaba la cadena `||` entera, la fila salía NULL, el marcador nunca se emitía y
  la secuencia desaparecía del paquete sin error y sin rastro. Todo va ahora envuelto en `NVL`.
- **Recycle bin**: `ALL_OBJECTS` cuenta los `BIN$…`; ahora se excluyen explícitamente.
- **Columnas IDENTITY**: el filtro `ISEQ$$` sale de la `WHERE` y pasa a Python, así que el número
  de bloques leídos es el del diccionario y la diferencia es atribuible.

Las exclusiones se **declaran** (`excluido` en el contrato de los extractores) en vez de
descartarse en silencio: si no, una exclusión legítima se cuenta como pérdida y el aviso de
cobertura se vuelve permanente — y un aviso permanente es un aviso que nadie vuelve a mirar.

#### Al actualizar

La primera sincronización reescribe el `model.json` entero al formato canónico. Es un commit
grande, **una sola vez**; a partir de ahí el diff vuelve a ser línea a línea. Conviene aislarlo en
su propio commit.

#### Tests

Los tres fallos de formato y los dos de cobertura son **silenciosos** —el JSON sigue siendo
válido, el conteo sigue saliendo—, así que la única defensa es probarlos:

- **`tests/test_modeljson.py`** (18 casos): el formato exacto (BOM, CRLF, `ensure_ascii`, dos
  espacios, sin espacios finales), la **idempotencia** —reescribir no cambia ni un byte, y el
  orden de las claves se respeta—, que la verificación rechaza de verdad cada uno de los cuatro
  síntomas, y que un fallo de escritura **deja intacto el modelo anterior**.
- **`tests/test_dbobjetos.py`** (+10 casos): la cobertura con las cifras reales medidas —329 vs
  323 tablas, 18 vs 17 secuencias con 1 excluida, 12 procedimientos invisibles con `EXECUTE 0`—,
  que una exclusión declarada no cuenta como hueco, y que siendo dueño el descuadre **no** se
  atribuye a permisos (mandar a alguien a pedir GRANTs que ya tiene es peor que callar).

Verificado además a mano el camino PowerShell→Python: un modelo escrito por `_modeljson.py`,
leído y reescrito con `Save-RsModelJson`, sale **byte a byte idéntico**. Suite completa en verde
(311 Python, 609 Pester).

#### Ficheros

- **Nuevos**: `scripts/_modeljson.py`, `hooks/lib-modeljson.ps1`, `hooks/lib-dbvisibilidad.ps1`,
  `hooks/db-visibilidad.ps1`, `tests/test_modeljson.py`.
- **Modificados**: `hooks/lib-dbconfig.ps1` (`Select-RsConexion`), `hooks/sync-from-db.ps1`,
  `hooks/sync-indexes.ps1`, `hooks/sync-model-tables.ps1`, `hooks/sync-model-objects.ps1`,
  `hooks/compare-model.ps1`, `hooks/get-config.ps1`, `hooks/installer-scripts.ps1`,
  `hooks/db-query.ps1` (tenía su propia copia de la resolución de conexión; pasa a usar
  `Select-RsConexion` como el resto),
  `scripts/_dbobjetos.py` (`cobertura`, `formato_cobertura`), `scripts/model-objects.py`,
  `scripts/analyze-dalc.py`, `scripts/installer-objects.py`, `scripts/installer-inserts.py`,
  `mcp/rs-workspace-server.py`, `tests/test_dbobjetos.py`, `references/{hooks,mcp,json-schema,bd}.md`,
  `docs/plugin-architecture.md`, `README.md`, `agents/rs-editor-db-modeler.md`,
  `agents/rs-instalador.md`, `agents/rs-actualizador.md`.

## 3.11.1 — 2026-08-07

### La política PII es de `db_query`, y en ningún sitio estaba escrito

Pregunta razonable que no tenía respuesta en la documentación: con `mode=enforce`, ¿se están
enmascarando los nombres de tablas, columnas y vistas al actualizar el modelo o al mirar la
estructura de la BD?

**No.** `db_query` es la única tool que pasa por `mask_resultset`. Las que mantienen el modelo y
leen estructura —`sync_from_db`, `sync_indexes`, `compare_model`, `analyze_dalc`,
`generate_sql`, `generate_migration`, `export_dmd`, `render_erd`— van a su hook con conexión
directa y no importan `pii_*`; `get_table_schema`, `search_model` y `get_model_index` leen el
`model.json` y ni tocan la BD. Los metadatos salen siempre en claro. (`sync-from-db.ps1`
menciona `pii`, pero solo para **conservar** las marcas `pii`/`safe` del modelo al
re-sincronizar.)

#### La parte contraintuitiva sí es real

Si el catálogo del sistema se interroga **con `db_query`** en vez de con las tools de modelo,
los nombres **sí** vuelven enmascarados: `ALL_TAB_COLUMNS`, `INFORMATION_SCHEMA.COLUMNS` o
`USER_OBJECTS` no están en el modelo, así que `clasificar()` da `NO_RESUELTA/sin_definicion` y
`resolver_no_resuelta()` ve texto en vez de números → `MASCARA/valores_no_numericos`. Los
patrones ni llegan a intervenir: la lista base es española (`NOMBRE*`, `TELEFON*`…) y
`TABLE_NAME`/`COLUMN_NAME` no casan — el fallback por forma de valor los tapa igual.

Es la regla general aplicada a un caso donde sobra. Se documenta y **no** se abre una excepción
de catálogo: cada excepción es un camino más por el que un `SELECT` puede salir sin filtrar, y
el rodeo es barato —para leer estructura ya están las tools de modelo—. Si aun así hace falta
cruzar estructura por SQL, la salida es preguntar por números: nombres dentro del `SELECT`,
recuentos o códigos de vuelta, que salen en claro por `valores_numericos`. Con dos bordes que
muerden: un entero de **9+ dígitos sin decimales** se enmascara (tiene forma de identificador,
`pii_policy.py:187`) y una columna que salga **entera vacía**, también.

#### Dónde queda escrito

- `docs/proteccion-pii-consultas-bd.md` — **§4.5 nueva**, "Qué camino pasa por el filtro": qué
  lo atraviesa, qué no y por qué (los metadatos no son datos de personas), la consecuencia
  contraintuitiva y el rodeo numérico. Más una precisión en §5.1, que decía "consultas
  realizadas a través de la herramienta" sin acotar que es *solo* ese camino.
- `references/bd.md` — la versión operativa para los agentes, con los nombres de tool concretos
  y la cadena de clasificación que produce el enmascarado.

#### Y una viñeta del README que llevaba desde la 3.4.0 diciendo lo contrario

El resumen de «Qué NO protege» seguía afirmando que las guardas *«viven en la configuración
personal de cada desarrollador y no viajan con el repositorio»*. Eso dejó de ser cierto en la
3.4.0 —desde entonces las declara el propio plugin— y el §5.2e del documento ya lo recogía como
resuelto; la viñeta del README se quedó atrás. Corregida: conserva la historia (por qué era
grave: rutas absolutas que cada actualización dejaba colgando, guardas que fallaban abiertas y
sin señal) y describe la dependencia que sí queda —sin plugin no hay guardas, y tras instalar o
actualizar hay que reiniciar—.

Sin cambios de código: la política se comporta como está diseñada.

Ficheros: `docs/proteccion-pii-consultas-bd.md`, `references/bd.md`, `README.md`.

## 3.11.0 — 2026-08-07

### El marketplace deja de publicar un solo plugin: entra `rs-validador`

Hasta ahora `marketplace.json` declaraba un único plugin con `source: "./"` — el repo *era* el
plugin. A partir de esta versión el marketplace publica **dos**, y el repo gana una carpeta
`plugins/` para los que no son la raíz.

El primero en entrar es **`rs-validador` 1.0.0**: desarrollo, mantenimiento y documentación de la
herramienta de validación de ficheros (Python/FastAPI + HTML/JS) con la que se definen las
estructuras de entrada, se valida lo que manda el cliente y se generan los scripts SQL de
configuración de uCollect. Su changelog propio está en `plugins/rs-validador/CHANGELOG.md`.

#### Por qué un plugin aparte y no unas skills más aquí

`rs-enterprise-agent` gira entero alrededor de una `.sln`: resolución de solución, `get_scope`,
`compile_check`, DALCs, modelo BD del workspace. Nada de eso aplica a una app Python sin solución ni
compilador. Mezclarlos habría metido triggers de una herramienta en el descriptor de la otra y atado
sus versiones. Compartiendo marketplace se instalan y se actualizan por separado:

```
/plugin install rs-validador@rs-enterprise-agent
```

#### Lo que esto cambia en el propio repo

- `marketplace.json` pasa a tener dos entradas; la del plugin raíz mantiene `source: "./"` y la
  nueva apunta a `./plugins/rs-validador`. La descripción del marketplace ya no describe solo al
  agente C#.
- `docs/plugin-architecture.md` documenta la carpeta `plugins/`, el marketplace multi-plugin y un
  patrón de extensión nuevo (§9.5: cómo se añade un plugin adicional), con su fila en la checklist
  de sincronización del §10.

No cambia nada del pipeline, de los agentes ni de las tools MCP de `rs-enterprise-agent`.

Ficheros: `.claude-plugin/marketplace.json`, `.claude-plugin/plugin.json`, `README.md`,
`docs/plugin-architecture.md`, y el árbol nuevo `plugins/rs-validador/`.

## 3.10.1 — 2026-08-07

### El README y el doc de arquitectura no contaban lo de la 3.10.0, y el catálogo llevaba mal la cuenta

Repaso antes de publicar la 3.10.0 en el marketplace.

- **El README no mencionaba el inventario de objetos.** Sección nueva: qué se guarda (ficha y
  firma, nunca el cuerpo), por qué —el instalador sigue extrayendo de la BD viva, que es la
  garantía de que un paquete no entregue código viejo— y qué gana con ello el actualizador.
- **`docs/plugin-architecture.md`** enumeraba los scripts Python del instalador sin los dos
  nuevos, y su índice de referencias describía `json-schema.md` sin la sección `objetos`.
- **El catálogo de comandos llevaba mal la cuenta**, y esto venía de antes de la 3.9.0: decía
  «48 comandos: los 45 modos directos…» con 49 ficheros en `commands/`. Los números correctos
  son **49 comandos / 46 modos directos**. Nadie añadió un comando en estas versiones; el
  desajuste ya estaba en la 3.8.0.

La checklist del §10 para «nuevo hook» —`references/hooks.md`, `hooks/README.md`, CHANGELOG—
ya estaba cumplida en la 3.10.0; lo que faltaba era lo que esa checklist no pide y aun así hace
falta cuando el cambio altera lo que el modelo significa.

Ficheros: `README.md`, `docs/plugin-architecture.md`.

## 3.10.0 — 2026-08-07

### Los objetos de BD entran en el modelo: vistas, procedimientos, paquetes, funciones, triggers, sinónimos y secuencias

Hasta ahora el `model.json` solo conocía tablas. Los demás objetos existían en la BD y en el
paquete del instalador —que los extrae en vivo— pero **nunca en el modelo**, así que no había
forma de verlos en el ERD, de preguntar qué procedimientos tocan una tabla antes de cambiarle
una columna, ni de saber que uno había cambiado.

Eso último es el agujero que más costaba: el delta de `/rs-actualizador` es por VCS
(`FECHA_CORTE` + `vcs_delta` sobre ficheros del repo) y **un procedimiento modificado en BD no
está en el repo**. Hasta hoy solo viajaba si alguien se acordaba de escribir su script a mano.

#### Ficha y firma, no el cuerpo

La decisión de diseño que lo ordena todo. Del objeto se guarda su ficha —estado, nº de líneas,
tablas que usa— y una **firma** del cuerpo. El cuerpo no.

El instalador **sigue extrayendo de la BD viva**, y esa es la garantía que hace que un paquete
no pueda entregar código viejo: lo que viaja es literalmente lo que hay en la BD. Si el modelo
pasara a ser la fuente, un `model.json` desactualizado entregaría un procedimiento de hace tres
meses a un cliente y nada lo avisaría. La firma da lo que faltaba —saber qué cambió— sin
renunciar a esa garantía. Y de paso un package de miles de líneas no acaba dentro del HTML del
ERD, que embebe el modelo entero.

⛔ La firma se calcula sobre el **mismo texto que emitiría el instalador** (los bloques que
devuelven sus extractores), no sobre otra lectura de la BD. Es lo que hace que "la firma
cambió" signifique exactamente "lo que se entregaría ha cambiado" y no "alguien reformateó
algo". Por eso los extractores de `installer-objects.py` pasan a exponer sus bloques y
`model-objects.py` los reutiliza: **cero consultas duplicadas**.

Normalización antes de firmar: CRLF→LF, sin relleno a la derecha, sin líneas en blanco finales.
Sin eso la firma cambiaría en cada extracción —la BD devuelve CRLF y sqlplus vuelve a convertir
el LF— y el actualizador reportaría el esquema entero como modificado hasta que nadie volviera
a mirarlo. La **indentación sí cuenta**: es del autor.

#### Qué hay ahora

- **`hooks/sync-model-objects.ps1`** — sincroniza el inventario. `-DryRun` lista y diffea sin
  escribir. Si un tipo de objeto falla, su sección se **conserva** del modelo anterior en vez
  de vaciarse: si no, el diff siguiente leería "se han eliminado todas las vistas" por un error
  de conexión puntual.
- **Siete secciones en el ERD**, con el estado de cada objeto y las tablas que usa. Y en el
  panel de cada tabla, **qué objetos la usan** — el análisis de impacto que antes había que ir
  a buscar a la BD a mano.
- **El instalador contrasta** modelo contra BD y reporta la deriva. No bloquea (el paquete se
  genera de la BD viva, así que es correcto), pero un objeto que está en BD y no en el modelo
  suele significar que alguien lo creó a mano y nadie lo sabe.
- **El actualizador pregunta.** Su paso de scripts incorpora la comprobación: todo objeto que
  salga como nuevo/modificado/con el estado cambiado y no esté cubierto por un script de la
  entrega se le plantea al usuario, en vez de decidirlo por cuenta propia.

`tablas_usadas` se deriva **por coincidencia de texto** con las tablas del modelo, no del
diccionario de dependencias. Se llama así y no `depende_de` para no prometer una autoridad que
no tiene: un nombre dentro de un comentario cuenta igual. Vale para la pregunta que se quiere
responder —"qué toca `RCLIENTES`"— donde un falso positivo se descarta de un vistazo y un falso
negativo duele.

En Oracle, especificación y cuerpo de un package son dos objetos en `ALL_SOURCE` y **una sola
ficha**: se firman los textos concatenados. SQL Server no tiene paquetes; allí esa sección va
vacía.

### Tests

`tests/test_dbobjetos.py` (24 casos). La extracción SQL no se puede probar sin un motor
delante, así que el gate está donde puede estar: en la lógica que decide qué entra en el
modelo, que tiene tres sitios donde un fallo no daría error sino un modelo sutilmente falso —
la firma (cambia por lo que no debe, o no cambia por lo que sí), la clasificación PL/SQL
(`PACKAGE BODY` probado después de `PACKAGE` archiva el cuerpo como especificación) y el diff
(un `estado_cambiado` no detectado deja un trigger deshabilitado en el cliente).

Se fija además que dos extracciones iguales den el mismo inventario: si no, cada sync produce
un diff falso en el `model.json` y nadie revisa los reales.

El JavaScript del ERD se verificó con node (7 casos: metadatos `_`, orden, análisis de impacto
y modelo antiguo sin la sección), pero eso **no queda como gate** — el repo no tiene runner de
JS y montarlo es otra cosa.

⛔ **Sin verificar contra un motor real**: la extracción en sí. Se apoya en los extractores que
ya existían y que tampoco lo estaban, pero el reparto por secciones y el contraste solo se han
probado con bloques sintéticos. Conviene un `sync-model-objects.ps1 -DryRun` contra DESA antes
de fiarse del inventario.

Ficheros: `scripts/_dbobjetos.py` (nuevo), `scripts/model-objects.py` (nuevo),
`hooks/sync-model-objects.ps1` (nuevo), `scripts/installer-objects.py`,
`scripts/erd-template.html`, `agents/rs-instalador.md`, `agents/rs-actualizador.md`,
`references/json-schema.md`, `references/hooks.md`, `hooks/README.md`,
`tests/test_dbobjetos.py` (nuevo).

## 3.9.1 — 2026-08-07

### El toggle de PK del ERD podía reintroducir la clave invertida que acababa de arreglarse

Encontrado al revisar la 3.9.0. `scripts/erd-template.html` escribía un booleano al marcar o
desmarcar una columna como PK (`columns[col].pk = isPk`), y `saveModel()` serializa el modelo
tal cual. En una PK compuesta eso deja la tabla en estado **mixto** —unas columnas con ordinal
y otras con `true`— que es peor que no tener posiciones:

```
tras sync-from-db      -> ('COD_EMP', 'ID_MOV')   correcto
tras un toggle del ERD -> ('ID_MOV', 'COD_EMP')   INVERTIDO
```

`pk_columns` ordenaba en cuanto detectaba **algún** ordinal, y trataba `true` como ordinal 0:
la columna tocada se iba al final aunque fuera la primera de la clave. Si alguien generaba un
instalador entre el toggle y la siguiente resincronización, el `CONSTRAINT ... PRIMARY KEY`
salía al revés. Como en la 3.9.0: DDL válido, tabla creada, ningún error, y el índice que
respalda la clave es otro.

Arreglado por los dos lados, porque cada uno cubre un agujero distinto:

- **El productor deja de generar mezclas.** El toggle asigna un ordinal (entra al final de la
  clave, que es lo único honesto sin preguntar) y después renumera la PK entera a `1..n`
  respetando las posiciones ya declaradas. Efecto colateral útil: tocar cualquier columna de
  una tabla **normaliza** los `true` heredados que hubiera en ella.
- **El consumidor deja de confiar en que no las haya.** Con la tabla en estado mixto,
  `pk_columns` ya no ordena a medias: cae al orden de declaración, y el nuevo
  `pk_orden_ambiguo` hace que `installer-ddl.py` y `generate-sql.py` lo digan por consola.
  Del `true` no se puede deducir ninguna posición, así que ordenar a medias era inventarse
  una. Esto protege además del `model.json` editado a mano, que es un caso real:
  `references/json-schema.md` documenta las dos formas del campo como válidas.

### Tests

Cuatro casos nuevos en `tests/test_installer_ddl_objetos.py`: que el estado mixto no se ordena
a medias, que una tabla coherente no se marca como ambigua, que `pk: false` no cuenta como «la
otra forma» (contarlo daría un falso aviso en toda tabla con PK por ordinal, que es justo lo
que escribe el sync desde la 3.9.0) y que el generador emite el aviso.

El JavaScript del ERD no tiene infraestructura de test en el repo, así que se verificó
extrayendo las dos funciones y ejercitándolas con node: 10 casos, incluidos el cierre de hueco
al desmarcar, la normalización de un mixto preexistente y que `true` no se confunda con la
posición 1. **El gate que sí queda en CI es el del consumidor**, y es el que importa: cubre la
mezcla venga de donde venga, también de un modelo editado a mano.

Ficheros: `scripts/_dbmodel.py`, `scripts/erd-template.html`, `scripts/installer-ddl.py`,
`scripts/generate-sql.py`, `references/json-schema.md`, `tests/test_installer_ddl_objetos.py`.

## 3.9.0 — 2026-08-07

### El instalador entregaba tablas y nada más: sin vistas, sin procedimientos y sin valores por defecto

Reportado desde un cliente. Las tres ausencias tienen causas distintas y una cosa en común: **ninguna
daba error**. El paquete se generaba, la etapa se reportaba OK, y el agujero aparecía en el servidor
del cliente, al usar la aplicación.

#### 1. Valores DEFAULT — el modelo nunca los tuvo

`installer-ddl.py` construye el `CREATE TABLE` desde `BD\<proyecto>-model.json`, y ese modelo **no
tenía dónde guardar un default**: ni `sync-from-db.ps1` ni `sync-model-tables.ps1` leían
`DATA_DEFAULT` (Oracle) / `COLUMN_DEFAULT` (SQL Server), y `references/json-schema.md` no declaraba el
campo. No es que se perdiera por el camino: no se capturaba nunca. En el cliente, toda columna con
valor por defecto quedaba a NULL en el primer `INSERT` que no la nombrara — sin error, se descubre
consultando.

Ahora la columna admite `default` y lo rellena la nueva librería **`hooks/lib-dbmodel.ps1`**, en
una pasada aparte del `SELECT` principal. Lo de la pasada aparte no es gratuito: en Oracle
`ALL_TAB_COLS.DATA_DEFAULT` es de tipo **LONG**, que no se puede concatenar ni pasar por
`REPLACE`/`TRIM` dentro de una sentencia SQL, y sacado tal cual por sqlplus con `SET COLSEP '|'`
arrastra sus saltos de línea y parte la fila. Dentro de un bloque PL/SQL, en cambio, una variable
LONG se comporta como `VARCHAR2(32760)` y admite `REPLACE`: los saltos se neutralizan **antes** de
imprimir. Es el mismo patrón que ya usaba `installer-objects.py` para `ALL_VIEWS.TEXT`.

Se descartan a propósito tres cosas que no son defaults reescribibles: las secuencias de columnas
IDENTITY (`ISEQ$$`, las crea el propio `CREATE TABLE`), las columnas virtuales y ocultas (su
"default" es la expresión de la columna generada) y `DEFAULT NULL` (equivale a no tener default).

El `DEFAULT` se emite **entre el tipo y el `NOT NULL`** — `COL TIPO DEFAULT x NOT NULL` — que es el
único orden válido en los dos motores. Y solo se inlinea si el destino es el motor del modelo: un
default es una **expresión** (`SYSDATE`, `getdate()`, `((0))`), no un tipo, y `adapt_type` no la
traduce. Colar un `DEFAULT SYSDATE` en un `CREATE TABLE` de SQL Server no perdería el default: se
perdería **la tabla entera**. Al generar cruzado salen aparte, comentados, al final del fichero.

#### 2. Vistas y procedimientos — SQL Server no estaba implementado

`installer-objects.py` cubría solo Oracle. Con cualquier otro motor imprimía
`AVISO: extracción de objetos solo implementada para ORACLE` y **salía con exit 0**. Peor: el hook
comprobaba después la existencia del maestro `CreacionObjetos.sql`, no lo encontraba y abortaba la
etapa con exit 1, así que en SQL Server tampoco llegaban a generarse los inserts paramétricos.

Implementados los seis tipos sobre el catálogo `sys.*`. Ahí no hay que reconstruir nada:
`sys.sql_modules.definition` ya trae el `CREATE` literal, así que solo se antepone un `DROP`
condicional y se separan lotes con `GO` (un `CREATE VIEW`/`FUNCTION`/`PROCEDURE`/`TRIGGER` tiene que
ser la primera sentencia de su lote). Se usa `DROP` + `CREATE` y no `CREATE OR ALTER` porque este
último es de SQL Server 2016 SP1 en adelante y el parque de clientes no está garantizado ahí.

Tres decisiones que replican lo que ya hacía el camino Oracle:

- **Los marcadores viajan dentro del propio result set**, concatenados en el `SELECT`, nunca con
  `PRINT`: dentro de un lote el flujo de mensajes y el de resultados no llegan necesariamente
  intercalados en orden, y el marcador dejaría de identificar su objeto.
- **El estado `DISABLED` de un trigger se preserva** (`DISABLE TRIGGER ... ON ...`): instalarlo
  activo cambia el comportamiento de la aplicación en el cliente.
- **No se quita el prefijo de schema**, al revés que en Oracle: en SQL Server el schema del objeto
  (`dbo` casi siempre) es estable entre origen y destino, y lo que se selecciona en el cliente es la
  base de datos (`sqlcmd -d`).

La cabecera de los `.sql` ya no emite `SET DEFINE OFF` / `SET SQLBLANKLINES ON` cuando el motor es
SQL Server: son directivas de sqlplus y en un fichero que va a correr sqlcmd son error de sintaxis.
El maestro se genera con `:r` + `GO` en vez de `@@`.

#### 3. Nadie miraba si estaban — el contrato del agente no los nombraba

Es lo que convirtió lo anterior en un fallo silencioso. `agents/rs-instalador.md` no listaba los
ficheros de objetos en el árbol del paquete, y su verificación de la etapa de scripts solo exigía
`CreacionTablas.sql` y los inserts. El inventario del hook, además, los listaba con un comodín
(`$proyecto-0*.sql`): si **no se generaba ninguno**, el listado salía vacío y el resumen decía `OK`
igual. Y el output final del agente rezaba literalmente `Scripts: DDL + <N> inserts` — exactamente lo
que el cliente recibió.

Ahora el inventario recorre los seis tipos por nombre y marca `AUSENTE` el que falte, con exit 2; el
agente tiene que reportar el conteo real por tipo y el número de defaults, y el contrato de salida
lleva su propia línea `Objetos BD`.

### El paquete ordenaba los scripts por nombre, y ese orden estaba mal

Encontrado al revisar lo anterior. Sin manifiesto, `Ejecutar-Scripts.ps1` descubre los `.sql` por
convención y los ordena **alfabéticamente**. Con los ficheros de objetos en la carpeta, el orden que
salía era:

```
00-RVERSIONES · 01-Secuencias · 02-Vistas · 03-Funciones · 04-Procedimientos ·
05-Triggers · 06-Sinonimos · CreacionObjetos · CreacionTablas · Inserts\ · PorEntorno```

`02-Vistas` y `05-Triggers` **antes** que `CreacionTablas`: el `CREATE TRIGGER` se lanza sobre tablas
que aún no existen (ORA-00942 / Msg 4902) y, como la ejecución es fail-fast, la instalación aborta
ahí. Y `CreacionObjetos.sql`, que es un maestro que encadena a los demás, también casaba con el
descubrimiento y volvía a crearlo todo.

`instalacion-paquete.ps1` genera ahora **`Scripts\scripts.json`** a partir de lo que hay realmente en
la carpeta, en orden de dependencias: RVERSIONES → secuencias → tablas+índices → vistas → funciones →
procedimientos → triggers → sinónimos → inserts → fila base del entorno. Y avisa, con nombres, si
falta alguno de los ficheros de objetos.

Para los maestros hacía falta una tercera categoría: viajan en el paquete (sirven para lanzarlo todo
a mano desde una sesión) pero no deben ejecutarse. `Ejecutar-Scripts.ps1` acepta por eso
**`"ejecutar": false`** en una entrada del manifiesto: se da por declarada —así no sale como
"presente en disco y NO declarado", que en su caso sería ruido— y no se ejecuta. Su ausencia en disco
tampoco es una entrega incompleta: nadie iba a lanzarla.

### El orden de la clave primaria se aplanaba en cada sincronización

El `SELECT` de los dos hooks de sync preguntaba solo **si** la columna es PK
(`CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 'Y'`), así que escribían siempre `pk: true`. El
modelo admite desde hace tiempo un entero con la posición dentro de la clave, y
`installer-ddl.py` lo usa para ordenar, pero nadie lo rellenaba: la posición había que ponerla
a mano y la siguiente resincronización se la llevaba por delante.

Con `pk: true` en todas, el `CONSTRAINT ... PRIMARY KEY (...)` sale en el orden de **declaración
de las columnas**, que no tiene por qué ser el de la clave:

```
PK real en BD       (COD_EMP, ID_MOV)
antes               PRIMARY KEY (ID_MOV, COD_EMP)     <- orden de la tabla
ahora               PRIMARY KEY (COD_EMP, ID_MOV)
```

No da error —el DDL es válido y la tabla se crea— pero el índice que respalda la clave es otro,
y con él se pierden los accesos por prefijo. En una instalación limpia eso no se ve el día de
la entrega: se ve como degradación de rendimiento semanas después.

Ahora las consultas traen la posición real (`ALL_CONS_COLUMNS.POSITION` en Oracle,
`KEY_COLUMN_USAGE.ORDINAL_POSITION` en SQL Server) y `New-RsColumnaModelo` la escribe como
ordinal. **Siempre**, también cuando la PK es de una sola columna: `pk_columns` solo ordena si
detecta algún ordinal y trata `true` como ordinal 0, así que una PK mezclada (`true` la primera,
`2` la segunda) sale **al revés** — peor que no tener ninguna posición. Es todo o nada, así que
es todo. Efecto colateral: la primera resincronización de un modelo existente cambia todos los
`"pk": true` por `"pk": 1`. Es ruido de diff de una sola vez, no un cambio de significado.

De paso, `generate-sql.py` arrastraba el mismo fallo por su cuenta: listaba la PK con un
`[c for c, d in cols.items() if d.get('pk')]`, sin ordenar. `pk_columns` y `column_default` pasan
a **`scripts/_dbmodel.py`**, fuente única para los dos generadores de DDL — es exactamente lo que
ya hubo que hacer con el mapeo de tipos cuando las copias divergieron en `RAW`. Y el `LEFT JOIN`
de SQL Server cruzaba las constraints **sin el schema**: dos tablas homónimas en schemas distintos
se mezclaban entre sí y duplicaban filas; ahora el schema entra en los dos JOIN.

### Dos fallos encontrados de camino

- **Las marcas `pii`/`safe` se borraban en cada sincronización del modelo.** `sync-from-db.ps1` y
  `sync-model-tables.ps1` no actualizan la columna: la tiran y la reescriben entera con los cinco
  campos que devuelve la BD, preservando solo `description`. Las marcas manuales de la política PII
  no las conoce la BD, así que se perdían en silencio: una columna marcada a mano volvía a salir
  **en claro** en las consultas después de cualquier resincronización, sin error y sin aviso.

  La reconstrucción pasa a una función pura, `New-RsColumnaModelo` (en `hooks/lib-dbmodel.ps1`,
  antes `lib-dbdefaults.ps1`: el fichero ya cubre los dos huecos de la columna, no solo el default).
  La preservación va por **presencia** de la propiedad y nunca por su verdad — `safe: false`
  equivale a `pii: true`, o sea que es la marca *más* restrictiva y su valor es falso; un
  `if ($col.safe)` la daría por ausente y la borraría. `tests/DbModel.Tests.ps1` fija ese caso
  aparte, porque es el fácil de volver a romper.
- **Todo `.sql` en subcarpeta se daba por no declarado fuera de Windows.** En
  `Get-RsScriptsManifiesto`, las rutas declaradas se normalizan a `\` y las de disco traen el
  separador del sistema; solo se normalizaba un lado. Sin arreglarlo, el manifiesto nuevo —que
  declara `Inserts/...` y `PorEntorno/...`— habría llenado de avisos falsos el CI, que corre en Ubuntu.

### Tests

`tests/test_installer_ddl_objetos.py` (25 casos) fija el orden `TIPO DEFAULT x NOT NULL`, que `0` y
`'N'` son defaults reales y no ausencias, que al generar cruzado el `CREATE TABLE` no se contamina, y
que los dos motores declaran los seis tipos de objeto con la misma numeración —que es de lo que
dependen el maestro y el manifiesto—. En `tests/EjecutarScripts.Tests.ps1`, tres casos para
`ejecutar: false` y la normalización de separadores. `tests/DbModel.Tests.ps1` (23 casos) cubre la
preservación de `pii`/`safe`/`description`, la posición dentro de la PK y el parseo del mapa de
defaults; cinco casos más en `tests/test_installer_ddl_objetos.py` fijan el orden de la PK en el
`CREATE TABLE` y que los dos generadores de DDL comparten de verdad la misma función.

⛔ No se puede probar Oracle/sqlplus ni SQL Server/sqlcmd en el entorno de desarrollo Linux: lo que
se prueba es la lógica pura y el SQL que se construye, no su ejecución contra un motor real.

Ficheros: `hooks/lib-dbmodel.ps1` (nuevo), `hooks/sync-from-db.ps1`,
`hooks/sync-model-tables.ps1`, `hooks/installer-scripts.ps1`, `hooks/instalacion-paquete.ps1`,
`scripts/installer-ddl.py`, `scripts/installer-objects.py`, `scripts/generate-sql.py`,
`scripts/_dbmodel.py` (nuevo),
`assets/instalacion/Ejecutar-Scripts.ps1`, `agents/rs-instalador.md`, `references/hooks.md`,
`references/json-schema.md`, `hooks/README.md`, `tests/test_installer_ddl_objetos.py` (nuevo),
`tests/DbModel.Tests.ps1` (nuevo), `tests/EjecutarScripts.Tests.ps1`.

## 3.8.0 — 2026-08-06

### El XML de configuración de un proceso viajaba en el paquete si no se llamaba como su .exe

`actualizador-build.ps1` identificaba el `<proceso>.xml` a excluir cruzándolo **solo** contra los
nombres de los `.exe` entregados. Los que no coincidían caían en `$xmlHuerfanos`, que **únicamente
avisa**: si nadie leía el aviso, el XML se quedaba en la entrega y al instalar machacaba la
configuración del cliente.

El supuesto de fondo era falso. No todo proceso lee un XML que se llame como él: los hay que reciben
la ruta del suyo **por línea de comandos** (`cGlobales.XMLProceso = args[0]`), así que el `.exe` y su
`.xml` tienen nombres distintos por diseño. En una instalación de cliente hay un proceso cuyo XML se
llama de otra forma, y salía en cada entrega.

El JSON del proyecto ya declaraba esa correspondencia en `batch_config`, pero el hook no lo miraba.
Ahora sí: el cruce pasa a tener tres ramas — coincidencia de nombre con un `.exe`, declaración en
`batch_config`, y solo lo que no encaja en ninguna sigue generando aviso.

```json
"batch_config": {
  "RSProcIN":    "Batch\\RSProcIN\\RSProcIN.xml",
  "RSMultihilo": "Batch\\RSMultihilo\\RSTareas.xml",
  "_comun":      "Batch\\XMLConfig.xml"
}
```

Tres decisiones de implementación, cada una por un motivo concreto:

- **Se lee de los dos JSON** del proyecto (`-instalador` y `-actualizador`) y se unifican: el bloque
  se mantiene indistintamente en cualquiera de ellos.
- **Se cruza por el nombre de fichero del valor**, no por la ruta: el valor es relativo al workspace
  y la comparación ocurre contra `<destino>\Exes`.
- **El filtro es por la extensión del valor, no por el nombre de la clave.** Las claves con `_` no son
  equivalentes entre sí: `_comun` es un XML compartido **real** que también debe excluirse, mientras
  `_comentario` es una frase. Descartar toda clave con `_` habría dejado el XML común dentro del
  paquete.

Los excluidos por declaración se listan **aparte** en el output (`-- De esos, N excluidos por
'batch_config' --`) en vez de desaparecer en silencio: que un XML salga o no del paquete es
exactamente lo que decide si la instalación pisa los ajustes del cliente. El texto del aviso de
huérfanos pasa a distinguir las dos salidas — `batch_config` si es el XML de arranque de un proceso,
`excluirEntrega` si es otra cosa.

⚠️ **Tres nombres parecidos, tres cosas distintas**, desambiguado en la documentación: `batch_config`
es el mapa proceso → XML de **ejecución** del cliente; `check_batch_config` (tool MCP) y
`references/batch-config.md` son la configuración **centralizada de compilación**
(`App.Batch.config` + `Directory.Build.targets`).

Verificado ejecutando el helper real —extraído del hook por AST, sin duplicar código— contra copias
de los dos JSON de un proyecto vivo: 13 XML resueltos, el del proceso que recibe la ruta por
argumentos entre ellos, `_comun` incluido, `_comentario` fuera, y JSON ausente/sin bloque/malformado
resueltos a vacío sin romper.

Ficheros: `hooks/actualizador-build.ps1`, `references/actualizador.md`, `references/hooks.md`,
`hooks/README.md`, `agents/rs-actualizador.md`, `agents/rs-instalador.md`.

## 3.7.4 — 2026-08-06

### El README documentaba una forma de invocar los comandos que no existe

98 referencias a `/rs-*` en el README, **cero** con el prefijo del plugin, y ni una sola mención de
que el prefijo exista. Claude Code namespacea **siempre** lo que aporta un plugin
(`/rs-enterprise-agent:rs-audit`), precisamente para que dos plugins puedan traer un comando con el
mismo nombre sin pisarse; el prefijo es el campo `name` de `.claude-plugin/plugin.json`. Un `/rs-audit`
literal no resuelve.

Ha pasado desapercibido porque el selector de comandos hace coincidencia parcial: tecleas `rs-audit`,
te ofrece `rs-enterprise-agent:rs-audit` y funciona. Quien lo teclea entero y lo envía, no.

Se explica **una vez**, en dos sitios, y las tablas se dejan con el nombre corto: prefijar 98
entradas las volvería ilegibles y el nombre corto es justo lo que se teclea en el selector.

- § *Cómo se usa (activación)* — bloque nuevo con la regla, de dónde sale el prefijo, que basta
  teclear el nombre corto, y por qué el pipeline queda como `/rs-enterprise-agent:rs-enterprise-agent`
  (el plugin y el skill del pipeline se llaman igual — no es una errata).
- § *Catálogo de comandos* — aviso de que las tablas omiten el prefijo por legibilidad, con enlace a
  la explicación.

Mismo tipo de agujero que el `pip install` de la 3.7.2: la guía no dejaba el plugin usable siguiendo
sus pasos al pie de la letra.

Ficheros: `README.md`.

## 3.7.3 — 2026-08-06

### Fuera la doble vida del origen del marketplace

El plugin lleva mucho publicado solo como marketplace Git, pero la documentación seguía escrita como
si el origen pudiera ser una carpeta local o de red. Eso obligaba al lector a decidir en qué caso
estaba antes de poder aplicar nada, y arrastraba un aviso de migración que ya no le sirve a nadie.

- `README.md` — retirado el aviso *"si tenías el marketplace anterior de tipo `directory`…"*. La frase
  sobre la copia cacheada se redacta en positivo: el plugin es portable y no depende de ninguna ruta
  compartida, en vez de contarlo como contraste con una situación que ya no existe.
- `docs/plugin-architecture.md` §1.1 — eliminada la tabla de dos orígenes y el bloque de diagnóstico
  (`Get-CimInstance` sobre el proceso de python) que servía para detectar un marketplace de tipo
  `directory`. La raíz efectiva es siempre la copia cacheada, así que la sección lo afirma
  directamente y se queda con lo que sí sigue mordiendo: el checkout local es solo un checkout, y la
  copia cacheada no se edita a mano porque se pisa en el siguiente update.

⚠️ Se pierde el procedimiento manual para diagnosticar una máquina que sirva el plugin desde donde no
debe. La comprobación automática sigue estando: el check *Coherencia instalación* de `check-env.ps1`
(`/rs-env`) detecta un MCP servido fuera del plugin.

Ficheros: `README.md`, `docs/plugin-architecture.md`.

## 3.7.2 — 2026-08-06

### La instalación documentada no dejaba el plugin funcionando

Al preparar el traspaso a otra máquina salió el hueco: el README pedía "Python 3.11+" y nada más,
pero **nadie instala el paquete `mcp`**. No hay ningún `pip install` en los hooks ni en los scripts
del repo, y `check-env.ps1` tampoco comprueba que el paquete sea importable. Siguiendo el README al
pie de la letra, el servidor MCP `rs-workspace` no arranca y las 48 tools no responden.

El README pasa a abrir la instalación con ese paso, antes del `/plugin marketplace add`, y con los
dos avisos que hacen falta para que salga bien a la primera:

- El tope `<2` es obligatorio: `mcp` 2.0.0 eliminó `mcp.server.fastmcp`, que es lo que importa el
  servidor. Un `pip install mcp` a secas arrastra 2.x y rompe el arranque. Ya estaba en
  `requirements.txt`, pero nadie llega a ese fichero desde el README.
- Tiene que quedar en el Python que resuelve `python` en el PATH, porque `.mcp.json` invoca
  literalmente `python`. Con varios Python o un venv por medio, `python -c "import mcp"` lo delata.

Se añade también la verificación posterior (`/rs-env` y `/rs-help` como prueba de que el MCP
responde) y la fila de requisitos de Python queda con el paquete y el porqué del tope.

Ficheros: `README.md`.

## 3.7.1 — 2026-08-06

### Los gates del instalador no eran ejecutables sin un cliente delante, así que nadie los probaba

La 3.7.0 arregló dos fallos del gate de binding redirects: auditaba una sola de las dos carpetas de
despliegue, y sus `catch` hacían `AVISO` + `continue`, de modo que un `.exe.config` ilegible se
saltaba la comprobación y el script acababa imprimiendo `Gate de binding redirects OK`. Los dos
vivieron desde la 2.15.8 sin que saltara nada.

La causa de fondo no era el código, era su forma. Los tres gates estaban soldados dentro de
`installer-batch.ps1`, mezclados con sus `Write-Host` y sus `exit`. Para que se ejecutara la
comprobación había que ejecutar antes las 258 líneas anteriores: `vswhere`, `msbuild`, un workspace
de cliente con sus `.sln`, el JSON del proyecto y un Rebuild completo. Eso no existe en CI.
**Una comprobación cuya corrección no es observable no protege de nada.**

`hooks/lib-deploy-gates.ps1` (nuevo) se queda con la parte que **decide**; el hook conserva la que
**presenta**. Mismo patrón que `lib-crypto.ps1`, `lib-dbconfig.ps1` y `lib-pii.ps1`:

- `Test-RsCoherenciaBuild` — stragglers de otro build (frankenbuild → StackOverflow, CHANGELOG 2.15.7)
- `Test-RsBindingRedirects` — `newVersion` vs `AssemblyVersion` real, sobre N carpetas
- `Test-RsOdpDependencies` — satélites presentes junto a `Oracle.ManagedDataAccess.dll`
- `Get-RsDllConfigHuerfanos` — residuos del mecanismo anterior

Ninguna imprime ni termina el proceso: devuelven el veredicto y las líneas de detalle ya
formateadas. Los `Write-Host` y los `exit 1` siguen en `installer-batch.ps1` palabra por palabra, así
que **el comportamiento observable no cambia**: mismas líneas por pantalla, mismos exit codes.

⚠️ Único matiz: el aviso de `.dll` no gestionado ahora se imprime junto al resto de avisos, antes de
los errores, en vez de intercalado en mitad del recorrido. Mismo texto, distinto orden.

### Los tests que la 3.7.0 no pudo escribir

`tests/DeployGates.Tests.ps1` — 20 tests, un segundo, sin Visual Studio. Los assemblies de prueba
son copias renombradas de una DLL gestionada real del runtime: `GetAssemblyName` necesita metadatos
válidos y un fichero de relleno no sirve. No dependen de ningún workspace de cliente.

Cubren, entre otros, los dos fallos de la 3.7.0: que un `.exe.config` ilegible **no** reporte OK, y
que al auditar dos carpetas el hallazgo lleve la etiqueta de la correcta. Más la excepción legítima
—`BadImageFormatException`: un nativo que coincide en nombre con la identidad del redirect no es el
assembly al que apunta, así que saltarlo es correcto y el gate sigue en OK—, el `newVersion` no
parseable, el redirect cuyo DLL no está desplegado (se resuelve del GAC), y las DLL compartidas
frente a las de terceros en el gate de coherencia.

**Verificados por mutación**: se reintrodujeron los cinco fallos —el `continue` del XML ilegible, el
recorrido de una sola carpeta, el gate ODP que deja de mirar, la coherencia que ignora las DLL
compartidas y `BadImageFormatException` dejando de ser excepción— y cada uno lo caza el test que le
corresponde. Sin esa comprobación, una suite en verde no dice nada.

Ficheros: `hooks/lib-deploy-gates.ps1` (nuevo), `tests/DeployGates.Tests.ps1` (nuevo),
`hooks/installer-batch.ps1`, `references/hooks.md`, `hooks/README.md`.

## 3.7.0 — 2026-08-06

### El gate de binding redirects miraba una sola de las dos carpetas de despliegue

`installer-batch.ps1` audita `<destino>\EXES`, la carpeta que produce él mismo. Pero los batch se
despliegan a **dos** carpetas compartidas con dueños distintos: esa y `C:\ais\<Proyecto>\Procesos\Exes`,
que escribe `batch-build.ps1` en cada desarrollo. Las dos sufren last-writer-wins y la segunda es
donde los procesos corren de verdad, así que un `.exe.config` viejo junto a un DLL nuevo allí rompe el
entorno **aunque el paquete esté impecable**. En una instalación de cliente había desalineos en las dos
a la vez y el gate solo podía ver los de una. Ahora audita ambas; `-OmitirProcesosExes` excluye la
carpeta viva como salida de emergencia.

Segundo agujero en el mismo gate: los `catch` reportaban `AVISO` y hacían `continue`. Un `.exe.config`
ilegible o un DLL cuya versión no se puede leer se saltaban la comprobación y el script terminaba
imprimiendo `Gate de binding redirects OK`. **Un gate que no puede evaluar no reporta OK**: ahora todo
fallo de lectura acumula y hace `exit 1`. Única excepción, `BadImageFormatException` — el fichero no es
un assembly gestionado, luego ese redirect no le aplica y saltarlo es correcto.

### Gate nuevo: dependencias de ODP.NET presentes junto a `Oracle.ManagedDataAccess.dll`

Fallo silencioso en build y explosivo en ejecución. `Comun.dll` no referencia `System.Text.Json` y
compañía en su IL — quien las usa es `Oracle.ManagedDataAccess.dll`. Al compilar un EXE, MSBuild sigue
la cadena `Comun.dll → Oracle.ManagedDataAccess.dll → System.Text.Json <ver>`, no encuentra esa versión
en `packages` y **descarta la referencia sin ningún warning**. El `bin` queda sin esas DLL, el proceso
arranca con normalidad y muere en el primer acceso a BD con `Se produjo una excepción en el
inicializador de tipo de 'Oracle.ManagedDataAccess.Client.OracleCommand'`.

El gate exige presencia física de los 7 satélites en cada carpeta de despliegue donde esté ODP.NET
(`odpDependencies` en el JSON del proyecto para ampliar la lista).

### La nota del readme metía en el mismo saco dos cosas opuestas

`instalacion-paquete.ps1` escribía *"los ficheros de configuracion (web.config, \*.exe.config) NO
viajan en el paquete"*. El `<Exe>.exe.config` **sí viaja siempre**: acompaña a su binario y lleva los
bindingRedirects; si no viaja, el destino conserva el config viejo y el EXE revienta con
`FileLoadException`. Es lo que ya hacía bien `actualizador-build.ps1`, con el que la nota se
contradecía. Lo que no viaja nunca es la configuración del entorno del cliente: `web.config`,
`appsettings*.json` y los XML de configuración de proceso.

La nota se reescribe en dos bloques separados y depende del modo (en instalación limpia viaja todo,
pero con valores de desarrollo). Es texto del readme, no había exclusión funcional mal — pero es lo que
lee Operaciones para decidir qué copia.

### Configuración centralizada de los batch: convención, detección y adopción

Los batch .NET 4.8/4.8.1 pueden sustituir el `app.config` por proyecto por dos ficheros en `Batch\`:
`App.Batch.config` (configuración común, **sin** bloque `<runtime>`) y `Directory.Build.targets`
(asigna `<AppConfig>`, activa `AutoGenerateBindingRedirects` y declara las dependencias de ODP.NET con
`HintPath` y `<Private>true</Private>`). El plugin no lo conocía. Consecuencias que ahora refleja:

- El `<Exe>.exe.config` **ya no existe como fuente**: lo genera MSBuild y la única copia válida es la
  de `bin\<Config>\`. Nunca reconstruirlo ni copiarlo del árbol de fuentes.
- `Batch\App.Batch.config` **no es desplegable**: es fuente de compilación.
- Los `<proyecto>.dll.config` ya no se generan — el CLR no los lee para binding. `installer-batch.ps1`
  avisa de los huérfanos y con `-LimpiarDllConfig` los barre.
- **Excepción por proyecto**: `<AppConfig>` solo se asigna si no hay `app.config` propio. Los procesos
  que hospedan un AppDomain hijo conservan el suyo por `<probing privatePath>`, `loadFromRemoteSources`
  y sus bindingRedirect, que MSBuild no puede autogenerar. ⛔ No unificarlos.
- `batch-build.ps1` usa `dotnet build`: verificado que aplica el `Directory.Build.targets` y genera el
  `.exe.config` completo. No se cambia.

**Nuevo** `hooks/batch-centralizar.ps1 <workspace> [-Aplicar]` + tool MCP `check_batch_config`
(informe, solo lectura — centralizar no se expone como tool porque escribe en el workspace). Clasifica
cada proyecto en `centralizable` / `excepcion` / `revisar` y **solo retira los primeros**. Los
`HintPath` del `.targets` se derivan de los `<Reference>` que ya existen: si alguno no se resuelve
devuelve `BLOCKED` y **no escribe nada**, porque un `.targets` a medias no arregla el descarte
silencioso de referencias. Plantillas versionadas en `assets/batch/`.

Se propone en dos momentos, y en los dos lo **confirma una persona**: `/rs-instalador` y
`/rs-actualizador` lo comprueban en el PASO 0 (cambia qué lleva el paquete), y en el pipeline la etapa
`build` devuelve `BATCH_CONFIG` y el orquestador surface la propuesta — mismo idioma que `NEW_PATTERN`.

`tests/BatchCentralizar.Tests.ps1` (13 tests Pester) fija la clasificación, que el modo informe no
escriba, la idempotencia y que `BLOCKED` no deje nada a medias.

Ficheros: `hooks/installer-batch.ps1`, `hooks/instalacion-paquete.ps1`, `hooks/batch-centralizar.ps1`
(nuevo), `hooks/actualizador-build.ps1`, `assets/batch/*.tpl` (nuevos), `references/batch-config.md`
(nuevo), `references/actualizador.md`, `references/hooks.md`, `references/mcp.md`, `hooks/README.md`,
`agents/rs-instalador.md`, `agents/rs-actualizador.md`, `agents/rs-editor-build.md`,
`skills/rs-enterprise-agent/SKILL.md`, `mcp/rs-workspace-server.py`, `docs/plugin-architecture.md`,
`README.md`, `tests/BatchCentralizar.Tests.ps1` (nuevo).

## 3.6.1 — 2026-08-06

### Las tres propiedades que sostienen la etapa de scripts del instalador eran un comentario

La 3.6.0 hizo que las tablas paramétricas se pidan agrupadas en una sola sesión SQL. Eso apoya el
resultado en propiedades que no estaban probadas, y las tres fallan **en silencio**: el instalador no
petardea, genera los ficheros igual con datos de menos, y eso solo se ve en el servidor del cliente
cargando paramétricas incompletas.

`tests/test_installer_inserts.py` (44 tests, pytest) las fija:

- **Aislamiento de error dentro de la sesión compartida** — un `ORA-` de una tabla no contamina a las
  vecinas del chunk. Incluye que el script enviado **no** lleve `WHENEVER SQLERROR EXIT` (con él, la
  primera tabla mala se lleva por delante a las siguientes) y que en SQL Server cada tabla cierre su
  lote con `GO` (sin eso, `PRINT` y resultados se desordenan y el marcador deja de identificar filas).
- **Troceo por marcador y por `ROWEND`, nunca por `\n`** — un valor con saltos de línea partiría la
  fila y se perdería.
- **La decisión `VARCHAR2`/`TO_CLOB`** y su red de seguridad: el reintento existe porque reconoce el
  `ORA-01489`, así que una estimación corta cuesta un reintento, nunca un fichero incorrecto.

Más el formateo del `.sql` (comilla doblada, `NULL` vs cadena vacía, numéricos sin comillas, `commit`
final, `RAW` reconstruido con `HEXTORAW`, aviso de BLOB no inlineable, fila corrupta descartada) y dos
propiedades de diagnóstico y de higiene: que un fallo de proceso reporte el error real y no el banner
`SQL*Plus: Release…` (se atribuye a **todas** las tablas de la sesión, así que el banner multiplicado
por 12 no es diagnosticable), y que la password de `sqlcmd` viaje por `SQLCMDPASSWORD` y no por `argv`.

Los tests no tocan BD ni necesitan cliente SQL instalado: `subprocess.run` se sustituye por un doble
que captura el script enviado, así que también corren en el CI. **Verificados por mutación**: se
rompieron a mano las 10 propiedades una a una y cada una la caza un test — un `44 passed` de un test
que no muerde no vale de nada.

### Doc obsoleta corregida (`docs/plugin-architecture.md`)

Decía que los `*.Tests.ps1` hay que correrlos con `pwsh` y **no** con `powershell` 5.1 "que falla al
enlazar el 3.er arg". Eso lo arregló la 3.5.1: hoy la suite pasa con los dos, y tiene que pasar con
los dos —`pwsh` 7 es el del CI (sobre `ubuntu-latest`, donde 5.1 no existe) y `powershell` 5.1 es el
que ejecuta los hooks de verdad—. Tal como estaba, la doc canónica invitaba a no probar nunca con el
intérprete de producción.

Ficheros: `tests/test_installer_inserts.py` (nuevo), `docs/plugin-architecture.md`.

## 3.6.0 — 2026-08-06

### La etapa de scripts de `/rs-instalador` pagaba un login de BD por cada tabla

El reloj de esa etapa no se lo llevaba consultar, se lo llevaba **conectar**. Tres cosas lo
provocaban, y las tres estaban repartidas por igual entre el hook y los scripts Python:

1. `installer-inserts.py` arrancaba **un proceso `sqlplus`/`sqlcmd` por tabla paramétrica**. Con
   decenas de tablas —todas pequeñas, que es lo normal en paramétricas— el spawn del proceso más
   el login dominaban el total. El cap `max_paralelo` limitaba las simultáneas, así que se pagaba
   una tanda de logins por ronda.
2. `installer-objects.py` recorría sus 6 tipos de objeto (secuencias, vistas, funciones,
   procedimientos, triggers, sinónimos) en un `for` **secuencial**: 6 spawns + 6 logins uno detrás
   de otro, cuando son independientes y cada uno escribe su propio fichero.
3. `read_db_config` lanzaba **PowerShell** para releer `get-config.ps1`, una vez por cada script
   Python de la etapa.

Ahora:

- **Una sesión SQL por chunk de tablas, no por tabla.** Las tablas de un chunk se piden en la misma
  sesión, separadas por el marcador `@@TBL:<TABLA>@@` que emite `PROMPT` (Oracle) / `PRINT` (SQL
  Server), y la salida se trocea por ese marcador. El aislamiento de error se mantiene: ni `sqlplus`
  ni `sqlcmd` abortan la sesión ante el error de una sentencia (a propósito **no** se pone
  `WHENEVER SQLERROR EXIT`), así que un `ORA-`/`Msg` queda dentro del bloque de *su* tabla y el
  resto del chunk se genera igual. En SQL Server cada tabla va en su propio lote (`GO`) porque
  dentro de un mismo lote el flujo de mensajes y el de resultados no llegan necesariamente
  intercalados en orden, y el marcador dejaría de identificar sus filas.
- **`VARCHAR2` en vez de `CLOB` cuando la fila cabe.** El `SELECT` envolvía siempre la primera
  expresión en `TO_CLOB` para no topar con el límite de 4000; eso hace la concatenación LOB por fila
  y añade fetch de LOB, y la mayoría de tablas paramétricas son estrechas. Ahora el ancho se estima
  con los tipos del `model.json` y solo se usa `TO_CLOB` si hace falta. La estimación es en
  caracteres y el límite es en bytes, así que el umbral deja margen (3000) y, si aun así se queda
  corta, el `ORA-01489` se reintenta con `TO_CLOB`: **la estimación no puede producir un fichero
  incorrecto, solo un reintento**.
- **`ARRAYSIZE 200`** en las sesiones Oracle: el default de `sqlplus` son 15 filas por roundtrip.
- **Los 6 tipos de objeto se extraen en paralelo.** Las consultas van concurrentes, pero la
  escritura de ficheros y todo el log se hacen después, en el orden de las etapas: la salida sigue
  siendo determinista y comparable entre ejecuciones.
- **Config de BD resuelta una sola vez** en `installer-scripts.ps1` y pasada a los Python por
  `RS_DB_CONFIG_JSON`. ⛔ Ese fichero **no** contiene la password (`get-config.ps1` no la emite
  nunca); cada script la sigue leyendo del `docs\.rs-databases.json`. Si la cachea falla, se avisa y
  cada script la resuelve por su cuenta — el camino de antes.
- **`parametricas.max_paralelo` pasa a ser el cap único de sesiones BD de la etapa**: gobierna
  inserts *y* objetos. Sigue siendo una sola palanca para el Oracle del cliente, no una por script.

Y para no repetir la etapa entera por un fallo puntual, `installer-scripts.ps1` acepta
**`-Solo todo|ddl|objetos|inserts`** y **`-Tablas "T1;T2"`** (implica `-Solo inserts`). ⛔ Con
`-Tablas`, `Inserts\_run_all.sql` **no** se reescribe: hacerlo lo dejaría cargando solo ese
subconjunto, y en silencio. El script lo avisa.

Todo el camino emite **tiempos** (`~ sesión k/N ... en X.Xs`, `Tiempo: X.Xs`, `OK — Scripts en …
(X.Xs)`), y el agente `rs-instalador` los incluye ahora en el SUMMARY: es lo único que permite ver
si la etapa se degrada y decidir si toca ajustar `max_paralelo`. La mejora en segundos depende del nº
de tablas y de la latencia contra el Oracle del cliente, así que no se afirma aquí ningún múltiplo:
la medición sale del propio log.

Ficheros: `scripts/installer-inserts.py`, `scripts/installer-objects.py`,
`hooks/installer-scripts.ps1`, `agents/rs-instalador.md`, `references/hooks.md`, `hooks/README.md`,
`docs/plugin-architecture.md`.

## 3.5.1 — 2026-08-05

### La suite entera fallaba con Windows PowerShell 5.1, que es el intérprete de los hooks

140 tests en rojo al ejecutarla con `powershell`, y ninguno era un fallo real. **132 de los 140
tenían una única causa**, repetida 35 veces con la misma forma:

```powershell
Join-Path $PSScriptRoot ".." "hooks" "lib-crypto.ps1"    # 3 posicionales
```

El tercer argumento posicional de `Join-Path` es `-AdditionalChildPath`, que existe **desde
PowerShell 6**. En 5.1 no encaja en ningún parámetro y la llamada falla. Como falla en *ejecución* y
no al parsear, el gate de la 3.4.6 no podía verlo. Ahora se escribe `Join-Path $base "a/b/c"`: la
barra vale igual en Windows y en Linux, así que sirve para los dos intérpretes y para el CI.

Esto importa más de lo que parece para un fichero de test. Los hooks los lanza `plugin.json` con
`powershell -File`, es decir 5.1: una suite que solo corre en PowerShell 7 no está probando el
intérprete en el que el plugin se ejecuta de verdad. Y quien la ejecutara en local con `powershell`
se encontraba 140 fallos que parecían de código y no lo eran.

Los 8 restantes eran tres cosas distintas, y una de ellas tampoco era lo que parecía: los 5 de
`log-execution.ps1 saneado de PII` fallaban por **el mismo `Join-Path`**, en una forma
(`Join-Path $ws "executions" "history.json"`) que no encajaba en la primera pasada de sustitución.
Los cazó el gate nuevo, no la revisión a ojo.

Quedan 3 saltados bajo 5.1, con `-Skip` explícito y el motivo escrito al lado, porque son
diferencias reales entre intérpretes y no defectos: dos usan la unidad ficticia `X:\` y el
`Join-Path` de 5.1 **valida que la unidad exista** mientras que el de 7 no; el tercero lanza un
`pwsh` hijo desde 5.1 y acaba midiendo el encoding de ese puente en vez del de la guarda. Bajo
PowerShell 7 los tres corren.

### `$IsWindows` no existe en Windows PowerShell 5.1, y las guardas estaban al revés

`$IsWindows` es una variable de PowerShell Core. En 5.1 vale `$null`, así que
`-Skip:(-not $IsWindows)` evaluaba `-not $null` = `$true`: los tests marcados «solo Windows» —el
roundtrip DPAPI de `lib-crypto` y los de `render-word`, que necesitan Word por COM— **se saltaban
precisamente al ejecutarlos en Windows**, y con el único intérprete donde esas dos cosas están
disponibles de verdad.

La comprobación correcta es contra `$false` explícito: `$null` (5.1, que solo existe en Windows) y
`$true` ejecutan; solo el `$false` de PS Core fuera de Windows salta. Con eso, bajo 5.1 `Crypto`
pasa de 3 a 6 tests y `RenderWord` de 0 a 12 — cobertura que se creía tener y no se estaba
ejecutando.

### Un gate más, del mismo tipo que el del BOM

`tests/Encoding.Tests.ps1` comprueba ahora también que ningún `.ps1` del repo use `Join-Path` con
tres o más posicionales. Va ahí y no en el parser por la razón de siempre: **el parser no lo caza**,
porque es un error de ejecución. Es el mismo patrón que el BOM en la 3.4.6 — una convención que solo
vive en la cabeza de quien la escribió se rompe; una que falla en la suite, no.

Resultado: **510 passed / 0 failed / 3 skipped** con Windows PowerShell 5.1 y **513 / 0 / 0** con
PowerShell 7.

## 3.5.0 — 2026-08-05

### `Ejecutar-Scripts.ps1` no servía en un cliente con wallet, y era el único lanzador

Construía siempre `sqlplus -L -S "$usuario/$Password@$conexion"`. Eso exige usuario y contraseña, no
contempla la autenticación externa, y mete la contraseña en `argv`, donde queda visible en la lista
de procesos de la máquina del cliente. En una instalación con Oracle Wallet no había forma de usarlo.

La plantilla se ha reescrito partiendo de un lanzador ya validado contra una base de datos real con
wallet. **No es una reescritura desde cero**: lo que traía dentro son cicatrices de fallos pagados en
producción, y el trabajo ha consistido en no volver a pagarlos.

Doble modo de conexión. Con autenticación externa, el alias viaja como **un único argumento
literal** `/@alias`, sin componer ni trocear ninguna cadena; con usuario, `sqlplus /nolog` y el
`CONNECT` dentro de un fichero temporal. En SQL Server, que tenía el mismo defecto con `sqlcmd -P`,
la contraseña pasa por `SQLCMDPASSWORD` y se añade autenticación integrada (`-E`). En ningún motor
queda ya una contraseña en la línea de comandos.

Validador de alias **antes** de conectar: un descriptor `(DESCRIPTION=...)` o un EZConnect
`host:puerto/servicio` se rechazan con un mensaje que explica el porqué. El wallet indexa la
credencial por el texto exacto del alias, y cualquier troceo por `/` o `@` rompe un descriptor TCPS
y produce un ORA-12154 que parece un problema de red y no lo es.

Pre-vuelo antes de tocar la BD: `sqlplus`/`sqlcmd` en el PATH, `TNS_ADMIN`, `sqlnet.ora`,
`WALLET_LOCATION`, `SQLNET.WALLET_OVERRIDE`, `cwallet.sso`, el alias en `tnsnames.ora`, y una
conexión real que reporta usuario, `CURRENT_SCHEMA`, BD y protocolo. Se conserva `-Schema` para el
`ALTER SESSION SET CURRENT_SCHEMA`: el usuario del wallet muchas veces no es el dueño de las tablas.

La cabecera de sqlplus lleva `WHENEVER SQLERROR`/`OSERROR EXIT FAILURE` —sin ellos sqlplus devuelve
0 aunque el script falle y la instalación se da por buena—, `SET DEFINE OFF` para que un `&` dentro
de un texto no sea una variable de sustitución, y `SET SQLBLANKLINES ON` para que un literal con
líneas en blanco no se corte en SP2-0042 ni entre truncado. Los ficheros temporales se escriben
**sin BOM**: con BOM, sqlplus se come la primera sentencia.

Tres fallos concretos que la plantilla ya trae resueltos, cada uno con su test:

- **`WALLET_LOCATION` con `?` de `ORACLE_HOME`.** `sqlnet.ora` admite `DIRECTORY = ?/network/admin`.
  En Windows `?` es un carácter ilegal en rutas, así que `Test-Path` no devuelve `$false`: lanza
  `ArgumentException` y abortaba el pre-vuelo entero. Ahora se quitan las comillas, se expande `?`
  con `$env:ORACLE_HOME` si está, y si la ruta sigue sin ser comprobable se avisa y se continúa.
- **`NLS_LANG` se pisaba incondicionalmente.** La precedencia correcta es `-NlsLang` > `%NLS_LANG%`
  del entorno > `AMERICAN_AMERICA.AL32UTF8`. Y si el valor final no es UTF-8 se avisa y se pide
  confirmación: los `.sql` se generan en UTF-8 y con otro `NLS_LANG` los acentos entran corruptos
  **sin error de Oracle**, así que el fallo se descubre al consultar, no al cargar.
- **SP2-0306 por contraseña vacía.** La contraseña solo se pedía si no había `-Simular`, pero
  `-Simular` sí conecta de verdad: el `CONNECT` salía como `usuario/@alias`. Ahora se pide también
  al simular, y los `SP2-xxxx` se diagnostican aparte de los `ORA-*` — son sintaxis del `CONNECT`,
  no wallet ni red ni credenciales, y el bloque de pistas ORA solo despistaba.

Se ha **sustituido** el lanzador en vez de añadir un segundo: `hooks/instalacion-paquete.ps1` ya lo
copiaba literal desde `assets/instalacion/` para los dos modos, así que el punto de unificación
existía. Dos lanzadores habrían significado arreglar el wallet en uno y no en el otro. Lo que **no**
se ha hecho es adoptar el fichero de referencia tal cual: era Oracle-only y el del plugin soporta
SQL Server, así que es una fusión —capa de conexión y pre-vuelo del primero, descubrimiento de
scripts, `rutas.json` y SQL Server del segundo—.

### El orden de los scripts de un actualizador ya no depende de renombrar ficheros

`scripts.json` opcional junto a los `.sql`. Si existe, **manda** sobre el descubrimiento por
carpetas: declara qué se ejecuta, en qué orden, qué es opcional, qué depende del entorno y qué es
purga (solo con `-Recargar`). Si no existe, se mantiene la convención de siempre —raíz, `Inserts\`,
`PorEntorno\99-RVERSIONES-<Entorno>.sql`—, así que los paquetes ya entregados siguen funcionando sin
regenerarlos.

Se eligió el manifiesto y no una plantilla con placeholders porque el `.ps1` **ya** era un fichero
fijo copiado literal: introducir sustitución de texto habría convertido en código generado algo que
no lo era, con el riesgo de romper la sintaxis al sustituir. Con manifiesto, el `.ps1` se testea una
vez y no cambia nunca.

Qué pasa si lo declarado no cuadra con el disco: un script obligatorio ausente es **error antes de
conectar** —una entrega incompleta no se empieza, es preferible no tocar la BD a dejarla a medias—;
uno marcado `opcional` solo avisa; y un `.sql` que viaja pero **no** está declarado se avisa y no se
ejecuta, porque lanzar SQL no declarado contra la base de datos de un cliente es peor que omitirlo.

Lo genera `/rs-actualizador`, que es quien tiene orden significativo y ya preguntaba al usuario por
las dependencias entre scripts. `/rs-instalador` no lo genera: su orden es estructural y la
convención le basta. Los dos flujos consumen el mismo lanzador, pero no se les ha forzado el mismo
manifiesto.

### Cobertura

`tests/EjecutarScripts.Tests.ps1` — 37 tests. El `.ps1` acepta `-DotSourceOnly`, que devuelve el
control tras definir las funciones puras y antes de tocar nada, de modo que los caminos de decisión
se ejercitan sin base de datos delante: validador de alias, precedencia de `NLS_LANG`, expansión de
`?` en `WALLET_LOCATION`, elección de modo de autenticación, temporal sin BOM, y la resolución del
manifiesto contra sus casos límite.

## 3.4.6 — 2026-08-05

### Tres hooks llegaron a la 3.4.5 sin BOM y no parseaban

`log_execution` fallaba con `Token '$(' inesperado en la expresión o la instrucción`, y el rastro
apuntaba a `lib-pii.ps1` línea 420 —una línea que está perfectamente escrita—. El hook no tenía
nada malo: tenía mal la codificación.

Windows PowerShell 5.1 es el intérprete con el que `plugin.json` y `runner/runner.ps1` lanzan los
hooks (`powershell -File ...`), y sin BOM decodifica el fichero con la codepage ANSI del sistema.
El guion largo de esa línea (U+2014, bytes `E2 80 94`) se lee entonces como `â€"`: esa comilla doble
cierra la cadena en curso y el script **ni siquiera parsea**. De ahí que el error se propagase a las
líneas 433, 437, 477, 478 y 499 — no eran seis fallos, era uno. Y como `log-execution.ps1` hace
`. lib-pii.ps1`, la tool caía sin haber ejecutado una sola instrucción propia.

El barrido del repo encontró que no era un caso aislado: **`lib-pii.ps1`, `installer-batch.ps1` y
`vcs-revert.ps1` estaban rotos** bajo 5.1, y otros seis hooks más los cinco ficheros de test
arrastraban el mismo defecto latente, salvados solo por dónde caían sus caracteres no-ASCII. Los
dieciséis se han reescrito en UTF-8 con BOM; el contenido es byte-idéntico, solo cambia el prefijo
`EF BB BF`. Antes de tocarlos se comprobó que los dieciséis eran UTF-8 estricto válido: sobre un
fichero realmente ANSI, anteponer el BOM lo declararía UTF-8 y corrompería el texto.

Se descartó sustituir los no-ASCII por ASCII. Los hooks emiten mensajes en español hacia el usuario
y hacia el modelo, y degradarlos rompería tildes en salida y en las aserciones de test que comparan
cadenas acentuadas. Sobre todo, no ataca la causa: el siguiente guion largo que alguien escriba
vuelve a romperlo.

### La convención de codificación ya estaba escrita y aun así se rompió tres veces

`hooks/README.md` documenta desde hace versiones que los `.ps1` van en UTF-8 con BOM, con el aviso
de que ya pasó con los cuatro hooks del instalador. No sirvió, porque la causa de la reincidencia es
mecánica y no de criterio: los editores y las herramientas de escritura automática guardan UTF-8
**sin** BOM por defecto, y el fichero queda roto sin que nadie haga nada mal a la vista.

El nuevo `tests/Encoding.Tests.ps1` convierte la convención en un gate ejecutable: recorre todos los
`.ps1` del repo —excluido `.venv`, que es de Python— y exige BOM, UTF-8 estricto válido y parseo sin
errores. De las tres aserciones la del BOM es la que de verdad protege, y por eso se comprueba como
byte y no a través del parser: PowerShell Core (el del runner de CI) sí lee UTF-8 sin BOM
correctamente, así que allí un fichero sin BOM pasaría desapercibido y solo reventaría en la máquina
Windows de quien lo usa. Lleva además una guarda contra el descubrimiento vacío, para que un fallo
del `Get-ChildItem` no deje la suite en verde sin haber comprobado nada.

## 3.4.5 — 2026-08-05

### Los 10 tests que cubren los caminos PII de `db-query.ps1` no llegaban a ejecutarse

Mockean `sqlplus` para poder ejercitar el hook sin base de datos. Pero **Pester no puede mockear un
comando que no existe en la sesión**: sin cliente Oracle instalado, `Mock -CommandName sqlplus`
aborta con `Could not find Command sqlplus` y el test cae antes de probar nada. En el runner de CI
no hay Oracle, así que esos 10 llevaban en rojo desde que se escribieron — y son justo los que
cubren lo más delicado del repo: el camino sin filas, el fallo cerrado cuando `pii_cli` falla, el
modelo declarado y ausente, el viaje de los acentos y el saneado del eco de SQL.

Un `function sqlplus { }` en el `BeforeAll` de los dos `Describe` le da a Pester algo que sustituir.
Donde sí hay cliente Oracle el `Mock` lo reemplaza igual, así que no cambia nada.

**No se han saltado con `-Skip`**, que era la salida fácil y la que usa el repo para Word y DPAPI:
esos dependen de algo que de verdad no se puede simular, mientras que aquí el mock ya estaba escrito
y solo le faltaba poder engancharse.

## 3.4.4 — 2026-08-05

### `check-env.ps1` se caía a media ejecución si `USERPROFILE` no estaba

Tres `Join-Path $env:USERPROFILE` sin respaldo. En Windows —donde corre el plugin— esa variable
siempre está, así que en uso real no se notaba; fuera de Windows es nula, `Join-Path` lanza
*argument is null* y **el resto del check no llega a ejecutarse**. Ahora hay un `$perfilUsuario`
con respaldo a `HOME`.

Lo destapó el CI: el runner es Linux y el único test que ejecuta este hook de punta a punta
llevaba en rojo por esto, desde antes de todo este trabajo.

Con esto **la suite de protección de datos personales queda entera en verde**: 129 → 130 tests
pasando. Los fallos que quedan en el CI están en `Crypto.Tests.ps1`, `DbQuery.Tests.ps1` y
`Mantis.Tests.ps1`, ninguno tocado en esta serie de cambios.

## 3.4.3 — 2026-08-05

### La suite invocaba las guardas de una forma en la que no pueden funcionar

Los tests llamaban al hook con el operador de invocación (`| & $g`), dentro del mismo proceso.
Pester fija `$ErrorActionPreference = 'Stop'` en cada `It`, y con eso el `Write-Error` con el que
la guarda emite el bloqueo **lanza una excepción antes de llegar a su `exit 2`**: el test veía una
`WriteErrorException` en vez del código de salida, y ni siquiera se ejecutaba la línea que fija ese
código. Todos los casos "bloquea …" salían en rojo desde siempre, midiendo un artefacto del arnés.

Claude Code no invoca así los hooks: los lanza como **proceso hijo** (`powershell -File`), donde
`$ErrorActionPreference` vale `Continue`, el `Write-Error` escribe y el `exit 2` corre. La suite
pasa a invocarlos igual. Reproducido y verificado con `$ErrorActionPreference = 'Stop'`:

```
invocacion directa: LANZA -> WriteErrorException
proceso hijo:       exit 2
```

El intento anterior (`2>$null`, 3.4.2) no servía: redirigir el flujo de error no evita que un error
terminante interrumpa el script. Se conserva porque mantiene limpia la salida del test.

El caso que ya invocaba como proceso hijo —el del texto con acentos— es el único de esa familia que
pasaba en verde, y era la pista.

## 3.4.2 — 2026-08-05

### La exclusión de `Instalador\`/`Actualizador\` no casaba con barras normales

`pii-guard-write.ps1` excluía las rutas de entrega con `'\\(Instalador|Actualizador)\\'` — barra
invertida a los dos lados. La ruta la trae el evento tal cual la escribió quien llama, así que una
con barras normales (`C:/AIS/<proyecto>/Instalador/x.sql`) **no quedaba excluida y se bloqueaba**:
justo la escritura que la guarda debe permitir, porque ahí el volcado de datos reales es el
propósito del fichero. Ahora es `[\\/](Instalador|Actualizador)[\\/]`.

Lo destapó el CI, no una lectura del código: el runner es Linux y ahí **todas** las rutas llevan
`/`, así que los dos tests de exclusión —que hasta 3.3.0 nunca habían llegado a ejercitar la guarda
por vivir fuera de un workspace— pasaron a fallar en cuanto se les dio un workspace en `enforce`.

### La suite de guardas contaba como fallo un bloqueo correcto

Las guardas emiten el bloqueo con `Write-Error` y salen con código 2. Los tests invocaban el hook
sin redirigir el flujo de error, así que Pester recogía ese `ErrorRecord` como fallo del test aunque
el comportamiento fuera el correcto: **todos** los casos "bloquea ..." salían en rojo. Con `2>$null`
la aserción mira el código de salida, que es el contrato real del hook. El único caso que inspecciona
el texto del mensaje sigue usando `2>&1` y no cambia.

Esto explica parte del rojo histórico del CI: la suite lleva tiempo fallando por cómo mide, no por
lo que mide.

## 3.4.1 — 2026-08-05

### El repo llevaba el nombre de un cliente en 24 sitios

`docs/proteccion-pii-consultas-bd.md` —que es un documento **dirigido al departamento de
Sistemas**— nombraba al cliente 19 veces, y con él su esquema y su usuario de consulta reales.
El CHANGELOG y `hooks/installer-batch.ps1` lo citaban en otras cinco, al documentar regresiones
reales.

El plugin es genérico y su repositorio se comparte, así que ahí no van nombres de clientes: ni en
documentación, ni en el CHANGELOG, ni en comentarios de código, ni en ejemplos o tests. Tampoco
sus derivados identificables — esquema, usuario de BD, nombres de solución que incluyan la marca.

- El documento pasa a usar la notación que ya tenía para la credencial (`<USUARIO_CONSULTA>`) y
  estrena `<ESQUEMA>`, con una nota explícita de que **los valores reales acompañan al documento
  por otro canal, no dentro de él**. El §6 añade lo mismo sobre el inventario de columnas: es un
  anexo, porque lleva nombres de tablas y columnas del cliente.
- Las regresiones reales del instalador se citan como "una instalación de cliente" y "el proyecto
  donde se detectó". Las referencias útiles (la revisión `r14970`) se conservan sin el nombre.

La regla queda escrita donde se aplica: `skills/rs-plugin-dev/SKILL.md` (reglas globales) y §10 de
`docs/plugin-architecture.md` (checklist de coherencia). Con una excepción explícita, porque la
confusión es fácil: **no** aplica a lo que los agentes escriben en el workspace del cliente, donde
los nombres propios son legítimos y necesarios.

## 3.4.0 — 2026-08-05

### Las guardas PII las declara el plugin: cada actualización las mataba en silencio

Se registraban a mano en `~/.claude/settings.json` desde `/rs-pii enforce`. Ahí
`${CLAUDE_PLUGIN_ROOT}` **no se expande** —solo lo hace en `.claude-plugin/plugin.json` y
`.mcp.json`—, así que había que cablear la ruta absoluta. Y el caché de plugins de Claude Code
organiza cada versión en su propia carpeta:

```
~/.claude/plugins/cache/rs-enterprise-agent/rs-enterprise-agent/3.2.1/hooks/pii-guard-bash.ps1
                                                                 ^^^^^
```

**Cada `/plugin marketplace update` dejaba las dos entradas apuntando a un directorio que ya no
existe.** Claude Code lanza el hook, `powershell` sale con error, y ese código **no es 2** —el único
que bloquea—, así que las dos guardas fallaban **abiertas**, sin ninguna señal. Hasta la 3.2.2
`check_env` seguía respondiendo `guards_registered: true`. No es un caso raro que exija mover el
plugin de sitio: le pasa a todo el mundo, en cada actualización, por construcción. Verificado sobre
una instalación real.

`.claude-plugin/plugin.json` declara ahora las dos guardas en `hooks.PreToolUse`, junto a los tres
hooks que ya tenía, con `${CLAUDE_PLUGIN_ROOT}` — que ahí sí se expande, y a la versión en curso. Se
instalan, se actualizan y se retiran con el plugin. Esto era inviable antes de la 3.3.0, cuando las
guardas bloqueaban siempre: declararlas en el manifiesto habría encendido un bloqueo de alcance de
máquina para todo el equipo. Como ahora siguen al modo del workspace, no enciende nada a nadie que
no lo haya pedido.

**`/rs-pii enforce` deja de escribir en `~/.claude/settings.json`.** Su procedimiento se reduce a:
inventario → verificar que las guardas están → confirmar → escribir el modo. Desaparece el paso de
editar a mano el fichero personal del usuario, que era la operación más frágil del agente.

**Los restos se retiran solos.** `scripts/cleanup-preplugin.ps1` —que ya corre en `SessionStart` por
esto mismo: `/plugin marketplace update` no toca `~/.claude`, y un hook del propio `plugin.json` es
el único vector que llega— detecta las entradas manuales y las quita, con copia previa en
`~/.claude/_backup-preplugin-<fecha>/`. Se lleva tanto las muertas (fallan en cada `Bash` y cada
`Write`) como las vivas (duplicarían el hook del plugin, que es el fallo de la v2.11.0), y **no toca
nada más** del fichero: permisos, hooks de otros proyectos y demás claves se conservan; si
`PreToolUse` se queda vacío, se elimina la clave en vez de dejar una lista huérfana.

`Test-RsPiiGuards` cambia de fuente de verdad: `-ManifestPath` (el `plugin.json`) manda, y
`settings.json` se mira solo para listar los restos. `check_env` gana `pii.guards_legacy` y
`pii.guards_source` (`plugin` | `settings`), y `guards_note` deja de hablar de `settings.json`:
`guards_registered` describe la **instalación**, `guards_active` si bloquea **en este workspace**.

## 3.3.0 — 2026-08-05

### Las guardas PII siguen al modo del workspace

⚠️ **Cambio de comportamiento.** Hasta ahora las dos guardas `PreToolUse`, una vez registradas,
bloqueaban **siempre**: `sqlplus`/`sqlcmd` directos y la escritura de contenido con forma de dato
personal, en cualquier proyecto del ordenador y con el workspace en el modo que fuera. Viven en
`~/.claude/settings.json`, que es configuración personal, así que su alcance era la **máquina**.

Desde esta versión siguen a `pii_policy.mode` del workspace al que pertenece cada operación:

| Situación | Guarda |
|---|---|
| Fuera de un workspace uCollect/RS | inactiva |
| Dentro, `mode = off` | inactiva |
| Dentro, `mode = audit` o `enforce` | **actúa** |
| Dentro, modo **indeterminado** (política declarada que no se puede leer) | **actúa** |

**Qué cambia para quien ya las tenga registradas:** en un workspace en `off` —el estado por defecto,
y hoy el de todos— **dejan de bloquear** al actualizar. Y dejan de bloquear también en el resto de
repos del usuario, que es lo que las hacía insostenibles: un `README` con la dirección de soporte
disparaba el patrón de correo en un proyecto que no tiene nada que ver con uCollect/RS.

La última fila de la tabla es la que sostiene el diseño: un modelo declarado y ausente, o una config
de BD ilegible, **no** degradan a "sin protección". Es el mismo criterio que ya aplica `db_query`,
que falla cerrado justo ahí. En `audit` las guardas bloquean aunque los datos aún salgan en claro:
es la fase en la que se mide un workspace que va a protegerse, y es cuando menos interesa que se
coja la costumbre de rodear la herramienta.

Con **varias conexiones** manda la más restrictiva. La guarda de Bash no puede saber a qué BD apunta
un comando, así que un workspace con PROD en `enforce` y DEV en `off` bloquea igual.

Cada guarda resuelve el workspace por la señal que tiene: la de escritura desde el `file_path` del
evento —manda el **destino**, no la sesión: si escribes en un workspace en `enforce` desde una sesión
abierta en uno en `off`, bloquea—, y la de Bash desde el `cwd`, que es lo único que trae. Corolario
que se documenta en §5.2b: un comando lanzado desde el workspace A contra la BD del B se mide con el
modo de A. Sigue siendo un guardarraíl, no una frontera.

**El coste se midió antes de elegir.** Esto corre en cada `Bash` y cada `Write`, y el modelo BD pesa
entre 288 KB y 664 KB. Sobre un modelo de 1,3 MB: **12 ms** leyendo el modo con una regex contra
**135 ms** con `ConvertFrom-Json` (×11), y en Windows PowerShell 5.1 la diferencia es mayor. Se lee
con regex. La contrapartida —que la regex no entienda una forma que el parser sí— se cubre por dos
lados: "hay bloque `pii_policy` y no consigo leer el modo" **no** degrada a `off` sino a
indeterminado (o sea, bloquea), y `check_env` contrasta la lectura rápida con el parseo completo que
ya hacía y publica `pii.mode_mismatch` si divergen.

`check_env` gana `pii.guards_active`: registradas y actuando son cosas distintas y se informan por
separado. `/rs-pii off` sigue sin desregistrar las guardas — ya no hace falta para dejar de bloquear
aquí, y quitarlas apagaría los workspaces que sí las necesitan.

## 3.2.2 — 2026-08-05

### Una guarda PII registrada con la ruta rota se contaba como protección

`Test-RsPiiGuards` verificaba que las dos guardas estuvieran bajo `hooks.PreToolUse` con un matcher
que dispare, pero **no que el `.ps1` al que apuntan exista**. Y la ruta va cableada en absoluto,
porque `${CLAUDE_PLUGIN_ROOT}` solo se expande en `.claude-plugin/plugin.json` y `.mcp.json` — en
`~/.claude/settings.json` llega literal. Basta con que el plugin cambie de sitio (reinstalación,
otra ruta de caché, otro perfil, un checkout movido) para que la entrada apunte a un fichero que ya
no está: Claude Code lanza el hook, `powershell` sale con error, y ese código **no es 2**, el único
que bloquea. La guarda falla **abierta** mientras `check_env` seguía devolviendo
`guards_registered = true` y `pii.ok = true`.

Es el mismo desenlace que ya corrigió el paso de `-match` sobre el texto a comprobación estructural
—«un workspace que cree estar protegido sin estarlo es peor que uno que sabe que está en `off`»—,
pero por una vía que no exige que nadie haga nada mal.

Ahora **registrada ≠ efectiva**: una entrada cuyo `.ps1` no se puede verificar cuenta como ausente.
Tres motivos, todos con la ruta en el mensaje:

| Situación | Veredicto |
|---|---|
| El fichero no existe | no efectiva — `el fichero no existe` |
| La ruta lleva `${...}`, `%VAR%` o `$env:VAR` sin expandir | no efectiva — `la ruta lleva una variable sin expandir` |
| La ruta es relativa (se resolvería contra un cwd que no se conoce) | no efectiva — `la ruta es relativa y no se puede verificar` |

Si hay **varias** entradas de la misma guarda y una de ellas sí es válida, la guarda protege y no se
reporta como rota: reinstalar deja restos, y lo que importa es que alguna dispare.

`check_env` gana `pii.guards_stale` (guardas registradas que no protegen) y `pii.guards_foreign`
(guardas que **sí** protegen, pero desde otra copia del plugin — la copia vendorizada de la v2.11.0,
que no se actualiza con `/plugin marketplace update`). `guards_stale` se avisa **en cualquier modo,
también en `off`**: las guardas no dependen de `pii_policy.mode`, así que una entrada muerta deja ese
bypass abierto siempre. Con `enforce` sale además por `pii.ok = false`. `guards_foreign` no invalida
el registro — esa copia protege — pero se dice.

`/rs-pii enforce` pasa a **sustituir** la entrada que apunte a otra ruta en vez de añadir una
segunda: dos entradas de la misma guarda no protegen más, y la muerta seguiría fallando en cada
llamada.

`tests/PiiGuard.Tests.ps1` se reescribe para fabricar guardas de mentira en ficheros **reales** —con
las rutas inventadas de antes los casos existentes ya no medirían lo que creen— y añade los seis
casos nuevos, incluido el de las dos entradas donde la buena rescata a la rota.

## 3.2.1 — 2026-08-04

### `/rs-word`: el documento salía con la tipografía de la plantilla perdida

Comparando la salida del hook con el mismo documento maquetado a mano sobre la misma plantilla, el
hook reconocía todas las construcciones del Markdown pero las escribía como `Normal` con formato
manual: 0 párrafos de lista, 0 preformateado y 0 estilos de tabla frente a 10 / 5 / 22 del maquetado
a mano. Cinco correcciones sobre `hooks/render-word.ps1`:

- **Título duplicado.** Con `-Title` la portada ya lleva el título; volcar además el `#` del
  Markdown lo repetía y hundía un nivel todo el documento (`##` acababa en Título 2 y el índice
  salía con un solo `TDC 1`). Con **un solo origen y `-Title` explícito** se omite el `#` y los
  niveles suben uno (`##` → Título 1). Con **varios orígenes** cada `#` es un capítulo distinto y
  la correspondencia anterior se mantiene. Además, si la plantilla trae varios párrafos con estilo
  Title en la portada (uno vacío de separación), ahora se sustituye solo uno.
- **Viñetas** → estilo built-in de lista (`wdStyleListBullet`), sin el carácter `•` literal ni
  sangría manual. Los niveles anidados usan las variantes profundas (`ListBullet2`...).
- **Listas numeradas** → estilo built-in (`wdStyleListNumber`), sin el `1.` literal: numera Word.
  Word encadena la numeración de todas las listas que comparten estilo, así que al cerrar cada
  bloque se reaplica su plantilla de lista con `ContinuePreviousList=$false` sobre un rango
  colapsado en el primer párrafo: dos listas independientes vuelven a empezar en 1 y los niveles
  anidados (2.1, 2.2) se respetan.
- **Bloques fenced** → estilo built-in preformateado (`wdStyleHtmlPre`) en vez de `Normal` con
  Consolas y sangría a mano.
- **Tablas.** Las tablas generadas y la fila rellenada del historial reciben los estilos de párrafo
  de tabla de la plantilla (cabecera y cuerpo); si la plantilla no los trae se cae a `Normal` con
  el formato manual de antes. Del historial se borran las filas de relleno no usadas (7 → 2).

Efecto colateral necesario: una línea sangrada que continúa un ítem de lista ya no se escribe como
párrafo suelto, se concatena al ítem — si no, cada línea partía el ítem, el bloque numerado se
cerraba en cada una y **todos** los ítems salían "1.".

Los tres primeros estilos son **built-in de Word y se resuelven por ID numérico**, nunca por nombre
local: el hook sigue funcionando con Word en cualquier idioma y con cualquier plantilla. Solo los
dos estilos de tabla se buscan por nombre, porque los define la plantilla, y degradan a `Normal`.

`tests/RenderWord.Tests.ps1` (nuevo) se fabrica su propia plantilla `.dotx` con Word en el
directorio temporal — la plantilla corporativa es material de marca y no se versiona — y comprueba
estilos, numeración reiniciada, ausencia de título duplicado y borrado de filas del historial. Sin
Word instalado el fichero entero se salta.

## 3.2.0 — 2026-08-04

### `/rs-word`: la documentación del `agentic_manual` sale a Word con la plantilla del cliente

El manual agentic vive en Markdown, pero lo que se entrega a operación y a negocio es un documento
formal con la plantilla corporativa. Ese paso se hacía a mano. Ahora es una tool.

**`hooks/render-word.ps1`** (nuevo) convierte uno o varios `.md` a un `.docx` sobre una plantilla
`.dotx` **del workspace del cliente** — ⛔ la plantilla no se versiona en el plugin: es material de
marca. Si no se pasa `-Template`, autodetecta el primer `*.dotx` de `<workspace>\docs`.

Sobre la plantilla hace: portada (`-Title`/`-Objeto`), historial de cambios (`-Autor`/`-Version`),
borrado del contenido de ejemplo y actualización del índice. Cada `.md` es un capítulo; su `#` pasa
a Título 1 y el resto de niveles baja en consecuencia. Convierte tablas Markdown a tablas Word con
cabecera repetida entre páginas, bloques ` ``` ` a párrafos monoespaciados, y `**negrita**` /
`` `código` `` a formato real (Find con comodines, patrón `[!x]@` para no comerse varias ocurrencias
de la misma línea).

Cuatro cosas que costaron un fallo real y quedan fijadas en el código:

- `Documents.Add(tpl, $false, 0, $true)` — el 4.º argumento (Visible del **documento**) debe ser
  `$true`. Con `$false` no hay ventana de documento, `$word.Selection` es `null` y no se puede
  escribir una línea. La aplicación sigue oculta por `$word.Visible = $false`.
- Si la plantilla ya trae un campo `TOC`, sus párrafos son **resultado de campo**: rango de solo
  lectura. Borrarlos o insertar otro TOC da "No se puede modificar el rango". Solo se hace
  `TablesOfContents.Item(1).Update()` al final.
- Los estilos se resuelven por **ID built-in** (`wdStyleHeading1 = -2`, `Title = -63`,
  `Subtitle = -75`), no por nombre local: con nombres en español el hook se rompe contra una
  instalación de Word en otro idioma. La portada también se localiza por estilo, no por el texto
  literal del placeholder.
- El `.ps1` va en **UTF-8 con BOM**, como `check-env.ps1`/`db-query.ps1`. Sin BOM, Windows
  PowerShell 5.1 lo lee como ANSI y los acentos dentro de literales lo tumban en tiempo de parseo.

**Tool `render_word`** en `mcp/rs-workspace-server.py` (46 → **47 tools**), fallback 1:1 del hook,
junto a `render_erd`/`render_dashboard`/`render_help`: devuelve `{path, pages, tables, warnings}` y
**no** carga el documento en contexto.

**Modo directo `/rs-word`** (`agents/rs-word.md` + `commands/rs-word.md`, ⚡ haiku): resuelve qué
`.md` entran y en qué orden — y **pregunta** en vez de convertir el manual entero por iniciativa
propia.

**`agents/rs-runbook.md`** gana una Fase 5 opcional: tras persistir el runbook, ofrece generarlo en
Word con `strip_marks=true`, que retira las marcas de procedencia `✅`/`👤` (en celda de tabla que
quede vacía escribe "Código"/"Operación", para no dejar huecos). El `.md` las conserva; el
entregable no las necesita. Las secciones `PENDIENTE DE CONFIRMAR` **sí** se mantienen: un
entregable que oculta sus huecos es peor que uno que los enseña. Se ofrece, no se ejecuta solo — el
`.md` es el artefacto canónico y el Word envejece en cuanto el runbook cambia.

**`hooks/check-env.ps1`** añade el check *Microsoft Word* (informativo): sin Word por COM la
conversión no es posible y **no hay alternativa** — el plugin no usa pandoc ni python-docx.

Limitación conocida y documentada en la cabecera del hook: el formateo inline se aplica con `Find`
sobre todo el documento, así que un bloque de código con `**` o backticks sueltos puede verse
reformateado.

## 3.1.0 — 2026-08-04

### Un modelo BD declarado y ausente ya no devuelve las filas en claro

Si una conexión de `docs/.rs-databases.json` **declara** su modelo (campo `"model"`) y ese
fichero no existe, la tool MCP `db_query` cargaba un modelo vacío, concluía `pii.mode = "off"`
y devolvía el resultado íntegro **en claro**, etiquetado como workspace sin política —
indistinguible de uno que nunca configuró nada. El hook `hooks/db-query.ps1` ya fallaba cerrado
ahí, así que los dos caminos discrepaban justo en el que es principal.

Ahora los dos aplican la misma regla:

| Situación | Comportamiento |
|---|---|
| Modelo **declarado** y el fichero no existe | `success: false`, cero filas, y el mensaje dice qué fichero falta y cómo generarlo (`/rs-init` en un workspace nuevo, `/rs-erd` para sincronizarlo desde la BD) |
| Modelo del **convenio** (`BD\<proyecto>-model.json`) y el fichero no existe | Sin cambios: la consulta corre, `pii.mode = "off"`, datos en claro |
| El fichero existe pero no se puede usar (ilegible, JSON inválido, raíz que no es objeto) | `success: false`, cero filas, venga de donde venga la ruta |

`Get-RsModelPath` devuelve **siempre** una ruta, así que `model_path` no distinguía las dos
primeras filas. Esa distinción la publica ahora quien ya resuelve la ruta:
`Test-RsModelDeclarado` (`hooks/lib-dbconfig.ps1`) → `hooks/get-config.ps1` la emite como
`model_declarado`, por conexión y en los campos planos. La tool MCP la lee de la config y el
hook se la pasa a `scripts/pii_cli.py` con `--convenio`. Sin esa información se asume
**declarado**: la imprecisión degrada hacia más enmascarado, nunca hacia menos.

En la tool MCP el modelo se carga **antes** de tocar la BD: si la política no se puede aplicar,
la consulta ni siquiera se ejecuta.

**Qué cambia para un workspace que actualiza.** Nada, salvo que ya tenga un modelo declarado y
perdido —en cuyo caso estaba enviando datos personales en claro sin saberlo—. Un workspace que
nunca declaró modelo sigue exactamente igual que en 3.0.0.

`get_table_schema`, `search_model` y `get_model_index` leen el mismo `model_path` y **no**
cambian: siguen devolviendo su propio "Modelo BD no encontrado".

### `db_query` (hook) ya no puede devolver `pii = null`

En `hooks/db-query.ps1`, el parseo de la respuesta de `pii_cli` quedaba fuera del `try/catch`
que envuelve la invocación. Un CLI que saliera con código 0 pero emitiera algo no parseable
dejaba la respuesta con `ok = true`, columnas y filas vacías y `pii = null`. No se escapaba
ninguna fila, pero once definiciones de agente tienen instrucción de leer ese bloque. Ahora una
salida no parseable —o un JSON válido sin bloque `pii`— se trata como el resto de fallos del
filtro que ya corrió: sin filas y con `pii.error` explicando el motivo.

### Codificación UTF-8 explícita en todo el camino de protección de datos personales

- `scripts/pii_cli.py` escribía `stdout` con la codificación por defecto del proceso. Como su
  salida es un *pipe* y no una consola, en un Windows con configuración regional española eso
  es cp1252, mientras el hook la descodifica como UTF-8: los acentos volvían destrozados y un
  carácter fuera de cp1252 mataba el filtro con `UnicodeEncodeError` **después** de emitir JSON
  a medias (que es justo el caso del apartado anterior). `stdout` y `stderr` pasan a UTF-8.
- Las guardas `pii-guard-bash.ps1` / `pii-guard-write.ps1` reciben el evento en UTF-8 por
  `stdin`, pero PowerShell lo descodifica con la página de códigos OEM: la ruta y el contenido
  con acentos salían destrozados en el mensaje de bloqueo. No se dejaba de bloquear nada (los
  patrones son ASCII), pero el texto que lee el usuario estaba mal. `Repair-RsTextoUtf8`
  (`hooks/lib-pii.ps1`) deshace esa descodificación y es idempotente sobre un texto ya correcto.
- `hooks/db-query.ps1` volcaba la salida de `sqlplus` con `>`, cuya codificación por defecto es
  UTF-16LE en Windows PowerShell 5.1 y UTF-8 en PowerShell 7; se leía de vuelta como UTF-8 y
  funcionaba por la detección de BOM, no porque coincidieran. Ahora es explícita.

El fichero `.sql` que lee `sqlplus` sigue escribiéndose en **UTF-8 sin BOM** a propósito, y la
`stdin` de `pii_cli` sigue leyéndose como `utf-8-sig`. Ninguna de las dos cosas cambia.

## 3.0.0 — 2026-08-03

### Protección de datos personales en las consultas a BD

`db_query` (tool MCP y hook) enviaba al contexto de la conversación el resultado íntegro
de cada consulta, incluidas columnas con nombres, DNI, teléfonos y cuentas. Ese contexto
se transmite a un proveedor externo. No había ningún filtro entre la BD y el envío.

Ahora los valores de las columnas con datos personales se sustituyen por un seudónimo
determinista (`pii:3f9a2c1b40de`) calculado con HMAC-SHA256 y una clave que vive en el perfil
local del usuario, fuera del repositorio. El mismo valor produce siempre el mismo
seudónimo, de modo que se conserva la capacidad de detectar duplicados y correlacionar
filas sin exponer el dato.

**Arranca apagado.** `pii_policy.mode` vale `off` mientras no se declare otra cosa, así
que un workspace que actualice sigue viendo los resultados de `db_query` igual que antes.
`/rs-pii` gestiona la transición `off` → `audit` → `enforce` con `status`, `bootstrap`,
`audit`, `enforce` y `off`.

Dos cosas **sí** cambian aunque el modo sea `off`, a propósito, porque no dependen de la
política del workspace: `hooks/log-execution.ps1` sanea siempre el texto que persiste en
`executions/history.json` (una descripción de tarea con un DNI/NIE válido, un IBAN o un
correo se guarda con `[PII]` en su lugar), y las guardas `PreToolUse`, si están
registradas, bloquean siempre `sqlplus`/`sqlcmd` directos y la escritura de datos
personales en ficheros. Ninguna de las dos afecta a lo que devuelve una consulta.

Qué se considera dato personal, por orden de precedencia: la marca `"pii"` / `"safe"` de
la columna en el modelo; el patrón del nombre (`TELEFON*`, `DNI*`, `*IBAN*`…); si la
tabla es paramétrica (`subviews["Parametricas"]`, la misma lista que usa el instalador);
el tipo (numérico, fecha, PK y FK salen en claro); y por defecto, el texto se enmascara.

Una columna que no resuelve contra el modelo — un alias, una expresión — se decide por la
forma de sus valores, con una prueba numérica **estricta**: rechaza el signo `+`, la
notación `inf`/`nan`, los separadores de miles con guion bajo (`1_000`), y cualquier
entero de **9 o más dígitos sin parte decimal** — la forma de un teléfono, una cuenta, un
contrato o una tarjeta, aunque en teoría pudiera ser un agregado real por encima de
99.999.999. Una muestra completamente vacía también se enmascara, no sale en claro. Así
`SELECT COUNT(*) AS TOTAL` sigue siendo útil y `SUBSTR(DNI,1,8) AS X` no.

Un detector por forma de valor (DNI, NIE, IBAN, correo, teléfono, tarjeta) corre sobre lo
que sale en claro y avisa cuando encuentra algo: es la señal de que la lista de patrones
de nombre está incompleta, y en `enforce` esa columna se tapa igualmente. Las formas
fuertes (DNI, NIE, IBAN, correo) bastan con un acierto; las débiles, puramente numéricas
(teléfono, tarjeta, DNI sin letra), exigen **mayoría estricta — al menos el 50% de los
valores no vacíos de la columna** — para no disparar por un importe suelto que parezca un
teléfono. Si `scripts/pii_patterns.json` no se puede leer, la lista de patrones de nombre
falla **cerrada**: pasa a ser `["*"]`, que enmascara toda columna, en vez de abrirse en
silencio y dejar pasar texto claro sin ningún aviso.

La extracción de tablas del SQL (`scripts/pii_sqlscope.py`) elimina antes los comentarios
(`--`, `/* */`) con un escáner que respeta los literales de cadena; un literal sin cerrar
(SQL malformado) hace que no se resuelva ninguna tabla — el alcance indeterminable
degrada hacia el lado seguro (todo sin resolver, todo enmascarado por forma de valor),
nunca al revés.

**El guardarraíl de escritura no usa los mismos patrones que el detector de columnas, a
propósito.** `hooks/pii-guard-write.ps1` excluye teléfono y tarjeta: un número suelto de
nueve, o de trece a diecinueve dígitos, casa con importes, identificadores de fila y
timestamps, y una guarda que salta constantemente se acaba desactivando — entonces no
protege nada. Mantiene DNI, NIE, IBAN y correo, y **valida la letra de control** de
DNI/NIE en vez de bastarle la forma (el repositorio está lleno de cadenas `AAAAMMDD` de
`Actualizador\<ENTORNO>_<AAAAMMDD>` que casan "8 dígitos + letra" por casualidad). El
detector de columnas de `scripts/pii_detect.py`, en cambio, mantiene las seis formas: ahí
el contexto ya se sabe que es dato de un resultset, no texto libre del repositorio.
`hooks/lib-pii.ps1` es nuevo — los patrones compartidos y el validador de letra de
control, dot-sourced por `pii-guard-write.ps1` y por `log-execution.ps1` (mismo patrón que
`hooks/lib-dbconfig.ps1`) — para que esta regla de detección no pueda divergir en dos
sitios.

`db_query` (tool MCP) gana `pii.model_error`: si el fichero de modelo existe pero no se
puede parsear o su raíz no es un objeto JSON, el dato vuelve **sin enmascarar** con un
diagnóstico visible que nombra el fichero, en vez de que la tool reviente o falle en
silencio.

`hooks/db-query.ps1` cambia la forma de su respuesta: ahora emite `columns` más `rows`
como arrays de valores, igual que la tool MCP, tanto en el camino con filas como en el de
"sin filas". El eco del SQL sustituye sus literales de cadena en todas las salidas.
Delega el enmascarado en `scripts/pii_cli.py`, al que le pasa el `model_path` de la
conexión seleccionada (`Get-RsModelPath` de `hooks/lib-dbconfig.ps1`, la misma resolución
que alimenta a la tool MCP). Falla **abierto** a propósito solo cuando el filtro no se
puede ni ejecutar —falta `python` o falta el fichero—: ahí el dato vuelve sin tocar con
`pii.error` puesto, porque es el camino de fallback y un filtro que bloquea cada consulta
empuja a la gente a `sqlplus` directo, que es peor. Si el filtro **sí corre** y falla, se
falla **cerrado**: `success: false`, `pii.error` y cero filas — tenía los datos en la mano
y no pudo aplicarles la política.

Se añaden dos guardas `PreToolUse` — `hooks/pii-guard-bash.ps1` impide invocar
`sqlplus`/`sqlcmd`/`osql`/`bcp`/`sqlldr`/`impdp`/`expdp` saltándose `db_query`,
`hooks/pii-guard-write.ps1` impide escribir datos con forma personal en ficheros — y
`log-execution.ps1` sanea el texto de la tarea antes de persistirlo en `history.json`.

`/rs-pii` gestiona `status`, `bootstrap`, `audit`, `enforce` y `off`. `bootstrap` se niega
a ejecutar bajo `enforce` (las muestras ya llegarían enmascaradas y el inventario saldría
vacío o falso) y nunca imprime un valor muestreado. `enforce` no cambia el modo sin antes
registrar las guardas y confirmar vía `check_env` que quedaron registradas — un workspace
que cree estar protegido sin estarlo es peor que uno que sabe que está en `off`. Esa
confirmación es **estructural** (`Test-RsPiiGuards` parsea `settings.json` y exige entradas
reales bajo `hooks.PreToolUse` con un matcher que dispare; `check_env` devuelve
`guards_missing` diciendo cuál falta), y comprueba el **fichero, no la sesión**: Claude Code
captura la configuración de hooks al arrancar, así que unas guardas registradas a mitad de
sesión no están vivas hasta reiniciar. Por eso `enforce` cierra pidiendo el reinicio en vez
de declarar la protección activa. La clasificación de columnas que hace `bootstrap` sale de
`scripts/pii_cli.py --clasificar`, el mismo motor que aplica `db_query`, y no de las reglas
reescritas en el prompt: el inventario que produce tiene que coincidir con lo que el plugin
enmascara de verdad.

`check_env` gana un bloque `pii`: `mode`, `guards_registered`, `ok` y `error` cuando no
está `ok`. `ok` es falso únicamente cuando el modo es `enforce` y faltan las guardas.

**Versión mayor** porque `db_query` añade la clave `pii` a su respuesta, porque el hook
cambia por completo la forma de la suya, y porque existe un modo (`enforce`) capaz de
alterar los valores devueltos.

**Límites, documentados en `docs/proteccion-pii-consultas-bd.md` §5:** el filtro actúa
DESPUES de que el dato salga del motor; el bloqueo de `sqlplus` es un guardarraíl y no un
control; filtrar por una columna enmascarada en el `WHERE` permite inferir su valor; y un
seudónimo sigue siendo dato personal a efectos del RGPD. El control efectivo es que la BD
no emita el dato — §3 de ese documento recoge la petición a Sistemas.

Ficheros tocados: `scripts/pii_detect.py`, `scripts/pii_sqlscope.py`, `scripts/pii_policy.py`,
`scripts/pii_mask.py`, `scripts/pii_cli.py`, `mcp/rs-workspace-server.py`,
`hooks/db-query.ps1`, `hooks/pii-guard-bash.ps1`, `hooks/pii-guard-write.ps1`,
`hooks/lib-pii.ps1`, `hooks/log-execution.ps1`, `hooks/check-env.ps1`, `agents/rs-pii.md`,
`commands/rs-pii.md`, `docs/proteccion-pii-consultas-bd.md`.

## 2.31.0 — 2026-08-03

### Security: cifrado en reposo (DPAPI) de los secretos en texto plano

Hasta ahora los tres secretos del plugin vivían en **texto plano** en disco: el password de BD (en
`docs/.rs-databases.json`, dentro de `cadena`) y los tokens de Jira y Mantis (en `~/.claude/`). Esta
versión añade **cifrado en reposo con DPAPI** (Windows Data Protection API), ligado a la cuenta de
Windows del usuario.

- **Helper compartido** `hooks/lib-crypto.ps1` (`Protect-RsSecret`/`Unprotect-RsSecret`/`Test-RsEncrypted`,
  DPAPI `CurrentUser`) + su espejo en Python `_unprotect_secret` (ctypes `CryptUnprotectData`, sin
  dependencias) en `mcp/rs-workspace-server.py` y `scripts/installer-inserts.py`. Mismo blob DPAPI en
  ambos lenguajes → un secreto cifrado en PowerShell se descifra en Python y viceversa (nota de paridad).
- **Formato `enc:<base64>`** con **retrocompatibilidad total**: los lectores tratan cualquier valor SIN
  el prefijo `enc:` como texto plano (legacy). Ficheros sin migrar siguen funcionando; la migración es
  opcional y gradual.
- **Descifrado al vuelo** en todos los lectores: password BD en `hooks/lib-dbconfig.ps1` (dot-source de
  lib-crypto) aplicado en `db-query.ps1`, `compare-model.ps1`, `sync-from-db.ps1`, `sync-model-tables.ps1`,
  `sync-indexes.ps1`, y en Python `_get_db_password` / `_read_password`; token Jira en `jira-attach.ps1`
  y `jira-download.ps1`; token Mantis en `lib-mantis.ps1` (`Get-MantisCreds`).
- **`/rs-cifrar`** (`rs-cifrar`, ⚡ Haiku) + hook `secure-credentials.ps1` + tool MCP `secure_credentials`:
  cifra in situ los tres secretos que encuentre, **idempotente**, **sin imprimir ningún valor**.
- **Tests**: `tests/test_mcp.py` (+3 casos de `_unprotect_secret`: passthrough de texto plano, `enc:`
  exige Windows), `tests/Crypto.Tests.ps1` (nuevo: detección `enc:` + passthrough). **36 casos pytest
  en verde.** ⚠️ El **roundtrip DPAPI real es Windows-only** — no se puede ejercitar en el CI (Ubuntu);
  se verifica manualmente en Windows.

**Límites de DPAPI (documentados):** el secreto cifrado solo lo descifra la **misma cuenta de Windows en
la misma máquina** (al migrar de equipo/usuario hay que re-introducir y re-cifrar); protege frente a copia
del fichero o a otro usuario del equipo, **no** frente a código ejecutado como el propio usuario. El
password sigue escribiéndose en claro en el `.sql` temporal del `CONNECT` de Oracle (follow-up aparte).

**MCP 45 → 46 tools** (`secure_credentials`); **hooks +`lib-crypto.ps1` +`secure-credentials.ps1`**;
**agentes 48 → 49; comandos 46 → 47.** Ficheros: `hooks/lib-crypto.ps1`, `hooks/secure-credentials.ps1`,
`agents/rs-cifrar.md`, `commands/rs-cifrar.md`, `mcp/rs-workspace-server.py`, `scripts/installer-inserts.py`,
`hooks/lib-dbconfig.ps1` + 5 lectores BD, `hooks/jira-attach.ps1`, `hooks/jira-download.ps1`,
`hooks/lib-mantis.ps1`, `skills/rs-enterprise-agent/SKILL.md`, `tests/`, `references/`, README, bump.

## 2.30.0 — 2026-07-31

### Security: inyección de comandos, password fuera de argv y guarda SQL más robusta

Endurecimiento de rutas ya vivas del pipeline (hallazgos de auditoría interna). Sin cambios de
superficie: mismos agentes/comandos/tools/hooks.

- **Inyección de comandos vía `Invoke-Expression`** (`hooks/compile-check.ps1`,
  `hooks/test-runner-check.ps1`): se construía `"dotnet build \"$SlnPath\" ..."` y se ejecutaba con
  `Invoke-Expression`; una `.sln` con `"` en la ruta podía romper el quoting e inyectar comandos.
  Ahora se usa el **operador de llamada con array de argumentos** (`& dotnet @args`), donde `$SlnPath`
  va como un argumento literal. El CI (`PSScriptAnalyzer`) pasa a **gatear** la regla
  `PSAvoidUsingInvokeExpression` para que el patrón no se reintroduzca.

- **Password de BD fuera de la línea de comandos** (`hooks/sync-model-tables.ps1`,
  `hooks/sync-from-db.ps1`, `scripts/installer-inserts.py`): `-P <password>` quedaba visible en la
  lista de procesos durante toda la ejecución. Ahora se pasa por la variable de entorno
  `SQLCMDPASSWORD`, mismo patrón que ya usaba la tool MCP `db_query`.

- **Guarda SQL read-only más robusta** (`mcp/rs-workspace-server.py`, `hooks/db-query.ps1`): la
  validación (SELECT/CTE, sin multi-statement ni verbo de escritura) no quitaba los comentarios SQL
  antes de contar `;` / buscar verbos, lo que provocaba **falsos positivos** (un `;` dentro de un
  comentario bloqueaba una query legítima) y dejaba la guarda menos sólida. Se extraen dos helpers
  puros y **testeables** en el MCP (`_strip_sql_comments`, `_is_readonly_sql`), replicados en el hook
  (`Remove-SqlComments`) — con nota de paridad. La ejecución sigue usando el SQL original (los
  comentarios son inocuos para el cliente BD).

- **Tests** (suite existente de 2.21.0): `tests/test_mcp.py` añade 18 casos de
  `_is_readonly_sql`/`_strip_sql_comments` (comentarios, literales, multi-statement, CTE con verbo);
  `tests/DbQuery.Tests.ps1` añade que un `;` comentado ya no es falso positivo y que un comentario no
  oculta un verbo. **33 casos pytest en verde** (15 previos + 18 nuevos).

- **Compat `mcp<2` en `requirements.txt`**: el major `mcp 2.0.0` eliminó `mcp.server.fastmcp`, así que
  `mcp>=1.2.0` sin tope arrastraba 2.x y rompía el import de FastMCP tanto en el **runtime del server**
  como en el CI. Se acota `mcp>=1.2.0,<2` (el plugin usa la API FastMCP de la línea 1.x).

Ficheros: `hooks/compile-check.ps1`, `hooks/test-runner-check.ps1`, `hooks/sync-model-tables.ps1`,
`hooks/sync-from-db.ps1`, `scripts/installer-inserts.py`, `mcp/rs-workspace-server.py`,
`hooks/db-query.ps1`, `.github/workflows/ci.yml`, `tests/test_mcp.py`, `tests/DbQuery.Tests.ps1`,
`requirements.txt`, bump de versión.

> Follow-up documentado (fuera de alcance de esta versión): password en claro en el fichero temporal
> `.sql` de la rama Oracle (`CONNECT user/pass@ds`) — inherente al patrón `sqlplus /nolog`, requiere
> rediseño mayor; y el rendimiento de `security-scan.ps1` (relee ficheros por patrón).

## 2.29.0 — 2026-07-31

### `/rs-instalador`: la fila base de `RVERSIONES` la genera el hook, y las paramétricas por fin se ejecutan

Tres cosas del paquete de instalación limpia ya existían (`Instalar.ps1` parametrizado por el bloque
`entornos` del JSON de config, `Ejecutar-Scripts.ps1` y el DDL de `RVERSIONES`), pero el **primer
registro** de `RVERSIONES` lo redactaba el modelo a mano en el PASO 7 del agente. Si ese paso se
saltaba, la entrega salía sin fila base y el primer `/rs-actualizador` de ese entorno se quedaba sin
`FECHA_CORTE` de partida. Ahora es determinista.

**`hooks/instalacion-paquete.ps1`** gana el parámetro `-Soluciones` (lista `;`-separada; si se omite
se deduce de `batch` + `agendaweb` + `servicemanager.modulos` del JSON) y, en modo `Instalacion`,
genera `Scripts\PorEntorno\99-RVERSIONES-<ENTORNO>.sql` — **uno por entorno declarado**, con el motor
de cada entorno (`entornos.<E>.bd.motor`, con el del proyecto como fallback):

- Oracle: bloque PL/SQL con `SEQ_RVERSIONES.NEXTVAL` y guarda `COUNT(*)` previo. No se usa
  `INSERT ... SELECT ... WHERE NOT EXISTS` porque `NEXTVAL` junto a una subconsulta da `ORA-02287`.
- SQL Server: `IF NOT EXISTS` + `INSERT` sin `ID_VERSION` (identity), separados por `GO`.
- Idempotente en ambos motores, y escrito en **UTF-8 sin BOM** (sqlplus interpreta el BOM como parte
  de la primera sentencia).

Un fichero por entorno en vez de un placeholder sustituido en ejecución: el DBA del cliente lee
exactamente el SQL que va a correr, y `Ejecutar-Scripts.ps1` lanza solo el del entorno pedido.

**`assets/instalacion/Ejecutar-Scripts.ps1`** pasa de una pasada alfabética a **tres tandas**:
(1) `.sql` de la carpeta, (2) `Inserts\*.sql`, (3) `PorEntorno\99-RVERSIONES-<Entorno>.sql`. La
tanda 2 arregla un agujero real: los inserts de tablas paramétricas viven en una subcarpeta y
`Get-ChildItem` iba **sin `-Recurse`**, así que **nadie los ejecutaba** — una instalación limpia
dejaba todas las paramétricas vacías. Las tandas 2 y 3 se saltan si su carpeta no existe (un
actualizador solo trae la 1), y los ficheros que empiezan por `_` se ignoran.

También se elimina una referencia colgante: `rs-instalador.md` documentaba y exigía como evidencia un
`Inserts\_run_all.sql` que **ningún hook generaba**. Lo sustituye la tanda 2, que funciona igual en
los dos motores sin depender de `@@` / `:r`.

Ficheros tocados: `hooks/instalacion-paquete.ps1`, `assets/instalacion/Ejecutar-Scripts.ps1`,
`agents/rs-instalador.md`, `references/actualizador.md`, `references/hooks.md`, `hooks/README.md`,
`docs/plugin-architecture.md`.

## 2.28.2 — 2026-07-30

### Fix: `vcs_delta` estaba roto en SVN — `{{fecha}}` no es escape en PowerShell

La rama SVN de `hooks/vcs-delta.ps1` construía el rango de revisiones con llaves dobles:

```powershell
$rango = "{{$($dDesde.ToString('yyyy-MM-dd HH:mm:ss'))}}:{{...}}"
```

`{{` escapa una llave en `String.Format` de C#, **no** en una cadena interpolada de PowerShell: ahí
sale literal. SVN recibía `-r {{2026-06-01 00:00:00}}:{{...}}` y abortaba con
`E205000: Syntax error in revision argument`, así que **toda** llamada a `vcs_delta` sobre un
workspace SVN fallaba — es decir, el cálculo del delta de `/rs-actualizador` no funcionaba en SVN
desde que se introdujo la tool en 2.28.0. La rama Git no estaba afectada (usa `--since/--until`,
sin llaves).

Ahora se emiten llaves simples y separador ISO `T` (`{2026-06-01T00:00:00}:{2026-06-30T00:00:00}`),
que es la sintaxis que documenta SVN para rangos por fecha. Verificado contra un working copy SVN
real: rango abierto y rango con `-Hasta` devuelven commits, ficheros con acción y tareas.

Ficheros tocados: `hooks/vcs-delta.ps1`.

## 2.28.1 — 2026-07-29

### Fix: el actualizador excluía de más — los `*.config` del binario sí son parte de la entrega

La regla de 2.28.0 ("en un actualizador no viaja ningún `*.config`") era incorrecta y peligrosa por su
cuenta: `RSProcIN.exe.config` y los `<dll>.config` llevan los **binding redirects**, y entregar la DLL
recompilada sin su `.config` alineado es exactamente el `FileLoadException` → `StackOverflowException`
que vigila el gate de binding redirects de `installer-batch.ps1`.

La exclusión pasa a ser de **configuración funcional del entorno del cliente**, no de extensión:

- `web.config` (a cualquier nivel de `AgendaWeb\`)
- el **`<proceso>.xml`** de cada batch — se identifica por coincidencia de nombre base con un `.exe`
  entregado (`rsprocin.exe` → `rsprocin.xml`)
- `appsettings*.json` (host y módulos net8)
- los wildcards que declare `excluirEntrega` en `docs\<proyecto>-instalador.json` (campo nuevo)

Los `.xml` de `Exes\` que **no** emparejan con ningún `.exe` se conservan y se avisa de ellos, para
que el mantenedor decida si son configuración (y los añada a `excluirEntrega`) en vez de perderlos en
silencio. El gate de `Instalar.ps1 -Modo Actualizacion` aplica el mismo criterio.

Ficheros tocados: `hooks/actualizador-build.ps1`, `assets/instalacion/Instalar.ps1`,
`agents/rs-actualizador.md`, `references/actualizador.md`, `references/hooks.md`, `hooks/README.md`,
`docs/plugin-architecture.md`, `README.md`.

## 2.28.0 — 2026-07-29

### Nuevo modo directo `/rs-actualizador` — entregas incrementales por entorno, con tabla `RVERSIONES`

`/rs-instalador` cubría la **instalación limpia**, pero no había forma de preparar una entrega
**incremental**: qué se ha tocado desde la última vez que se entregó a TEST, qué binarios llevar y
qué scripts SQL acompañan. Se hacía a mano, y lo que se olvida en ese proceso (una DLL compartida,
un script de una tarea) aparece como incidencia en el cliente.

**`rs-actualizador`** (opus) genera la entrega delta en
`C:\AIS\<Proyecto>\Actualizador\<ENTORNO>_<AAAAMMDD>\`:

1. Lee de **`RVERSIONES`** (BD de control) la `FECHA_CORTE` de la última entrega de cada solución en
   ese entorno. Sin fila previa → **pregunta** la fecha de partida; no la inventa.
2. Calcula el delta con la tool nueva `vcs_delta` (hasta hoy, o hasta la fecha de `--hasta`
   descartando desarrollos posteriores) y lo cruza con `get_scope` de cada solución para saber qué
   está realmente afectado.
3. ⛔ **Gate de alcance** (solución / última entrega / commits / tareas / artefacto) antes de compilar.
4. Empaqueta: `Exes\` (solo batch afectados), `AgendaWeb\` completa, `ServiceManager\Modulos\` con
   las DLL recién compiladas, `scripts\` con los `.sql` de las tareas Mantis/Jira citadas en los
   commits, y los inserts de registro (uno para el cliente, otro para nuestra BD de control).
5. Redacta la **descripción funcional** de la entrega desde los commits y **la hace confirmar** antes
   de escribirla: es lo que acaba viendo el usuario final en `RVERSIONES`, y no puede ser técnica.

**Tabla `RVERSIONES`** (DDL idempotente Oracle y SQL Server en `assets/instalacion/`): `ENTORNO`,
`SOLUCION`, `VERSION`, `FECHA_ENTREGA`, `FECHA_CORTE`, `DESCRIPCION`, `TAREAS`, `USUARIO`. El delta
parte de `FECHA_CORTE`, no de `FECHA_ENTREGA` — con `--hasta`, entregar desde la fecha de entrega
perdería los commits intermedios. Ninguno de los dos inserts se ejecuta solo: el modo avisa de que
sin ejecutar el local, el siguiente actualizador repetirá los mismos commits.

**Por qué Rebuild de la solución batch entera y no solo del `.csproj` tocado**: `Comun`/`BusComun`/
`RSModel` no tienen strong-name y el CLR enlaza por nombre simple — mezclar binarios de builds
distintos reproduce el `StackOverflowException` documentado en `installer-batch.ps1`. El mismo gate
de coherencia se aplica aquí.

**⛔ La configuración funcional del cliente no viaja** — `web.config`, el `<proceso>.xml` de cada
batch y `appsettings*.json` — con triple defensa: el hook los excluye y los lista,
`Instalar.ps1 -Modo Actualizacion` aborta si los encuentra, y los parámetros nuevos se documentan en
`readme.txt`. **Los `*.config` del binario sí viajan** (`RSProcIN.exe.config`, `<dll>.config`): llevan
los binding redirects y separarlos de sus DLL reproduce el `FileLoadException`.

### `/rs-instalador` también entrega el script de instalación

El instalador completo ganó la **etapa 6** (`instalacion-paquete.ps1`) y el paso 7 de cierre: además
de EXES/AgendaWeb/ServiceManager/Scripts, el paquete lleva ahora `Instalar.ps1`,
`Ejecutar-Scripts.ps1`, `rutas.json`, `readme.txt`, el DDL de `RVERSIONES` y el insert de la versión
base (sin él, el primer actualizador de ese entorno no tiene fecha de partida). El JSON de config
por cliente admite un bloque `entornos` con rutas de instalación y backup.

Las plantillas de instalación son **compartidas por los dos modos** y viven versionadas en
`assets/instalacion/` — la lógica de backup e instalación no la reescribe el modelo en cada entrega:

- `Instalar.ps1` — backup ZIP de cada carpeta destino antes de copiar; no toca la BD.
- `Ejecutar-Scripts.ps1` — segundo script, el único que escribe en BD: ejecuta los `.sql` en orden
  con fail-fast (sqlplus con `WHENEVER SQLERROR EXIT FAILURE`, o `sqlcmd -b`), pide confirmación y
  password por consola (nunca en el JSON).
- `rutas.json` — rutas de instalación por módulo y de backup, **una entrada por entorno**.

**Ficheros nuevos**: `agents/rs-actualizador.md`, `commands/rs-actualizador.md`,
`hooks/vcs-delta.ps1`, `hooks/actualizador-build.ps1`, `hooks/instalacion-paquete.ps1`,
`references/actualizador.md`, `assets/instalacion/*` (5 ficheros).
**Tool MCP nueva**: `vcs_delta(workspace, desde, hasta?, ruta?, limit?)` — delta de commits entre dos
fechas autodetectando SVN/Git, con los IDs de tarea Mantis/Jira citados y los ficheros tocados.

### Fix (doc): `jira_download` no estaba en el catálogo MCP

`references/mcp.md` documentaba 43 de las 44 tools reales — faltaba `jira_download`, que existe en el
server desde la integración Jira. Añadida su fila y reconciliados los contadores contra disco:
**45 tools**, **48 subagentes**, **42 modos directos** (46 slash commands − 4 que no son modos).

## 2.27.1 — 2026-07-29

### Fix (doc): conteo de modos directos descuadrado + `/rs-sync-indexes` huérfano en SKILL.md

README y `skills/rs-enterprise-agent/SKILL.md` no cuadraban, y cada uno fallaba hacia un lado.
Conteo reconciliado contra `commands/*.md`, que es la fuente real:

**45 slash commands − 4 que no son modos directos = 41 modos directos.** Los 4 excluidos:
`/rs-enterprise-agent` (pipeline principal), `/rs-tarea` (skill `rs-jira`), `/rs-mantis`
(skill `rs-mantis`) y `/rs-plugin-dev` (meta-desarrollo del plugin, no toca soluciones cliente).

- **README** decía 42 (+1) en dos sitios → **41**. Su catálogo de comandos sí estaba completo:
  lista los 45 sin faltar ninguno.
- **Tabla `# Modos directos` de SKILL.md** tenía 40 filas (−1): faltaba **`/rs-sync-indexes`**, que
  además **no aparecía ni una vez** en todo el SKILL.md. Efecto real: el comando solo se disparaba
  escribiendo el slash exacto — por lenguaje natural ("sincroniza los índices") el orquestador no
  tenía trigger que lo enrutara. Añadida su fila (→ `rs-editor-db-modeler`, igual que `/rs-erd`).
- **README** declaraba `agents/ 46 subagentes` → **47** (el conteo no se actualizó al añadir
  `rs-runbook` en 2.27.0).

Los tres números quedan verificados contra el disco, no estimados.

## 2.27.0 — 2026-07-29

### Nuevo modo directo `/rs-runbook` — runbooks operativos con entrevista

Hueco detectado en uso real: había que documentar **cómo se ejecuta** un proceso (una carga inicial
de históricos) más los **errores encontrados** en entorno de cliente, y ningún modo cubría eso.
`/rs-doc` documenta *la solución* derivándola del código; un runbook es un procedimiento de
operación cuyo valor está justo en lo que **no** está en el código: precondiciones, reglas que solo
aplican a esa operación, e incidencias vividas.

**`rs-runbook`** (sonnet) es el primer modo directo que **entrevista al usuario** como parte de su
proceso. Trabaja con dos fuentes que nunca se mezclan:

- **Código/BD** (las extrae él: flujo, tablas, parámetros, motor) → bloques marcados `✅ verificado
  en código` con `archivo:línea`.
- **Usuario** (se las pregunta: precondiciones, reglas de negocio de la operación, verificación
  post-carga, errores literales, rollback) → bloques marcados `👤 aportado por operación`.

⛔ Regla dura: sin una de las dos marcas, el bloque **no se escribe**. Los huecos quedan como
`⚠️ PENDIENTE DE CONFIRMAR`, nunca como suposición redactada como hecho — un paso inventado en un
runbook se ejecuta contra datos reales de cliente.

**Ruta canónica**: `docs/agentic_manual/funcional/OPERACION/<Proceso>.md`, hermana de `BATCH/` y
`ONLINE/`. Elegida dentro de `funcional\` porque `hooks/find-doc-section.ps1` la escanea en
**recursivo** → los runbooks quedan localizables por `find_doc_section` sin tocar el hook (una
carpeta `operacion/` colgando de la raíz de `agentic_manual` no se escanearía). ⛔ Explícitamente
**no** en `soluciones/<Sln>.md`: `/rs-doc` regenera ese fichero y lo sobrescribiría.

**Errores de entorno del cliente** (`NLS_LANG`, juego de caracteres, driver, permisos) le pasan a
todas las soluciones contra ese cliente: el agente los deja en el runbook **y además** emite
`TECNICA_PROPUESTA` hacia `tecnica/05_CONVENCIONES_BD.md` para confirmación humana — mismo patrón
que el objetivo 3 de `rs-documentar`, nunca escritura directa en `tecnica/`.

**Ficheros**: `agents/rs-runbook.md` (nuevo) · `commands/rs-runbook.md` (nuevo) ·
`skills/rs-enterprise-agent/SKILL.md` (fila en `# Modos directos` + tipo de doc nuevo en el mapa de
documentación) · `README.md` (tabla de comandos) · `docs/plugin-architecture.md` §4.
Sin cambios en MCP ni hooks.

## 2.26.5 — 2026-07-29

### Fix: `mantis-cli.ps1 advance` mandaba `status.name` como array anidado (HTTP 500)

Reportado por un agente en ejecución real: `advance` fallaba con **HTTP 500** en el primer paso, y
no era el 500 por rate de PATCH que documenta `references/mantis.md`.

**Causa** — `hooks/mantis-cli.ps1:207` envolvía el resultado con `@( )`:

```powershell
$path = @(Get-MantisAdvancePath $chainArr $cur $To)   # ⛔
```

`Get-MantisAdvancePath` ya devuelve un array vía **comma unario** (`return ,$result`). Sobre una
función que emite así, `@( )` **no aplana**: recoge el array como **un solo objeto** y lo anida, así
que `@(...).Count` vale **1 siempre** — para 0, 1 o 3 pasos. Tres fallos de la misma raíz:

1. **HTTP 500**: `foreach ($step in $path)` iteraba una vez con `$step` = el array entero, generando
   `{"status":{"name":["acknowledged","assigned","confirmed"]}}`.
2. **Saltos de estado**: un único PATCH en vez de uno por paso — justo lo que `advance` existe para
   evitar en un workflow encadenado sin saltos.
3. **Idempotencia rota**: `$path.Count -eq 0` nunca se cumplía → la rama `"ya en el estado destino"`
   era código muerto y se enviaba `{"status":{"name":[]}}`.

Los tests existentes pasaban en verde porque llamaban a la función **sin** `@( )`: cubrían la
función pura, no el contrato de consumo.

**Ficheros**: `hooks/mantis-cli.ps1` (quitado el `@( )` + comentario del porqué) ·
`hooks/lib-mantis.ps1` (contrato de consumo explícito junto al comma unario) ·
`tests/Mantis.Tests.ps1` (nuevo `Describe` de regresión: elementos `[string]` no anidados, body
PATCH con `name` string, `Count 0` en mismo estado, y guarda estática de que el fuente del CLI no
reintroduce el `@( )`) · `references/mantis.md` (distingue las **dos** causas de 500 en `advance`:
rate de PATCH vs `status.name` como array).

## 2.26.4 — 2026-07-28

### Fix (doc): corrige la nota errónea sobre `ENABLE_TOOL_SEARCH` de 2.26.2

La nota de instalación de 2.26.2 tenía la **semántica invertida**. Según la doc oficial de Claude
Code (context-window): los schemas de las tools MCP se **difieren por defecto** (tool-search bajo
demanda) — ese es ya el comportamiento de ahorro, sin configurar nada. `ENABLE_TOOL_SEARCH=auto`
**carga los schemas upfront** cuando caben en el 10% del contexto, y `=false` los carga todos:
**ambos deshacen el ahorro**. La recomendación correcta es **no** poner la variable. README corregido.

## 2.26.3 — 2026-07-27

### Perf: descriptions más cortas en los 7 agents de pipeline (coste fijo/sesión)

Las descriptions de los agents van **siempre** en el prompt (no se difieren como los tool-schemas).
Adelgazadas las de los **7 `rs-editor-*`** — `core`, `planner`, `validator`, `fixer`, `plan-check`,
`tester`, `build` — de ~2900 a ~1938 chars, conservando la señal que importa (nombre de stage, quién
invoca, read/write, "nunca por el usuario"). **Riesgo de routing nulo**: estos agents los invoca el
orquestador **por nombre** vía STAGES, no por match de description.

Excluido a propósito `rs-editor-db-modeler`: tiene **modo directo `/rs-erd`** → sí se enruta por
description, no se toca. Los modos standalone `/rs-*` tampoco se tocan (su description guía la
selección). Sin cambios de comportamiento.

## 2.26.2 — 2026-07-27

### Perf: caps de output faltantes + doc de tool-search (menos tokens/sesión)

- **`search_model`**: nuevo `max_results` (default 100) + flag `results_truncated`; una keyword amplia
  ya no vuelca todas las tablas coincidentes a contexto.
- **`security_scan`**: nuevo `max_findings` (default 50) + flag `findings_truncated`; los conteos por
  severidad (`critical`/`high`/`medium`/`low`/`total_findings`) siguen viniendo **completos** aunque
  se recorte el detalle. Cierra el hueco que quedaba en el camino de outputs (el resto de tools ya
  tenían cap: `db_query`, `find_symbol`, `search_code`, `compile_check`, `run_tests`, logs, diffs…).
- **README**: nota de que el MCP `rs-workspace` corre en **stdio** → los schemas de sus 44 tools se
  pueden **diferir** con `ENABLE_TOOL_SEARCH=auto`, quitando su coste fijo del prompt de cada sesión
  (no aplica el bug HTTP #40314). Es la mayor palanca de tokens y no requiere cambio de código.

## 2.26.1 — 2026-07-27

### Perf: `rs-mantis` — recorte de contexto en `list`/`create`

Optimización de tokens en el camino más caliente del cliente REST (`hooks/mantis-cli.ps1`):

- **`list`** ahora **proyecta** cada issue a `{ id, summary, status }` antes de emitir, en vez de
  volcar la issue completa (historial, `custom_fields`, notas, relaciones). La skill solo usa
  `id — resumen (estado)` para elegir en Fase 1a → ~10× menos JSON a contexto en proyectos con muchas
  issues. El detalle completo sigue disponible vía `get`.
- **`create`** deja de hacer eco de la issue completa (`issue`): la skill solo usa el `id`. Devuelve
  `{ success, id, handler }`.

Sin cambios de comportamiento en la skill. Detalle en `references/mantis.md`.

## 2.26.0 — 2026-07-27

### Fix + Feat: `rs-mantis` — rate de PATCH, handler siempre y proyecto sin asumir

- **Sensibilidad de rate en PATCH** (`hooks/mantis-cli.ps1`): la instancia objetivo devuelve HTTP 500
  ante `PATCH` consecutivos rápidos al mismo `/issues/{id}` — un `transition` aislado funciona, dos
  seguidos fallan. Nueva función `Invoke-MantisPatchRetry`: `Start-Sleep 800ms` **antes** de cada
  intento (cubre la pausa entre PATCH y la posterior al GET inicial) + retry ×3 con backoff ante
  5xx/no-2xx. La usan `advance` (cada paso de la cadena), `create` (follow-up de handler) y `assign`.
  Verificado: con la pausa pasa toda la cadena `new→acknowledged→assigned→confirmed`.
- **Toda issue creada queda asignada al usuario del token**: `create` hace el alta **sin** handler
  (Mantis lo rechaza en estado `new`) y lo fija con un `PATCH {handler:{id}}` tras crear (verificado
  200 sobre issue existente). Nuevo subcomando reutilizable **`assign -Id -Handler`**. `SKILL.md`
  Fase 1b resuelve `me` y pasa `-Handler <me.id>` en ambos submodos — cerrando el hueco de
  *crear-suelto*, que no avanza estado y dejaba la issue sin handler.
- **Fase 0 nunca asume el proyecto** (`SKILL.md`): 1 proyecto curado → se usa; más de uno → listar y
  preguntar cuál; ninguno → listar candidatos que ve el token y preguntar cuál/cuáles añadir. No se
  trabaja con un proyecto supuesto.

11 subcomandos (`+assign`). Sin cambios en el pipeline. Detalle en `references/mantis.md`.

## 2.25.0 — 2026-07-27

### Feat: `rs-jira` — crear issues, asignar y descargar adjuntos (paridad con `rs-mantis`)

Tres capacidades que ya tenía `rs-mantis` llegan a `rs-jira`:

- **Crear issue** (Fase 1b, submodos crear-y-trabajar / crear-suelto) vía `createJiraIssue`, replicando
  los campos **informados** de la última tarea asignada al usuario (blocklist de campos de sistema;
  confirmación humana; loop de reintento acotado guiado por el error de Jira al no existir `createmeta`
  en Rovo).
- **Asignar** la issue al desarrollador (`me` = `atlassianUserInfo`): al crear (`assignee` en el alta) y
  en Fase 3 tras la transición (`editJiraIssue`); un 403 no-assignable no bloquea el flujo.
- **Descargar adjuntos** a `docs/`: hook autónomo `hooks/jira-download.ps1` (GET autenticado a
  `/rest/api/3/attachment/content/{id}`, token redactado) expuesto como tool
  `jira_download(issue_key, file_id, out)`; triggers en Fase 1 (oferta) y subrutina `/rs-tarea descargar`.

Sin cambios en el pipeline `rs-enterprise-agent`. Detalle en `references/jira.md`.

## 2.24.0 — 2026-07-27

### Feat: integración MantisBT — skill `rs-mantis` + cliente REST autónomo

Nueva skill **`rs-mantis`** (`/rs-mantis`), orquestador del ciclo de vida de una issue de MantisBT
sobre una solución uCollect/RS que espeja `rs-jira` (selección/creación → formateo → transición a
"En Proceso" → lanza el pipeline → commit → adjunta SQL → transición a "En Validación"), y que además
permite **crear issues nuevas** (crear-y-trabajar / crear-suelto) — algo que `rs-jira` no hace.

**Cliente REST autónomo** (`hooks/mantis-cli.ps1` + `hooks/lib-mantis.ps1`), 10 subcomandos:
`projects`/`list`/`get`/`create`/`transition`/`advance`/`me`/`comment`/`attach`/`download`. A
diferencia de Jira (MCP Atlassian Rovo), MantisBT no tiene MCP equivalente — **motivo de no
envolverlo en tools del MCP `rs-workspace`**: dependería del proceso `python.exe` vivo desde la
primera fase, exponiéndose al falso positivo de CrowdStrike que cuelga el turno hasta 1800s (ver
`docs/crowdstrike-fp-justification.md`; `rs-jira` solo toca `rs-workspace` en su Fase 4 por la misma
razón). Un hook PowerShell autónomo invocado por Bash esquiva `python.exe` por completo.

**Base REST**: `{baseUrl}/api/rest/index.php` — el rewrite `.htaccess` está **inactivo** en la
instancia objetivo (`/api/rest/projects` → 404), así que `New-MantisRequest` usa siempre la forma vía
front controller (funciona con y sin rewrite).

**Protocolo de transición ordenada** (`advance` + `me`): esta instancia de Mantis usa un workflow
**encadenado, sin saltos** — verificado en vivo `new` (Nueva) → `acknowledged` (Aceptada) →
`assigned` (Asignada) → `confirmed` (Confirmada) → `resolved` (Resuelta) → `closed` (Cerrada). El
subcomando `advance -Id -To -Chain [-Handler] [-HandlerStatus]` recorre `statusChain` paso a paso
desde el estado actual hasta el destino, un `PATCH /issues/{id}` por salto, sin saltarse ninguno; es
idempotente hacia delante (si la issue ya está en el destino o después, no hace nada) y, si un paso
intermedio falla, se detiene ahí y reporta en `applied` qué estados sí llegó a aplicar. El
subcomando `me` (`GET /users/me`) resuelve `{id,name,real_name}` del usuario del token. En la Fase 3
de la skill, `me` resuelve el id del desarrollador una vez y `advance` lo fija como `handler` en el
paso que llega a "En Proceso" (`assigned`) — el desarrollador se autoasigna la issue al ponerla en
curso. En la Fase 4, el orden es ahora **estricto**: primero `advance` hasta "En Validación"
(`confirmed`), y **solo después** de confirmado ese paso se adjuntan los scripts SQL (antes ambos
pasos no tenían un orden explícito) — protocolo acordado con el cliente: "cuando el orquestador
termina se pasa a Confirmada y es cuando se suben los scripts". Nuevo campo `statusChain` en
`docs\.mantis-dev-config.json` (array ordenado de nombres de estado); `statusMap` pasa a
`{ "inProgress": "assigned", "inValidation": "confirmed" }` (antes `"inValidation": "resolved"`).

**Config y credenciales**: lista curada de proyectos en `docs\.mantis-dev-config.json` (workspace,
sin secretos, misma convención que `.rs-databases.json`) + token en
`~/.claude/rs-mantis-credentials.json` (fuera del repo). `/rs-mantis proyectos` gestiona la lista
curada; `/rs-mantis init` crea el config del workspace (ahora también con `statusChain`).

**Estado de verificación**: lecturas (`projects`/`get`/`list`) **verificadas en vivo** contra
`soporte.ais-int.net` (200 OK, 41 proyectos; estados `new`/`acknowledged`/`assigned`/`confirmed`/
`resolved`/`closed` con etiquetas en español). Los subcomandos de escritura (`create`/`transition`/
`advance`/`comment`/`attach`) están **unit-testeados**; la verificación en vivo de escritura queda
**pendiente** sobre una issue de prueba autorizada.

Ficheros: `hooks/mantis-cli.ps1`, `hooks/lib-mantis.ps1`, `skills/rs-mantis/SKILL.md`,
`commands/rs-mantis.md`, `references/mantis.md`, `tests/Mantis.Tests.ps1`, `README.md`, bump de
versión.

## 2.23.3 — 2026-07-24

### Feat: instalador genera un script maestro `_run_all.sql` (ejecuta todos los inserts de golpe)

`scripts/installer-inserts.py` genera ahora, junto a los `<TABLA>.sql`, un `_run_all.sql` en la
misma carpeta que los ejecuta todos en orden (solo las tablas que salieron OK). Por motor:
- **Oracle:** `@@<TABLA>.sql` por tabla (`@@` = ruta relativa al propio master), `WHENEVER SQLERROR
  EXIT SQL.SQLCODE` (fail-fast). Uso: `sqlplus user/pass@db @_run_all.sql` desde la carpeta.
- **SQL Server:** `:r <TABLA>.sql` + `GO` por tabla, `:on error exit`. Uso: `sqlcmd -S srv -d db -i
  _run_all.sql`. Requiere sqlcmd (procesa `:r`).

Cada `<TABLA>.sql` sigue siendo autónomo (su cabecera de sesión y su `commit`, ver 2.23.2); el master
solo los encadena. Verificado generando el master para ambos motores.
`agents/rs-instalador.md` y README actualizados.

## 2.23.2 — 2026-07-24

### Feat: scripts de inserts del instalador con cabecera/commit de sesión Oracle

Los `.sql` de inserts de tablas paramétricas que genera el instalador
(`scripts/installer-inserts.py`, `generate_table_file`) ahora, **solo para Oracle**, incluyen:
- Al inicio (tras los comentarios):
  ```
  SET DEFINE OFF;
  ALTER SESSION SET NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS';
  ALTER SESSION SET NLS_TIMESTAMP_FORMAT='YYYY-MM-DD HH24:MI:SS';
  ```
  `SET DEFINE OFF` evita que un `&` en los datos se interprete como variable de sustitución de
  sqlplus; los `NLS_*_FORMAT` fijan el formato de fecha/timestamp para que los literales importen
  igual en cualquier entorno.
- Al final: `commit;` (sqlplus no auto-commitea → sin esto los inserts se perderían al cerrar sesión).

SQL Server queda **sin cambios** (esa sintaxis es específica de Oracle/sqlplus). Verificado generando
para ambos motores.

## 2.23.1 — 2026-07-24

### Fix (crítico): cada tool MCP tardaba ~3 min por llamada (`_run_ps` sin `stdin`)

`_run_ps` lanzaba `powershell` **sin redirigir stdin**: el proceso hijo heredaba el pipe stdin
JSON-RPC del servidor MCP (que nunca recibe EOF) y **bloqueaba en el arranque hasta un timeout
interno (~3 min por llamada)**. El mismo script suelto corría en ~1s. Afectaba a TODA tool que pasa
por `_run_ps` (`check_env`, `get_scope`, `compile_check`, `run_tests`, `sync_from_db`,
`generate_sql`, VCS…) → `rs-init` y el pipeline tardaban 20+ min.

**Fix** (`mcp/rs-workspace-server.py`, `_run_ps`):
- `stdin=subprocess.DEVNULL` → EOF inmediato, powershell arranca al instante. **Es el fix real.**
- `timeout=1200` (20 min, parametrizable) como red de seguridad para procesos realmente colgados
  (ej. conexión BD que no responde). Holgado a propósito para **no** matar operaciones largas
  legítimas (`sync-from-db` 5-10 min, builds, tests); si expira devuelve `{"error": "timeout…"}` en
  vez de propagar la excepción.

**Mismo bug en los otros 4 `subprocess.run` del server** (no pasaban por `_run_ps`) — corregidos con
`stdin=subprocess.DEVNULL`:
- `db_query` **SQL Server (`sqlcmd`)** y **Oracle (`sqlplus`)** — los peores: sin `stdin` **ni**
  `timeout`. `sqlplus` es interactivo → sin EOF se quedaba esperando input. Añadido DEVNULL +
  `timeout=300` (devuelve `{"success": false, "error": "timeout…"}` si la BD no responde).
- `_check_svn_cli` / `_check_git_cli` — ya tenían `timeout=5`; añadido DEVNULL por robustez.

Auditados los 5 `subprocess.run` del fichero: **todos** llevan ya `stdin=DEVNULL`.

Diagnóstico: script standalone rápido pero vía MCP lento = clásico stdin heredado sin EOF.
Verificación: tras el fix + `/plugin marketplace update` + reiniciar Claude Code, `check_env` vía MCP
vuelve en ~1-2s (no 3 min).

## 2.23.0 — 2026-07-24

### Feat: soporte de soluciones `tipo=Servicio` (servicio Windows + instalador .vdproj)

Hasta ahora `get_scope` solo reconocía `.sln` bajo `Batch\Soluciones\` u `OnLine\` — cualquier otra
(servicios, utilidades bajo `trunk\` como `RecBatch2014\`, `RSManager\`, `Servicios\`) devolvía
`tipo=Unknown` **y** un `workspace` mal resuelto (la carpeta del `.sln` en vez del trunk), rompiendo
las tools de BD/config para esas soluciones.

**`parse-sln.ps1` (`get_scope`):**
- Nuevo `tipo=Servicio` cuando el `.sln` referencia un Setup Project `.vdproj` (solución instalable,
  típicamente un servicio Windows .NET Framework). Señal estructural — no mal-clasifica utilidades
  sin instalador (AES256, Encriptador… siguen `Unknown`).
- Nuevo campo de salida `installer_vdproj` (ruta del `.vdproj`).
- **Fix `workspace`:** para `.sln` fuera de `Batch\Soluciones\`/`OnLine\`, resuelve el workspace al
  `…\trunk` (antes = carpeta del `.sln`). Arregla la resolución de `docs\.rs-databases.json` y del
  modelo BD para RecBatchSvc **y** para todas las `.sln` de raíz. Verificado sin regresión en Batch
  (un batch) y Online (la Agenda Web).

**Nueva rama de build `Servicio`** (`agents/rs-editor-build.md` + `hooks/service-build.ps1`):
- Código (.NET Framework) con **MSBuild** (vía vswhere); instalador `.vdproj` con **devenv** (MSBuild
  no compila Setup Projects). Degrada a solo-código con aviso si falta devenv o la extensión
  *Installer Projects*. ⛔ **No copia a AIS** — el `.msi`/`setup.exe` es el entregable que se instala
  como servicio en el cliente. ⚠️ La rama devenv no se puede probar end-to-end en CI (requiere VS +
  extensión); se valida al correr el pipeline sobre una solución Servicio real.

Ficheros: `hooks/parse-sln.ps1`, `hooks/service-build.ps1` (nuevo), `agents/rs-editor-build.md`,
`mcp/rs-workspace-server.py` (desc `get_scope`), `skills/rs-enterprise-agent/SKILL.md`,
`docs/plugin-architecture.md`, `references/mcp.md`, `references/hooks.md`, `hooks/README.md`, bump.
**Hooks 48 → 49; nuevo `tipo=Servicio`.** (La reubicación del DT del servicio RecBatch en la doc de
cada cliente se hace en el repo del cliente, no aquí.)

## 2.22.0 — 2026-07-24

### Feat: `/rs-help` — guía de usuario navegable + reescritura del README

**Reescritura del README como guía de usuario.** El `README.md` pasa a estar orientado a usuario
final (índice navegable, leyenda de modelos ⚡/🔷/🟣, catálogo de comandos en 12 categorías con
tablas comando→qué-hace, sección de requisitos y primer arranque). Corrige counts que habían
quedado obsoletos respecto al código real y documenta los 41 modos directos.

**`/rs-help` (`rs-help`, ⚡ Haiku)** — nuevo modo directo que renderiza el propio `README.md` a un
HTML autónomo (tema claro/oscuro, tablas con formato, anclas de índice GitHub-style, sin
dependencias externas) y lo abre en el navegador. Pensado para pasar la guía a usuarios. Reproduce
el patrón de `/rs-dashboard`: script `scripts/render-help.py` (conversor Markdown→HTML solo stdlib)
+ plantilla `scripts/help-template.html` + hook `hooks/render-help.ps1` + tool MCP `render_help`
(genera el fichero, **no** lo carga en contexto). La fuente es el README del plugin, así que la guía
se mantiene sola al día. Salida a `<workspace>\executions\rs-help.html`.

Además: se añadieron a `hooks/README.md` las entradas de `render-dashboard.ps1` (gap previo) y
`render-help.ps1`.

Ficheros: `scripts/render-help.py` + `scripts/help-template.html` + `hooks/render-help.ps1` + tool
`render_help`, `agents/rs-help.md`, `commands/rs-help.md`, `skills/rs-enterprise-agent/SKILL.md`
(fila en la tabla de modos), `README.md` (reescritura + counts), `docs/plugin-architecture.md`
(43 tools), `references/mcp.md`, `references/hooks.md`, `hooks/README.md`, bump de versión.
**MCP 42 → 43 tools; hooks 47 → 48; agentes 45 → 46; comandos 42 → 43; modos directos 40 → 41.**
## 2.21.0 — 2026-07-23

### Feat: tests del plugin + dashboard de estadísticas + 4 modos directos

Tercera tanda. Además de modos nuevos, esta versión introduce la **primera suite de tests del propio
plugin** y un **dashboard visual**.

**Tests del plugin (CI).** Hasta ahora el CI solo hacía `py_compile` + PSScriptAnalyzer; ni una prueba
funcional sobre las 42 tools ni los 47 hooks.
- `tests/test_mcp.py` (**pytest**, 15 casos): funciones puras de `mcp/rs-workspace-server.py` —
  `_resolve_workspace`, `_get_db_password` (parseo de connection string), `_parse_resultset`
  (CSV Oracle / separador SQL Server), `_diff_summary`, `_proyecto`. Cargadas por `importlib` sin
  arrancar el server.
- `tests/DbQuery.Tests.ps1` (**Pester**): la guarda read-only de `hooks/db-query.ps1` rechaza
  multi-statement, CTE con verbo de escritura y no-SELECT (sin necesidad de BD).
- `.github/workflows/ci.yml`: nuevo paso `pytest` (job Python) y paso `Invoke-Pester` (job PowerShell).
  `requirements.txt` añade `pytest` (dev). ⚠️ Los tests **no** modifican código sensible de seguridad;
  ejercitan la guarda SQL como caja negra.

**`/rs-dashboard` (`rs-dashboard`, ⚡ Haiku)** — dashboard HTML autónomo de `executions/history.json`
(KPIs, distribución por estado, top soluciones, agentes, tendencia 7 días), tema claro/oscuro, sin
dependencias externas. Reproduce el patrón de `render_erd`: script `scripts/render-dashboard.py` +
plantilla `scripts/dashboard-template.html` + hook `hooks/render-dashboard.ps1` + tool MCP
`render_dashboard` (genera el fichero, **no** lo carga en contexto). Versión visual de `/rs-stats`.
**MCP 41 → 42 tools; hooks +`render-dashboard.ps1`.**

**`/rs-explicar` (`rs-explicar`, 🔷 Sonnet)** — explica en lenguaje natural qué hace una
clase/método/proceso, su flujo de datos y efectos laterales (onboarding). Distinto de `/rs-doc` (que
persiste un resumen): explicación puntual bajo demanda.

**`/rs-doc-drift` (`rs-doc-drift`, 🔷 Sonnet)** — cruza los cambios recientes (delta VCS) contra la doc
funcional (`find_doc_section`) y marca secciones obsoletas / incompletas / sin doc. Advisory, no
reescribe.

**`/rs-test` (`rs-test`, ⚡ Haiku)** — ejecuta `dotnet test` (`run_tests`) y reporta
passed/failed/skipped, como modo directo sin lanzar el pipeline completo.

**`/rs-format` (`rs-format`, 🟣 Opus)** — auto-fix de convenciones (naming/usings/formato) — el
complemento de `/rs-audit` (que solo señala). ⛔ Solo formato/naming, **nunca lógica**; ⛔ gate de
confirmación antes de escribir; renombrados públicos se derivan a `/rs-rename`.

Ficheros: `tests/` (nuevo), `scripts/render-dashboard.py` + `scripts/dashboard-template.html` +
`hooks/render-dashboard.ps1` + tool `render_dashboard`, `agents/rs-{dashboard,explicar,doc-drift,test,format}.md`,
`commands/rs-{dashboard,explicar,doc-drift,test,format}.md`, `skills/rs-enterprise-agent/SKILL.md`
(5 filas), `.github/workflows/ci.yml`, `requirements.txt`, README, `docs/plugin-architecture.md`,
`references/mcp.md`, `references/hooks.md`, bump de versión. Agentes 40 → 45, comandos 37 → 42.

## 2.20.0 — 2026-07-23

### Feat: seis modos directos nuevos — cobertura, dead-code, rename, seed, comparar-entornos, hotspots

Segunda tanda de modos directos (tras 2.19.0). **Todos son agente-solo, sin hooks ni tools MCP
nuevos** — reutilizan tools existentes (`find_symbol`, `search_code`, `get_table_schema`,
`db_query` con su parámetro `conexion`, `git_log`/`svn_log`, `map_dependencies`) y las reglas de
dominio ya escritas (`references/bd.md`, `references/testing.md`, `scripts/installer-inserts.py` como
referencia de formato de literales). Superficie mínima: solo markdown (agente + comando + fila en
`SKILL.md`) por modo. El conteo de tools MCP se mantiene en 41.

**`/rs-cobertura` (`rs-cobertura`, 🔷 Sonnet)** — mapa de cobertura de tests: cruza la superficie
pública del scope contra los proyectos de test (mismo criterio que `test-runner-check.ps1`) y reporta
qué clases/métodos (DALC/BUS primero) no tienen test. Cobertura aproximada por referencia, no por
ejecución. Cierra el hueco entre `/rs-crear-tests` (genera) y saber dónde faltan.

**`/rs-dead-code` (`rs-dead-code`, 🔷 Sonnet)** — el inverso de `/rs-impacto`: símbolos con cero
referencias en el scope. ⛔ Marca como "no concluyente" (nunca muerto) los puntos de entrada, handlers
`.aspx`, reflexión/DI, interfaces públicas y overrides. Advisory, no borra.

**`/rs-rename` (`rs-rename`, 🟣 Opus)** — renombrado seguro: localiza todas las referencias (como
`/rs-impacto`) y las reescribe. Único modo de esta tanda que **escribe código** → ⛔ gate de
confirmación humana antes de aplicar `Edit`. Avisa de referencias cross-solución (`map_dependencies`)
y de colisiones; recomienda validar con `/rs-review` o el pipeline tras aplicar.

**`/rs-seed` (`rs-seed`, 🔷 Sonnet)** — genera INSERTs **sintéticos** de prueba respetando
tipo/longitud/nullabilidad/FKs/unicidad del modelo (`get_table_schema`). Literales por motor según
`references/bd.md`; salida a `C:\AIS\<proyecto>\scripts\`. ⛔ No ejecuta contra la BD. Complementa el
instalador (que vuelca paramétricas reales).

**`/rs-comparar-entornos` (`rs-comparar-entornos`, 🔷 Sonnet)** — diff de esquema entre **dos
conexiones** de `.rs-databases.json` (p.ej. dev vs pro) vía `db_query(..., conexion=<id>)` sobre las
vistas de catálogo. Reporta tablas/columnas/tipos/longitudes/índices divergentes. ⛔ Solo SELECT.
Complementa `/rs-comparar-modelo` (que compara modelo↔BD viva).

**`/rs-hotspots` (`rs-hotspots`, 🔷 Sonnet)** — puntos calientes de riesgo cruzando churn
(`git_log`/`svn_log`) con complejidad/tamaño (heurísticas de `rs-auditoria`). Ranking para priorizar
tests/refactor.

Ficheros: `agents/rs-{cobertura,dead-code,rename,seed,comparar-entornos,hotspots}.md` (nuevos) ·
`commands/rs-{cobertura,dead-code,rename,seed,comparar-entornos,hotspots}.md` (nuevos) ·
`skills/rs-enterprise-agent/SKILL.md` (6 filas en `# Modos directos`) · `README.md` ·
`docs/plugin-architecture.md` · bump de versión. Agentes 34 → 40, comandos 31 → 37.

## 2.19.0 — 2026-07-23

### Feat: cinco modos directos nuevos — review, perf, deshacer, init, release-notes

Ampliación de la superficie de modos directos (sin tocar el pipeline principal). Todos siguen el
patrón de extensión de `docs/plugin-architecture.md §9` (agente + comando + fila en la tabla
`# Modos directos` de `SKILL.md`) y **reutilizan** agentes/hooks/tools existentes en vez de duplicar
lógica.

**`/rs-review` (`rs-review`, 🟣 Opus)** — revisión de un cambio (diff/PR) con **veredicto de bloqueo**
`APRUEBA | CAMBIOS | BLOQUEA`. Unifica sobre el delta las tres lecturas que hoy están sueltas:
riesgo técnico (como `rs-analisis`), seguridad (`security_scan`) y compatibilidad BD
(`references/bd.md`, como `rs-validacion-bd`). Con `--pr <n>` publica el veredicto en el pull request
vía el MCP `github` (nunca `APPROVE` automático; footer de atribución obligatorio).

**`/rs-perf` (`rs-perf`, 🟣 Opus)** — análisis de rendimiento de acceso a BD: cruza el SQL de los
DALC del scope contra los índices del modelo (`get_table_schema`) para detectar índices que faltan,
full-scans, filtros no-sargables (`UPPER(col)=`, `LIKE '%x'`, prefijo de compuesto no usado) y
`SELECT *` en tablas anchas. Agente-solo, sin hook/tool nuevos. Capacidad de dominio nueva —
complementa `/rs-validar-bd` (que cubre tipos/longitudes) con el eje de rendimiento.

**`/rs-deshacer` (`rs-deshacer`, 🔷 Sonnet)** — deshace los cambios **pendientes de commit** del
último cambio del pipeline, revirtiéndolos a su estado versionado. Premisa: en el flujo RS el commit
es un paso aparte, así que "el último cambio" = los cambios pendientes del working copy en scope;
`executions/history.json` se usa solo como contexto. ⛔ **Gate de confirmación humana** antes de
revertir (previsualiza con `dry_run`). Nuevos: hook `hooks/vcs-revert.ps1` + tool MCP `vcs_revert`
(revierte una lista **explícita** de ficheros; autodetecta SVN/Git; elimina los nuevos, restaura a
HEAD/versionado los modificados). No toca commits ya hechos ni la BD real.

**`/rs-init` (`rs-init`, 🔷 Sonnet)** — bootstrap de un workspace nuevo: crea `docs/.rs-databases.json`
(o migra `XMLConfig.xml` con `convert-config.ps1`), el andamiaje `docs/agentic_manual/` y el primer
`model.json` (`sync_from_db`), y valida con `check_env`. ⛔ Nunca sobrescribe ficheros existentes.
Complementa `/rs-env` (que solo valida).

**`/rs-release-notes` (`rs-release-notes`, 🔷 Sonnet)** — convierte el historial de commits (SVN/Git,
vía `svn_log`/`git_log`) en notas de versión funcionales agrupadas (✨ nuevo · 🐛 correcciones ·
🗄️ BD · ⚙️ interno), en lenguaje de negocio/QA.

**MCP:** 40 → **41 tools** (`vcs_revert`). **Hooks:** +`vcs-revert.ps1`.

Ficheros: `agents/rs-{review,perf,deshacer,init,release-notes}.md` (nuevos) ·
`commands/rs-{review,perf,deshacer,init,release-notes}.md` (nuevos) · `hooks/vcs-revert.ps1` (nuevo) ·
`mcp/rs-workspace-server.py` (tool `vcs_revert`) · `skills/rs-enterprise-agent/SKILL.md` (5 filas en
`# Modos directos`) · `README.md` · `docs/plugin-architecture.md` · `references/mcp.md` ·
`references/hooks.md` · bump de versión.

## 2.18.0 — 2026-07-23

### Feat: nueva etapa `plan-check` — verifica que el código cumple el PLAN aprobado

Hasta ahora el pipeline no tenía ningún agente que comprobara que el código implementado por `core`
cubría lo que el `PLAN` del planner prometía. `validator` y `tester` reciben solo `FILES_CHANGED`
(juzgan la calidad/lógica del **cambio**, no su completitud respecto al plan) y `core` recibe el
`plan` pero es quien lo implementa — nadie cerraba el círculo. Un `core` que implementaba medio plan
y compilaba pasaba en silencio a build.

**Nuevo agente `rs-editor-plan-check`** (🔷 Sonnet, read-only): descompone el `PLAN` aprobado en
ítems accionables y busca evidencia concreta de cada uno en `FILES_CHANGED` (`search_code` /
`find_symbol` / `batch_find_symbols` acotados a `scope_dirs`). Devuelve el contrato
`STATUS: OK|INCOMPLETE` + `MISSING`. Sonnet, no Haiku: mapear ítem de plan (lenguaje natural) →
evidencia semántica en código exige juicio; un falso `OK` reabre exactamente el hueco que la etapa
existe para tapar. Anti-ruido: solo bloquea con certeza alta de ausencia, no exige más de lo que el
plan pide, y no cuenta como faltantes los ítems delegados a otras etapas (idiomas→tester,
doc→documentar, modelo→db-modeler, tests→crear-tests).

**Cableado (orquestador):** el planner coloca `plan-check` en `STAGES` justo después de `core`.
Posición: `core → plan-check → validator` (fail-fast antes de compilar/validar). `INCOMPLETE` →
reinvoca `core` con `MISSING` (máx **1 ciclo**, independiente del presupuesto de fixer; agotado →
escala al usuario, porque un hueco suele ser lógica nueva y `fixer` no puede añadirla). **Red de
seguridad** como la de db-modeler: si `core` corrió y `plan-check` no estaba en `STAGES`, el
orquestador lo ejecuta igualmente antes de validator.

Ficheros: `agents/rs-editor-plan-check.md` (nuevo) · `skills/rs-enterprise-agent/SKILL.md`
(paso 2, handoff paso 3, control de flujo) · `README.md` (set STAGES + tabla pipeline) ·
`docs/plugin-architecture.md` (§3 set STAGES, §4 tabla agentes) · bump de versión.

## 2.17.2 — 2026-07-23

### Fix: `sync-from-db.ps1` regeneraba el modelo BD en O(n²) → O(n)

El loop de post-proceso de `hooks/sync-from-db.ps1` (regeneración del modelo BD desde el esquema
real) hacía, **por cada fila** devuelta por la BD (tablas × columnas), dos `Get-Member -Name` sobre
un `PSCustomObject` que crece: uno para comprobar si la tabla ya existía y otro para la columna.
`Get-Member` enumera todos los miembros en cada invocación → coste **O(n²)** sobre el total de
columnas. En una BD con cientos de tablas (p.ej. 362) y miles de columnas, ahí se iba el tiempo de
la regeneración — no en la I/O de BD, que ya es una única query (JOIN sobre `ALL_TAB_COLUMNS` /
`INFORMATION_SCHEMA`), no N queries por tabla.

**Fix**: se construye un índice hashtable O(1) de tablas y columnas existentes en la misma pasada
que ya normalizaba `relations`/`indexes`. El loop de sync sustituye los dos `Get-Member -Name` por
lookups de hashtable → **O(n)**. Aplica a ambas ramas (Oracle y SQL Server), ya que el índice se
construye antes del `if ($motor)`.

Sin cambio de comportamiento: se preservan exactamente las semánticas de merge previas —
`description`/`relations`/`indexes`/`source` de tablas existentes, `description` de columnas
existentes, y las tablas/columnas desaparecidas de la BD **no se borran** (igual que antes). El
paralelismo no aplica aquí: la extracción ya es una sola query y el `PSCustomObject` no es
thread-safe para `Add-Member` concurrente. Ficheros: `hooks/sync-from-db.ps1`.

## 2.17.1 — 2026-07-23

### Fix: `ping` trivial (sin subprocesos) + checks svn/git no envenenan la cache con timeouts

`ping` (`mcp/rs-workspace-server.py`) spawneaba `svn --version` + `git --version` en cada llamada
(vía `_check_svn_cli`/`_check_git_cli`), así que un health check heredaba el cuelgue del arranque en
frío bajo el FP de CrowdStrike (ver `docs/crowdstrike-fp-justification.md`) y, en transporte stdio
serie, bloqueaba las demás tools hasta 10s (2× `timeout=5`).

Además había un bug de correctness: `_check_svn_cli`/`_check_git_cli` cacheaban `False` tanto ante
`FileNotFoundError` como ante `TimeoutExpired`. Un timeout transitorio durante la congestión del
arranque quedaba **pegado toda la sesión** → las tools VCS reportaban "git/svn CLI no disponible" en
falso el resto de la sesión (observado: `ping` devolviendo `git_cli:false` con git funcionando bien).

**Fix**:
- `ping` no spawnea subprocesos: reporta el estado **ya cacheado** de los CLIs (`svn_cli`/`git_cli`,
  `null` = aún no comprobado). Los checks reales quedan perezosos, en las tools VCS que los usan.
- `_check_svn_cli`/`_check_git_cli` separan excepciones: `FileNotFoundError` (ausencia real) cachea
  `False`; `TimeoutExpired` devuelve `False` **sin cachear** → reintenta en la próxima llamada.

Sin hook equivalente: `ping` no tiene hook PowerShell y los hooks son procesos frescos por
invocación (sin cache en-proceso que envenenar). Ficheros: `mcp/rs-workspace-server.py`,
`references/mcp.md`.

## 2.17.0 — 2026-07-23

### Feat: generación de inserts del instalador en paralelo (`parametricas.max_paralelo`)

`scripts/installer-inserts.py` generaba un fichero `Inserts\<TABLA>.sql` por tabla paramétrica en un
bucle **secuencial**: cada tabla spawnea un `sqlplus`/`sqlcmd`, hace login fresco y consulta la tabla
entera. Con 40-60 paramétricas eso eran decenas de segundos a minutos de espera en serie — el cuello
de botella de la etapa 5 del instalador (`/rs-instalador`).

**Fix**: el bucle pasa a `concurrent.futures.ThreadPoolExecutor`. Es seguro (I/O-bound, GIL libre en
`subprocess.run`): cada tabla escribe un fichero distinto, `model`/`cfg` son solo-lectura y cada query
usa su propio fichero temporal. La agregación de filas/errores y los exit codes (0 OK / 2 con avisos)
no cambian; la salida se recolecta y se imprime en orden de tablas (determinista, no entrelazada).

El paralelismo = nº de conexiones BD simultáneas, así que va **acotado** por la nueva clave opcional
`parametricas.max_paralelo` en `docs\<Proyecto>-instalador.json` (default `8`, mínimo `1`, capado a
`len(tablas)`). Bajar en clientes con pocas sesiones Oracle; subir en servidores holgados. Mejora
típica ~6-8× en la etapa de inserts.

Ficheros: `scripts/installer-inserts.py`, `agents/rs-instalador.md` (ejemplo de config + nota),
`docs/plugin-architecture.md`.

## 2.16.1 — 2026-07-23

### Fix: el guard de `db_query` bloqueaba CTEs legítimos (`WITH ... SELECT`)

El guard solo-lectura de `db_query` (tool MCP `mcp/rs-workspace-server.py` + su fallback 1:1
`hooks/db-query.ps1`) exigía que la sentencia empezara por `SELECT`. Una consulta con CTE, que
empieza por `WITH`, caía como falso positivo con `"Solo se permiten consultas SELECT"`, aunque
`WITH ... SELECT` es solo-lectura. Obligaba a reescribir el CTE como subconsulta inline.

**Fix**: el guard acepta ahora sentencias que empiecen por `SELECT` **o** `WITH`. Como un CTE puede
colgar un verbo de escritura tras el bloque (`WITH x AS (...) DELETE FROM ...`) que el `startswith`
no detecta, en la rama `WITH` se rechaza la sentencia si contiene cualquier verbo de escritura
(`INSERT|UPDATE|DELETE|MERGE`, `\b...\b`). El bloqueo multi-statement (`;`) y la rama `SELECT`
(single-statement, no puede escribir) no cambian.

**Limitación conocida**: el check de verbo de escritura es textual, así que un CTE legítimo con un
literal `'DELETE'` o una columna llamada `UPDATE` se bloquearía. Falla en dirección segura (bloquea
una lectura, nunca deja pasar una escritura) — aceptable.

Ficheros: `mcp/rs-workspace-server.py` (guard + descripción de la tool), `hooks/db-query.ps1`
(guard 1:1), `references/mcp.md`, `references/hooks.md`.

## 2.16.0 — 2026-07-23

### Feat: `rs-jira` deja 2 comentarios automáticos en la issue (prompt lanzado + resultado final)

La skill `rs-jira` (`/rs-tarea`) ahora registra en la propia issue de Jira, vía
`addCommentToJiraIssue` (Atlassian Rovo, ya disponible), dos hitos de trazabilidad:

- **Fase 3** — al dar OK a lanzar el orquestador, se comenta el **prompt exacto**
  (`<Solucion>.sln - <cambio>`) que se pasa al pipeline. La confirmación de Fase 3 pasa a cubrir las
  tres escrituras: comentario del prompt + transición a "En Proceso" + lanzamiento.
- **Fase 4** — al cerrar la tarea, además de adjuntar los `.sql` + transicionar a "En Validación" +
  `log_execution`, se comenta el **resumen final** (el mismo "Informe final": qué se hizo, SQL
  adjuntados, revisión de commit, estado). Bajo ⛔ confirmación; si el comentario falla, el cierre
  (commit + transición) ya está hecho → cierre parcial, no cuelga.

Sin cambios en el pipeline, sin tools MCP ni hooks nuevos. `addCommentToJiraIssue` se carga con
ToolSearch en runtime (patrón deferred ya documentado en la skill).

## 2.15.10 — 2026-07-23

### Fix: tools MCP fallaban cuando el modelo llamaba con `path` en vez de `workspace`

29 tools del MCP `rs-workspace` (+ 4 helpers) declaran `workspace` como primer parámetro. El modelo
a veces las invocaba con `path` (especialmente VCS/log — `detect_vcs`, `svn_status`, `log_execution` —
leídas como "opera sobre un path") → pydantic rechazaba con `Field required [workspace]`. El modelo
reintentaba con `workspace` y funcionaba, pero generaba una llamada fallida + ruido cada vez.

**Fix**: tipo compartido `Workspace = Annotated[str, Field(validation_alias=AliasChoices("workspace",
"path"), ...)]` en `mcp/rs-workspace-server.py`, aplicado a las 33 firmas `workspace: str`. `"workspace"`
va primero en `AliasChoices` → el schema expuesto conserva el nombre canónico; `"path"` se acepta solo
como alias de entrada. Es `Annotated[str]` → runtime idéntico, helpers no afectados.

⚠️ Verificar tras recargar: una llamada con `path=...` debe funcionar Y `workspace=...` seguir OK.

## 2.15.9 — 2026-07-23

### Fix: hooks PowerShell hacían timeout (`UserPromptSubmit hook timed out after 5s/10s — output discarded`)

Los 3 hooks de `plugin.json` (`SessionStart` → `cleanup-preplugin.ps1`, `Stop` → `runner.ps1`,
`UserPromptSubmit` → `skill-trigger.ps1`) se lanzaban con `powershell -ExecutionPolicy Bypass -File`
**sin `-NoProfile`**. `-File` carga el perfil de usuario de Windows PowerShell en cada arranque
(imports de módulos + init), lo que en frío y sobre `cwd` en unidad de red sumaba varios segundos.
El `UserPromptSubmit` (recordatorio de skill) superaba su timeout de 10s → output descartado → el
recordatorio no se inyectaba.

**Fix**:

- **`-NoProfile` en los 3 commands** de `.claude-plugin/plugin.json` — corta el arranque de perfil
  (de segundos a ~200-400ms). Palanca principal.
- **Timeout `UserPromptSubmit` `10`→`15`** — margen adicional (cinturón + tirantes).
- **`hooks/skill-trigger.ps1` fail-fast** — el loop `Test-Path` ahora valida primero que `cwd` sea
  accesible (`Test-Path -LiteralPath $cwd`) y usa `-ErrorAction SilentlyContinue` por marcador, para
  que una unidad de red lenta/caída no bloquee el `UserPromptSubmit`.

## 2.15.8 — 2026-07-22

### Fix: `installer-batch.ps1` — gate de binding redirects (config viejo + DLL nueva → StackOverflow)

`hooks/installer-batch.ps1` (etapa Batch de `/rs-instalador`). Segundo vector de frankenbuild, distinto
al de 2.15.7: en una **carpeta de deploy compartida**, last-writer-wins puede dejar un `<exe>.exe.config`
viejo (con `bindingRedirect newVersion=X`) junto a una `System.*.dll`/tercero **nueva**
(`AssemblyVersion=Y`). El redirect apunta a una versión que ya no está en la carpeta →
`FileLoadException` → bucle de re-resolución → **StackOverflow** en `RSActBD`/`RSCore`. La asunción
"terceros version-pinned = OK, no hace falta verificarlos" es **falsa** en carpeta compartida.

**Fix**: gate nuevo (bloqueante, tras el gate de coherencia por timestamp de 2.15.7). Para cada
`EXES\*.exe.config` se parsea `runtime/assemblyBinding/dependentAssembly` (namespace
`urn:schemas-microsoft-com:asm.v1`); por cada `bindingRedirect` cuyo `<name>.dll` **está físicamente
desplegado** (si no lo está, se resuelve de GAC y no aplica), se compara `newVersion` del config contra
la `AssemblyName.Version` real del DLL (`[System.Reflection.AssemblyName]::GetAssemblyName`). Si no
coinciden → se listan `config · assembly · newVersion vs real` y **exit 1**, no se despliega.

## 2.15.7 — 2026-07-22

### Fix: `installer-batch.ps1` generaba frankenbuilds → StackOverflowException al arrancar

`hooks/installer-batch.ps1` (etapa Batch de `/rs-instalador`). El hook compilaba con `dotnet build`
**incremental**, por-sln y sin verificación final. En un caso real dejó en `EXES` 8 exes
del build 07-20 15:33 junto a `Comun.dll`/`BusComun.dll`/`RsExtrae.exe` del 07-21 10:31.

**Causa raíz**: las DLLs compartidas (`Comun`/`BusComun`/`RSModel`) **no tienen strong-name** y su
`AssemblyVersion` es `1.0.*` → el CLR las enlaza **por nombre simple**. Un exe viejo, compilado
contra un snapshot distinto de esas DLLs, llama en runtime a un método cuya firma cambió → recursión
infinita → **StackOverflowException** al arrancar `RSActBD.exe`. Agravante: `dotnet build` de una
`.sln` con proyecto de Tests (p.ej. `RsExtrae.Tests`) fallaba y dejaba su `.exe` **sin actualizar** =
el straggler exacto observado.

**Fix** (reescritura del hook):

- **Rebuild desde snapshot único, no incremental** — `msbuild /t:Rebuild` (VS2022 via `vswhere`, mismo
  patrón que `installer-agendaweb`), precedido de un **wipe de todos los `bin`/`obj` del scope** en una
  sola pasada. Sin restos de builds anteriores.
- **Los proyectos de Tests ya no rompen ni contaminan el build** — no se compila la `.sln` entera; se
  resuelven los **csproj-exe** (`<OutputType>Exe|WinExe`, fallback = csproj homónimo de la sln) y se
  compilan **directamente** con `-t:Rebuild`, arrastrando sus `<ProjectReference>` (las DLLs
  compartidas se recompilan del mismo snapshot). El `*.Tests` queda fuera.
- **Gate de coherencia final (bloqueante)** — se sella `$buildStart` antes de compilar; tras copiar,
  todo `*.exe` + DLLs compartidas (`Comun`/`BusComun`/`RSModel`, override por JSON `sharedAssemblies`)
  en `EXES` debe tener `LastWriteTime >= $buildStart`. Cualquier fichero de otra fecha → se listan y
  **exit 1**, nunca "OK".
- **Aviso de la trampa estructural `HintPath`** — detecta `<Reference><HintPath>..\bin\Debug\X.dll`
  cuando existe `X.csproj` en el workspace (debería ser `<ProjectReference>`): se enlaza contra una DLL
  de otro build. Advisory (no falla). Ya corregida en r14970 del proyecto donde se detectó.

## 2.15.6 — 2026-07-22

### Fix: inserts del instalador vacíos por saltos de línea (regresión de 2.15.5)

`scripts/installer-inserts.py` (`Inserts\<TABLA>.sql` de `/rs-instalador`). Tras 2.15.5, tablas con
texto multilínea (p.ej. `RACCION.ACSQL`, con sentencias SQL de varias líneas) generaban **0 inserts**
(`-- (sin filas)`), y los scripts de idiomas salían **incompletos**.

**Causa raíz** (reproducida contra Oracle real, mínima):

```
SELECT 'linea1' || CHR(10) || 'linea2' || '@@ROWEND@@' FROM DUAL   ->   linea1
```

sqlplus en modo `PAGESIZE 0` **trunca el valor en el primer `CHR(10)` interno**: se pierde el resto
del dato **y** el terminador de fila `@@ROWEND@@`. Sin terminador, las filas se fundían (`nº campos
28 != 4`) y **todas** se descartaban. El terminador de fila que introdujo 2.15.5 iba al **final**, es
decir, detrás del salto — por eso siempre se perdía. Reubicarlo no sirve: cualquier cosa tras el 1er
`\n` muere.

**Fix**: la query **codifica** `CHR(13)`/`CHR(10)` como tokens (`@@CR@@`/`@@LF@@`) vía `REPLACE`
anidado, de modo que **cada fila sale en una sola línea física** (sin truncado); Python revierte los
tokens a saltos reales tras trocear, y el literal SQL queda multilínea (válido en Oracle/SQL Server).
El troceo por `@@ROWEND@@` se mantiene como red de seguridad. Aplica a ambos motores.

Verificado contra una BD Oracle real: `RACCION` (9 filas, todas con salto interno) pasó de **0** a
**9** inserts, con el `ACSQL` completo y multilínea. Test de aislamiento del round-trip
codificar→trocear→decodificar.

## 2.15.5 — 2026-07-22

### Fix: inserts del instalador — acentos corruptos y pérdida de filas con salto de línea

Dos bugs en `scripts/installer-inserts.py` (los ficheros `Inserts\<TABLA>.sql` que genera
`/rs-instalador`).

- **Acentos como caracteres corruptos** — los `.sql` se escribían en UTF-8 **sin BOM**; las
  herramientas gráficas de Oracle (SQL Developer/TOAD/PL-SQL Developer) asumían Windows-1252 y los
  acentos salían mal. Ahora se escriben con **BOM UTF-8** (`utf-8-sig`), que esas herramientas
  detectan. Los ficheros de inserts son independientes (se ejecutan aparte), así que el BOM no afecta
  a ningún flujo de `@@include`.
- **Pérdida de filas con salto de línea** — la salida del SELECT se troceaba **por líneas**
  (`splitlines`), asumiendo "1 fila = 1 línea". Un valor de texto con un salto de línea hacía que la
  fila ocupara varias líneas de salida; cada trozo quedaba con un nº de campos distinto al esperado y
  la fila **se descartaba entera** (`-- AVISO fila omitida`). Ahora el SELECT añade un terminador de
  fila `@@ROWEND@@` y la salida se trocea por ese terminador (`_split_rows`), no por `\n`: los saltos
  internos de un valor se conservan dentro de su literal SQL (multilínea, válido en Oracle).

Verificado con tests de aislamiento: el nuevo troceo recupera las filas que el viejo perdía por el
salto de línea, y el fichero se escribe con BOM. (No se puede probar Oracle/sqlplus en el entorno de
desarrollo Linux; la lógica de parseo y de codificación sí se prueba.)

**Fuera de alcance (deliberado)**: el DDL (`installer-ddl.py`) y los objetos
(`installer-objects.py`) NO llevan BOM — su maestro `CreacionObjetos.sql` los encadena con `@@`, y un
BOM en cada sub-fichero podría romper ese `@@include`. Si aparecieran acentos corruptos en
vistas/triggers, se aborda aparte con otro enfoque.

## 2.15.4 — 2026-07-22

### Fix: los slash commands `/rs-*` no mostraban descripción al teclearlos

**Síntoma**: al escribir un `/rs-*`, Claude Code no mostraba la descripción del comando (salvo
`/rs-enterprise-agent`).

**Causa**: el `description:` del frontmatter iba **sin comillas** y contenía `: ` interno (p.ej.
`... Uso: /rs-audit ...` o `Estadísticas del pipeline: total...`). YAML interpreta ese `: ` como un
mapping anidado y **falla al parsear el frontmatter entero** → Claude Code no lee la descripción. Solo
`/rs-enterprise-agent` funcionaba porque su descripción ya iba entrecomillada.

- **Todos los `commands/*.md`**: `description` entrecomillada (comillas dobles, escapando internas) —
  el frontmatter vuelve a parsear.
- **`argument-hint` añadido** a cada comando: muestra los parámetros al teclear (`< >` fijos, `[ ]`
  opcionales), p.ej. `/rs-migrar <Solution>.sln a <ORACLE|SQLSERVER>`. La cola redundante "Uso: ..."
  se retira de la descripción, que ahora la cubre `argument-hint`.

## 2.15.3 — 2026-07-22

### Tier 3 (3/n): dedup del post-proceso de diff svn/git en el MCP server

`svn_diff_revision` y `git_diff_revision` (`mcp/rs-workspace-server.py`) duplicaban ~30 líneas
idénticas de post-proceso (construcción del resumen por fichero: `+lines`/`-lines`/`symbols`), que
solo diferían en el marcador de fichero del diff (`Index:` en SVN vs `diff --git` en Git).

- **Nuevo helper `_diff_summary(diff_text, revisions, file_header_re)`** — fuente única del resumen;
  cada tool le pasa su regex de cabecera. El regex de símbolo C# se extrae a una constante compilada
  `_DIFF_SYMBOL_RE` (antes recompilado por línea).
- Se eliminan los `import re as _re` locales redundantes (el módulo ya importa `re` arriba) y una
  variable muerta en la rama SVN (`files_changed = raw.get("files_changed", [])`, asignada y nunca
  usada).
- **Sin cambio de comportamiento**: verificado con un test de equivalencia que compara la salida JSON
  del código viejo y el nuevo sobre diffs SVN y Git representativos (incluido diff vacío) — idénticas.

Los wrappers finos `svn_status`/`git_status`, `svn_add`/`git_add`, `svn_log`/`git_log` se dejan como
están: son ~4 líneas cada uno y deben seguir siendo tools MCP separadas con su propia descripción y
sus guardas/fallbacks específicos (git exige `_check_git_cli`; svn ofrece fallback TortoiseSVN).

## 2.15.2 — 2026-07-22

### Tier 3 (2/n): corrección del drift de documentación

Resuelve dos de las inconsistencias conocidas del §11 de `docs/plugin-architecture.md` y varias
imprecisiones de la doc. Solo documentación (+ un arreglo de ruta en un script de instalación
legacy). No cambia el runtime del plugin.

- **`subagents/` → `agents/`** — se actualizan las referencias a la carpeta antigua en ficheros
  versionados: `references/hooks.md`, `references/testing.md`, `commands/rs-erd.md`,
  `commands/rs-sync-indexes.md`. Además `scripts/install-hooks.ps1` tenía la **misma** ruta rota
  (`Join-Path $SkillPath "subagents"`) que ya se corrigió en `install-to-project.ps1` en 2.14.1 —
  ahora apunta a `agents/`. (El design spec vive en `docs/superpowers/`, no publicado — queda fuera.)
- **Hook `SessionStart` documentado** — `plugin.json` declara tres hooks (SessionStart → 
  `cleanup-preplugin.ps1`, Stop, UserPromptSubmit), pero `docs/plugin-architecture.md` (§2 y §7) y el
  `README.md` (§Estructura) solo mencionaban dos. Añadido el SessionStart en los tres sitios.
- **Carpeta `BD/`** — retirada del árbol de estructura del `README.md`: el `model.json` vive en el
  workspace de cada solución cliente, no en el repo del plugin (el árbol la listaba con un
  "(no en el repo)" contradictorio).
- **Conteo de agentes** — `README.md` decía "27 subagentes"; son **28**.
- **§11** actualizado: las dos inconsistencias resueltas se mueven a un apartado "Resueltas" con su
  versión; quedan como conocidas solo `settings.json` (legacy con `_note`) y la no-expansión de
  `${CLAUDE_PLUGIN_ROOT}` en markdown (mitigada en 2.12.0).

## 2.15.1 — 2026-07-22

### Tier 3 (1/n): helper Python compartido para el mapeo de tipos entre motores

Primer paso de la deduplicación del Tier 3. El bloque de mapeo de tipos Oracle ⇄ SQL Server
(`ORACLE_TO_SS`, `SS_TO_ORACLE`, `adapt_type`, `ensure_oracle_char_semantics`) estaba copiado
literalmente en `scripts/generate-sql.py` y `scripts/installer-ddl.py`.

- **`scripts/_dbtypes.py`** (nuevo) — fuente única. Los scripts se ejecutan con `scripts/` en
  `sys.path`, así que `import _dbtypes` resuelve sin trucos (a diferencia de los otros scripts, cuyo
  nombre lleva guion y no son importables directamente).
- **Corrige un drift ya existente**: las dos copias habían divergido — `installer-ddl.py` se había
  quedado sin la entrada `RAW → VARBINARY` que sí tenía `generate-sql.py`. Al unificar sobre el
  superconjunto, `installer-ddl.py` ahora mapea correctamente las columnas `RAW` de Oracle a
  `VARBINARY` en SQL Server (antes las dejaba como `RAW`, tipo inexistente en SQL Server). Cambio de
  comportamiento intencionado en el DDL generado para columnas `RAW`.
- Sin cambios de comportamiento en el resto de conversiones (verificado: ambos scripts comparten
  ahora el mismo objeto `adapt_type`; casos representativos idénticos).

Pendiente en próximos pasos del Tier 3: colapsar las funciones `svn_*`/`git_*` casi idénticas del
MCP server y corregir el drift de documentación (§11 de `docs/plugin-architecture.md`).

## 2.15.0 — 2026-07-22

### Higiene de proyecto: manifiesto de dependencias + CI

Infraestructura de desarrollo que faltaba por completo en el repo. No cambia el runtime del plugin.

- **`requirements.txt`** — el MCP server importa `from mcp.server.fastmcp import FastMCP`
  (`mcp/rs-workspace-server.py`), una dependencia de terceros que hasta ahora no estaba declarada en
  ninguna parte (solo prosa en el README). Se fija `mcp>=1.2.0` (piso donde `mcp.server.fastmcp` es
  estable). Las CLIs externas (sqlplus, sqlcmd, svn, git, dotnet, msbuild) no son deps Python y se
  siguen comprobando en runtime.
- **CI en GitHub Actions** (`.github/workflows/ci.yml`) — primer conjunto de checks automáticos del
  repo, sobre cada PR y push a `main`:
  - `py_compile` del MCP server y de los scripts Python.
  - **Paridad de versión** `plugin.json` == `marketplace.json` + verificación de que `CHANGELOG.md`
    tiene entrada para esa versión (`.github/scripts/check_version.py`) — automatiza el invariante de
    publicación del §10 de `docs/plugin-architecture.md`, el error más fácil de cometer al publicar.
  - **PSScriptAnalyzer** sobre los `.ps1` de `hooks/`, `scripts/` y `runner/`. Falla solo con
    severidad Error/ParseError (los warnings se listan pero no rompen el build) — caza fallos de
    sintaxis PowerShell que el entorno Linux de desarrollo no puede validar en vivo.

## 2.14.1 — 2026-07-22

### Seguridad y correctitud en el fallback `db-query.ps1` + script de instalación por proyecto

Arreglos de bajo riesgo que no tocan el pipeline ni el contrato de las tools MCP. `hooks/db-query.ps1`
es el **fallback 1:1** de la tool MCP `db_query` (convención Preferente/Fallback, `references/hooks.md`);
regresaba tres protecciones que el camino MCP (`mcp/rs-workspace-server.py`) ya tenía. Ahora quedan
alineados con ese patrón:

- **Password fuera de la línea de comando** — antes `sqlplus -S "$user/$password@$dataSource"` dejaba
  la contraseña visible en la lista de procesos durante toda la consulta. Ahora usa `/nolog` +
  `CONNECT` escrito en el script SQL temporal, igual que la rama Oracle de la tool MCP. `WHENEVER
  SQLERROR EXIT SQL.SQLCODE` va antes del `CONNECT` para que un login fallido salga con el código de
  error.
- **Guarda SELECT-only** — el hook interpolaba `$Sql` directo en el script sqlplus sin validación, así
  que cualquier sentencia (`DROP`/`DELETE`/bloque PL/SQL) se ejecutaba. Se añade la misma validación
  que `db_query`: exige que empiece por `SELECT` y bloquea multi-statement (`;` fuera de literales).
- **Fuga de fichero temporal** — `GetTempFileName() + ".sql"` creaba un fichero de 0 bytes en OTRA ruta
  que nunca se limpiaba. Ahora las rutas temp se generan con `[Guid]` y ambas se borran en el `finally`.

- **`scripts/install-to-project.ps1`** — apuntaba a la estructura pre-v2: la carpeta de subagentes
  `subagents\` (real: `agents\` desde v2.0.0) y la versión leída de un `SKILL.md` en la raíz (hoy en
  `skills\rs-enterprise-agent\` y la versión en `plugin.json`). Se corrigen ambas rutas; la versión se
  lee ya de `.claude-plugin\plugin.json` (fuente canónica). Resuelve dos de las inconsistencias del §11
  de `docs/plugin-architecture.md`.

## 2.14.0 — 2026-07-21

### Portabilidad: el plugin deja de depender del árbol del mantenedor

**Síntoma**: el pipeline reportaba `Plugin root: N:\SVN\RS\Agentes\SkillsClaude\rs-skill-full` y el
proceso MCP vivo era `python N:/SVN/.../mcp/rs-workspace-server.py`, pese a existir una copia
instalada en `~/.claude/plugins/cache/.../2.13.0`.

**Diagnóstico**: el marketplace estaba registrado como `source: directory` apuntando al repo fuente.
Un marketplace `directory` no se clona — el plugin (`source: "./"`) se resuelve relativo a esa ruta y
`${CLAUDE_PLUGIN_ROOT}` expande a ella, así que hooks, runner y MCP se ejecutan *in situ*. El
`installPath` del cache es un snapshot que no se usa en runtime. Consecuencia: cualquier usuario sin
esa unidad montada no podía usar el plugin.

- **Distribución** — la fuente canónica pasa a ser el repo Git privado
  `https://github.com/vgege86/rs-enterprise-plugin.git`. Con origen Git, Claude Code clona el
  marketplace y ejecuta el plugin desde `~/.claude/plugins/cache/<mp>/<plugin>/<versión>/`.
  `README.md` §Instalación reescrito (incluye quitar el marketplace `directory` anterior con
  `/plugin marketplace remove`); se corrige la afirmación falsa de que el cache hacía innecesaria la
  unidad de red.
- **Nuevo `.gitignore`** — fuera del repo publicado: `executions/`, `settings.local.json`,
  `docs/superpowers/` y `.superpowers/` (planes y specs de sesiones de desarrollo del propio plugin,
  con hosts de BD, usuarios y nombres de proyecto de cliente).
- **Contrato de tools MCP (BREAKING para los agentes)** — `mcp__rs-workspace__*` →
  `mcp__plugin_rs-enterprise-agent_rs-workspace__*` en 142 referencias de 40 ficheros (frontmatter
  `tools:` de los 27 agentes, comandos, skills, references y docs). El nombre corto no lo aportaba el
  plugin sino un registro manual en `~/.claude.json` que apuntaba al árbol fuente de quien lo creó;
  el namespaced lo aporta `.mcp.json` del propio plugin. El plugin queda autocontenido.
- **`scripts/cleanup-preplugin.ps1`** — eliminada la lista de rutas absolutas
  (`$env:RS_SKILL_SRC` → unidad de red → árbol de desarrollo → `$pluginRoot`) y toda la rama de
  "repunte" del MCP, que era justo lo que ataba el plugin a una ruta concreta. Ahora **elimina** el
  registro global `rs-workspace` de `~/.claude.json` (ya sobra), con backup previo en
  `~/.claude/_backup-preplugin-<fecha>/`. La edición es textual y se valida con la nueva
  `Test-JsonEstructura`: `~/.claude.json` tiene claves que solo difieren en mayúsculas
  (`ConvertFrom-Json` aborta) y `Test-Json` no existe en Windows PowerShell 5.1, que es quien ejecuta
  los hooks.
- **`hooks/skill-trigger.ps1`** — el gate dejaba pasar solo rutas que contuvieran `\SVN\RS\`. Ahora
  detecta el workspace por estructura (`Batch\Soluciones`, `OnLine\Soluciones`,
  `OnLine\AISServiceManager`, `docs\.rs-databases.json`), con override `$env:RS_WORKSPACE_MATCH`.

### Anonimización de datos de cliente

El repo se reparte a todos los usuarios del plugin, así que no puede llevar nombres de proyecto de
cliente. Sustituidos por el placeholder `<Proyecto>` / `<proyecto>` / `MIPROYECTO`:

- **19 hooks** — ejemplos `.EXAMPLE` y rutas `C:\Desarrollo\SVN|Git\...` → `C:\SVN|Git\RS\<Proyecto>\trunk`.
- **Triggers de la skill** (`plugin.json`, `skills/rs-enterprise-agent/SKILL.md`,
  `commands/rs-enterprise-agent.md`, `commands/rs-instalador.md`) y ejemplos de
  `agents/rs-editor-core.md`, `agents/rs-editor-planner.md`, `agents/rs-validar-entorno.md`,
  `references/arquitectura.md`, `references/json-schema.md`, `scripts/installer-objects.py`.
- **`scripts/erd-template.html`** — además de anonimizar, **fix real**: `generateTableSQL` emitía
  `CREATE TABLE`/`CREATE INDEX` con un schema hardcodeado en lugar del schema del modelo; ahora usa
  `_sch()`.

### Documentación

- **`docs/plugin-architecture.md`** — nueva §1.1 "Dónde se ejecuta realmente el plugin": tabla
  marketplace `git` vs `directory`, qué raíz efectiva implica cada uno, y cómo verificarlo
  (`Get-CimInstance Win32_Process` sobre el proceso python del MCP).
- **`skills/rs-enterprise-agent/SKILL.md`** — la comprobación de instalación duplicada cubre ahora
  también el caso "MCP servido desde una unidad de red o un árbol de desarrollo".
- **`skills/rs-plugin-dev/SKILL.md`** y **`README.md`** — el alcance y la fuente canónica se definen
  por `plugin_root` / el repo Git, no por una ruta fija.

## 2.13.0 — 2026-07-21

### Cambio de formato de configuración de BD (BREAKING)

`docs\XMLConfig.xml` queda sustituido por `docs\.rs-databases.json`, que soporta N conexiones.
Motivación: <Proyecto> se despliega sobre Oracle y SQL Server desde el mismo modelo lógico, y
hacía falta declarar ambos motores para generar el DDL de los dos.

- **Nuevo** `hooks\lib-dbconfig.ps1` — lectura y validación del formato, y parseo de cadenas de
  conexión. Único sitio que conoce el formato.
- **Nuevo** `hooks\convert-config.ps1 <workspace> [-Force]` — convierte el XMLConfig existente.
  No borra el XML.
- `get-config.ps1` mantiene todos sus campos planos (= conexión principal, `conexiones[0]`) y
  añade `conexiones[]` y `motores[]`. Retrocompatible para workspaces de una sola conexión.
- `db-query.ps1` y `db_query` aceptan `-Conexion` / `conexion` (id). Sin él, la principal.
- `generate_sql` sin `motor` genera un fichero DDL por cada motor declarado.
- `check-env.ps1` valida el JSON (conexiones no vacías, ids únicos, motor soportado) y da FAIL
  con instrucciones si el workspace no está migrado.
- `compare-model.ps1`, `sync-from-db.ps1`, `sync-indexes.ps1`, `sync-model-tables.ps1` y
  `scripts\installer-inserts.py` también dejan de leer `XMLConfig.xml` y pasan por
  `lib-dbconfig.ps1` (el `.py`, al no poder dot-sourcear el `.ps1`, replica la lectura directa del
  JSON que ya usa `_get_db_password` en el MCP server). Los cinco operan solo sobre la conexión
  principal.
- **Sin fallback a XML.** Verificado: ningún camino de código lee ya `XMLConfig.xml` — las únicas
  referencias que quedan son la detección de legacy en `hooks\lib-dbconfig.ps1` y
  `hooks\check-env.ps1` (le dicen a un workspace sin migrar qué comando de conversión ejecutar), más
  `hooks\convert-config.ps1`, que lee el XML porque es justamente el conversor.

`generate_migration` sigue operando solo sobre la conexión principal: compara contra la BD real
y solo la principal se consulta.

### Consultas a BD: resultados estructurados y cuatro bugs de fondo

`db_query` devolvía las líneas de texto tal cual las escupía el cliente SQL. Ahora devuelve
`columns[]` (los nombres una sola vez) y `rows[]` (listas de valores en ese mismo orden) — forma
compacta, un 19% menos de contexto que el texto crudo que sustituye. Lo que se arregla por el
camino, todo verificado contra la BD de <Proyecto>:

- **Nombres de columna truncados.** Con salida tabular, sqlplus recorta la cabecera al ancho del
  campo: una columna `IDIOMA` con valores `'ES'` se anunciaba como `ID`. El agente recibía —y podía
  usar en el SQL que generaba— un nombre de columna que no existe en la BD. Ahora se usa
  `SET MARKUP CSV` (sqlplus 12.2+), que da el nombre completo.
- **Cabeceras contadas como datos.** Con `PAGESIZE 50`, sqlplus repite la cabecera cada 48 filas y
  todas ellas entraban en `rows`. `row_count` devolvía 62 para una consulta de 60 filas, y 2 para
  un escalar de 1 fila.
- **Un error SQL se reportaba como éxito.** Faltaba `WHENEVER SQLERROR EXIT SQL.SQLCODE`, así que
  sqlplus salía con código 0 ante un `ORA-` y la respuesta era `success: true` con 0 filas —
  indistinguible de "la tabla está vacía". Los `ORA-`/`SP2-` se leen ahora de stdout, que es donde
  sqlplus los escribe.
- **La rama SQL Server ignoraba la contraseña.** Construía el `sqlcmd` sin `-U`/`-P`, forzando
  autenticación integrada de Windows aunque la config declarase usuario y contraseña.

`hooks\db-query.ps1` recibe los mismos arreglos de fondo (`MARKUP CSV`, `WHENEVER SQLERROR`), y
además escribía su `.sql` temporal con BOM (rompía el primer `SET` con `SP2-0734`) y colapsaba a
escalar con una sola fila o columna, produciendo claves no-string que hacían fallar
`ConvertTo-Json`. Su forma de salida **no** es la de la tool: el hook devuelve
`rows: [{columna: valor}]` y `truncated`, mientras la tool devuelve `columns[]` + `rows[][]` y
`rows_truncated`. Solo importa a quien invoque el hook a mano — el plugin no lo llama.

⚠️ La rama SQL Server no ha podido verificarse contra un servidor real: la cuenta de la conexión
SQL Server de <Proyecto> está deshabilitada. Oracle sí está verificado extremo a extremo.

- Un `XMLConfig.xml` en formato `<Conexion>` con motor SQLSERVER cuyo connection string incluya
  `Database=` ahora produce `schema` = ese catálogo, donde el hook antiguo emitía `schema` vacío.
  Verificado con fixtures ejecutando ambas versiones. Es una corrección: el valor vacío se pasaba
  a `sqlcmd -d`. Ningún proyecto actual usa esa combinación.
- La misma corrección aplica en `sync-from-db.ps1`: con motor SQLSERVER pasaba `-d` vacío a
  `sqlcmd` (bug preexistente en el hook antiguo); ahora pasa el catálogo real (`dataBase` de la
  conexión, o `Database=` de la cadena como fallback). Decisión consciente: se documenta como
  desviación intencional para que no sorprenda a quien compare comportamiento antiguo vs nuevo.
  Ningún proyecto actual usa esa combinación.

**Migración:** ejecutar `hooks\convert-config.ps1` en cada workspace. El conversor no borra el
`XMLConfig.xml`: retirarlo debe hacerse en un commit aparte y solo después de que esta versión del
plugin esté desplegada, porque una versión anterior sigue leyendo el XML y se quedaría sin config.

**Sobre versionar el JSON:** el fichero contiene el password dentro de `cadena`, igual que hacía
`XMLConfig.xml`. Si el workspace declara varias conexiones, concentra todas sus credenciales en un
único fichero. Queda a criterio de cada proyecto versionarlo o dejarlo fuera del control de
versiones (como ya está `docs\.jira-dev-config.json`) y generarlo por desarrollador con el
conversor.

## 2.12.2 — 2026-07-21

Auditoría del DDL del instalador contra la BD real de <Proyecto> (316 tablas): el script generado
**no se podía ejecutar entero**. Dos defectos de `installer-ddl.py` lo rompían y un tercero
degradaba las PK.

- **La coma separadora quedaba dentro del comentario de columna → `ORA-00907`.** El generador
  concatenaba `  -- <descripcion>` al final de la línea de columna y luego unía las líneas con
  `',\n'`, así que salía `COL VARCHAR2(40) NOT NULL  -- texto,` y la coma no separaba nada.
  Afectaba a 23 columnas en 11 tablas —justo las centrales: RBGES, RCLIENTECS, RCONVP, RESPECIE,
  ROBCL, ROBLG, RPRODUCTOS, RRELARATR, RTARS, RTARSDISC, RUSUARIOS—. Confirmado con el parser real
  de Oracle sobre el bloque de RCLIENTECS. Ahora la coma se emite **antes** del comentario.
- **Índice con el mismo nombre que la PK de su tabla → `ORA-00955`.** El filtro que evitaba emitir
  el índice que respalda la PK comparaba la lista de columnas *en orden*; si el modelo traía el
  índice con las columnas ordenadas distinto, se colaba un `CREATE UNIQUE INDEX PK_<tabla>` además
  del `CONSTRAINT PK_<tabla>` inline. Pasaba con `PK_RPAGOS` y `PK_RHTELE`. Ahora se compara por
  conjunto de columnas y, además, se descarta cualquier índice cuyo nombre sea el de la constraint.
- **Orden de columnas de la PK.** `pk_cols` salía del orden de declaración de las columnas, no de
  la posición real dentro de la PK: 19 tablas generaban la PK con las columnas en otro orden que
  producción (RTBGES, RCOMPAGO, RHLOTE, RMAILS, RTELE...), lo que cambia el índice que la respalda
  y tira los accesos por prefijo de clave. `pk` pasa a admitir un **entero con la posición** además
  del booleano; nueva función `pk_columns()` que ordena por él (retrocompatible: `bool` se descarta
  explícitamente antes de tratarlo como ordinal, porque en Python `True` es `1`).
  Documentado en `references/json-schema.md`.
- **Verificación tras el arreglo** (<Proyecto>, 380 tablas emitidas): 0 comas dentro de comentario,
  0 errores estructurales de separador, 0 índices con nombre de PK, 267/267 PK con las columnas en
  el mismo orden que la BD, 65/65 índices no-PK reales presentes con columnas y unicidad idénticas,
  y los 74 índices emitidos existen los 74 en la BD.
- **Ficheros**: `scripts/installer-ddl.py`, `references/json-schema.md`.

## 2.12.1 — 2026-07-20

Tres fallos reales detectados ejecutando `/rs-instalador` de principio a fin sobre <Proyecto> (Oracle).
El instalador terminaba con AgendaWeb sin publicar y 23 de 94 tablas paramétricas sin inserts.

- **`installer-agendaweb.ps1`: el publish generaba un `.zip` en vez de publicar a carpeta.** Con
  `/p:DeployOnBuild=true` pero **sin** `DeployTarget`, msbuild elige el target `Package` y deja
  `obj\Release\Package\<app>.zip`; el hook abortaba con `ERROR: publish sin ficheros`.
  - Se añade `/p:DeployTarget=WebPublish` y se pasa el `agendaweb.publishProfile` del JSON de config
    como `/p:PublishProfile` (p.ej. `FolderProfile`).
  - `publishUrl` sigue forzado al Instalador como propiedad global —gana al `<PublishUrl>` del
    `.pubxml`, que apunta al AIS **en vivo**— y se añade `/p:DeleteExistingFiles=false` como red de
    seguridad: si el override fallara, el peor caso es añadir ficheros al AIS, no borrarlo.
  - Verificado en real: `Publish profile: FolderProfile`, 544 ficheros en
    `C:\AIS\<Proyecto>\Instalador\AgendaWeb`, sin `.zip`, exit 0.
- **`installer-inserts.py`: 23 tablas sin inserts por tres defectos del generador de SQL.**
  - `SP2-0341` en tablas anchas (RCARTERA 34 columnas, RCARTERA_DEL, RPARAM): el SELECT de
    concatenación se emitía en **una sola línea**. Ahora va una expresión por línea.
  - `ORA-01489` latente por el mismo motivo: la primera expresión se envuelve en `TO_CLOB` para que
    toda la concatenación sea CLOB en vez de quedarse en el límite de 4000 de `VARCHAR2`.
  - `ORA-00932 expected NUMBER got BINARY` (RCENTMENSA `CMIDHILO`/`CMIDMENSAJE`, CUSUARIO `CUID`):
    se aplicaba `TO_CHAR` a columnas `RAW`. Ahora los binarios cortos (`RAW`/`VARBINARY`/`BINARY`)
    viajan en hexadecimal y se reconstruyen en el INSERT (`HEXTORAW('..')` en Oracle, literal `0x..`
    en SQL Server).
  - Los LOB binarios (`BLOB`/`LONG RAW`/`IMAGE`) no son inlineables en un INSERT de texto: se emiten
    como `NULL` y se avisa en la cabecera del `.sql` con la lista de columnas afectadas, en vez de
    reventar la tabla entera.
  - Verificado contra la BD real de <Proyecto>: las 5 tablas que fallaban generan ahora
    (RCARTERA 178, RCARTERA_DEL 181, RPARAM 1, RCENTMENSA 10, CUSUARIO 6 filas).
- **11 hooks `.ps1` guardados sin BOM no parseaban en Windows PowerShell 5.1.** `plugin.json` y
  `runner/runner.ps1` invocan `powershell -File ...` (5.1), que sin BOM decodifica el fichero con la
  codepage ANSI: los acentos rompían literales y bloques (`Falta la cadena en el terminador: "`,
  `Falta el nombre de tipo después de '['`). Fallaban los 4 hooks del instalador y
  `git-diff-revision.ps1`; los otros 6 eran latentes (mojibake en pantalla).
  - Reguardados en **UTF-8 con BOM** (solo cambia el BOM, cero cambios de código):
    `detect-vcs`, `git-add`, `git-diff-revision`, `git-log`, `git-status`, `installer-agendaweb`,
    `installer-batch`, `installer-scripts`, `installer-servicemanager`, `jira-attach`,
    `sync-model-tables`.
  - Convención documentada en `hooks/README.md` con el snippet de comprobación. Antes: 48/53 `.ps1`
    parseaban bajo 5.1; ahora **53/53**.
- **No reproducido**: el reporte incluía un cuarto fallo (`db-query.ps1` línea 110, `ConvertTo-Json`
  con `OrderedDictionary` bajo pwsh 7). Comprobado en pwsh 7.6.3 y en PS 5.1: serializa correctamente
  (`{"rows":[{"A":1,"B":2}]}`). No se toca. Queda anotado que el defecto real conocido de `db_query`
  con multicolumna está en el `-split '\|'` (valores que contienen `|`), pendiente de abordar aparte.
- **Ficheros**: `hooks/installer-agendaweb.ps1`, `scripts/installer-inserts.py`, 11 `.ps1`
  reguardados con BOM, `hooks/README.md`, `references/hooks.md`.

## 2.12.0 — 2026-07-20

- **`${CLAUDE_PLUGIN_ROOT}` no se expande en markdown — el contrato `skill_dir` apuntaba a la carpeta
  equivocada.** Síntoma reportado al ejecutar `/rs-instalador`: el agente avisaba de que el `skill_dir`
  recibido (`...\2.11.0\skills\rs-enterprise-agent`) no contenía `hooks\` ni `runner\`, y tenía que
  deducir la raíz del plugin por su cuenta.
  - **Diagnóstico**: Claude Code solo sustituye `${CLAUDE_PLUGIN_ROOT}` en `.claude-plugin/plugin.json`
    y `.mcp.json` (JSON). En `skills/*/SKILL.md`, `agents/*.md` y `commands/*.md` la variable llega
    literal y la resuelve el modelo — que la interpretaba como la carpeta de la propia skill, donde no
    hay `hooks\` ni `runner\` (issues upstream anthropics/claude-code #9354 y #9427). El nombre
    `skill_dir`, introducido en la migración a plugin de la 2.6.0, reforzaba justo la lectura errónea.
  - **Defecto adicional**: 8 comandos pasaban «`skill_dir` (resolved in PASO 0)», pero el bloque
    `PASO 0` se eliminó de `SKILL.md` en esa misma migración (ver entrada 2.6.0) — referencia colgante
    desde entonces. Solo reventaba de forma visible en `rs-instalador` y `rs-editor-build`, los que
    ejecutan `runner\` por ruta literal; los otros 10 agentes fallaban en silencio al leer `references\`.
- **Contrato renombrado `skill_dir` → `plugin_root`** en los 22 ficheros del contrato de invocación
  (9 `commands/*.md` + 13 `agents/*.md`), incluidas las rutas `$skill_dir\references\...`. El nombre
  ahora describe lo que es: la raíz del plugin, no la carpeta de la skill.
- **Regla canónica de resolución** — nueva sección `# Raíz del plugin (plugin_root)` en
  `skills/rs-enterprise-agent/SKILL.md`: partir de la ruta inyectada, si termina en `\skills\<algo>`
  subir dos niveles, **verificar con Glob que contiene `hooks\` y `runner\`**, subir un nivel más hasta
  3 saltos y, si no aparecen, detener y pedir la ruta — nunca inventarla ni asumir una versión del
  caché. Incluye el ⛔ de no usar `${CLAUDE_PLUGIN_ROOT}` como ruta en markdown.
- **Verificación defensiva** en los tres agentes que ejecutan `runner\`/`hooks\` por ruta
  (`rs-instalador`, `rs-editor-build`, `rs-editor-db-modeler`): comprueban el `plugin_root` recibido
  antes de usarlo, en vez de confiar en que el orquestador acierte.
- **Ficheros alineados**: `skills/rs-plugin-dev/SKILL.md` (alcance, fuente canónica y auto-verificación),
  `commands/rs-tarea.md` (lectura de `skills/rs-jira/SKILL.md`), `agents/rs-idiomas-standalone.md`,
  y `docs/plugin-architecture.md` (§3 contrato de invocación + §11.4 nueva inconsistencia conocida).
  No se tocan `plugin.json`, `.mcp.json`, `hooks/README.md` ni `README.md`: ahí la variable sí se expande.

## 2.11.0 — 2026-07-20

- **El pipeline se estaba ejecutando sobre una instalación fantasma pre-plugin.** Síntoma reportado:
  dos desarrollos seguidos sobre `AgendaWeb<Proyecto>.sln` no propusieron plan y fueron directos a
  implementar. Ni `SKILL.md` ni `agents/rs-editor-planner.md` tenían el fallo — los subagentes se
  resolvían contra restos de la instalación manual anterior al plugin.
  - **Diagnóstico** (logs de sesión en `~/.claude/projects/n--SVN-RS-<Proyecto>-trunk/`): la traza
    ejecutó `planner → core → analyzer → validator → tester → build` **en un solo turno**.
    `rs-editor-analyzer` y `rs-editor-bd` se eliminaron en la v2.7.0 y no existen en el caché del
    plugin: solo en `~/.claude/agents/` (7-jul). El planner de esa copia es "Etapa 1", `sonnet`, sin
    tools de BD, y su contrato es `SUMMARY` + `STATUS` — **sin bloque `PLAN` ni `STAGES`**. Sin `PLAN`
    el orquestador no tiene qué presentar en el Gate A (no para), y sin `STAGES` recae en la secuencia
    fija antigua. De ahí "no propone plan y lanza core".
  - **Cuatro superficies obsoletas** encontradas y retiradas a `~/.claude/_backup-preplugin-2026-07-20/`:
    `~/.claude/agents/` (28 ficheros), `~/.claude/commands/` (20), `~/.claude/rs-skill-full/` (server
    MCP + 38 hooks + scripts, 7-jul) y `~/.claude/hooks/rs` + `hooks/scripts` (25/29-jun).
  - **El MCP también servía de la copia**: `~/.claude.json` registraba globalmente `rs-workspace`
    apuntando a `~/.claude/rs-skill-full/mcp/rs-workspace-server.py`; como el server resuelve
    `HOOKS_DIR = __file__/../hooks`, **todas** las tools `mcp__rs-workspace__*` ejecutaban hooks del
    7-jul. Repuntado al árbol fuente. Se repunta y no se elimina porque el nombre `mcp__rs-workspace__*`
    está en el `tools:` de todos los agentes. Corolario: el trabajo del ERD de las v2.9.0/2.10.0 no se
    estaba aplicando (se generaba con la plantilla del 29-jun), lo que además explica por qué el ERD
    desplegado parseaba pese a los errores de sintaxis que corrigió la 2.9.0.
  - **Hooks duplicados**: `~/.claude/settings.json` registraba `skill-trigger.ps1` y `runner.ps1` de
    la copia vendorizada, los mismos dos que ya declara `plugin.json` — corrían por duplicado en cada
    prompt. Registro de usuario eliminado; queda solo el del plugin.
- **Remediación automática para el resto del equipo.** `/plugin marketplace update` solo refresca el
  caché del plugin: no toca `~/.claude/agents`, `~/.claude/commands`, `~/.claude.json` ni
  `~/.claude/settings.json`, así que **la limpieza no llega sola** a quien ejecutara en su día
  `install-hooks.ps1`. Y quedaban atrapados en un círculo: su `~/.claude/commands/rs-env.md` sombrea
  al del plugin, con lo que mandarles ejecutar `/rs-env` corre el comando viejo → agente viejo →
  hook viejo. El único vector que escapa es un hook declarado por el propio `plugin.json`, que se
  ejecuta desde `${CLAUDE_PLUGIN_ROOT}` sin pasar por comandos, agentes ni MCP:
  - **`scripts/cleanup-preplugin.ps1`** (nuevo) — detecta y retira las cuatro superficies, repunta el
    MCP y quita los hooks duplicados. **No borra nada**: mueve a
    `~/.claude/_backup-preplugin-<fecha>/`. Idempotente (marca `~/.claude/.rs-preplugin-cleaned`),
    con `-WhatIf` y `-Quiet`.
  - **Hook `SessionStart`** en `plugin.json` — lo ejecuta con `-Quiet` al arrancar cada sesión: quien
    actualice a esta versión queda limpio en el siguiente arranque, con informe de lo movido y aviso
    de reinicio. Silencioso si no hay nada que limpiar.
  - El registro global `rs-workspace` se **repunta, nunca se elimina** (ver caveat abajo). Destino por
    orden: `$env:RS_SKILL_SRC` → `N:\SVN\...\rs-skill-full` → `C:\Desarrollo\SVN\...` → raíz del
    plugin. Se evita apuntar al caché porque su ruta lleva la versión y se rompería en cada update.
- ⚠️ **Caveat arquitectónico detectado (sin resolver).** Los 27 agentes declaran
  `mcp__rs-workspace__*` en su `tools:`, nombre que **solo existe gracias al registro global** que
  creaba el instalador legacy. El `.mcp.json` del plugin publica el servidor como
  `mcp__plugin_rs-enterprise-agent_rs-workspace__*`, que ningún agente declara. Es decir: una
  instalación **solo-plugin** deja a los 27 agentes sin ninguna tool MCP. Por eso la limpieza repunta
  el registro en vez de quitarlo. Falta decidir el arreglo de fondo (renombrar en los 27 `tools:` o
  replantear el `.mcp.json`).
- **Ficheros PowerShell sin BOM.** `scripts/cleanup-preplugin.ps1` y `hooks/skill-trigger.ps1` se
  guardaban en UTF-8 sin BOM; los hooks se lanzan con `powershell` (5.1), que sin BOM lee el fichero
  como ANSI y rompe los caracteres no ASCII — `skill-trigger.ps1` llevaba tiempo inyectando su
  recordatorio con los acentos corrompidos, y el script nuevo directamente no parseaba. Añadido BOM a
  ambos (el resto de hooks ya lo tenían). Verificado con el parser de Windows PowerShell 5.1.
- **Blindaje para que no pueda repetirse:**
  - `mcp/rs-workspace-server.py` — `ping` devuelve ahora **`version`** (leída del `plugin.json`
    contiguo) y **`server_path`**. `SKILL.md` (`# Auto-verificación`) aborta si `server_path` no
    cuelga del plugin ni del árbol fuente. Es el guardián más barato: `ping` ya se llamaba al inicio
    de cada ejecución y su `hooks_dir` habría delatado esto desde el primer día.
  - `hooks/check-env.ps1` — nuevo check **"Coherencia instalación"** (`/rs-env`): detecta
    `~/.claude/agents/rs-*.md`, `~/.claude/commands/rs-*.md`, `~/.claude/rs-skill-full/`,
    `~/.claude/hooks/rs|scripts`, y verifica a qué ruta apunta el `rs-workspace` de `~/.claude.json`.
    `FAIL` → `overall: BLOQUEANTE`.
  - `SKILL.md` — los subagentes del pipeline se invocan **con prefijo de plugin**
    (`rs-enterprise-agent:rs-editor-*`): un nombre prefijado no lo puede ocupar un fichero suelto de
    `~/.claude/agents/`.
  - `SKILL.md` paso 2 — **fail-fast de contrato**: si la respuesta del planner no contiene bloque
    `STAGES`, detener con "planner devolvió contrato antiguo". Antes degradaba en silencio a "sin plan".
  - `scripts/install-hooks.ps1` — **marcado obsoleto**: es quien creaba las copias. Aborta con
    `exit 2` y remite a `/plugin install` + `/rs-env`; solo continúa con `-Force`.
- **Segundo defecto, independiente — los seguimientos no entraban al pipeline.** El otro desarrollo
  ("FrmCambioPass.aspx da errores de compilación") ejecutó `general-purpose → core`, sin planner: el
  disparador exigía el patrón `<Sln>.sln - <cambio>` y un seguimiento dentro de una sesión abierta no
  lo repite, así que no era "petición de pipeline" ni encajaba en ningún modo directo. Nueva regla en
  `# Modos directos`: **resuelta una solución en la sesión, cualquier petición posterior de cambio de
  código vuelve a entrar por el paso 2** (Planner + Gate A) aunque no repita el `.sln`; los modos
  directos y las consultas de solo lectura mantienen prioridad.
- `agents/rs-editor-db-modeler.md` — "Mostrar ERD" deja de invocar
  `$env:USERPROFILE\.claude\hooks\rs\render-erd.ps1` y usa `<skill_dir>\hooks\render-erd.ps1`.
- ⚠️ **Pendiente de revisar**: `executions/history.json` del workspace no tiene entradas desde el
  29-jun pese a que el paso 5 es "Log SIEMPRE" — `/rs-historial` y `/rs-stats` están ciegos para ese
  periodo. Probablemente mismo origen (el `log_execution` de la copia vieja); verificar tras reiniciar.

## 2.10.0 — 2026-07-20

- **Toolbar del ERD reorganizada en menús por función.** La barra acumulaba **26 controles en una
  fila** con `overflow-x:auto`: en cualquier pantalla por debajo de ~2000px la mitad quedaba fuera y
  había que hacer scroll horizontal para llegar a acciones cotidianas, sin distinguir lo diario
  (buscar, filtrar, encuadrar, guardar) de lo esporádico (importar DDL, exportar CSV, stats).
  - **Visible en barra**: título · selector de subvista · buscador · `Filtro ▾` · chip de filtro
    activo · `Fit view` · `PKs` · `Guardar` · los 4 menús · `?` · contadores. De 26 a 17 elementos.
  - **`Vista ▾`** — Auto layout, Gestor de subvistas, Nueva vista desde selección, Relaciones…,
    Presentación. **`Modelo ▾`** — Tabla +, Sugerir FKs, Validar, Stats. **`Exportar ▾`** — SQL
    Oracle/Server, SVG, PNG, los 4 CSV y las 2 fichas. **`Importar ▾`** — Abrir modelo…, Import DDL,
    Import Índices.
  - **Chip de filtro activo**: al filtrar por patrón o desmarcar confianzas de relación aparece
    junto al buscador un chip `Patrón: AG* · Relaciones: 3 de 4` con una ✕ que limpia todo
    (`clearAllFilters()`). Sustituye al aviso anterior —el botón se teñía de azul—, que se habría
    perdido al mover el control dentro de un menú.
  - **Un solo mecanismo de menú**: `toggleMenu(btn, popupId, align)` + `closeMenu()` +
    `runFromMenu(fn)` reemplazan las tres funciones casi idénticas que había
    (`togglePatternFilterPopup`, `toggleRelFilterPopup`, `toggleExportCSVPopup`). Aporta lo que
    antes no había: abrir un menú **cierra el anterior** (podían quedar dos abiertos), cierre con
    **Esc**, y clamp contra el borde derecho de la ventana. El rect del botón se toma **antes** de
    cerrar, porque "Relaciones…" vive dentro del menú Vista y si no quedaría un rect a cero.
  - **CSS**: los estilos inline repetidos de los tres popups pasan a las clases `.menu-popup` /
    `.menu-item` / `.menu-label` / `.menu-sep`, más `.tb-sep` y `#filter-chip`. `max-width:340px` en
    `.menu-popup` corrige de paso que el popup de confianza de relaciones se estirase a **1011px**
    (no tenía tope y sus textos largos no envolvían).
  - **Responsive**: por debajo de 1150px se ocultan los contadores y se recortan título, buscador y
    selector — primero se sacrifica información, nunca controles. Verificado sin scroll horizontal a
    1100px y 1280px con el modelo real de 379 tablas.
  - `agents/rs-editor-db-modeler.md` y `README.md` actualizados: "Abrir modelo…" ahora está en
    `Importar ▾`.

## 2.9.0 — 2026-07-20

- **El ERD HTML ya no caduca: carga el modelo JSON en caliente.** Hasta ahora
  `BD\<proyecto>-erd.html` era un snapshot — `render-erd.py` incrustaba el modelo serializado en la
  plantilla, así que cualquier cambio en `BD\<proyecto>-model.json` (`sync_from_db`, `analyze_dalc`,
  `sync_indexes`, edición manual) obligaba a regenerar el HTML o se miraba un ERD obsoleto sin aviso.
  `fetch()` sobre `file://` está bloqueado por CORS, pero la File System Access API sí funciona ahí:
  - **`scripts/erd-template.html`**: nuevo botón **"Abrir modelo…"** (`openModelFile()`) que usa
    `showOpenFilePicker` con fallback a `<input type="file">` + `FileReader`; `applyLoadedModel()`
    valida el JSON (tolerante a BOM, como `utf-8-sig` en el render), reemplaza `MODEL` y
    re-renderiza. El modelo embebido se mantiene como arranque por defecto (regresión cero).
  - `init()` se parte en `init()` (cableado de eventos, una vez) + **`renderModel()`** (todo lo que
    depende de `MODEL`, re-entrante: limpia cajas, `positions`, `_elCache`, selección y undo/redo).
  - **`resizeCanvas(n)`** calcula lienzo y modo compacto en cliente con la misma fórmula que tenía
    `render-erd.py`, de modo que el HTML se adapta al modelo que se le cargue.
  - El placeholder `{proyecto}` deja de estar hardcodeado en ~20 sitios (título, `LS_KEY`, nombres de
    export CSV/SVG/PNG/DDL/validación): pasa a la variable `PRJ`, que se recalcula del nombre del
    fichero abierto. Un mismo HTML sirve ya para cualquier proyecto.
  - **`saveModel()`** reutiliza el handle de "Abrir modelo…" (pidiendo permiso `readwrite`) y escribe
    **sobre el fichero real** — se acabó el "descárgalo y cópialo a mano al workspace", que queda
    solo como fallback para navegadores sin la API.
  - **`scripts/render-erd.py`**: dejan de inyectarse `{canvas_w}`/`{canvas_h}`/`{compact_js}` (los
    calcula el cliente); se conservan `{proyecto}`, `{model_json}`, `{render_ts}`, `{table_count}`,
    `{rel_count}`.
  - **`agents/rs-editor-db-modeler.md`**: la sección "Mostrar ERD" indica que, si el HTML ya existe y
    solo cambió el modelo, se usa "Abrir modelo…" en vez de regenerar.
- **Fix: la plantilla del ERD tenía dos errores de sintaxis que dejaban muerto el `<script>` entero.**
  Detectados con `node --check` sobre el HTML generado; afectaban a código añadido después del último
  ERD desplegado (el desplegado del 14-jul sí parseaba), o sea que cualquier ERD regenerado desde el
  repo habría salido en blanco:
  - `validateModel()` — `errs.map(i=>{...i,type:'error'})`: arrow devolviendo object literal sin
    paréntesis, que JS lee como bloque con rest parameter → `SyntaxError`.
  - `parseDDL()` / importador de índices / `ensureOracleChar` auxiliares — literales de regex con los
    backslashes duplicados (`/CREATE\\s+TABLE.../`), que además de romper el parseo (`\\(` abría un
    grupo sin cerrar) hacían no funcionales *Import DDL* e *Import Índices*.
  - **Escapes dobles en cadenas** (mismo origen, defecto que arrastraba también el ERD desplegado):
    ~20 literales usaban `'\\n'` y `'\\u2713'` donde se quería `'\n'` y `'✓'`. Efecto real: el DDL
    generado (`SQL Oracle`/`SQL Server`), los CSV de columnas/relaciones/índices/tablas/ficha, el SVG
    exportado y el informe de validación salían **en una sola línea con `\n` literal**, y los iconos
    de estado se imprimían como `✓`/`✕`/`⚠`. Corregidos a saltos reales y a los
    caracteres UTF-8 (`✓ ✕ ⚠ ¿`). Se respetan los dos usos donde el backslash doble **sí** era
    intencionado: el escapado de metacaracteres en el filtro por patrón y el separador de rutas
    Windows en el toast de descarga.

## 2.8.0 — 2026-07-20

- **Nuevo modo directo `/rs-instalador`** — genera el **instalador completo de cliente** (instalación
  limpia del producto en el servidor destino) en `C:\AIS\<Proyecto>\Instalador\`:
  - `EXES\` — procesos batch **activos del cliente** compilados en Release. La lista de procesos
    activos se lee de un nuevo JSON de config por cliente `docs\<Proyecto>-instalador.json` (campo
    `batch`); si el JSON no existe, el agente lo crea preguntando qué soluciones/módulos añadir; si
    existe, lo muestra y pregunta si añadir alguno más antes de compilar.
  - `AgendaWeb\` — publicación FileSystem (msbuild) de la Agenda Web, forzando el destino a la carpeta
    del instalador (no usa el `<PublishUrl>` del `.pubxml`, que apunta al AIS en vivo).
  - `ServiceManager\` — `dotnet publish` (net8) del host `AIS.ServicesManager`, con `Modulos\`
    conteniendo solo las DLL de los **módulos activos** del cliente (deduplicadas contra el host).
  - `Scripts\` — `<Proyecto>-CreacionTablas.sql` (DDL de todas las tablas **sin schema** en tabla/PK/
    índices) e `Inserts\<TABLA>.sql` (un fichero por **tabla paramétrica**). La clasificación
    paramétrica se toma del `BD\<Proyecto>-model.json` → clave raíz `subviews` (vista `"Parametricas"`
    por defecto, configurable) — el model.json del agente, **no** Oracle Data Modeler.
  - **Ficheros nuevos**: `agents/rs-instalador.md` (Opus, orquestador), `commands/rs-instalador.md`,
    fila en `# Modos directos` de `skills/rs-enterprise-agent/SKILL.md`; hooks
    `hooks/installer-batch.ps1`, `hooks/installer-agendaweb.ps1`, `hooks/installer-servicemanager.ps1`,
    `hooks/installer-scripts.ps1` (patrón runner, sin tool MCP, como `batch-build`/`online-publish`);
    scripts `scripts/installer-ddl.py` (DDL sin schema, reutiliza la lógica de tipos de
    `generate-sql.py`) y `scripts/installer-inserts.py` (inserts por tabla, detección de NULL fiable
    vía CASE-wrap, conexión leída de `XMLConfig.xml` igual que `db_query`).
  - **Limitaciones conocidas** (documentadas): `installer-inserts.py` asume que los valores de las
    tablas paramétricas no contienen el delimitador `|@#@|` ni saltos de línea (filas así se omiten
    con AVISO); la etapa Scripts termina con exit 2 (AVISO, no FAIL) si alguna tabla da error de BD.

## 2.7.2 — 2026-07-17

- **Fix: `rs-editor-core` leía ficheros `.sql` de `BD\` como fuente de datos.** La prohibición ya
  existía, pero estaba **fragmentada y enterrada** como sub-bullets condicionales (línea de "orden de
  consulta" bajo el caso `ORA-00942`, y sección "Scripts SQL generados"), y la sección era
  **schema-céntrica** ("tipos/columnas") — no cubría de forma prominente el caso de **datos/valores
  de fila** (RIDIOMA/RCONTROLES/config/seed), que es donde falló. Correcciones:
  - **`agents/rs-editor-core.md`**: nueva **regla marco** al inicio de la sección BD ("Fuente de
    datos y esquema"), única, prominente e incondicional: esquema → modelo (`model.json`); datos →
    `db_query` directo; ⛔ nunca `.sql` de `BD\`. Los sub-bullets antiguos ahora **remiten** a ella
    en vez de repetirla parcialmente.
  - **`references/bd.md`**: sección "Fuente de datos" al inicio (donde `rs-editor-core.md` ya apunta),
    mismo patrón que el cableado de la regla CHAR en 2.7.1.
  - **`agents/rs-editor-planner.md`**: el plan tampoco puede instruir a core a *leer* un `.sql` de
    `BD\` como fuente (antes solo se prohibía nombrar rutas de escritura).
- **Fix: versión desincronizada entre manifiestos.** `plugin.json` estaba en `2.7.1` pero
  `marketplace.json` seguía en `2.7.0`. Como Claude Code detecta la actualización por la versión de
  `marketplace.json`, los cambios no se propagaban. Ambos quedan sincronizados en `2.7.2`.
- **Mejora: `rs-editor-core` gana un Procedimiento (orden obligatorio).** El agente estaba organizado
  por temas (15 secciones sueltas), sin flujo ordenado — el único `-editor` sin espina dorsal (a
  diferencia de validator "Paso 1/2" y fixer "Estrategia 1-5"), y con gates críticos enterrados
  ("leer docs ANTES de emitir código", CHECKLIST compuerta). Se añade una sección numerada de 10
  pasos (validación → scope → docs → localizar → esquema/datos → implementar → SQL → GATE CHECKLIST →
  señales de salida → Output), cada paso remitiendo a su sección de detalle, y se eleva la CHECKLIST
  a sub-encabezado `### GATE`. Evita que el agente se líe o salte pasos. Contrato de Output intacto.

## 2.7.1 — 2026-07-17

- **Fix: DDL Oracle emite `VARCHAR2(n CHAR)` en todo el pipeline.** Un script SQL generado por el
  pipeline salió con `VARCHAR2(20)` sin `CHAR`. En Oracle, sin `CHAR` la longitud es en bytes y
  trunca strings multibyte (UTF-8). El `model.json` guarda el tipo sin `CHAR` por diseño; el `CHAR`
  se inyecta al emitir el DDL. Causa raíz en dos frentes, corregidos ambos:
  - **Agentes que redactan DDL a mano sin la regla en contexto** (origen del bug): se cablea la regla
    CHAR + `references/bd.md` en `agents/rs-editor-core.md` (sección "Scripts SQL generados") y en
    `agents/rs-editor-db-modeler.md` (fallback de DDL a mano). Antes solo estaba en planner/migracion/validacion-bd.
  - **Generador `generate_migration`** (`hooks/generate-migration.ps1`): nuevo helper idempotente
    `Ensure-OracleChar` aplicado en la rama ORACLE de `Get-ColDef` (cubre CREATE/ADD/MODIFY); la rama
    SQL Server ahora quita `CHAR` (`VARCHAR2(n CHAR)` → `VARCHAR(n)`).
  - **Editor ERD** (`scripts/erd-template.html`): helper `ensureOracleChar` en las ramas ORACLE de
    `ddlAddColumn`/`ddlModifyColumn`/`ddlCreateTable`, `generateTableSQL` y el export DDL completo;
    aplicado solo con motor ORACLE para no ensuciar tipos SQL Server.
  - Ya correctos, sin cambios: `scripts/generate-sql.py` (`ensure_oracle_char_semantics`), `assets/erd-widget.html`.

## 2.7.0 — 2026-07-17

Release mayor de la arquitectura del pipeline y de la documentación (sube directo desde 2.5.3; la 2.6.0 intermedia no llegó a publicarse). Tres frentes: rediseño del pipeline, modos de análisis standalone y gestión de documentación.

- **Rediseño del pipeline: planner como cerebro + pipeline delgado dirigido por `STAGES`.** El
  pipeline estaba sobrecargado (11 pasos, hasta 9 subagentes, 3 condicionales dispersos por el
  orquestador, doble fuente de verdad en el planner) y fallaba de forma intermitente en los saltos
  entre etapas. Motivación: centralizar toda la decisión en un planner con datos reales y que el
  resto de agentes solo **apliquen** el plan aprobado por el humano.
  - **`rs-editor-planner` es ahora el cerebro** (`agents/rs-editor-planner.md`): sube a **opus** y
    gana tools MCP de lectura (`search_model`, `get_model_index`, `get_table_schema`, `get_db_config`,
    `db_query`, `find_symbol`, `batch_find_symbols`, `search_code`) — antes planificaba a ciegas con
    solo `Read/Grep/Glob`. Con `get_db_config`+`db_query` el planner es un **superconjunto estricto**
    del antiguo `rs-editor-bd` (mismo toolset BD, más contexto de código, y **antes** de escribir): la
    fusión no pierde profundidad de validación BD. `db_query` restringido a SELECT (no DDL/DML). Analiza símbolos y modelo BD reales, y emite un **contrato único**: bloque
    `PLAN` (para el gate humano) + `STAGES` (lista ordenada y autoritativa de etapas) + `CONTEXT` +
    `STATUS`. Se derogan los flags sueltos `CREATE_TESTS`/`UPDATE_DOCS` (eran doble fuente de verdad):
    todo se lee de `STAGES`.
  - **Pipeline dirigido por `STAGES`** (`skills/rs-enterprise-agent/SKILL.md`, `commands/rs-enterprise-agent.md`):
    el orquestador recorre la lista del planner y ejecuta cada token **sin re-decidir** qué etapas
    corren. Se eliminan los condicionales dispersos del orquestador. Única corrección empírica: red de
    seguridad que ejecuta `db-modeler` si core devuelve `TABLES_TOUCHED` aunque el planner no lo pusiera.
  - **Menos subagentes** (de 9 a 6 en el pipeline): **eliminado `rs-editor-bd`** (la validación de
    tipos/longitudes/compatibilidad de motor la hace el planner en la fase de análisis) y **fusionado
    `rs-editor-analyzer` dentro de `rs-editor-validator`** (el validator ahora compila + análisis
    estático + revisión lógica, con `search_code`/`security_scan` añadidos).
  - **SKILL.md adelgazado** (~175 → ~135 líneas): los gates 2b (aprobación) y 10b (checklist) + Log se
    extraen a la nueva **`references/gates.md`**; el gate de aprobación se enuncia una vez (antes
    repetido 4×) y baja la densidad de marcadores ⛔.
  - **Modos VCS unificados**: `rs-diff-svn`+`rs-diff-git` → **`rs-diff`** y `rs-commit-svn`+`rs-commit-git`
    → **`rs-commit`**, cada uno ramificando internamente según `detect_vcs`. Comandos `/rs-diff` y
    `/rs-commit` actualizados. Total de agentes 28 → 24.
  - Docs sincronizadas: `docs/plugin-architecture.md` (§3/§4/§5/§8), `README.md` (tabla de pipeline),
    design spec (nota de actualización).
- **3 modos directos nuevos para análisis/validación fuera del pipeline.** Al fusionar `bd`/`analyzer`
  en el pipeline quedaron capacidades que solo eran invocables dentro de un run; se exponen ahora como
  modos ad-hoc (patrón §9.1: agente + comando + fila en la tabla de modos), **sin duplicar lógica** —
  comparten la fuente de reglas (`references/bd.md`) con las etapas del pipeline:
  - **`/rs-validar-bd`** (`rs-validacion-bd`, 🔷 sonnet) — valida código C# (DALC/clase/tabla) contra la
    BD real: tipos, longitudes (truncamiento silencioso), nullabilidad y compatibilidad de motor. Es la
    versión standalone de la validación BD que hace el planner.
  - **`/rs-analizar`** (`rs-analisis`, 🔷 sonnet) — análisis estático de calidad/riesgo de un **diff/cambio
    concreto** (reconstruye el delta vía `detect_vcs`; por defecto, cambios pendientes). Versión standalone
    del análisis estático que hace el validator. Complementa a `/rs-audit` (que audita toda la solución).
  - **`/rs-schema`** (`rs-esquema`, ⚡ haiku) — consulta pura del esquema de una o varias tablas
    (columnas/tipos/longitudes/nullabilidad/índices). Cierra el hueco de no tener un modo de esquema sin
    pasar por `/rs-erd` (que genera DDL/ERD).
  - Total de agentes 24 → 27, modos directos 19 → 22. Docs sincronizadas (`SKILL.md` tabla de modos,
    `docs/plugin-architecture.md` §4, `README.md`).
- **Documentación: técnica como input dirigido + actualización garantizada por tipo de doc.** La doc
  técnica de las soluciones RS es un **manual de convenciones** (cómo escribir clases/queries/controles),
  transversal, no un resumen por-solución. Antes core la leía de forma vaga y `tecnica/` no se
  actualizaba nunca. Ahora:
  - **Lectura dirigida:** el planner lee el `tecnica/00_INDICE_MAESTRO.md` (tabla tarea→docs), clasifica
    el cambio y emite `READ_DOCS` — la **lista exacta** de docs técnicos que core debe leer + el
    `CHECKLIST_CONVENCIONES_UI_BD.md` (compuerta antes de emitir `.aspx`/`.cs`). Core lee esos docs por
    sección y pasa la checklist antes de dar por emitido el código. Sube la calidad del código generado.
  - **Manual técnico (solo patrón nuevo, propuesta+confirmación):** core reporta `NEW_PATTERN` si
    introduce algo reutilizable nuevo (control AIS, clase común, convención de query/nomenclatura, tipo
    de tarea). La etapa `documentar` **propone** el cambio al fichero correcto del manual (`02`, `05`,
    `06`...) como `TECNICA_PROPUESTA`; ⛔ nunca escribe en `tecnica/` sin confirmación humana — es la
    referencia compartida de todas las soluciones.
  - **Resumen por-solución persistente:** nueva ruta `docs/agentic_manual/soluciones/<Sln>.md`;
    `/rs-doc` (GenerarDoc) ahora **escribe** ahí (antes solo mostraba); la etapa `documentar` lo refresca
    cuando cambia estructura/tablas/flujo.
  - **Doc funcional:** sigue actualizándose auto (sin confirmación) por la etapa `documentar`.
  - `find_doc_section` (hook + tool) ahora recorre también `tecnica/` (antes solo `funcional/` + raíz),
    necesario para localizar la sección a proponer.
  - Ficheros: `agents/rs-editor-planner.md`, `agents/rs-editor-core.md`, `agents/rs-documentar.md`,
    `hooks/find-doc-section.ps1`, `skills/rs-enterprise-agent/SKILL.md`, `commands/rs-enterprise-agent.md`,
    `references/gates.md` (Gate B), `references/mcp.md`, `references/hooks.md`.

## 2.5.3 — 2026-07-16
- **Guardrail en la Fase 2 de la skill `rs-jira`: encuadrar el requisito, no analizar código**
  (`skills/rs-jira/SKILL.md`). En un run de `/rs-tarea`, la Fase 2 se puso a **analizar el código**
  de la solución (qué columnas, qué nº de catálogo, qué pantalla) para "entender" la issue —
  solapándose con el `rs-editor-planner`, que ya hace ese análisis técnico **dentro** del pipeline
  (gate 2b). La Fase 2 solo debe traducir la issue a un **requisito accionable** (el *qué*); el
  *cómo* es del planner. El propio título de la fase ("**Análisis**, formateo y aclaración") invitaba
  al exceso. Cambios:
  - Fase 2 renombrada a **"Encuadre del requisito (NO análisis técnico)"** + bloque ⛔ que la limita
    a trabajar **solo** con Jira (issue + comentarios) y aclaraciones del usuario: **prohíbe** leer
    el código de la solución, llamar a `get_scope`/`find_symbol`/`search_code` o abrir ficheros
    fuente, y decidir el "cómo". Ambigüedad → **preguntar al usuario**, no explorar el repo.
  - Nueva **regla global** que fija el límite F2 (qué) vs `rs-editor-planner`/gate 2b (cómo), y
    puntos 3-4 reforzados para dejar explícita la frontera entre la aprobación del **requisito**
    (Fase 2) y la del **plan técnico** (gate 2b del pipeline, Fase 3).
  - Sin cambio del contrato de fases ni del resto del flujo. Bump por §10 (`plugin.json` +
    `marketplace.json` idénticos) para que Claude Code re-indexe la skill.

## 2.5.2 — 2026-07-16
- **Bump para forzar el re-indexado del comando `/rs-tarea`.** El comando (`commands/rs-tarea.md`)
  y la skill `rs-jira` existían en la fuente desde 2.4.0 y estaban correctos, pero `/rs-tarea` no
  aparecía como slash command en la sesión: el plugin está instalado como marketplace **tipo
  directorio** con `autoUpdate: false`, y los fixes de 2.5.0/2.5.1 editaron ficheros **sin cambiar
  el string de versión**, así que Claude Code no re-indexó (los slash commands se registran al
  arrancar / al cambiar la versión, no se hot-reload). Sin cambio funcional — solo bump de versión
  (`plugin.json` + `marketplace.json` idénticos, §10) para disparar `/plugin marketplace update`.

## 2.5.1 — 2026-07-16
- **Fix real del cuelgue de `/rs-tarea` (skill `rs-jira`).** El fix de 2.5.0 solo cambió el **texto de
  diagnóstico** ("si `ping` cuelga → sospechar EDR"), pero el modelo seguía **llamando a
  `mcp__rs-workspace__ping` como primera acción** de la auto-verificación. Bajo CrowdStrike el proceso
  `python.exe` del MCP queda bloqueado y `ping` no responde hasta el timeout de 1800s → congela el turno
  entero. Un cuelgue de tool call bloqueante **no es "detectable"** por el modelo (solo espera), así que
  la instrucción de 2.5.0 era inalcanzable. Ahora la auto-verificación (`skills/rs-jira/SKILL.md`):
  - ⛔ **No llama a `ping` (ni a ninguna tool `rs-workspace`) en el arranque** — solo comprueba
    **presencia del nombre en el registro** deferred (instantáneo, no cuelga).
  - **Prioriza Atlassian Rovo**, que es la dependencia real de las Fases 1–3 (selección/formateo/
    transición); `rs-workspace` solo interviene en la **Fase 4** (`jira_attach`/`log_execution`), donde
    se difiere su verificación viva.
  - **Fase 4**: nota de riesgo — si `jira_attach`/`log_execution` no responde en segundos → MCP
    bloqueado por el EDR; commit y transiciones ya están hechos, se reporta cierre **parcial** en vez de
    colgar.
- **Reconciliado el drift de versión de `marketplace.json`** (estaba en `2.2.0` mientras `plugin.json`
  iba por `2.5.0`). Ambos manifests quedan idénticos en `2.5.1`, como exige §10 del
  `plugin-architecture.md`.

## 2.5.0 — 2026-07-16
- **Endurecida la auto-verificación de la skill `rs-jira`** (`skills/rs-jira/SKILL.md`). El primer run
  falló declarando "MCP Atlassian Rovo ausente" cuando en realidad las tools estaban *deferred* en la
  sesión (solo el nombre visible, schema sin cargar). Ahora la Fase 0:
  - Carga el schema de las tools con **ToolSearch** antes de llamarlas (`select:...`), y explicita que
    *deferred ≠ ausente* — un `InputValidationError` por llamar directo no implica MCP inexistente.
  - Distingue los modos de fallo de `ping`: **cuelga/timeout** → proceso MCP bloqueado por el EDR
    (CrowdStrike FP, ver `docs/crowdstrike-fp-justification.md`), NO "reinstalar"; **nombre inexistente
    en el registro** → server no configurado.
  - Para Atlassian Rovo, decide por **presencia del nombre `...Atlassian_Rovo__*` en el registro**
    (deferred incluido): presente → conectado, cargar schema y confirmar auth con `atlassianUserInfo`;
    ausente del registro → integración no conectada; auth error → falta login Rovo interactivo.

## 2.4.0 — 2026-07-16
- **Seguridad: `runner/runner.ps1` deja de usar `Invoke-Expression`.** Ejecutaba un `COMMAND:`
  extraído del output del LLM (transcript) vía IEX, filtrado solo por substring `hooksRoot` + una
  denylist corta — no frenaba comandos añadidos (`.\hooks\x.ps1; <payload>`) → **inyección de
  comandos**. Ahora separa ruta del script + argumentos, valida que el `.ps1` resuelto queda dentro
  de `hooks/` (`GetFullPath` + `StartsWith`, bloquea `..\` escape), existe y es `.ps1`, tokeniza los
  argumentos respetando comillas y ejecuta con `& $script @argList` — todo lo que va tras el `.ps1`
  viaja como **argumento literal**, nunca como PowerShell (sin `;`/`|`/`&&`). Denylist conservada
  como defensa en profundidad.
- **Falso positivo de CrowdStrike documentado** — nuevo `docs/crowdstrike-fp-justification.md` para
  entregar a IT/Seguridad. CrowdStrike (EDR conductual) marcó "virus" al ejecutar `ping` del MCP
  `rs-workspace` y bloqueó el proceso `python.exe` → `ping` colgó → la skill `rs-jira` abortó. Es FP
  sobre código propio (spawn de `powershell -ExecutionPolicy Bypass`, `Add-Type System.Net.Http` en
  `jira-attach.ps1`, spawns svn/git/dotnet); sin descarga de red de código, sin `-EncodedCommand`,
  sin `FromBase64String`, sin reflection/shellcode. El doc incluye exclusión mínima recomendada
  (proceso python MCP + dir del plugin) y la petición del detalle de detección a IT.
- **Nota rs-jira**: el síntoma "MCP Atlassian Rovo ausente" del run fallido era falso — las tools
  Jira están registradas como *deferred* en la sesión; hay que cargar su schema con ToolSearch antes
  de declararlas ausentes. (Endurecer la precondición de la skill queda como mejora futura.)

## 2.3.0 — 2026-07-16
- **Fix gate de aprobación del plan que no detenía el pipeline.** El gate `Plan approval` existía en
  disco pero se había añadido **sin subir la versión** → Claude Code no recarga un plugin salvo que
  cambie la versión, así que las sesiones activas seguían cargando el cuerpo del command **anterior
  al gate** y encadenaban `rs-editor-core` sin presentar el plan. **Lección:** todo cambio en el
  contenido del pipeline (`commands/`, `skills/`) requiere bump de versión, es lo único que fuerza la
  recarga.
- **Reconciliada la numeración command↔SKILL** (`commands/rs-enterprise-agent.md`). Los dos ficheros
  divergían: en el command `2b` era *Scope* mientras que en `SKILL.md` `2b` era *Aprobación* — esa
  colisión hacía que el orquestador tratara "2b" como scope y se deslizara sobre la aprobación. Ahora
  ambos usan el mismo esquema canónico (igual que `docs/plugin-architecture.md`):
  `1 validate → 1b scope → 2 planner → 2b ⛔ aprobación → 4 core`, con scope resuelto **antes** del
  Planner (que lo recibe en su header).
- **Gate `2b` endurecido** en command y SKILL.md: primera línea `⛔⛔ PARADA OBLIGATORIA — NO invocar
  rs-editor-core en este turno`, imposible de confundir con un paso de preparación.

## 2.2.0 — 2026-07-16
- **Integración Jira: nueva skill `rs-jira` + comando `/rs-tarea`** (`skills/rs-jira/SKILL.md`,
  `commands/rs-tarea.md`). Orquesta el ciclo de vida de una tarea de Jira sobre una solución
  uCollect/RS: F1 selección (búsqueda JQL de tareas asignadas abiertas, o KEY/URL manual) · F2
  formateo del requisito al prompt del pipeline `<Sln>.sln - <cambio>` (⛔ el `.sln` **siempre se
  pregunta**, nunca se infiere) · F3 transición a "En Proceso" + lanzamiento del pipeline
  `rs-enterprise-agent` · F4 commit (`/rs-commit`) + adjuntar `.sql` + transición a "En Validación"
  + `log_execution` con la KEY de Jira para trazar issue↔ejecución en `/rs-historial`. **Cambio
  100% aditivo**: no toca el pipeline ni ningún `rs-editor-*`/`/rs-commit` — los envuelve. Diseño:
  Jira (búsqueda/lectura/transición/comentario) se opera con el **MCP Atlassian Rovo ya conectado**,
  sin cliente ni credenciales propias; los estados **no se hardcodean** (se resuelven con
  `getTransitionsForJiraIssue` + `statusMap` de config, robusto a idioma/workflow); toda escritura
  en Jira va detrás de un gate ⛔ de confirmación explícita.
- **Nuevo hook + tool MCP para adjuntar ficheros a Jira** (`hooks/jira-attach.ps1`,
  `jira_attach(issue_key, files)` en `mcp/rs-workspace-server.py` — **39 → 40 tools**). El MCP Rovo
  no expone attachment, así que el adjunto real se hace vía Jira Cloud REST v3
  (`POST /rest/api/3/issue/{KEY}/attachments`, `X-Atlassian-Token: no-check`, multipart con
  `HttpClient` compatible con Windows PowerShell 5.1). Credenciales en
  `~/.claude/rs-jira-credentials.json` (**fuera del repo**, nunca en `.jira-dev-config.json`); ⛔ el
  token nunca se escribe en stdout/stderr. Convención Preferente/Fallback 1:1 (tool ↔ hook) como el
  resto.
- **Config y documentación** — `docs\.jira-dev-config.json` (en la carpeta `docs\` del workspace,
  junto a `XMLConfig.xml`; no-secreto: `projectKey`, `jiraUser`, `cloudId?`, `statusMap`,
  `openStatuses?`; scaffolding con `/rs-tarea init`) y nueva
  reference `references/jira.md` (setup config + credenciales + tabla de herramientas). Sincronizado:
  `README.md` (comando, setup Jira, nº tools), `references/mcp.md`, `references/hooks.md`,
  `hooks/README.md`, `docs/plugin-architecture.md`. Límite documentado: el MCP Rovo usa auth
  interactiva → la skill no corre en headless/cron.

## 2.1.2 — 2026-07-16
- **el Planner siempre genera un PLAN legible, y el orquestador siempre lo presenta y detiene el turno — Plan Mode del harness OFF incluido**. Motivo: con el Plan Mode del harness OFF, en el pipeline `<Sln>.sln - <cambio>` el modelo podía saltarse la presentación del plan y encadenar Core directo. La intención ya estaba escrita (`SKILL.md` gate 2b: "con independencia del Plan Mode del harness") pero (1) la redacción no era lo bastante imperativa y (2) el Planner solo emitía una lista de pasos + el bloque de contrato para máquina (`FILES_CHANGED/CREATE_TESTS/UPDATE_DOCS/SUMMARY/STATUS`), sin un artefacto `PLAN` legible garantizado que presentar. Doble corrección: (1) `agents/rs-editor-planner.md` (sección Output) — nuevo bloque `PLAN` legible por humano (Objetivo · Pasos · Despliega a AIS · Genera tests · Impacto en datos/BD) que el Planner emite **SIEMPRE**, justo antes del bloque de contrato, con o sin Plan Mode. (2) `skills/rs-enterprise-agent/SKILL.md` — paso 2 con regla imperativa (⛔ el Planner se ejecuta SIEMPRE y su bloque `PLAN` es obligatorio, no se salta aunque Plan Mode esté OFF; nunca se llega a Core sin `PLAN`), paso 2b endurecido (con Plan Mode OFF el orquestador presenta el `PLAN` del Planner y detiene el turno igualmente, nunca encadena Core en el mismo turno sin aprobación; presentar el bloque ya emitido, no reconstruirlo) y Regla Global (línea 22) alineada. Sin cambios en las etapas de escritura ni en el contrato de salida (el bloque `PLAN` es un campo extra del Planner, ya cubierto por "+ campos extra documentados en cada `rs-editor-*.md`" de `docs/plugin-architecture.md`); `README.md` sin cambios (la tabla de pasos ya marca "planner | Siempre").

## 2.1.1 — 2026-07-15
- **fix incongruencia de ruta de scripts SQL (planner inventaba `BD\scripts\`)** — `agents/rs-editor-planner.md` no mencionaba ninguna ruta de destino para los `.sql`, así que el planner (modelo `sonnet`) rellenaba el hueco inventando una ruta, y en una ejecución eligió `BD\scripts\` del repo — justo la ubicación que el fix de v1.6.0 (ver entrada 1.6.0) documentó como bug ("una sesión dejó el script solo en `BD\` del repo y dio el paso por completado"). `rs-editor-core` tenía la regla correcta (`.sql` → `C:\AIS\<proyecto>\scripts\`, prohibido `BD\`) pero dejaba que la ruta nombrada por el plan la sobrescribiera. No era una convención doble: la única ruta válida para cualquier `.sql` (DDL/migración/seed/idiomas) es `C:\AIS\<proyecto-lowercase>\scripts\` (`rs-editor-core.md`, `rs-editor-db-modeler.md`, `rs-editor-tester.md`, `SKILL.md`). Doble corrección: (1) `rs-editor-planner.md` (sección Reglas) — regla explícita de que el plan **nunca** especifica dónde se guarda un `.sql`; solo indica qué script hace falta, ⛔ nunca nombrar `BD\scripts\` ni carpeta del repo. (2) `rs-editor-core.md` (sección Scripts SQL) — regla de **precedencia**: si el plan nombra otra ruta para un `.sql`, ignorarla; `C:\AIS\<proyecto>\scripts\` prevalece siempre. Sin cambios de comportamiento en ejecución de DDL/DML: los agentes siguen sin ejecutar scripts en BD (los ejecuta el usuario/DBA antes de desplegar); solo se corrige la ruta de escritura del fichero.

## 2.1.0 — 2026-07-14
- **`docs/plugin-architecture.md` (nuevo)**: doc canónico de la anatomía interna del plugin y del patrón para extenderlo — anatomía de directorios, manifests y qué se auto-descubre por convención, resumen del pipeline y sus contratos de invocación/salida, familias de agentes (`rs-editor-*` vs `rs-*`), patrón de comandos, MCP server (39 tools sobre hooks vía `_run_ps`), hooks infra vs worker, references, **cómo extender** (modo directo de 3 ficheros, etapa de pipeline, tool MCP, skill) y **puntos de sincronización de documentación** (checklist de coherencia). Documenta también 3 inconsistencias conocidas (referencias a `subagents/` vs `agents/` real; carpeta `BD/` del README que no vive en el repo; `settings.json` legacy). Complementa —no duplica— `README.md` (uso), `references/*.md` (dominio) y el design spec del pipeline.
- **Skill `rs-plugin-dev` (nueva)** — `skills/rs-plugin-dev/SKILL.md` + `commands/rs-plugin-dev.md`: meta-skill de mantenimiento del propio plugin (no de soluciones cliente). Lee `docs/plugin-architecture.md` como fuente canónica, clasifica el cambio, planifica, **se detiene en un gate de aprobación explícita antes de escribir**, aplica siguiendo las convenciones (agentes/comandos/references/SKILL/MCP Python/hooks PowerShell/manifests), **sube la versión de forma obligatoria** en `plugin.json` + `marketplace.json` idénticas —requisito para que Claude Code detecte la actualización—, y sincroniza `CHANGELOG`/`README`/tabla de modos/references con una verificación de coherencia final. Alcance de edición: toda la superficie del plugin, incluido MCP y hooks.
- **`.claude-plugin/marketplace.json`**: se añade `version` a la entrada del plugin, para que quede idéntica a `plugin.json` (la meta-skill mantiene ambas sincronizadas en cada cambio).

## 2.0.3 — 2026-07-14
- **fix `validate_solution`: falso error en soluciones válidas** — `hooks/validate-solution.ps1` no escribía nada en stdout en la ruta de éxito (solo `Write-Host "Solution not found"` + `exit 1` en la ruta de fallo, y en la válida ni output ni `exit`). `_run_ps` en `mcp/rs-workspace-server.py` trata stdout vacío como fallo, así que una `.sln` **válida** devolvía `{"error":"No output from validate-solution.ps1","exit_code":0}` y una inexistente devolvía `{"raw":"Solution not found"}` — la tool estaba efectivamente invertida y nunca daba un éxito limpio. Ahora el script emite JSON en ambas rutas (`@{...} | ConvertTo-Json` + `exit` explícito, misma convención que `detect-vcs.ps1`): válida → `{"success":true,"sln_path":...,"solution":...}` exit 0; inexistente → `{"success":false,"error":"Solution not found",...}` exit 1. Sin cambios en `rs-workspace-server.py` (el script se lee vía `subprocess` en cada llamada; no requiere reinicio del MCP server).

## 2.0.1 — 2026-07-09
- **Reducción de consumo de tokens en el pipeline principal**:
  - `rs-editor-build.md`/`rs-editor-analyzer.md`: `model: sonnet` → `haiku` — build es mecánico (lee resultado de `validate_solution` y reporta), analyzer es puramente advisory y no bloquea el flujo; ninguno de los dos necesita un tier más caro.
  - **Doble resolución de solución/scope corregida**: `SKILL.md` invocaba Planner en el paso 1 y resolvía `validate_solution`/`get_scope` después, en los pasos 2/2b — pero `rs-editor-planner.md` decía recibirlos ya resueltos y a la vez los volvía a llamar como paso propio "AnalyzeSolution", duplicando ambas tools en cada ejecución. Reordenado: solución+scope se resuelven primero (pasos 1/1b), Planner pasa a ser el paso 2 y los recibe ya resueltos en el header — se quitó "AnalyzeSolution" de `rs-editor-planner.md` y las tools `validate_solution`/`get_scope` de su frontmatter.
  - **Analyzer (paso 6) ahora condicional**: antes corría siempre aunque `rs-editor-planner.md` ya listaba "AnalyzeChanges" como paso opcional dentro de su propio plan; el orquestador lo ignoraba y lo invocaba de todas formas. Ahora solo se invoca si el plan del Planner lo incluyó (cambio no trivial). Riesgo bajo: Analyzer es advisory, Validator sigue siendo el único gate bloqueante.
  - **Tool `Bash` sin uso quitada** de `rs-editor-core.md` y `rs-editor-tester.md` — no aparecía referenciada en ningún paso del cuerpo de ninguno de los dos (a diferencia de `rs-editor-build.md`/`rs-editor-db-modeler.md`, donde sí hay uso real documentado). Menos overhead de definición de tools por invocación.
  - **Texto de troubleshooting `MSB4019` centralizado**: estaba duplicado casi literal en `rs-editor-build.md` y `rs-editor-tester.md`; ahora vive una sola vez en `references/troubleshooting.md`, ambos agentes solo lo referencian.

## 2.0.0 — 2026-07-08
- **Conversión a plugin de Claude Code (cambio de mecanismo de distribución)**: se retiran los DOS mecanismos anteriores — el paquete `.skill` para Claude Desktop (`rs-skill-full.skill`, `scripts/build-skill.ps1`, marker `agents/.skill-root`, bloque "PASO 0" de `SKILL.md` que buscaba ese marker bajo `%APPDATA%\Claude\local-agent-mode-sessions\...`) y los instaladores PowerShell a mano para Claude Code CLI (`scripts/install-hooks.ps1`/`install-to-project.ps1`, que copiaban `commands/`/`subagents/` a `~/.claude/` y editaban `~/.claude/settings.json`/`~/.claude.json` directamente). Motivo: en la sesión que llevó a v1.9.2/1.9.3 los instaladores a mano fallaron tres veces distintas (comando base inexistente, `~/.claude/agents/` nunca poblado, crash en PowerShell 5.1) — síntomas de mantener a mano algo que Claude Code ya resuelve nativamente.
- **`.claude-plugin/marketplace.json` + `.claude-plugin/plugin.json` (nuevos)**: manifiesto de plugin de un solo componente (`source: "./"`, mismo patrón que el plugin `caveman`). `plugin.json` declara los hooks `Stop` (runner de builds) y `UserPromptSubmit` (`skill-trigger.ps1`) inline, usando `${CLAUDE_PLUGIN_ROOT}` — sin tocar `~/.claude/settings.json`.
- **`.mcp.json` (nuevo)**: registra el MCP server `rs-workspace` (mismo `command`/`env` que tenía la entrada manual en `~/.claude.json`) apuntando a `${CLAUDE_PLUGIN_ROOT}/mcp/rs-workspace-server.py` — sin cambios en el propio `mcp/rs-workspace-server.py` (su resolución de rutas ya era relativa a sí mismo).
- **`SKILL.md` → `skills/rs-enterprise-agent/SKILL.md`**: bloque "PASO 0" eliminado por completo; las ~12 referencias a `$SKILL_DIR` pasan a `${CLAUDE_PLUGIN_ROOT}` (inyectado directo por Claude Code, sin bucle de reintentos buscando un marker).
- **`subagents/` → `agents/`** (renombrado, `svn move` preserva historial): la carpeta `agents/` ya no aparece en la convención de plugin como el marker suelto de Desktop — ahora contiene los 28 subagentes reales, descubiertos automáticamente por Claude Code.
- Instalación ahora es `/plugin marketplace add "N:\SVN\RS\Agentes\SkillsClaude\rs-skill-full"` + `/plugin install rs-enterprise-agent@rs-enterprise-agent`, en vez de instalar un `.skill` y correr un script PowerShell aparte. Ver `README.md`.

## 1.9.3 — 2026-07-08
- **`rs-editor-tester.md`: fix gate idiomas** — el gate solo disparaba para controles nuevos o cambios de `ICCONTROL` (rebind/rename); un texto (`LabelText`/`Text`/mensaje de validación/`Idm.Texto`) editado en un control YA EXISTENTE, sin tocar su clave, pasaba desapercibido y el Tester reportaba OK sin generar script. Caso real: cambiar el literal "Contrato" → "Contrato externo" en un label existente de `FrmBusqueda.aspx`. Regla ahora explícita: dispara el gate cualquier texto visible por el usuario que cambie, sea alta o edición. Nueva rama de acción — texto editado con clave igual: `UPDATE RIDIOMA` si el IDTEXTO es exclusivo de ese control, o alta de IDTEXTO nuevo + reasignar `RCONTROLES` si el IDTEXTO está compartido con otros controles (evita romper el texto de esos otros).

## 1.9.2 — 2026-07-08
- **fix crítico**: el nombre base `rs-enterprise-agent` nunca tuvo un archivo en `commands/` — solo existían los wrappers de modo directo (`rs-audit.md`, `rs-diff.md`, etc). El hook `skill-trigger.ps1` instruye a invocar "la skill `rs-enterprise-agent` (tool Skill)" para el patrón `<Sln>.sln - <cambio>` (pipeline completo), pero esa invocación fallaba siempre con `Unknown skill: rs-enterprise-agent` porque Claude Code CLI resuelve nombres de skill contra archivos en `commands/`/`agents/` instalados, no contra el `SKILL.md` de un paquete `.skill` de Claude Desktop (ese sí queda registrado bajo `%APPDATA%\Claude\local-agent-mode-sessions\...`, un registro completamente distinto e invisible para el CLI).
- **`commands/rs-enterprise-agent.md` (nuevo)**: entry point del pipeline completo, mismo patrón que los demás comandos (autocontenido, sin depender de resolver `$SKILL_DIR` en runtime) — reproduce "PIPELINE OBLIGATORIO" de `SKILL.md` para que el orquestador (main thread) lo seguido directamente al invocarse por nombre o por el hook.
- Recordatorio: tras instalar, correr `scripts/install-hooks.ps1` (o `install-to-project.ps1` para scope de proyecto) y reiniciar Claude Code — sin esto el comando nuevo no aparece y, si `~/.claude/agents/` nunca se pobló (instalación previa a la v1.7.0), ningún modo que despache a subagente Task-tool funciona.
- **`install-hooks.ps1`: fix compat PS 5.1** — el paso 3 (registrar MCP `rs-workspace` en `~/.claude.json`) usaba `ConvertFrom-Json -AsHashtable`, parámetro inexistente en Windows PowerShell 5.1 (el `powershell.exe` que de hecho ejecuta hooks/instalador en runtime — `pwsh` 7 no es lo que corre ahí). El fallback a `ConvertFrom-Json` plano tampoco sirve: este `.claude.json` en particular tiene una clave con nombre de propiedad vacío en otra sección que hace que hasta el parseo plano falle. Ahora usa `ConvertTo-HashtableDeep` (mismo helper que ya tenía `install-to-project.ps1`) y, si el parseo completo falla igual, atrapa el error y avisa sin tocar el archivo — nunca arriesga reserializar `~/.claude.json` completo a ciegas.

## 1.9.1 — 2026-07-07
- **build.md / tester.md / references/hooks.md**: fix — en <Proyecto>, `dotnet build`/`dotnet test`/`compile_check`/`run_tests` fallaban con `MSB4019` (falta `Microsoft.WebApplication.targets`) en cuanto el build tocaba un proyecto Online WebForms, incluso solo por `ProjectReference` desde un proyecto de test; `compile-check.ps1` solo parsea `CS####` así que el `MSB####` real quedaba invisible (`error_count=0` con `exit_code=1`, falso positivo). Documentado: compilar con `msbuild.exe` real (vswhere) y ejecutar tests con `vstest.console.exe` sobre el `.dll` compilado.
- **build.md / references/hooks.md**: fix — asumir `FolderProfile1` como nombre de perfil de publish causó fallo; el nombre real varía por proyecto (en <Proyecto> era `FolderProfile`, sin el "1"). Ahora obligatorio listar los `.pubxml` reales y leer `<PublishUrl>` antes de invocar `online-publish.ps1`.

## 1.9.0 — 2026-07-07
- **Soporte Git en paralelo a SVN (nuevo)**: pronto habrá proyectos RS en Git además de SVN — ambos deben seguir funcionando. Nueva tool `mcp__rs-workspace__detect_vcs(workspace)` (hook `detect-vcs.ps1`) detecta SVN/Git subiendo por las carpetas; nunca se asume uno u otro.
- **5 tools Git nuevas**, espejo 1:1 de las SVN existentes: `git_status` (`git-status.ps1`), `git_log` (`git-log.ps1`), `git_diff_revision` (`git-diff-revision.ps1`), `git_add` (`git-add.ps1`, fallback TortoiseGitProc), `_check_git_cli()`. `ping()` y `check_env`/`check-env.ps1` reportan también `git_cli`/fila "Git" (no bloqueante, igual que SVN)
- **2 subagentes nuevos**: `rs-diff-git` (Haiku, espejo de `rs-diff-svn`) y `rs-commit-git` (Sonnet, espejo de `rs-commit-svn` — con una diferencia importante: `git commit` es local, así que hace **commit + push con dos confirmaciones separadas**, no una)
- **`rs-historial` y `rs-validar-req`**: rama condicional vía `detect_vcs` para usar `git_log`/`git_diff_revision` en vez de sus pares SVN cuando el workspace es Git
- **`commands/rs-commit.md`, `commands/rs-diff.md`**: llaman `detect_vcs` antes de despachar, y eligen el subagente `-svn` o `-git` según corresponda
- **Convención de carpetas sin cambios**: los repos Git nuevos mantienen la misma estructura `trunk\Batch\Soluciones\*.sln` / `trunk\OnLine\Soluciones\*.sln` que SVN — `get-config.ps1`/`parse-sln.ps1` no se tocan
- **SKILL.md**: nueva sección "Detección de VCS", tabla "Modos directos" generaliza filas Diff/Commit

## 1.8.0 — 2026-07-07
- **Subagentes Sonnet/Opus (nuevo)**: 11 modos directos más despachan vía Task tool a subagentes reales — `rs-comparar-modelo` (Haiku), `rs-auditoria`/`rs-impacto`/`rs-generar-dalc`/`rs-documentar`/`rs-commit-svn`/`rs-crear-tests` (Sonnet), `rs-migracion-motor`/`rs-idiomas-standalone`/`rs-validar-req`/`rs-seguridad` (Opus). Modelo elegido por lo que exige la tarea (juicio real, escritura de código/SQL de producción, gate de seguridad/cumplimiento), no por el modelo activo del chat.
- **Dual-rol preservado**: `documentar.md`, `crear-tests.md` e `idiomas-standalone.md` se mantienen en `agents/` (sin cambios funcionales) para su uso embebido en el pipeline (pasos 8/8b/8c), que necesita continuidad de contexto con la tarea en curso — solo se aisló la invocación directa (`/rs-doc` GenerarDoc, `/rs-crear-tests`, `/rs-idiomas`). `db-modeler.md` (ERD/Modelo BD) queda igual, por el mismo motivo.
- **Pipeline principal y ERD/Modelo BD**: sin cambios — etapas encadenadas que comparten contexto implícito, aislarlas en subagente arriesgaría perder ese estado
- **SKILL.md** "Modos directos": tabla con marcas ⚡ Haiku / 🔷 Sonnet / 🟣 Opus por modo
- **agents/**: eliminados `auditoria.md`, `impacto.md`, `comparar-modelo.md`, `generar-dalc.md`, `migracion-motor.md`, `commit-svn.md`, `validar-requerimiento.md`, `seguridad.md` — contenido migrado a `subagents/`

## 1.7.0 — 2026-07-07
- **Subagentes Haiku (nuevo)**: `/rs-historial`, `/rs-diff`, `/rs-estructura`, `/rs-stats`, `/rs-env`, `/rs-deps` — 6 modos directos de solo-lectura/mecánicos — ahora despachan vía Task tool a subagentes reales (`subagents/rs-*.md`, frontmatter `model: haiku`) en vez de ejecutarse inline en el modelo activo del chat. Reduce costo sin afectar pipeline principal ni modos que requieren razonamiento (auditoría, impacto, seguridad, migración, etc.)
- **install-hooks.ps1**: vendoriza `subagents/*.md` → `~/.claude/agents/` (mismo patrón que `commands/` → `~/.claude/commands/`); requiere reinstalar + reiniciar Claude Code para que el Task tool descubra los subagentes
- **agents/**: eliminados `historial.md`, `diff-svn.md`, `estructura.md`, `stats.md`, `validar-entorno.md`, `dependencias.md` — contenido migrado a `subagents/` (ya no se leen inline)
- **SKILL.md** "Modos directos": marcadas con ⚡ las 6 filas que ahora despachan a subagente Haiku

## 1.6.0 — 2026-07-07
- **db-modeler.md / core.md**: DDL escrito a mano para tablas nuevas (cuando `generate_sql`/`generate_migration` no emiten el CREATE TABLE esperado) sigue requiriendo copia obligatoria a `C:\AIS\<proyecto>\scripts\` — fix: una sesión dejó el script solo en `BD\` del repo y dio el paso por completado
- **core.md** "Modelo BD — orden de consulta": prohibido el polling en bucle de vistas catálogo Oracle (`ALL_TABLES`/`ALL_OBJECTS`/`ALL_TAB_COLUMNS`/`USER_TABLES`) para confirmar existencia de tabla — máx 1 intento, luego SELECT directo a la tabla; `sync_model_tables`/`get_table_schema` siguen siendo autoritativos
- **references/troubleshooting.md**: nueva entrada "Tabla nueva no aparece en ALL_TABLES/ALL_OBJECTS (Oracle)" documentando el lag de dictionary cache; nueva regla clave anti-repetición de consultas ya respondidas
- **validator.md**: aclarado que `compile_check` (paso 1) es solo el gate del validator, no sustituye el paso 9 Build
- **SKILL.md**: nuevo paso **10b Checklist final** (obligatorio antes de Log) — verifica Build real ejecutado + copia AIS, scripts SQL copiados a AIS, y esquema BD consultado vía model.json — fix: una sesión reportó éxito tras `compile_check` sin ejecutar nunca el Build real ni la copia de binarios a AIS

## 1.5.0 — 2026-07-06
- **hooks/skill-trigger.ps1** (nuevo): hook UserPromptSubmit — detecta `.sln` en el prompt dentro de workspaces `\SVN\RS\` e inyecta recordatorio de invocar la skill (fix: Claude no siempre disparaba la skill con el patrón "Solucion.sln - cambio")
- **install-hooks.ps1**: registra automáticamente el UserPromptSubmit hook (idempotente); fix doble escape de backslashes en el Stop hook; fix lectura de `~/.claude.json` (`-AsHashtable`, `-Depth 100`, escritura solo si cambia)
- **SKILL.md description**: ampliada para mejorar el disparo (cualquier mención de .sln/solución RS, no solo el patrón exacto); `version` movida a `metadata:` (requisito del validador de empaquetado)
- **Deduplicación**: reglas globales (scope, warning model.json 180K, límite fixer, Preferente/Fallback) viven solo en SKILL.md; agentes recortados (~1.200 tokens menos por invocación de pipeline)
- **Convención global Preferente/Fallback** en SKILL.md — agentes solo detallan fallback cuando no es 1:1
- **Gate scripts-idiomas unificado**: core.md es la fuente única; tester.md y SKILL.md (paso 8b) lo referencian — cubre rebinds de grid en `.aspx.cs` que la condición ".aspx tocado" perdía
- **MCP**: eliminada tool redundante `get_bd_model` (cubierta por get_model_index/search_model/get_table_schema); quitados warnings obsoletos sobre `db_query`
- **idiomas-standalone.md**: reglas migradas de memoria — mensajes de error solo RIDIOMA (sin RCONTROLES), IDTEXTO nunca por huecos de coerr.cs, casing ICFORM
- **build.md**: verificación post-build obligatoria con evidencia mínima
- **references/hooks.md**: añadidos search-code, db-query, get-bd-model, sync-indexes y sección Build; **references/mcp.md**: firma real de compile_check, fila sync_indexes
- **hooks/sync-model-tables.ps1**: portada versión corregida desde copia instalada (fix colisión `$Tables`, manejo JSON-objeto)
- **Limpieza**: eliminado `hooks/config.json` (sin referencias); README documenta desarrollo del skill (fuente canónica, reempaquetado, reinstalación)

## 1.3.0 — 2026-06-26
- **compare-model.ps1**: detecta drift de tipo y nullable en columnas existentes (`modified_columns`)
- **generate-migration.ps1**: genera ALTER TABLE MODIFY (tipo/nullable), ADD CONSTRAINT FK, CREATE INDEX, DROP COLUMN comentado
- **db-modeler.md**: corregido comentario incorrecto sobre `render_erd` MCP
- **MCP**: descripciones actualizadas para `compare_model` y `generate_migration`
- **ERD viewer**: modal DDL en cada mutación de esquema (add/drop columna, rename, PK toggle, create/drop tabla)
- **ERD viewer**: modo presentación (P), panel atajos (?), DDL filtra tablas visibles
- **ERD viewer**: búsqueda columnas, filtro patrón, lock tabla, rubber band selection
- **ERD viewer**: export CSV (catálogo, relaciones, índices, resumen, ficha técnica)
- **sync-indexes.ps1** + MCP `sync_indexes`: sincronización de índices desde Oracle
- **generate-migration.ps1**: CREATE INDEX para tablas nuevas
- **Todos los slash commands**: `description:` en frontmatter YAML para tooltips

## 1.2.0
- ERD viewer: export SVG, PNG
- sync-model-tables.ps1: fix bug índices borrados en sync parcial
- generate-sql.py: soporte índices
- bd.md: validación [perf] para índices

## 1.1.0
- MCP server inicial
- Hooks: sync-from-db, compare-model, generate-migration, analyze-dalc
- ERD viewer: base con drag/zoom, relaciones, subvistas, undo/redo

## 1.0.0
- Release inicial
