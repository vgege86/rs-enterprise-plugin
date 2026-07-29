-- =====================================================================================
-- RVERSIONES — registro de entregas por entorno y solucion (SQL Server)
-- Idempotente: se puede ejecutar varias veces sin error.
--
-- Una fila = una entrega de UNA solucion sobre UN entorno.
-- FECHA_CORTE es la fecha hasta la que se incluyeron commits: es el punto de partida
-- del delta de la SIGUIENTE entrega de esa solucion en ese entorno.
-- DESCRIPCION es funcional (la lee el usuario final), nunca tecnica.
-- =====================================================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RVERSIONES')
BEGIN
    CREATE TABLE RVERSIONES (
        ID_VERSION      INT IDENTITY(1,1) NOT NULL,
        ENTORNO         VARCHAR(10)       NOT NULL,
        SOLUCION        VARCHAR(100)      NOT NULL,
        VERSION         VARCHAR(30)       NOT NULL,
        FECHA_ENTREGA   DATETIME          NOT NULL CONSTRAINT DF_RVERSIONES_FE DEFAULT (GETDATE()),
        FECHA_CORTE     DATETIME          NOT NULL,
        DESCRIPCION     VARCHAR(4000)     NULL,
        TAREAS          VARCHAR(500)      NULL,
        USUARIO         VARCHAR(50)       NULL,
        CONSTRAINT PK_RVERSIONES PRIMARY KEY (ID_VERSION),
        CONSTRAINT CK_RVERSIONES_ENT CHECK (ENTORNO IN ('DESA','TEST','PROD'))
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_RVERSIONES_ENT_SOL')
BEGIN
    CREATE INDEX IX_RVERSIONES_ENT_SOL ON RVERSIONES (ENTORNO, SOLUCION, FECHA_CORTE);
END
GO
