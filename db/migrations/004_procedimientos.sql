
-----------------------------------------------
-- 1. sp_procesar_ingreso
-- proposito: procesa un ingreso en estado "terminado",acreditando las botellas en el stock del deposito central.
-- regla del nogocio: RN-10 (solo un ingreso terminado puede impactar y pasar a procesado)
---------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_procesar_ingreso(p_cod_ingreso INTEGER)
LANGUAGE plpgsql AS $$
DECLARE

    v_estado   estado_documento;
    v_cant_renglones INTEGER;
BEGIN 
    --LO que hace es bloquear la fila del ingreso para evitr concurrencias
    SELECT estado INTO v_estado
    FROM ingreso
    WHERE cod_ingreso = p_cod_ingreso
    FOR UPDATE;

    IF NOT FOUND THEN
    
        RAISE EXCEPTION 'No existe el ingreso con codigo %', p_cod_ingreso;
    END IF;

    IF v_estado IS DISTINCT FROM 'terminado' THEN
        RAISE EXCEPTION '"El ingreso con codigo % no esta en estado terminado" (ESTADO ACTUAL: %).(RN-10)', p_cod_ingreso, v_estado;
    END IF;
    -- Verifico que el ingreso tenga al menos un renglone
    SELECT COUNT(*) INTO v_cant_renglones
    FROM renglon_ingreso
    WHERE cod_ingreso = p_cod_ingreso;

    IF v_cant_renglones = 0 THEN
        RAISE EXCEPTION 'El ingreso con codigo % no tiene renglones asociados', p_cod_ingreso;
    END IF;

    -- impacto en stock del deposito central(creamos fila sino existia)
    INSERT INTO stock_deposito (cod_vino, cantidad)
    SELECT cod_vino, cantidad
    FROM renglon_ingreso
    WHERE cod_ingreso = p_cod_ingreso
    ON CONFLICT (cod_vino)
    DO UPDATE SET cantidad = stocj_deposito.cantidad + EXCLUDED.cantidad;

    -- transicion del estado al procesado
    UPDATE ingreso
    SET estado = 'procesado'
    WHERE cod_ingreso = p_cod_ingreso;
END;
$$;

------------------------------------------------
--- 2. sp_procesar_transferencia
--- proposito: descuenta sotck del sposito central y lo transfiere a la sala
--- regla del nogicio: RN-11 (solo transferencias terminasdas ;valida existencia y stock previo).
---------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_procesar_transferencia(p_nro_solicitud INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_estado     estado_documento;
    v_id_sala     INTEGER;
    v_cant_renglones INTEGER;
    r                RECORD;
    v_stock_actual INTEGER;
BEGIN

   --bloquea la fila de la trasferencia
   SELECT estado, id_sala INTO v_estado, v_id_sala
    FROM transferencia
    WHERE nro_solicitud = p_nro_solicitud
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la transferencia con nro de solicitud %', p_nro_solicitud;
    END IF;

    IF v_estado IS DISTINCT FROM 'terminado' THEN
        RAISE EXCEPTION 'La transferencia con nro de solicitud % no esta en estado terminado (ESTADO ACTUAL: %).(RN-11)', p_nro_solicitud, v_estado;
    END IF;
    --verifica la existencia de al menos un reglon
    SELECT COUNT(*) INTO v_cant_renglones
    FROM renglon_transferencia
    WHERE nro_solicitud = p_nro_solicitud;

    IF v_cant_renglones = 0 THEN
        RAISE EXCEPTION 'La transferencia con nro de solicitud % no tiene renglones asociados', p_nro_solicitud;
    END IF;

    --VALIDACION PREVENTIVA VINO POR VINO (RESULEVE LA ADVERTENCIA DEL ANEXO A.6 (CREO))
    FOR R IN (
        SELECT cod_vino, cantidad
        FROM renglon_transferencia
        WHERE nro_solicitud = p_nro_solicitud
        ORDER BY cod_vino
    ) LOOP
        --bloquea la fila en stock_deposito para evitar concurrencias
        SELECT cantidad INTO v_stock_actual
        FROM stock_deposito
        WHERE cod_vino = r.cod_vino
        FOR UPDATE;

        IF NOT FOUND THEN
        
            RAISE EXCEPTION 'No existe stock del vino con codigo % en el deposito central', r.cod_vino;
        END IF;

        if v_stock_actual < r.cantidad then
            raise exception 'stock insuficiente del vino con codigo % en el deposito central (STOCK ACTUAL: %, CANTIDAD SOLICITADA: %)', r.cod_vino, v_stock_actual, r.cantidad;
        end if;
    end loop;

    --decontar del deposito central 
    UPDATE stock_deposito sd
    SET cantidad = sd.cantidad - rt.cantidad
    FROM renglon_transferencia rt
    WHERE rt.nro_solicitud = p_nro_solicitud AND sd.cod_vino = rt.cod_vino;

    --sumar al stock a la sala de venta
    INSERT INTO stock_sala (id_sala, cod_vino, cantidad)
    SELECT v_id_sala, rt.cod_vino, rt.cantidad
    FROM renglon_transferencia rt
    WHERE rt.nro_solicitud = p_nro_solicitud    
    ON CONFLICT (id_sala, cod_vino)
    DO UPDATE SET cantidad = stock_sala.cantidad + EXCLUDED.cantidad;

    --transicion del estado al procesado
    UPDATE transferencia
    SET estado = 'procesado'
    WHERE nro_solicitud = p_nro_solicitud;  
END;
$$;


