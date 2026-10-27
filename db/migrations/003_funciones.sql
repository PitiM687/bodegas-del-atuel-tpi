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
-- 4. fn_total_comprobante
-- Propósito: Calcula los importes derivados de un comprobante sumando sus
--            renglones y aplicando el descuento del cliente.
-- Parámetros: p_nro_comprobante (INTEGER).
-- Retorna: TABLE (subtotal NUMERIC, descuento NUMERIC, total NUMERIC).
-- Regla de negocio: RN-08.
-- Volatilidad: STABLE (lee las tablas comprobante, cliente y renglon_comprobante).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_total_comprobante(p_nro_comprobante INTEGER)
RETURNS TABLE (
    subtotal  NUMERIC(14,2),
    descuento NUMERIC(14,2),
    total     NUMERIC(14,2)
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_pct_descuento NUMERIC(5,2);
    v_subtotal      NUMERIC(14,2);
    v_descuento     NUMERIC(14,2);
    v_total         NUMERIC(14,2);
BEGIN
    -- Obtener el porcentaje de descuento asignado al cliente del comprobante
    SELECT c.descuento INTO v_pct_descuento
    FROM comprobante comp
    JOIN cliente c ON c.id_cliente = comp.id_cliente
    WHERE comp.nro = p_nro_comprobante;

    IF NOT FOUND THEN
        v_pct_descuento := 0;
    END IF;

    -- Calcular la suma de subtotales brutos de los renglones
    SELECT COALESCE(SUM(rc.cantidad * rc.precio_unitario), 0)
    INTO v_subtotal
    FROM renglon_comprobante rc
    WHERE rc.nro = p_nro_comprobante;

    -- Calcular el monto de descuento y el neto final
    v_descuento := ROUND(v_subtotal * (v_pct_descuento / 100.0), 2);
    v_total     := v_subtotal - v_descuento;

    RETURN QUERY SELECT v_subtotal, v_descuento, v_total;
END;
$$;