-- =====================================================================
-- 001_esquema.sql  ·  Bodegas del Atuel  ·  PostgreSQL 14+
-- Etapa 1: tipos, dominios, tablas, PK y FK.
-- Las restricciones adicionales (UNIQUE, CHECK) y la lógica (funciones,
-- triggers, procedimientos) se completan en las etapas siguientes.
-- Los CHECK mínimos de la Etapa 2 van en 002_constraints.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- TIPOS Y DOMINIOS
-- ---------------------------------------------------------------------
CREATE TYPE estado_documento AS ENUM ('en_confeccion', 'terminado', 'procesado');
CREATE TYPE tipo_cepa        AS ENUM ('tinta', 'blanca');
CREATE TYPE tipo_vino        AS ENUM ('tinto', 'blanco', 'rosado', 'espumante');
CREATE TYPE tipo_cliente     AS ENUM ('socio', 'distribuidor', 'exportador');
CREATE TYPE tipo_documento   AS ENUM ('DNI', 'CUIT', 'CUIL', 'PASAPORTE');
CREATE TYPE dia_semana       AS ENUM ('lunes', 'martes', 'miercoles', 'jueves',
                                      'viernes', 'sabado', 'domingo');

CREATE DOMAIN cuit_dom AS CHAR(11)
    CHECK (VALUE ~ '^[0-9]{11}$');

-- ---------------------------------------------------------------------
-- GEOGRAFÍA, SALAS Y EMPLEADOS
-- ---------------------------------------------------------------------
-- Clave subrogada: el código postal no es único entre provincias.
-- encargado_regional depende solo de la localidad (localidad -> encargado).
CREATE TABLE localidad (
    id_localidad        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_postal       VARCHAR(8)   NOT NULL,
    nombre              VARCHAR(80)  NOT NULL,
    provincia           VARCHAR(60)  NOT NULL,
    encargado_regional  VARCHAR(100) NOT NULL
);

CREATE TABLE sala_venta (
    id_sala        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    calle          VARCHAR(100) NOT NULL,
    numero         VARCHAR(10)  NOT NULL,
    dia_cierre     dia_semana   NOT NULL,
    id_localidad   INTEGER      NOT NULL
        REFERENCES localidad (id_localidad) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE TABLE empleado (
    cuit           cuit_dom      PRIMARY KEY,
    nombre         VARCHAR(100)  NOT NULL,
    fecha_ingreso  DATE          NOT NULL,
    salario        NUMERIC(12,2) NOT NULL,
    id_sala        INTEGER       NOT NULL                       -- RN-03
        REFERENCES sala_venta (id_sala) ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------
-- PRODUCCIÓN DE UVA
-- ---------------------------------------------------------------------
-- Se separa departamento para evitar la dependencia transitiva
-- finca -> departamento -> provincia (3FN).
CREATE TABLE departamento (
    id_departamento  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre           VARCHAR(80) NOT NULL,
    provincia        VARCHAR(60) NOT NULL
);

CREATE TABLE finca (
    id_finca         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre           VARCHAR(100)  NOT NULL,
    superficie_ha    NUMERIC(10,2) NOT NULL,
    id_departamento  INTEGER       NOT NULL
        REFERENCES departamento (id_departamento) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE TABLE cepa (
    id_cepa  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre   VARCHAR(60) NOT NULL,
    tipo     tipo_cepa   NOT NULL
);

-- Entidad débil: la parcela no existe sin su finca -> CASCADE.
CREATE TABLE parcela (
    id_finca        INTEGER       NOT NULL
        REFERENCES finca (id_finca) ON DELETE CASCADE ON UPDATE CASCADE,
    nro_parcela     INTEGER       NOT NULL,
    superficie_ha   NUMERIC(10,2) NOT NULL,
    anio_plantacion SMALLINT      NOT NULL,
    id_cepa         INTEGER       NOT NULL                      -- RN-04: una sola cepa
        REFERENCES cepa (id_cepa) ON DELETE RESTRICT ON UPDATE CASCADE,
    PRIMARY KEY (id_finca, nro_parcela)
);

CREATE TABLE bodega (
    cuit          cuit_dom     PRIMARY KEY,
    razon_social  VARCHAR(120) NOT NULL,
    domicilio     VARCHAR(150) NOT NULL
);

CREATE TABLE lote_uva (
    nro_lote       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_finca       INTEGER  NOT NULL,
    nro_parcela    INTEGER  NOT NULL,
    campania       SMALLINT NOT NULL,                           -- año de cosecha
    fecha_cosecha  DATE     NOT NULL,
    kg_cosechados  NUMERIC(12,2) NOT NULL,
    cuit_bodega    cuit_dom NOT NULL
        REFERENCES bodega (cuit) ON DELETE RESTRICT ON UPDATE CASCADE,
    FOREIGN KEY (id_finca, nro_parcela)
        REFERENCES parcela (id_finca, nro_parcela) ON DELETE RESTRICT ON UPDATE CASCADE
    -- UNIQUE (id_finca, nro_parcela, campania) -> 002_constraints.sql (RN-04)
);

CREATE TABLE analisis_calidad (
    id_analisis  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nro_lote     INTEGER       NOT NULL
        REFERENCES lote_uva (nro_lote) ON DELETE CASCADE ON UPDATE CASCADE,
    fecha        DATE          NOT NULL,
    grado_brix   NUMERIC(4,1)  NOT NULL,
    ph           NUMERIC(3,2)  NOT NULL,
    acidez_total NUMERIC(4,2)  NOT NULL                         -- g/L
);

-- ---------------------------------------------------------------------
-- VINOS
-- ---------------------------------------------------------------------
CREATE TABLE vino (
    cod_vino     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre       VARCHAR(80)   NOT NULL,
    tipo         tipo_vino     NOT NULL,
    anada        SMALLINT      NOT NULL,
    volumen_ml   INTEGER       NOT NULL,
    graduacion   NUMERIC(4,2)  NOT NULL,
    precio       NUMERIC(10,2) NOT NULL,                        -- RN-01
    cuit_bodega  cuit_dom      NOT NULL
        REFERENCES bodega (cuit) ON DELETE RESTRICT ON UPDATE CASCADE   -- RN-14
);

-- N:M con atributo (porcentaje). La suma = 100 va en trigger diferido (RN-05).
CREATE TABLE composicion_vino (
    cod_vino    INTEGER      NOT NULL
        REFERENCES vino (cod_vino) ON DELETE CASCADE ON UPDATE CASCADE,
    id_cepa     INTEGER      NOT NULL
        REFERENCES cepa (id_cepa) ON DELETE RESTRICT ON UPDATE CASCADE,
    porcentaje  NUMERIC(5,2) NOT NULL,
    PRIMARY KEY (cod_vino, id_cepa)
);

CREATE TABLE maridaje (
    id_maridaje        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre             VARCHAR(80)  NOT NULL,
    temperatura_c      NUMERIC(4,1) NOT NULL
);

CREATE TABLE vino_maridaje (
    cod_vino     INTEGER NOT NULL
        REFERENCES vino (cod_vino) ON DELETE CASCADE ON UPDATE CASCADE,
    id_maridaje  INTEGER NOT NULL
        REFERENCES maridaje (id_maridaje) ON DELETE RESTRICT ON UPDATE CASCADE,
    PRIMARY KEY (cod_vino, id_maridaje)
);

-- ---------------------------------------------------------------------
-- CLIENTES: supertipo + subtipos
-- El descuento se almacena en cliente (lo inicializa fn_descuento_cliente)
-- porque la consigna U6 lo modifica por cliente (exportador -> 35 %).
-- ---------------------------------------------------------------------
CREATE TABLE cliente (
    id_cliente        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre_razon      VARCHAR(150)  NOT NULL,                   -- apellido y nombre o razón social
    tipo              tipo_cliente  NOT NULL,
    tipo_documento    tipo_documento NOT NULL,
    nro_documento     VARCHAR(20)   NOT NULL,
    direccion         VARCHAR(150)  NOT NULL,
    id_localidad      INTEGER       NOT NULL
        REFERENCES localidad (id_localidad) ON DELETE RESTRICT ON UPDATE CASCADE,
    fecha_alta        DATE          NOT NULL DEFAULT CURRENT_DATE,
    descuento         NUMERIC(5,2)  NOT NULL                    -- porcentaje
);

CREATE TABLE socio (
    id_cliente INTEGER PRIMARY KEY
        REFERENCES cliente (id_cliente) ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE distribuidor (
    id_cliente       INTEGER PRIMARY KEY
        REFERENCES cliente (id_cliente) ON DELETE CASCADE ON UPDATE CASCADE,
    zona_cobertura   VARCHAR(100) NOT NULL,
    nro_habilitacion VARCHAR(30)  NOT NULL
);

CREATE TABLE exportador (
    id_cliente    INTEGER PRIMARY KEY
        REFERENCES cliente (id_cliente) ON DELETE CASCADE ON UPDATE CASCADE,
    pais_destino  VARCHAR(60) NOT NULL
);

CREATE TABLE permiso_exportacion (
    id_permiso        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo            VARCHAR(30) NOT NULL,
    id_cliente        INTEGER     NOT NULL
        REFERENCES exportador (id_cliente) ON DELETE CASCADE ON UPDATE CASCADE,
    fecha_emision     DATE        NOT NULL,
    fecha_vencimiento DATE        NOT NULL                      -- RN-07 (CHECK en etapa 2)
);

-- ---------------------------------------------------------------------
-- VENTAS
-- subtotal / descuento / total: almacenados, calculados por función+trigger (RN-08).
-- ---------------------------------------------------------------------
CREATE TABLE comprobante (
    nro         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha       DATE          NOT NULL DEFAULT CURRENT_DATE,
    id_cliente  INTEGER       NOT NULL
        REFERENCES cliente (id_cliente) ON DELETE RESTRICT ON UPDATE CASCADE,
    id_sala     INTEGER       NOT NULL
        REFERENCES sala_venta (id_sala) ON DELETE RESTRICT ON UPDATE CASCADE,
    subtotal    NUMERIC(14,2) NOT NULL DEFAULT 0,
    descuento   NUMERIC(14,2) NOT NULL DEFAULT 0,               -- importe descontado
    total       NUMERIC(14,2) NOT NULL DEFAULT 0
);

CREATE TABLE renglon_comprobante (
    nro              INTEGER       NOT NULL
        REFERENCES comprobante (nro) ON DELETE CASCADE ON UPDATE CASCADE,
    cod_vino         INTEGER       NOT NULL
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE CASCADE,
    cantidad         INTEGER       NOT NULL,
    precio_unitario  NUMERIC(10,2) NOT NULL,                    -- precio al momento de la venta
    descuento_pct    NUMERIC(5,2)  NOT NULL,
    subtotal         NUMERIC(14,2) NOT NULL,
    PRIMARY KEY (nro, cod_vino)
);

-- ---------------------------------------------------------------------
-- TRANSPORTISTAS
-- ---------------------------------------------------------------------
CREATE TABLE transportista (
    id_transportista  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    razon_social      VARCHAR(120) NOT NULL,
    cuit              cuit_dom     NOT NULL,
    email             VARCHAR(120) NOT NULL,
    telefono          VARCHAR(30)  NOT NULL,
    domicilio         VARCHAR(150) NOT NULL
);

CREATE TABLE transportista_localidad (
    id_transportista INTEGER NOT NULL
        REFERENCES transportista (id_transportista) ON DELETE CASCADE ON UPDATE CASCADE,
    id_localidad     INTEGER NOT NULL
        REFERENCES localidad (id_localidad) ON DELETE CASCADE ON UPDATE CASCADE,
    PRIMARY KEY (id_transportista, id_localidad)
);

-- ---------------------------------------------------------------------
-- INGRESOS, TRANSFERENCIAS Y STOCK
-- ---------------------------------------------------------------------
CREATE TABLE ingreso (
    cod_ingreso       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha             DATE             NOT NULL DEFAULT CURRENT_DATE,
    estado            estado_documento NOT NULL DEFAULT 'en_confeccion',
    id_transportista  INTEGER          NOT NULL
        REFERENCES transportista (id_transportista) ON DELETE RESTRICT ON UPDATE CASCADE,
    cuit_bodega       cuit_dom         NOT NULL
        REFERENCES bodega (cuit) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE TABLE renglon_ingreso (
    cod_ingreso  INTEGER NOT NULL
        REFERENCES ingreso (cod_ingreso) ON DELETE CASCADE ON UPDATE CASCADE,
    cod_vino     INTEGER NOT NULL
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE CASCADE,
    cantidad     INTEGER NOT NULL,
    PRIMARY KEY (cod_ingreso, cod_vino)
);

CREATE TABLE transferencia (
    nro_solicitud     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_sala           INTEGER          NOT NULL
        REFERENCES sala_venta (id_sala) ON DELETE RESTRICT ON UPDATE CASCADE,
    fecha_confeccion  DATE             NOT NULL DEFAULT CURRENT_DATE,  -- RN-11 (trigger)
    estado            estado_documento NOT NULL DEFAULT 'en_confeccion'
);

CREATE TABLE renglon_transferencia (
    nro_solicitud  INTEGER NOT NULL
        REFERENCES transferencia (nro_solicitud) ON DELETE CASCADE ON UPDATE CASCADE,
    cod_vino       INTEGER NOT NULL
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE CASCADE,
    cantidad       INTEGER NOT NULL,
    PRIMARY KEY (nro_solicitud, cod_vino)
);

CREATE TABLE stock_sala (
    id_sala   INTEGER NOT NULL
        REFERENCES sala_venta (id_sala) ON DELETE RESTRICT ON UPDATE CASCADE,
    cod_vino  INTEGER NOT NULL
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE CASCADE,
    cantidad  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (id_sala, cod_vino)
);

-- Un solo depósito central -> la clave es solo el vino.
CREATE TABLE stock_deposito (
    cod_vino  INTEGER PRIMARY KEY
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE CASCADE,
    cantidad  INTEGER NOT NULL DEFAULT 0
);

-- Completada por trigger AFTER UPDATE en vino (RN-13).
CREATE TABLE auditoria_precio (
    id_auditoria     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cod_vino         INTEGER       NOT NULL
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE CASCADE,
    precio_anterior  NUMERIC(10,2) NOT NULL,
    precio_nuevo     NUMERIC(10,2) NOT NULL,
    fecha_hora       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    usuario          TEXT          NOT NULL DEFAULT current_user
);
