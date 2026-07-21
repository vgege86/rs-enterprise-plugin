# Oracle Data Modeler — Formato .dmd

Los archivos `.dmd` son XML. Este es el subset relevante para import/export.

---

## Estructura raiz

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<model version="..." xmlns:xsi="...">
  <relationalModels>
    <relationalModel id="...">
      <tables>
        <table .../>
      </tables>
      <fkAssociations>
        <fkAssociation .../>
      </fkAssociations>
    </relationalModel>
  </relationalModels>
</model>
```

---

## Tabla

```xml
<table id="TAB1234" name="CLIENTES">
  <createdTime>...</createdTime>
  <columns>
    <column id="COL001" name="ID_CLIENTE" dataTypeID="..." dataTypeName="NUMBER"
            dataTypeParameters="10" mandatory="true" primaryKey="true">
      <comment>Identificador unico del cliente</comment>
    </column>
    <column id="COL002" name="NOMBRE" dataTypeID="..." dataTypeName="VARCHAR2"
            dataTypeParameters="100" mandatory="true" primaryKey="false">
      <comment></comment>
    </column>
  </columns>
  <primaryKey>
    <primaryKeyColumn columnID="COL001"/>
  </primaryKey>
  <comment>Tabla maestra de clientes</comment>
</table>
```

---

## Relacion FK (aunque la BD no las use, se pueden documentar en el modelo)

```xml
<fkAssociation id="FK001" name="FK_CLIENTES_PEDIDOS"
               referredTableID="TAB1234" referringTableID="TAB5678">
  <fkAssociationColumns>
    <fkAssociationColumn id="FKCOL001"
                         referredColumnID="COL001"
                         referringColumnID="COL_PEDIDOS_001"/>
  </fkAssociationColumns>
</fkAssociation>
```

---

## Mapeo JSON → .dmd

| JSON | .dmd |
|------|------|
| `table_name` | `<table name="...">` |
| `column.type` | `dataTypeName` + `dataTypeParameters` |
| `column.nullable` | `mandatory` (invertido) |
| `column.pk` | `primaryKey="true"` + entrada en `<primaryKey>` |
| `column.description` | `<comment>` |
| `table.description` | `<comment>` en tabla |
| `relation` | `<fkAssociation>` (aunque sea logica, no fisica) |

---

## Notas

- Los IDs en .dmd son GUIDs internos — generar con `uuid.uuid4()` al exportar
- Las posiciones visuales (x,y) se almacenan en archivos auxiliares `.dmd` de diagramas
- Al exportar, solo generar el modelo relacional — no el diagrama (las posiciones se pierden)
- Al importar, ignorar elementos de diagrama, solo leer `relationalModels`
