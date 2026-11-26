# Convenciones de Proyecto

---

# 🧠 Naming

---

## Clases

- PascalCase
- nombres descriptivos

---

## Métodos

- verbo + acción
- evitar nombres genéricos

---

## Variables

- camelCase
- evitar abreviaturas confusas

---

# 📂 Estructura

---

## Batch

Batch\Soluciones\<Solution>\

---

## Online

OnLine\Soluciones\<Solution>\

---

# ⚙️ Reglas de código

- métodos cortos
- validaciones explícitas
- evitar lógica duplicada

---

# 💬 Comentarios (CRÍTICO)

Menos comentarios y más precisos. El código bien nombrado se explica solo; un comentario que
repite lo que dice la línea de debajo es ruido y envejece mal.

## 1. Función nueva → `summary` obligatorio

Todo método, función, constructor o propiedad con lógica **creado** en la tarea lleva su
comentario de documentación: qué hace, qué recibe y qué devuelve. Ni más ni menos.

C#:
```csharp
/// <summary>Calcula el importe pendiente de una cartera descontando los pagos aplicados.</summary>
/// <param name="idCartera">Identificador de la cartera.</param>
/// <param name="fechaCorte">Fecha hasta la que se tienen en cuenta los pagos.</param>
/// <param name="numPagos">Salida: número de pagos aplicados.</param>
/// <returns>Importe pendiente; 0 si la cartera está saldada.</returns>
public decimal CalcularPendiente(int idCartera, DateTime fechaCorte, out int numPagos)
```

VB.NET: lo mismo con `'''`. PL/SQL (procedimiento o función nueva): cabecera `/* */` con
propósito, parámetros (`IN`/`OUT`) y retorno.

- Un `<param>` por parámetro, en orden; los `out`/`ref` (o `OUT` en PL/SQL) se marcan como
  **salida**. `<returns>` solo si devuelve algo. Una línea por elemento.
- Métodos de test: basta el `<summary>` con el caso que prueban.
- ⛔ No añadir `summary` a lo que **no** se ha creado: un método existente que se modifica
  conserva su comentario (si el cambio lo deja falso, se corrige esa frase y nada más).

## 2. Código existente modificado → un comentario con la tarea

Al tocar código **que ya existía**, como mucho **un** comentario por bloque modificado, encima
del bloque, con la tarea y qué se cambia:

```csharp
// Mantis 48213: se valida la longitud de CAAPORTEXPERIAN antes de grabar
if (cartera.AporteExperian?.Length > 1) { ... }
```

- La tarea es el identificador que viene en la solicitud (Mantis, Jira…: `Mantis 48213`,
  `RS-312`), que el planner pasa en `CONTEXT` → `Tarea`. Si no hay identificador, una
  descripción breve del cambio. ⛔ No inventar un número.
- Dentro de una **función nueva** no se pone este comentario: ya la documenta su `summary`.
- Un bloque contiguo = un comentario, aunque cambien varias líneas.

## 3. Lógica compleja → comentario explicativo, solo ahí

Un comentario dentro del cuerpo solo si explica el **porqué** de algo que no se deduce leyendo:
una regla de negocio, un caso límite, una restricción de la BD o del motor, un orden que no se
puede cambiar. Uno, breve, encima del trozo.

## ⛔ Prohibido

- Comentarios que repiten el código (`// incrementa el contador`, `// llama al DALC`,
  `// declaración de variables`).
- Un comentario por línea o por paso obvio; separadores y banners (`// ====`), `#region` nuevos
  solo para agrupar.
- Código comentado, autor/fecha/historial dentro del código (eso está en el control de
  versiones), `TODO` que nadie ha pedido.
- Borrar o reescribir comentarios existentes que no tienen que ver con el cambio (fuera de
  scope).

---

# 🔐 Validaciones

- validar inputs SIEMPRE
- no confiar en datos externos

---

# 🧪 Testing

- validar flujo principal
- cubrir casos borde

---

# ⚠️ Buenas prácticas

- no modificar código fuera de scope
- cambios mínimos
- evitar refactors innecesarios
