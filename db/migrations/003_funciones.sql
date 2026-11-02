-- =====================================================================
-- 003_funciones.sql  ·  Bodegas del Atuel  ·  PostgreSQL 14+
-- Etapa 2: Funciones del sistema (RN-06, RN-08, RN-09 y soporte a reportes)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. fn_descuento_cliente
-- Propósito: Devuelve el porcentaje de descuento base según el tipo de cliente.
-- Parámetros: p_tipo (tipo_cliente: 'socio', 'distribuidor', 'exportador').
-- Regla de negocio: RN-06 (socio 10%, distribuidor 20%, exportador 30%).
-- Volatilidad: IMMUTABLE (siempre devuelve el mismo valor para el mismo tipo).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_descuento_cliente(p_tipo tipo_cliente)
RETURNS NUMERIC(5,2)
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    CASE p_tipo
        WHEN 'socio' THEN
            RETURN 10.00;
        WHEN 'distribuidor' THEN
            RETURN 20.00;
        WHEN 'exportador' THEN
            RETURN 30.00;
        ELSE
            RETURN 0.00;
    END CASE;
END;
$$;

-- ---------------------------------------------------------------------
-- 2. fn_antiguedad_anios
-- Propósito: Calcula la cantidad de años cumplidos desde una fecha dada hasta hoy.
-- Parámetros: p_fecha_ingreso (DATE).
-- Uso: Liquidación salarial y aumentos por antigüedad (consigna U2).
-- Volatilidad: STABLE (depende de CURRENT_DATE; no varía dentro de la misma transacción).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_antiguedad_anios(p_fecha_ingreso DATE)
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT EXTRACT(YEAR FROM age(CURRENT_DATE, p_fecha_ingreso))::INTEGER;
$$;

-- ---------------------------------------------------------------------
-- 3. fn_stock_sala
-- Propósito: Devuelve el stock actual de un vino en una sala determinada.
--            Si no existe registro para ese vino en la sala, retorna 0.
-- Parámetros: p_id_sala (INTEGER), p_cod_vino (INTEGER).
-- Regla de negocio: RN-09.
-- Volatilidad: STABLE (consulta tablas de la base, varía entre transacciones).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_stock_sala(p_id_sala INTEGER, p_cod_vino INTEGER)
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT cantidad 
         FROM stock_sala 
         WHERE id_sala = p_id_sala AND cod_vino = p_cod_vino), 
        0
    );
$$;

-- ---------------------------------------------------------------------
-- 4. fn_subtotal_renglon
-- Propósito: Importe neto de un renglón de venta:
--            cantidad × precio_unitario × (1 − descuento_pct / 100), a 2 decimales.
-- Parámetros: p_cantidad, p_precio_unitario, p_descuento_pct.
-- Regla de negocio: RN-08. Es la ÚNICA fórmula del subtotal de un renglón;
--            la usan el trigger de renglón y la consulta de control de la carga.
-- Volatilidad: IMMUTABLE (solo depende de sus argumentos).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_subtotal_renglon(
    p_cantidad        INTEGER,
    p_precio_unitario NUMERIC,
    p_descuento_pct   NUMERIC
)
RETURNS NUMERIC(14,2)
LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND(p_cantidad * p_precio_unitario * (1 - p_descuento_pct / 100.0), 2);
$$;

-- ---------------------------------------------------------------------
-- 5. fn_total_comprobante
-- Propósito: Calcula los importes derivados de un comprobante a partir de
--            sus renglones.
--              subtotal  = Σ cantidad × precio_unitario        (bruto)
--              total     = Σ subtotal de cada renglón           (neto)
--              descuento = subtotal − total
--            Usa el precio y el descuento GUARDADOS EN EL RENGLÓN (valores
--            históricos del momento de la venta), no los actuales del vino o
--            del cliente: así, un cambio de precio (RN-13) o de descuento
--            (consigna U6) no altera ventas ya emitidas.
-- Parámetros: p_nro_comprobante (INTEGER).
-- Retorna: TABLE (subtotal, descuento, total).
-- Regla de negocio: RN-08.
-- Volatilidad: STABLE (lee renglon_comprobante).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_total_comprobante(p_nro_comprobante INTEGER)
RETURNS TABLE (
    subtotal  NUMERIC(14,2),
    descuento NUMERIC(14,2),
    total     NUMERIC(14,2)
)
LANGUAGE sql STABLE AS $$
    SELECT bruto, bruto - neto, neto
      FROM (SELECT COALESCE(SUM(rc.cantidad * rc.precio_unitario), 0)::NUMERIC(14,2) AS bruto,
                   COALESCE(SUM(rc.subtotal), 0)::NUMERIC(14,2)                      AS neto
              FROM renglon_comprobante rc
             WHERE rc.nro = p_nro_comprobante) t;
$$;
