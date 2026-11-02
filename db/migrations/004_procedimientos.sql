-- =====================================================================
-- 004_procedimientos.sql  ·  Bodegas del Atuel  ·  PostgreSQL 14+
-- Etapa 2: procedimientos transaccionales (RN-10 y RN-11).
--
-- Los dos procedimientos siguen el mismo esquema "todo o nada":
--   1. Bloquean la cabecera con FOR UPDATE (dos procesos simultáneos sobre
--      el mismo documento quedan serializados).
--   2. Validan estado y existencia de renglones.
--   3. Modifican los stocks.
--   4. Pasan el documento a 'procesado'.
-- Si cualquier paso lanza una excepción, PostgreSQL revierte TODO lo hecho
-- dentro del CALL (el procedimiento corre dentro de la transacción del
-- llamador), así que nunca queda un cambio a medias.
--
-- Pase de 'terminado' a 'procesado':
--   El trigger de estados (005_triggers.sql) solo acepta ese cambio si la
--   variable de sesión 'bodegas.via_procedimiento' vale 'on'. Estos
--   procedimientos la activan con set_config(..., true) — es decir, LOCAL a
--   la transacción — justo antes del UPDATE y la apagan inmediatamente
--   después. Así un UPDATE directo a 'procesado' (que no movería stock) es
--   rechazado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. sp_procesar_ingreso
-- Propósito: acredita en el depósito central las botellas de un ingreso
--            'terminado' y lo pasa a 'procesado'.
-- Parámetros: p_cod_ingreso (INTEGER).
-- Regla de negocio: RN-10.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_procesar_ingreso(p_cod_ingreso INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_estado         estado_documento;
    v_cant_renglones INTEGER;
BEGIN
    -- Bloquea la cabecera: otro proceso que intente procesar el mismo
    -- ingreso espera acá y, al continuar, ya lo ve 'procesado'.
    SELECT estado INTO v_estado
      FROM ingreso
     WHERE cod_ingreso = p_cod_ingreso
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el ingreso %. (RN-10)', p_cod_ingreso;
    END IF;

    IF v_estado IS DISTINCT FROM 'terminado' THEN
        RAISE EXCEPTION 'El ingreso % no está terminado (estado actual: %). Solo un ingreso terminado impacta en el depósito. (RN-10)',
            p_cod_ingreso, v_estado;
    END IF;

    SELECT COUNT(*) INTO v_cant_renglones
      FROM renglon_ingreso
     WHERE cod_ingreso = p_cod_ingreso;

    IF v_cant_renglones = 0 THEN
        RAISE EXCEPTION 'El ingreso % no tiene renglones. (RN-10)', p_cod_ingreso;
    END IF;

    -- Acredita en el depósito central (crea la fila si el vino todavía no
    -- tenía stock). El UPSERT bloquea cada fila de stock_deposito que toca.
    INSERT INTO stock_deposito (cod_vino, cantidad)
    SELECT cod_vino, cantidad
      FROM renglon_ingreso
     WHERE cod_ingreso = p_cod_ingreso
    ON CONFLICT (cod_vino)
    DO UPDATE SET cantidad = stock_deposito.cantidad + EXCLUDED.cantidad;

    -- Transición terminado -> procesado, autorizada solo dentro del SP.
    PERFORM set_config('bodegas.via_procedimiento', 'on', true);
    UPDATE ingreso SET estado = 'procesado' WHERE cod_ingreso = p_cod_ingreso;
    PERFORM set_config('bodegas.via_procedimiento', 'off', true);
END;
$$;

COMMENT ON PROCEDURE sp_procesar_ingreso(INTEGER) IS
    'RN-10: acredita un ingreso terminado en stock_deposito y lo pasa a procesado (todo o nada).';

-- ---------------------------------------------------------------------
-- 2. sp_procesar_transferencia
-- Propósito: descuenta del depósito central y acredita en la sala las
--            botellas de una transferencia 'terminada'; la pasa a 'procesado'.
-- Parámetros: p_nro_solicitud (INTEGER).
-- Regla de negocio: RN-11 (y RN-09: el stock nunca es negativo).
--
-- Resuelve el caso del Anexo A.6: si un vino no tiene fila en
-- stock_deposito, un UPDATE ... FROM simplemente no lo descontaría y no
-- daría error. Por eso se valida vino por vino ANTES de mover stock.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_procesar_transferencia(p_nro_solicitud INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_estado         estado_documento;
    v_id_sala        INTEGER;
    v_cant_renglones INTEGER;
    r                RECORD;
    v_stock_actual   INTEGER;
BEGIN
    SELECT estado, id_sala INTO v_estado, v_id_sala
      FROM transferencia
     WHERE nro_solicitud = p_nro_solicitud
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la transferencia %. (RN-11)', p_nro_solicitud;
    END IF;

    IF v_estado IS DISTINCT FROM 'terminado' THEN
        RAISE EXCEPTION 'La transferencia % no está terminada (estado actual: %). (RN-11)',
            p_nro_solicitud, v_estado;
    END IF;

    SELECT COUNT(*) INTO v_cant_renglones
      FROM renglon_transferencia
     WHERE nro_solicitud = p_nro_solicitud;

    IF v_cant_renglones = 0 THEN
        RAISE EXCEPTION 'La transferencia % no tiene renglones. (RN-11)', p_nro_solicitud;
    END IF;

    -- Validación previa vino por vino. Se recorre ORDENADO por cod_vino:
    -- si dos transferencias concurrentes piden los mismos vinos, ambas
    -- bloquean las filas en el mismo orden y no se produce un deadlock.
    FOR r IN
        SELECT cod_vino, cantidad
          FROM renglon_transferencia
         WHERE nro_solicitud = p_nro_solicitud
         ORDER BY cod_vino
    LOOP
        SELECT cantidad INTO v_stock_actual
          FROM stock_deposito
         WHERE cod_vino = r.cod_vino
           FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'El vino % no tiene stock en el depósito central. (RN-11)', r.cod_vino;
        END IF;

        IF v_stock_actual < r.cantidad THEN
            RAISE EXCEPTION 'Stock insuficiente del vino % en el depósito central (disponible: %, solicitado: %). (RN-11)',
                r.cod_vino, v_stock_actual, r.cantidad;
        END IF;
    END LOOP;

    -- Descuenta del depósito (las filas ya están bloqueadas por este proceso).
    UPDATE stock_deposito sd
       SET cantidad = sd.cantidad - rt.cantidad
      FROM renglon_transferencia rt
     WHERE rt.nro_solicitud = p_nro_solicitud
       AND sd.cod_vino = rt.cod_vino;

    -- Acredita en la sala (crea la fila si no existía).
    INSERT INTO stock_sala (id_sala, cod_vino, cantidad)
    SELECT v_id_sala, rt.cod_vino, rt.cantidad
      FROM renglon_transferencia rt
     WHERE rt.nro_solicitud = p_nro_solicitud
    ON CONFLICT (id_sala, cod_vino)
    DO UPDATE SET cantidad = stock_sala.cantidad + EXCLUDED.cantidad;

    PERFORM set_config('bodegas.via_procedimiento', 'on', true);
    UPDATE transferencia SET estado = 'procesado' WHERE nro_solicitud = p_nro_solicitud;
    PERFORM set_config('bodegas.via_procedimiento', 'off', true);
END;
$$;

COMMENT ON PROCEDURE sp_procesar_transferencia(INTEGER) IS
    'RN-11: mueve stock del depósito a la sala para una transferencia terminada y la pasa a procesado (todo o nada).';
