-- =====================================================================
-- 006_vistas.sql  ·  Bodegas del Atuel  ·  PostgreSQL 14+
-- Etapa 2: Vistas ajustadas al 001_esquema.sql oficial
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. vw_stock_total_vino
-- Propósito: Consolida el stock de cada vino entre el depósito central,
--            las salas de venta y el total global.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_stock_total_vino AS
SELECT 
    v.cod_vino,
    v.nombre AS vino,
    v.tipo AS tipo_vino,
    v.anada,
    v.precio,
    COALESCE(sd.cantidad, 0) AS stock_deposito_central,
    COALESCE(SUM(ss.cantidad), 0) AS stock_total_salas,
    COALESCE(sd.cantidad, 0) + COALESCE(SUM(ss.cantidad), 0) AS stock_total_sistema
FROM vino v
LEFT JOIN stock_deposito sd ON v.cod_vino = sd.cod_vino
LEFT JOIN stock_sala ss ON v.cod_vino = ss.cod_vino
GROUP BY v.cod_vino, v.nombre, v.tipo, v.anada, v.precio, sd.cantidad;

-- ---------------------------------------------------------------------
-- 2. vw_ventas_mensuales_sala
-- Propósito: Agrupa las ventas por año, mes y sala de venta.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_ventas_mensuales_sala AS
SELECT 
    s.id_sala,
    ('Sala ' || s.numero::text) AS sala_venta,
    EXTRACT(YEAR FROM c.fecha)::INTEGER AS anio,
    EXTRACT(MONTH FROM c.fecha)::INTEGER AS mes,
    COUNT(c.nro) AS cantidad_comprobantes,
    SUM(c.subtotal) AS subtotal_acumulado,
    SUM(c.descuento) AS descuento_acumulado,
    SUM(c.total) AS total_facturado
FROM sala_venta s
JOIN comprobante c ON s.id_sala = c.id_sala
GROUP BY s.id_sala, s.numero, EXTRACT(YEAR FROM c.fecha), EXTRACT(MONTH FROM c.fecha);

-- ---------------------------------------------------------------------
-- 3. vw_documentos_pendientes
-- Propósito: Muestra ingresos y transferencias no procesados.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_documentos_pendientes AS
SELECT 
    'Ingreso' AS tipo_documento,
    i.cod_ingreso AS nro_documento,
    i.fecha,
    i.estado,
    (CURRENT_DATE - i.fecha) AS dias_antiguedad,
    b.razon_social AS entidad_asociada
FROM ingreso i
JOIN bodega b ON i.cuit_bodega = b.cuit
WHERE i.estado <> 'procesado'

UNION ALL

SELECT 
    'Transferencia' AS tipo_documento,
    t.nro_solicitud AS nro_documento,
    t.fecha_confeccion AS fecha,
    t.estado,
    (CURRENT_DATE - t.fecha_confeccion) AS dias_antiguedad,
    ('Sala ' || s.numero::text) AS entidad_asociada
FROM transferencia t
JOIN sala_venta s ON t.id_sala = s.id_sala
WHERE t.estado <> 'procesado';