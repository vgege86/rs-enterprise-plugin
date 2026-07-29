-- =====================================================================================
-- RVERSIONES — registro de entregas por entorno y solucion (Oracle)
-- Idempotente: se puede ejecutar varias veces sin error.
--
-- Una fila = una entrega de UNA solucion sobre UN entorno.
-- FECHA_CORTE es la fecha hasta la que se incluyeron commits: es el punto de partida
-- del delta de la SIGUIENTE entrega de esa solucion en ese entorno.
-- DESCRIPCION es funcional (la lee el usuario final), nunca tecnica.
-- =====================================================================================

DECLARE
    v_existe NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_existe FROM USER_TABLES WHERE TABLE_NAME = 'RVERSIONES';
    IF v_existe = 0 THEN
        EXECUTE IMMEDIATE '
            CREATE TABLE RVERSIONES (
                ID_VERSION      NUMBER(10)      NOT NULL,
                ENTORNO         VARCHAR2(10)    NOT NULL,
                SOLUCION        VARCHAR2(100)   NOT NULL,
                VERSION         VARCHAR2(30)    NOT NULL,
                FECHA_ENTREGA   DATE            DEFAULT SYSDATE NOT NULL,
                FECHA_CORTE     DATE            NOT NULL,
                DESCRIPCION     VARCHAR2(4000),
                TAREAS          VARCHAR2(500),
                USUARIO         VARCHAR2(50),
                CONSTRAINT PK_RVERSIONES PRIMARY KEY (ID_VERSION),
                CONSTRAINT CK_RVERSIONES_ENT CHECK (ENTORNO IN (''DESA'',''TEST'',''PROD''))
            )';
    END IF;
END;
/

DECLARE
    v_existe NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_existe FROM USER_SEQUENCES WHERE SEQUENCE_NAME = 'SEQ_RVERSIONES';
    IF v_existe = 0 THEN
        EXECUTE IMMEDIATE 'CREATE SEQUENCE SEQ_RVERSIONES START WITH 1 INCREMENT BY 1 NOCACHE';
    END IF;
END;
/

-- Consulta de ultima entrega por entorno/solucion (la que usa /rs-actualizador para el delta)
DECLARE
    v_existe NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_existe FROM USER_INDEXES WHERE INDEX_NAME = 'IX_RVERSIONES_ENT_SOL';
    IF v_existe = 0 THEN
        EXECUTE IMMEDIATE 'CREATE INDEX IX_RVERSIONES_ENT_SOL ON RVERSIONES (ENTORNO, SOLUCION, FECHA_CORTE)';
    END IF;
END;
/
