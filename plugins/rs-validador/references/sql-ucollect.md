# Generación de scripts SQL de configuración uCollect — RSValidador

La parte más delicada de la herramienta: los scripts que dan de alta en uCollect la configuración de
**mandantes, especies, archivos, atributos y algoritmos**. Se generan a partir de las estructuras del
grupo **Estándar (SQL)** (`grupo_id IS NULL` — ver `schema-estructuras.md` §5).

⛔ El almacén de la herramienta guarda la configuración de **múltiples clientes de uCollect**. Un
cambio en el generador afecta a todos: exige verificación explícita y entra siempre por el gate de
PLAN.

## 1. Scripts generados

| Script | Contenido |
|--------|-----------|
| `RMANDANTE.sql` | Alta de mandantes |
| `RESPECIE.sql` | Especies — tabla **común a todos los mandantes** del proyecto |
| `RARCHIVOS.sql` | Definición de ficheros |
| `RRELARCHESP.sql` | Relación archivo ↔ especie **por mandante** |
| `RRELARATR.sql` | Atributos de la relación |
| `IN_TABLAS.sql` | DDL: `DROP TABLE IF EXISTS` + `CREATE TABLE` + `ALTER TABLE … PRIMARY KEY` |

Tipos por motor: string/date → `VARCHAR2(n CHAR)` (Oracle) o `VARCHAR(n)` (SQL Server);
decimal → `DECIMAL(p,s)`. Columnas con coma al final de línea (formato normalizado).

Descarga: ficheros individuales o **SQL unificado** (concatenado). Tras generar, la barra de estado
muestra el recuento de instrucciones INSERT/DDL.

## 2. ⛔ Mandante dueño vs mandante usuario

Distinción crítica, origen de bugs reales:

- **`RARCHIVOS.armandante`** = **dueño** del fichero. Puede ser el genérico `9999`.
- **`RRELARCHESP.aemandante`** = **usuario** del fichero: el mandante que realmente lo procesa.

**Regla:** al generar estructuras desde la BD, iterar siempre desde los pares
`(aemandante, archivo)` de `RRELARCHESP`, **nunca** desde `RARCHIVOS` agrupado por dueño.
En la importación, `rel_by_especie` se construye desde el `RRELARCHESP` directo, no desde la lista
aumentada con el fallback `9999`.

## 3. Índices de columna — tablas del generador

Las filas se representan como **objetos con clave nombrada** (no arrays posicionales). Las funciones
`_*ArrayToObj` absorben cualquier formato histórico al cargar; `renderRows()` convierte
automáticamente; `_get*Rows()` extrae objetos del DOM. Aun así, los índices siguen importando en el
DOM y en las migraciones de configuraciones antiguas:

**`ATRIBUTOSBD`** (15 columnas, 0-indexed):
`[0] Mandante · [1] Archivo · [2] Atributo · [3] TipoDato · [4] Longitud · [5] Decimales ·
[6] CampoBD · [7] Nulo · [8] PK · [9] OrdenTabla · [10] OrdenCampoTabla · [11] ValorPorOmisión ·
[12] CatalogoObservaciones · [13] ExclBD ("Solo IN_") · [14] flag manual`

**`RARCHIVOS`** (0-indexed desde la primera columna de datos):
`ArDelimitadorTexto` = 7 · `ArOrdenProceso` = 8 · `ArFilaCabecera` = 9 · `ArObligatorio` = 10.

⛔ **Añadir una columna a `RARCHIVOS`** obliga a actualizar: `_archivosRowHtml`, el INSERT SQL, los
propagadores de parámetros, la migración de configuraciones antiguas y el índice de referencia en
**todos** los listeners.

⛔ **Añadir una columna a `ATRIBUTOSBD`** obliga a actualizar: `_atrBdRowHtml`, `_atrBdArrayToObj`
(campo nuevo + valor por defecto), `_getAtrBdRows` (leerlo del DOM), el INSERT SQL de
`generarScripts`, la comparación de esquema, la marca de huérfanas y el `colspan` del `thead`.
La conversión se hace en `renderRows` vía `_atrBdArrayToObj`, no en la aplicación de configuración.

## 4. Comparar con la BD productiva

Conecta a Oracle o SQL Server del proyecto y propone `ALTER TABLE` para columnas nuevas o ampliadas.
Además valida:
- **PK**: compara la PK declarada (col 8) con la real (`all_constraints` en Oracle,
  `information_schema` en SQL Server). Genera `ADD CONSTRAINT PRIMARY KEY` si falta, o aviso de
  revisión manual si difiere.
- **Nullable**: compara el flag Nulo (col 7) con `NULLABLE`/`IS_NULLABLE` y genera el
  `MODIFY (col NULL/NOT NULL)` (Oracle) o `ALTER COLUMN` (SQL Server).

La columna **"Solo IN_"** (`ExclBD`, col 13) marca campos que solo existen en la tabla `IN_` y no en
la productiva: esas filas quedan **excluidas** de la comparación de tipos, PK y nullable, y se
filtran en el frontend antes de enviar.

## 5. Órdenes y filas huérfanas

- Mantener la coherencia de `OrdenTabla` / `OrdenCampoTabla` **antes** de generar.
- `OrdenTabla` de las filas nuevas toma el `ESOrdenProceso` de la especie; editar el
  `ESOrdenProceso` de una especie lo propaga a las filas de atributos de esa especie.
- **Filas huérfanas** (archivo que ya no existe en `RARCHIVOS`): se marcan al generar. La detección
  de las eliminables se apoya en el **color de fondo** aplicado a la fila — si se cambia ese color,
  hay que actualizar también el filtro de la función de borrado.
- El código de especie es referenciado por los atributos y los selectores: renombrarlo debe propagar
  a las filas de atributos y a los selects, o quedan especies huérfanas.
- **Borrar una especie** afecta solo a la configuración del validador; los cambios en la BD del
  cliente se aplican mediante los scripts generados. Verificar siempre en el código el alcance real
  antes de documentarlo: este comportamiento ya cambió una vez.

## 6. Algoritmos y acciones

`RALGORITMO` (`ALCOD`, `ALACCION`, `ALORDEN`, `ALDESCRIPCION`) y `RACCION` (`ACCOD`, `ACORDEN`,
`ACDESCRIPCION`, `ACSQL`) se mantienen en una **pestaña** de la pantalla de scripts SQL. Sustituyen
el flujo manual de un Excel con macros.

- Ambas tablas están **scopeadas por proyecto**, no por mandante.
- Se crean automáticamente con `Base.metadata.create_all(engine)`; no requieren migración manual.
- Guardado y generación siguen el patrón **DELETE + INSERT** (`/guardar-todo`). Enteros sin comillas,
  cadenas con `'...'`.
- `RMANDANTE.MAALGCOMI` referencia `RALGORITMO.ALCOD` y se muestra como desplegable con los `ALCOD`
  del proyecto. ⛔ No hay FK en SQLite por diseño: borrar algoritmos puede dejar mandantes con
  referencias huérfanas.

## 7. Persistencia de la configuración

La configuración de scripts se guarda en la tabla `configuraciones_sql` **por proyecto + mandante**
(ya no en `localStorage`) y se carga automáticamente al entrar. Cualquier cambio en la lógica de
guardado o de carga afecta a los dos lados; las configuraciones antiguas se migran al cargar, nunca
al aplicar.
