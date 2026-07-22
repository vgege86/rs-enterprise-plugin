# Patrones de Test — RS/uCollect

Guía de convenciones para tests en soluciones uCollect/RS. Referenciada por `agents/rs-crear-tests.md`.

## Framework estándar

xUnit (preferido), MSTest (si ya existe en el proyecto), NUnit (solo si el proyecto ya lo usa).

## Naming

```
Método:    <MetodoATestear>_<Escenario>_<ResultadoEsperado>
Clase:     <ClaseATestear>Tests
Namespace: <SolutionName>.Tests.<NamespaceOrigen>
```

Ejemplos:
```csharp
ValidarFecha_FechaVacia_RetornaFalse
ValidarFecha_FechaValida_RetornaTrue
ProcesarCliente_ClienteNull_LanzaArgumentNullException
```

## Estructura de test (AAA)

```csharp
[Fact]
public void MetodoATestear_Escenario_ResultadoEsperado()
{
    // Arrange
    var sut = new ClaseATestear();
    var input = ...;

    // Act
    var result = sut.Metodo(input);

    // Assert
    Assert.Equal(expected, result);
}
```

## Patrones por tipo de clase

### Lógica de negocio / validación

```csharp
public class ValidadorFechaTests
{
    [Theory]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("99/99/9999")]
    public void ValidarFecha_EntradaInvalida_RetornaFalse(string fecha)
    {
        var sut = new ValidadorFecha();
        Assert.False(sut.Validar(fecha));
    }
}
```

### Procesadores / transformadores

```csharp
[Fact]
public void Procesar_InputCompleto_GeneraSalidaCorrecta()
{
    var sut = new Procesador();
    var input = BuildInputCompleto();  // método helper en la clase de test
    var result = sut.Procesar(input);
    Assert.NotNull(result);
    Assert.Equal("ValorEsperado", result.Campo);
}
```

### Clases con dependencias de BD (DALC)

No testear contra BD real en tests unitarios. Usar patrón repositorio o stub:

```csharp
// Si la clase recibe la dependencia por constructor → inyectarla como stub
// Si no → test de integración manual, marcar con [Trait("Category","Integration")]
[Fact]
[Trait("Category", "Unit")]
public void Metodo_SinBD_ComportamientoEsperado()
{
    // Testear la lógica pura, no la persistencia
}
```

## Convenciones uCollect/RS

- Namespace del proyecto de test = `<SolutionName>.Tests`
- Un archivo .cs por clase testeada
- Máx 20 métodos de test por clase de test
- Tests de integración (requieren BD) → carpeta `Integration\` dentro del proyecto de test y marcados con `[Trait("Category","Integration")]`
- Datos de prueba hardcodeados con valores realistas (IDs RS, fechas, códigos)

## Referencia rápida de asserts (xUnit)

```csharp
Assert.Equal(expected, actual)
Assert.NotEqual(expected, actual)
Assert.True(condition)
Assert.False(condition)
Assert.Null(value)
Assert.NotNull(value)
Assert.Throws<ExceptionType>(() => action())
Assert.Contains(item, collection)
Assert.Empty(collection)
Assert.InRange(value, low, high)
```
