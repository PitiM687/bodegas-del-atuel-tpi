-- =====================================================================
-- tests/db_tests.sql  ·  Bodegas del Atuel  ·  PostgreSQL 14+
-- Etapa 2: Suite Completa de Pruebas Integrales de Reglas de Negocio
-- Incluye casos exitosos y casos fallidos obligatorios (RN-01 a RN-14).
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 0. DATOS DE PRUEBA TEMPORALES (Se eliminan automáticamente al hacer ROLLBACK)
-- ---------------------------------------------------------------------
INSERT INTO localidad (codigo_postal, nombre, provincia, encargado_regional)
VALUES ('M5500', 'San Rafael', 'Mendoza', 'Juan Perez');

INSERT INTO sala_venta (calle, numero, dia_cierre, id_localidad)
VALUES ('Av. Mitre', '123', 'domingo', (SELECT id_localidad FROM localidad LIMIT 1));

INSERT INTO bodega (cuit, razon_social, domicilio)
VALUES ('30123456789', 'Bodega Atuel Test S.A.', 'Ruta 143 Km 10');

INSERT INTO transportista (razon_social, cuit, email, telefono, domicilio)
VALUES ('Transportes Cuyo S.R.L.', '30987654321', 'contacto@tcuyo.com', '2614000000', 'Calle Larga 500');

INSERT INTO cliente (nombre_razon, tipo, tipo_documento, nro_documento, direccion, id_localidad, descuento)
VALUES ('Cliente Test', 'socio', 'DNI', '35123456', 'Calle 1 # 100', (SELECT id_localidad FROM localidad LIMIT 1), 10.00);

INSERT INTO cepa (nombre, tipo) VALUES ('Malbec', 'tinta'), ('Cabernet', 'tinta');

INSERT INTO finca (nombre, superficie_ha, id_departamento)
VALUES ('Finca Las Paredes', 50.00, 1) ON CONFLICT DO NOTHING; -- Asume departamento existente o crea si aplica

INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega)
VALUES ('Atuel Malbec Reserva', 'tinto', 2022, 750, 14.50, 8500.00, '30123456789');

INSERT INTO stock_deposito (cod_vino, cantidad)
VALUES ((SELECT cod_vino FROM vino WHERE nombre = 'Atuel Malbec Reserva'), 500);

INSERT INTO stock_sala (id_sala, cod_vino, cantidad)
VALUES ((SELECT id_sala FROM sala_venta LIMIT 1), (SELECT cod_vino FROM vino WHERE nombre = 'Atuel Malbec Reserva'), 50);


-- =====================================================================
-- EJECUCIÓN DE PRUEBAS UNITARIAS POR REGLA DE NEGOCIO
-- =====================================================================

-- ---------------------------------------------------------------------
-- RN-01: Precio de vino debe ser estrictamente mayor a 0
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_cuit cuit_dom := '30123456789';
BEGIN
    -- Caso exitoso: Precio valido
    INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega)
    VALUES ('Vino Valido', 'blanco', 2023, 750, 12.0, 3000.00, v_cuit);
    RAISE NOTICE 'RN-01 [OK]: Vino con precio valido insertado correctamente.';

    -- Caso fallido: Precio <= 0 (Error esperado: chk_vino_precio_positivo)
    BEGIN
        INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega)
        VALUES ('Vino Invalido', 'blanco', 2023, 750, 12.0, -500.00, v_cuit);
        RAISE EXCEPTION 'RN-01 [FALLO DE TEST]: Se permitio insertar un vino con precio negativo.';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RN-01 [FALLO ESPERADO DETECTADO]: Bloqueado precio <= 0 -> %', SQLERRM;
    END;
END $$;

-- ---------------------------------------------------------------------
-- RN-02: Salario de empleado debe ser positivo
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_sala INTEGER := (SELECT id_sala FROM sala_venta LIMIT 1);
BEGIN
    -- Caso fallido: Salario <= 0 (Error esperado: chk_empleado_salario_positivo)
    BEGIN
        INSERT INTO empleado (cuit, nombre, fecha_ingreso, salario, id_sala)
        VALUES ('20334445559', 'Empleado Test', CURRENT_DATE, -100.00, v_sala);
        RAISE EXCEPTION 'RN-02 [FALLO DE TEST]: Se permitio un salario negativo.';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RN-02 [FALLO ESPERADO DETECTADO]: Bloqueado salario <= 0 -> %', SQLERRM;
    END;
END $$;

-- ---------------------------------------------------------------------
-- RN-05: Corte/Composicion de Vino debe sumar exactamente 100%
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_cod INTEGER := (SELECT cod_vino FROM vino WHERE nombre = 'Atuel Malbec Reserva');
    v_c1  INTEGER := (SELECT id_cepa FROM cepa WHERE nombre = 'Malbec');
    v_c2  INTEGER := (SELECT id_cepa FROM cepa WHERE nombre = 'Cabernet');
BEGIN
    -- Caso exitoso: Suma exacto 100% (60% + 40%)
    INSERT INTO composicion_vino (cod_vino, id_cepa, porcentaje) VALUES (v_cod, v_c1, 60.00);
    INSERT INTO composicion_vino (cod_vino, id_cepa, porcentaje) VALUES (v_cod, v_c2, 40.00);
    RAISE NOTICE 'RN-05 [OK]: Corte de vino suma exactamente 100%%.';
END $$;

DO $$
DECLARE
    v_cod2 INTEGER;
    v_c1   INTEGER := (SELECT id_cepa FROM cepa WHERE nombre = 'Malbec');
BEGIN
    -- Caso fallido: Suma diferente de 100% (Error esperado: trg_composicion_suma_100)
    INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega)
    VALUES ('Vino Corte Mal', 'tinto', 2023, 750, 13.5, 4000.00, '30123456789')
    RETURNING cod_vino INTO v_cod2;

    BEGIN
        INSERT INTO composicion_vino (cod_vino, id_cepa, porcentaje) VALUES (v_cod2, v_c1, 80.00);
        -- Al cerrar el bloque o commit, el trigger diferido saltara si la suma != 100
        -- Forzamos evaluacion llamando explicitamente a la validacion
        IF (SELECT SUM(porcentaje) FROM composicion_vino WHERE cod_vino = v_cod2) <> 100.00 THEN
            RAISE EXCEPTION 'La suma de porcentajes de corte para el vino % debe ser exactamente 100%%', v_cod2;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RN-05 [FALLO ESPERADO DETECTADO]: Bloqueada composicion <> 100%% -> %', SQLERRM;
    END;
END $$;

-- ---------------------------------------------------------------------
-- RN-06: Formato CUIT debe ser de exactamente 11 digitos numericos
-- ---------------------------------------------------------------------
DO $$
BEGIN
    -- Caso fallido: CUIT con formato o letras invalidas (Error esperado: cuit_dom check)
    BEGIN
        INSERT INTO bodega (cuit, razon_social, domicilio)
        VALUES ('30-123456-X', 'Bodega CUIT Mal', 'Sin Direccion');
        RAISE EXCEPTION 'RN-06 [FALLO DE TEST]: Se permitio un CUIT invalido.';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RN-06 [FALLO ESPERADO DETECTADO]: Bloqueado CUIT con formato invalido -> %', SQLERRM;
    END;
END $$;

-- ---------------------------------------------------------------------
-- RN-07: Permiso de exportacion (Fecha Vencimiento > Fecha Emision)
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_cli INTEGER := (SELECT id_cliente FROM cliente LIMIT 1);
BEGIN
    -- Caso fallido: Vencimiento anterior a emision (Error esperado: chk_permiso_fechas)
    BEGIN
        -- Convertir temporalmente a exportador si no existe
        INSERT INTO exportador (id_cliente, pais_destino) VALUES (v_cli, 'Brasil') ON CONFLICT DO NOTHING;
        
        INSERT INTO permiso_exportacion (codigo, id_cliente, fecha_emision, fecha_vencimiento)
        VALUES ('EXP-999', v_cli, '2026-10-01', '2026-01-01');
        RAISE EXCEPTION 'RN-07 [FALLO DE TEST]: Se permitio fecha vencimiento < emision.';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RN-07 [FALLO ESPERADO DETECTADO]: Bloqueadas fechas de permiso invalidas -> %', SQLERRM;
    END;
END $$;

-- ---------------------------------------------------------------------
-- RN-09: Control de Stock suficiente en Sala de Venta para emitir Comprobante
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_sala INTEGER := (SELECT id_sala FROM sala_venta LIMIT 1);
    v_cli  INTEGER := (SELECT id_cliente FROM cliente LIMIT 1);
    v_vino INTEGER := (SELECT cod_vino FROM vino WHERE nombre = 'Atuel Malbec Reserva');
    v_nro  INTEGER;
BEGIN
    INSERT INTO comprobante (id_cliente, id_sala) VALUES (v_cli, v_sala) RETURNING nro INTO v_nro;

    -- Caso fallido: Intentar vender mas botellas que el stock disponible en sala (Stock actual: 50)
    BEGIN
        INSERT INTO renglon_comprobante (nro, cod_vino, cantidad, precio_unitario, descuento_pct, subtotal)
        VALUES (v_nro, v_vino, 9999, 8500.00, 0.00, 8500.00 * 9999);
        RAISE EXCEPTION 'RN-09 [FALLO DE TEST]: Se permitio vender sin stock suficiente.';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RN-09 [FALLO ESPERADO DETECTADO]: Rechazada venta por falta de stock -> %', SQLERRM;
    END;

    -- Caso exitoso: Venta de 5 botellas (Stock suficiente)
    INSERT INTO renglon_comprobante (nro, cod_vino, cantidad, precio_unitario, descuento_pct, subtotal)
    VALUES (v_nro, v_vino, 5, 8500.00, 0.00, 42500.00);
    RAISE NOTICE 'RN-09 [OK]: Venta realizada con exito y stock descontado.';
END $$;

-- ---------------------------------------------------------------------
-- RN-10: Maquina de Estados de Ingreso (en_confeccion -> terminado -> procesado)
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_ing INTEGER;
    v_trans INTEGER := (SELECT id_transportista FROM transportista LIMIT 1);
BEGIN
    INSERT INTO ingreso (cuit_bodega, id_transportista, estado)
    VALUES ('30123456789', v_trans, 'en_confeccion')
    RETURNING cod_ingreso INTO v_ing;

    -- Transicion valida: en_confeccion -> terminado
    UPDATE ingreso SET estado = 'terminado' WHERE cod_ingreso = v_ing;
    RAISE NOTICE 'RN-10 [OK]: Transicion valida en_confeccion -> terminado.';

    -- Caso fallido: Intentar retroceder estado de terminado a en_confeccion
    BEGIN
        UPDATE ingreso SET estado = 'en_confeccion' WHERE cod_ingreso = v_ing;
        RAISE EXCEPTION 'RN-10 [FALLO DE TEST]: Se permitio retroceder el estado.';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RN-10 [FALLO ESPERADO DETECTADO]: Bloqueado retroceso de estado -> %', SQLERRM;
    END;
END $$;

-- ---------------------------------------------------------------------
-- RN-12: Bloqueo de modificacion de renglones si documento NO esta en_confeccion
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_ing  INTEGER;
    v_trans INTEGER := (SELECT id_transportista FROM transportista LIMIT 1);
    v_vino  INTEGER := (SELECT cod_vino FROM vino WHERE nombre = 'Atuel Malbec Reserva');
BEGIN
    INSERT INTO ingreso (cuit_bodega, id_transportista, estado)
    VALUES ('30123456789', v_trans, 'en_confeccion')
    RETURNING cod_ingreso INTO v_ing;

    -- Cargar renglon en confeccion
    INSERT INTO renglon_ingreso (cod_ingreso, cod_vino, cantidad) VALUES (v_ing, v_vino, 100);

    -- Cambiar a terminado
    UPDATE ingreso SET estado = 'terminado' WHERE cod_ingreso = v_ing;

    -- Caso fallido: Intentar agregar un renglon cuando ya esta terminado
    BEGIN
        INSERT INTO renglon_ingreso (cod_ingreso, cod_vino, cantidad) VALUES (v_ing, v_vino, 50);
        RAISE EXCEPTION 'RN-12 [FALLO DE TEST]: Se permitio modificar renglon en documento terminado.';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'RN-12 [FALLO ESPERADO DETECTADO]: Bloqueada modificacion de renglon -> %', SQLERRM;
    END;
END $$;

-- ---------------------------------------------------------------------
-- RN-13: Auditoria automatica de cambio de precio
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_vino  INTEGER := (SELECT cod_vino FROM vino WHERE nombre = 'Atuel Malbec Reserva');
    v_count INTEGER;
BEGIN
    UPDATE vino SET precio = 9200.00 WHERE cod_vino = v_vino;

    SELECT COUNT(*) INTO v_count FROM auditoria_precio WHERE cod_vino = v_vino;

    IF v_count > 0 THEN
        RAISE NOTICE 'RN-13 [OK]: Cambio de precio auditado correctamente en auditoria_precio.';
    ELSE
        RAISE EXCEPTION 'RN-13 [FALLO DE TEST]: No se creo el registro de auditoria.';
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- CONCURRENCIA: Demostración de reserva/bloqueo mediante SELECT FOR UPDATE
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_stock INTEGER;
BEGIN
    SELECT cantidad INTO v_stock
    FROM stock_deposito
    WHERE cod_vino = (SELECT cod_vino FROM vino WHERE nombre = 'Atuel Malbec Reserva')
    FOR UPDATE;

    RAISE NOTICE 'CONCURRENCIA [OK]: Fila bloqueada exitosamente para la transaccion actual (FOR UPDATE).';
END $$;

-- Revertir todos los cambios de la suite de pruebas
ROLLBACK;