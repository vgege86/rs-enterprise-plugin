# Patrones DALC — Ubicación y extracción de relaciones

---

## Ubicación de ficheros DALC

### Online (AgendaWeb y similares)

Proyectos dentro de la solución `.sln` Online:
- `RSDalc` → contiene clases que acceden a tablas del dominio principal
- `RSJudiDalc` → tablas del módulo judicial (si existe en el proyecto)

Ruta típica:
```
OnLine\Soluciones\AgendaWeb\RSDalc\*.cs
OnLine\Soluciones\AgendaWeb\RSJudiDalc\*.cs
```

Buscar con Glob dentro del scope del .sln:
```
OnLine\**\RSDalc\*.cs
OnLine\**\RSJudiDalc\*.cs
```

### Batch

Proyectos cuyo nombre empieza por `Bus` — dentro de la solución `.sln` Batch.
Clases que terminan en `Dalc.cs`:

```
Batch\Soluciones\<Solution>\Bus*\*Dalc.cs
```

---

## Extracción de tablas

Buscar en el código C# strings que contengan SQL:

### Patrones de tabla (FROM, JOIN, INTO, UPDATE)

```regex
\bFROM\s+([A-Z_][A-Z0-9_]+)(?:\s+\w+)?\b
\bJOIN\s+([A-Z_][A-Z0-9_]+)(?:\s+\w+)?\b
\bINTO\s+([A-Z_][A-Z0-9_]+)\b
\bUPDATE\s+([A-Z_][A-Z0-9_]+)\b
```

Filtrar falsos positivos: ignorar palabras clave SQL como SELECT, WHERE, SET, VALUES, DUAL, etc.

---

## Extracción de relaciones

### JOINs explícitos — confianza HIGH

```sql
JOIN PEDIDOS p ON c.ID_CLIENTE = p.ID_CLIENTE
```

Patrón:
```regex
JOIN\s+(\w+)\s+\w+\s+ON\s+(\w+)\.(\w+)\s*=\s*(\w+)\.(\w+)
```

Extrae: tabla_join, alias_join, col_join ↔ alias_origen, col_origen

### WHERE con cruce de tablas — confianza MEDIUM

```sql
WHERE c.ID_CLIENTE = p.ID_CLIENTE
  AND c.ID_TIPO = t.ID_TIPO
```

Patrón: condiciones donde ambos lados referencian alias distintos de tablas conocidas.

### Subqueries — confianza LOW

```sql
WHERE ID_CLIENTE IN (SELECT ID_CLIENTE FROM PEDIDOS WHERE ...)
```

Marcar como `confidence: "low"` — puede ser filtro, no relación estructural.

---

## Mapeo alias → tabla

Los DALCs usan alias en las queries. Para resolver alias:

```sql
FROM CLIENTES c               -- c → CLIENTES
JOIN PEDIDOS p ON ...         -- p → PEDIDOS
```

Construir mapa de alias por query antes de inferir relaciones.

---

## Strings SQL en C#

Las queries pueden estar en:

```csharp
// String literal simple
string sql = "SELECT * FROM CLIENTES c JOIN PEDIDOS p ON c.ID_CLIENTE = p.ID_CLIENTE";

// StringBuilder
sb.Append("SELECT * FROM CLIENTES c ");
sb.Append("JOIN PEDIDOS p ON c.ID_CLIENTE = p.ID_CLIENTE ");

// Interpolación / concatenación
string sql = "SELECT * FROM " + tableName + " WHERE ...";  // → ignorar si tabla es dinámica

// Atributo o constante
private const string SQL_SELECT = @"
    SELECT ...
    FROM CLIENTES c
    JOIN PEDIDOS p ON c.ID_CLIENTE = p.ID_CLIENTE";
```

Para StringBuilder: concatenar las líneas del mismo método antes de parsear.
Para variables dinámicas: extraer las partes estáticas, marcar relaciones como `confidence: "low"`.

---

## Salida esperada por fichero DALC

```json
{
  "source_file": "OnLine\\...\\RSDalc\\ClienteDalc.cs",
  "tables_found": ["CLIENTES", "PEDIDOS", "TIPOS_CLIENTE"],
  "relations": [
    {
      "source_table": "CLIENTES",
      "source_column": "ID_CLIENTE",
      "target_table": "PEDIDOS",
      "target_column": "ID_CLIENTE",
      "inferred_from": "JoinClause",
      "confidence": "high"
    }
  ]
}
```
