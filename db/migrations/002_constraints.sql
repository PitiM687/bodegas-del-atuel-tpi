-- =====================================================================
-- 002_constraints.sql  ·  Bodegas del Atuel
-- Etapa 2: restricciones UNIQUE y CHECK sobre el esquema de 001.
--
-- Ya resueltos en 001_esquema.sql (no se repiten acá):
--   * PRIMARY KEY y FOREIGN KEY con ON DELETE / ON UPDATE en todas las tablas.
--   * NOT NULL en todo atributo obligatorio.
--   * DEFAULT: estado = 'en_confeccion' (ingreso, transferencia),
--     fecha = CURRENT_DATE (comprobante, ingreso, transferencia, fecha_alta),
--     cantidad = 0 (stock), now() y current_user (auditoria_precio).
--   * ENUM (estado_documento y otros) y DOMAIN (cuit_dom).
--
-- Regla: ningún CHECK usa CURRENT_DATE ni funciones no determinísticas
-- (esas reglas van en triggers, ver 005_triggers.sql).
-- =====================================================================

-- ---------------------------------------------------------------------
-- UNIQUE (claves candidatas)
-- ---------------------------------------------------------------------
-- Un vino se distingue por nombre + añada + presentación.
ALTER TABLE vino
    ADD CONSTRAINT uq_vino_nombre_anada_volumen UNIQUE (nombre, anada, volumen_ml);

-- RN-04: una parcela se cosecha a lo sumo una vez por campaña.
ALTER TABLE lote_uva
    ADD CONSTRAINT uq_lote_parcela_campania UNIQUE (id_finca, nro_parcela, campania);

-- Claves candidatas de catálogos.
ALTER TABLE localidad
    ADD CONSTRAINT uq_localidad_nombre_provincia UNIQUE (nombre, provincia);
ALTER TABLE departamento
    ADD CONSTRAINT uq_departamento_nombre_provincia UNIQUE (nombre, provincia);
ALTER TABLE cepa
    ADD CONSTRAINT uq_cepa_nombre UNIQUE (nombre);
ALTER TABLE maridaje
    ADD CONSTRAINT uq_maridaje_nombre UNIQUE (nombre);

-- Un mismo documento no puede darse de alta dos veces como cliente.
ALTER TABLE cliente
    ADD CONSTRAINT uq_cliente_documento UNIQUE (tipo_documento, nro_documento);

ALTER TABLE transportista
    ADD CONSTRAINT uq_transportista_cuit UNIQUE (cuit);
ALTER TABLE permiso_exportacion
    ADD CONSTRAINT uq_permiso_codigo UNIQUE (codigo);

-- ---------------------------------------------------------------------
-- CHECK
-- ---------------------------------------------------------------------
-- RN-01 y RN-15: precio positivo, graduación entre 5 y 20, volumen positivo.
ALTER TABLE vino
    ADD CONSTRAINT ck_vino_precio      CHECK (precio > 0),
    ADD CONSTRAINT ck_vino_graduacion  CHECK (graduacion BETWEEN 5 AND 20),
    ADD CONSTRAINT ck_vino_volumen     CHECK (volumen_ml > 0),
    ADD CONSTRAINT ck_vino_anada       CHECK (anada BETWEEN 1900 AND 2100);

-- RN-15: salarios, superficies y kilos positivos.
ALTER TABLE empleado
    ADD CONSTRAINT ck_empleado_salario CHECK (salario > 0);
ALTER TABLE finca
    ADD CONSTRAINT ck_finca_superficie CHECK (superficie_ha > 0);
ALTER TABLE parcela
    ADD CONSTRAINT ck_parcela_superficie CHECK (superficie_ha > 0),
    ADD CONSTRAINT ck_parcela_anio       CHECK (anio_plantacion BETWEEN 1800 AND 2100);
ALTER TABLE lote_uva
    ADD CONSTRAINT ck_lote_kg       CHECK (kg_cosechados > 0),
    ADD CONSTRAINT ck_lote_campania CHECK (campania BETWEEN 2000 AND 2100);

-- Rangos físicos razonables para el análisis de calidad.
ALTER TABLE analisis_calidad
    ADD CONSTRAINT ck_analisis_brix   CHECK (grado_brix BETWEEN 0 AND 50),
    ADD CONSTRAINT ck_analisis_ph     CHECK (ph BETWEEN 0 AND 14),
    ADD CONSTRAINT ck_analisis_acidez CHECK (acidez_total > 0);

-- RN-05 (parte por fila): cada porcentaje está entre 0 y 100 (exclusive el 0).
-- La suma exacta de 100 por vino se garantiza con un constraint trigger diferido.
ALTER TABLE composicion_vino
    ADD CONSTRAINT ck_composicion_porcentaje CHECK (porcentaje > 0 AND porcentaje <= 100);

ALTER TABLE maridaje
    ADD CONSTRAINT ck_maridaje_temperatura CHECK (temperatura_c BETWEEN 0 AND 30);

-- RN-06 (parte por fila): el descuento es un porcentaje válido.
-- El valor que corresponde a cada tipo lo define fn_descuento_cliente.
ALTER TABLE cliente
    ADD CONSTRAINT ck_cliente_descuento CHECK (descuento BETWEEN 0 AND 100);

-- RN-07: CHECK ENTRE COLUMNAS. El vencimiento es posterior a la emisión.
ALTER TABLE permiso_exportacion
    ADD CONSTRAINT ck_permiso_fechas CHECK (fecha_vencimiento > fecha_emision);

-- RN-08 / RN-15: importes y cantidades de la venta.
ALTER TABLE comprobante
    ADD CONSTRAINT ck_comprobante_importes
        CHECK (subtotal >= 0 AND descuento >= 0 AND total >= 0);
ALTER TABLE renglon_comprobante
    ADD CONSTRAINT ck_renglon_cant        CHECK (cantidad > 0),
    ADD CONSTRAINT ck_renglon_precio      CHECK (precio_unitario > 0),
    ADD CONSTRAINT ck_renglon_descuento   CHECK (descuento_pct BETWEEN 0 AND 100),
    ADD CONSTRAINT ck_renglon_subtotal    CHECK (subtotal >= 0);

-- RN-15: cantidades de ingresos y transferencias siempre positivas.
ALTER TABLE renglon_ingreso
    ADD CONSTRAINT ck_renglon_ingreso_cant CHECK (cantidad > 0);
ALTER TABLE renglon_transferencia
    ADD CONSTRAINT ck_renglon_transf_cant CHECK (cantidad > 0);

-- RN-09: el stock nunca es negativo (sala y depósito).
ALTER TABLE stock_sala
    ADD CONSTRAINT ck_stock_sala_cantidad CHECK (cantidad >= 0);
ALTER TABLE stock_deposito
    ADD CONSTRAINT ck_stock_deposito_cantidad CHECK (cantidad >= 0);

-- RN-13: la auditoría solo guarda precios válidos.
ALTER TABLE auditoria_precio
    ADD CONSTRAINT ck_auditoria_precios CHECK (precio_anterior > 0 AND precio_nuevo > 0);
