-- =====================================================================
-- tests/db_tests.sql  ·  Bodegas del Atuel  ·  PostgreSQL 14+
-- Etapa 2: pruebas de las reglas de negocio RN-01 a RN-15.
--
-- Cómo se ejecuta (como superusuario o como propietario):
--   psql -d bodegas_atuel -f tests/db_tests.sql
--
-- Características
--   * Todo corre dentro de UNA transacción que termina en ROLLBACK: la base
--     queda exactamente como estaba (solo avanzan las secuencias).
--   * Funciona con la base vacía o con la base cargada: crea sus propios
--     datos con nombres 'TEST ...' y CUIT 33999999xxx, y nunca usa IDs fijos
--     (los guarda en la tabla temporal ctx y los lee con pg_temp.id()).
--   * Cada caso que DEBE FALLAR indica el SQLSTATE esperado:
--        23502 not_null_violation      23503 foreign_key_violation
--        23505 unique_violation        23514 check_violation (CHECK y DOMAIN)
--        P0001 raise_exception (trigger/procedimiento)   42501 sin privilegio
--        23001 restrict_violation (ON DELETE RESTRICT desde PostgreSQL 18;
--              las versiones 14 a 17 informan 23503)
--     Si un caso admite más de un SQLSTATE se escriben separados por '|'.
--     El caso pasa solo si se produce ESE error. Si la sentencia no falla,
--     se fuerza un error 'ZZ001' que revierte lo que haya hecho y el caso
--     se registra como FALLO. (La versión anterior capturaba con
--     WHEN OTHERS su propio aviso de fallo y nunca podía fallar.)
--   * Los casos que DEBEN FUNCIONAR se registran como FALLO si lanzan error.
--   * Al final se muestra el detalle, un resumen por regla y, si hubo algún
--     FALLO, el script termina con error (código de salida distinto de 0).
-- =====================================================================
\set ON_ERROR_STOP on
\set QUIET on
\pset footer off
SET client_min_messages = warning;

BEGIN;

-- ---------------------------------------------------------------------
-- 0. Infraestructura de pruebas (objetos temporales, desaparecen solos)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE resultado (
    n         SERIAL,
    regla     TEXT,
    caso      TEXT,
    esperado  TEXT,
    ok        BOOLEAN,          -- NULL = omitido
    detalle   TEXT
) ON COMMIT DROP;

CREATE TEMP TABLE ctx (clave TEXT PRIMARY KEY, valor BIGINT) ON COMMIT DROP;

-- Auxiliares: debe_fallar / debe_funcionar son procedimientos (CALL).

-- Lee un ID guardado durante la preparación.
CREATE FUNCTION pg_temp.id(p_clave TEXT) RETURNS BIGINT
LANGUAGE sql STABLE AS $$ SELECT valor FROM ctx WHERE clave = p_clave $$;

-- Ejecuta una o más sentencias que DEBEN fallar con p_sqlstate.
CREATE PROCEDURE pg_temp.debe_fallar(p_regla TEXT, p_caso TEXT, p_sqlstate TEXT, VARIADIC p_sql TEXT[])
LANGUAGE plpgsql AS $$
DECLARE
    s       TEXT;
    v_state TEXT;
    v_msg   TEXT;
BEGIN
    BEGIN
        FOREACH s IN ARRAY p_sql LOOP
            EXECUTE s;
        END LOOP;
        -- No falló: se fuerza un error para revertir sus efectos.
        RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'la sentencia NO falló';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;
    SET CONSTRAINTS ALL DEFERRED;   -- por si el caso las puso IMMEDIATE
    INSERT INTO resultado (regla, caso, esperado, ok, detalle)
    VALUES (p_regla, p_caso, 'falla ' || p_sqlstate,
            v_state = ANY (string_to_array(p_sqlstate, '|')), v_state || ': ' || v_msg);
END;
$$;

-- Ejecuta una o más sentencias que DEBEN funcionar (sus efectos quedan).
CREATE PROCEDURE pg_temp.debe_funcionar(p_regla TEXT, p_caso TEXT, VARIADIC p_sql TEXT[])
LANGUAGE plpgsql AS $$
DECLARE
    s       TEXT;
    v_state TEXT;
    v_msg   TEXT;
BEGIN
    BEGIN
        FOREACH s IN ARRAY p_sql LOOP
            EXECUTE s;
        END LOOP;
        INSERT INTO resultado (regla, caso, esperado, ok, detalle)
        VALUES (p_regla, p_caso, 'funciona', TRUE, 'ok');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        INSERT INTO resultado (regla, caso, esperado, ok, detalle)
        VALUES (p_regla, p_caso, 'funciona', FALSE, v_state || ': ' || v_msg);
    END;
    SET CONSTRAINTS ALL DEFERRED;
END;
$$;

-- Verifica una condición sobre el estado de la base. Es función (no
-- procedimiento) porque CALL no admite subconsultas en los argumentos; se
-- invoca con SELECT ... \gset para que no imprima nada.
CREATE FUNCTION pg_temp.verificar(p_regla TEXT, p_caso TEXT, p_condicion BOOLEAN, p_detalle TEXT DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO resultado (regla, caso, esperado, ok, detalle)
    VALUES (p_regla, p_caso, 'verifica', COALESCE(p_condicion, FALSE), COALESCE(p_detalle, ''));
$$;

-- ---------------------------------------------------------------------
-- 1. Datos de prueba (válidos: cumplen todas las reglas)
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v BIGINT;
BEGIN
    INSERT INTO departamento (nombre, provincia) VALUES ('TEST Depto', 'TEST Provincia') RETURNING id_departamento INTO v;
    INSERT INTO ctx VALUES ('depto', v);

    INSERT INTO localidad (codigo_postal, nombre, provincia, encargado_regional)
    VALUES ('T0000', 'TEST Localidad', 'TEST Provincia', 'TEST Encargado') RETURNING id_localidad INTO v;
    INSERT INTO ctx VALUES ('localidad', v);

    INSERT INTO sala_venta (calle, numero, dia_cierre, id_localidad)
    VALUES ('TEST Calle', '1', 'lunes', pg_temp.id('localidad')) RETURNING id_sala INTO v;
    INSERT INTO ctx VALUES ('sala', v);

    INSERT INTO bodega (cuit, razon_social, domicilio) VALUES ('33999999001', 'TEST Bodega', 'TEST Domicilio');
    INSERT INTO bodega (cuit, razon_social, domicilio) VALUES ('33999999002', 'TEST Bodega sin vinos', 'TEST Domicilio');

    INSERT INTO transportista (razon_social, cuit, email, telefono, domicilio)
    VALUES ('TEST Transportes', '33999999101', 'test@test.com', '0', 'TEST') RETURNING id_transportista INTO v;
    INSERT INTO ctx VALUES ('transportista', v);

    INSERT INTO cepa (nombre, tipo) VALUES ('TEST Cepa tinta', 'tinta') RETURNING id_cepa INTO v;
    INSERT INTO ctx VALUES ('cepa1', v);
    INSERT INTO cepa (nombre, tipo) VALUES ('TEST Cepa tinta 2', 'tinta') RETURNING id_cepa INTO v;
    INSERT INTO ctx VALUES ('cepa2', v);

    INSERT INTO finca (nombre, superficie_ha, id_departamento)
    VALUES ('TEST Finca', 50, pg_temp.id('depto')) RETURNING id_finca INTO v;
    INSERT INTO ctx VALUES ('finca', v);
    INSERT INTO parcela (id_finca, nro_parcela, superficie_ha, anio_plantacion, id_cepa)
    VALUES (pg_temp.id('finca'), 1, 5, 2010, pg_temp.id('cepa1'));

    -- Vino de prueba "Malbec Reserva" (85/15, como el ejemplo del enunciado)
    INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega)
    VALUES ('TEST Malbec Reserva', 'tinto', 2021, 750, 14.00, 12500.00, '33999999001') RETURNING cod_vino INTO v;
    INSERT INTO ctx VALUES ('vino', v);
    INSERT INTO composicion_vino VALUES (v, pg_temp.id('cepa1'), 85), (v, pg_temp.id('cepa2'), 15);

    -- Clientes, uno de cada tipo (el descuento lo completa la base)
    INSERT INTO cliente (nombre_razon, tipo, tipo_documento, nro_documento, direccion, id_localidad)
    VALUES ('TEST Socio', 'socio', 'DNI', 'TEST-1', 'TEST', pg_temp.id('localidad')) RETURNING id_cliente INTO v;
    INSERT INTO socio VALUES (v);
    INSERT INTO ctx VALUES ('socio', v);

    INSERT INTO cliente (nombre_razon, tipo, tipo_documento, nro_documento, direccion, id_localidad)
    VALUES ('TEST Distribuidor', 'distribuidor', 'CUIT', 'TEST-2', 'TEST', pg_temp.id('localidad')) RETURNING id_cliente INTO v;
    INSERT INTO distribuidor VALUES (v, 'TEST Zona', 'TEST-HAB');
    INSERT INTO ctx VALUES ('distribuidor', v);

    INSERT INTO cliente (nombre_razon, tipo, tipo_documento, nro_documento, direccion, id_localidad)
    VALUES ('TEST Exportador', 'exportador', 'CUIT', 'TEST-3', 'TEST', pg_temp.id('localidad')) RETURNING id_cliente INTO v;
    INSERT INTO exportador VALUES (v, 'TEST País');
    INSERT INTO ctx VALUES ('exportador', v);

    -- Stock inicial
    INSERT INTO stock_sala (id_sala, cod_vino, cantidad) VALUES (pg_temp.id('sala'), pg_temp.id('vino'), 10);
    INSERT INTO stock_deposito (cod_vino, cantidad) VALUES (pg_temp.id('vino'), 100);
END $$;

-- =====================================================================
-- 2. CASOS DE PRUEBA
-- =====================================================================

-- ---------------------------------------------------------------------
-- RN-01  Precio único para toda la red y mayor que cero.
-- Mecanismo: columna vino.precio (no hay precio por sala) + CHECK ck_vino_precio.
-- ---------------------------------------------------------------------
SELECT pg_temp.verificar('RN-01', 'El precio vive solo en vino (ninguna otra tabla tiene precio de lista)',
    NOT EXISTS (SELECT 1 FROM information_schema.columns c
                  JOIN information_schema.tables t USING (table_schema, table_name)
                 WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
                   AND c.column_name = 'precio' AND c.table_name <> 'vino')) \gset
CALL pg_temp.debe_fallar('RN-01', 'Precio 0', '23514',
    $q$UPDATE vino SET precio = 0 WHERE cod_vino = pg_temp.id('vino')$q$);
CALL pg_temp.debe_fallar('RN-01', 'Precio negativo', '23514',
    $q$UPDATE vino SET precio = -500 WHERE cod_vino = pg_temp.id('vino')$q$);

-- ---------------------------------------------------------------------
-- RN-02  Una sala pertenece a una sola localidad; cada localidad tiene un
--        único encargado regional.
-- Mecanismo: FK NOT NULL sala_venta.id_localidad; encargado_regional NOT NULL
--            en localidad (3FN: no se repite en cada sala).
-- ---------------------------------------------------------------------
CALL pg_temp.debe_fallar('RN-02', 'Sala sin localidad', '23502',
    $q$INSERT INTO sala_venta (calle, numero, dia_cierre, id_localidad) VALUES ('TEST', '2', 'martes', NULL)$q$);
CALL pg_temp.debe_fallar('RN-02', 'Sala con localidad inexistente', '23503',
    $q$INSERT INTO sala_venta (calle, numero, dia_cierre, id_localidad) VALUES ('TEST', '2', 'martes', -1)$q$);
CALL pg_temp.debe_fallar('RN-02', 'Localidad sin encargado regional', '23502',
    $q$INSERT INTO localidad (codigo_postal, nombre, provincia, encargado_regional) VALUES ('T1', 'TEST Loc 2', 'TEST Provincia', NULL)$q$);
SELECT pg_temp.verificar('RN-02', 'El encargado no está en sala_venta (depende solo de la localidad)',
    NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'sala_venta' AND column_name LIKE '%encargado%')) \gset

-- ---------------------------------------------------------------------
-- RN-03  Cada empleado trabaja en una sola sala.
-- Mecanismo: FK NOT NULL empleado.id_sala; PK por CUIT (no puede repetirse en otra sala).
-- ---------------------------------------------------------------------
CALL pg_temp.debe_funcionar('RN-03', 'Alta de empleado en una sala',
    $q$INSERT INTO empleado VALUES ('33999999201', 'TEST Empleado', '2020-01-01', 500000, pg_temp.id('sala'))$q$);
CALL pg_temp.debe_fallar('RN-03', 'Empleado sin sala', '23502',
    $q$INSERT INTO empleado VALUES ('33999999202', 'TEST Empleado 2', '2020-01-01', 500000, NULL)$q$);
CALL pg_temp.debe_fallar('RN-03', 'El mismo empleado en una segunda sala', '23505',
    $q$INSERT INTO empleado VALUES ('33999999201', 'TEST Empleado', '2020-01-01', 500000, pg_temp.id('sala'))$q$);

-- ---------------------------------------------------------------------
-- RN-04  Una parcela tiene una sola cepa y se cosecha como máximo una vez
--        por campaña.
-- Mecanismo: FK NOT NULL parcela.id_cepa + UNIQUE uq_lote_parcela_campania.
-- ---------------------------------------------------------------------
CALL pg_temp.debe_fallar('RN-04', 'Parcela sin cepa', '23502',
    $q$INSERT INTO parcela VALUES (pg_temp.id('finca'), 2, 3, 2015, NULL)$q$);
CALL pg_temp.debe_funcionar('RN-04', 'Primera cosecha de la parcela en la campaña 2024',
    $q$INSERT INTO lote_uva (id_finca, nro_parcela, campania, fecha_cosecha, kg_cosechados, cuit_bodega)
       VALUES (pg_temp.id('finca'), 1, 2024, '2024-03-10', 8000, '33999999001')$q$);
CALL pg_temp.debe_fallar('RN-04', 'Segunda cosecha de la misma parcela en la misma campaña', '23505',
    $q$INSERT INTO lote_uva (id_finca, nro_parcela, campania, fecha_cosecha, kg_cosechados, cuit_bodega)
       VALUES (pg_temp.id('finca'), 1, 2024, '2024-04-01', 1000, '33999999001')$q$);
CALL pg_temp.debe_funcionar('RN-04', 'La misma parcela en otra campaña',
    $q$INSERT INTO lote_uva (id_finca, nro_parcela, campania, fecha_cosecha, kg_cosechados, cuit_bodega)
       VALUES (pg_temp.id('finca'), 1, 2025, '2025-03-10', 7500, '33999999001')$q$);

-- ---------------------------------------------------------------------
-- RN-05  Los porcentajes de corte de un vino suman exactamente 100.
-- Mecanismo: constraint triggers diferidos trg_composicion_suma_100 y
--            trg_vino_requiere_composicion. Se validan al COMMIT; acá se
--            fuerza la validación con SET CONSTRAINTS ... IMMEDIATE.
-- ---------------------------------------------------------------------
CALL pg_temp.debe_funcionar('RN-05', 'Corte 85 % + 15 % = 100 (vino de prueba)',
    'SET CONSTRAINTS trg_composicion_suma_100, trg_vino_requiere_composicion IMMEDIATE');
CALL pg_temp.debe_fallar('RN-05', 'Corte que suma 80', 'P0001',
    $q$INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega)
       VALUES ('TEST Corte 80', 'tinto', 2023, 750, 13.5, 4000, '33999999001')$q$,
    $q$INSERT INTO composicion_vino SELECT cod_vino, pg_temp.id('cepa1'), 80 FROM vino WHERE nombre = 'TEST Corte 80'$q$,
    'SET CONSTRAINTS trg_composicion_suma_100, trg_vino_requiere_composicion IMMEDIATE');
CALL pg_temp.debe_fallar('RN-05', 'Vino sin composición', 'P0001',
    $q$INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega)
       VALUES ('TEST Sin corte', 'tinto', 2023, 750, 13.5, 4000, '33999999001')$q$,
    'SET CONSTRAINTS trg_vino_requiere_composicion IMMEDIATE');
CALL pg_temp.debe_fallar('RN-05', 'Quitar una cepa de un corte existente', 'P0001',
    $q$DELETE FROM composicion_vino WHERE cod_vino = pg_temp.id('vino') AND id_cepa = pg_temp.id('cepa2')$q$,
    'SET CONSTRAINTS trg_composicion_suma_100 IMMEDIATE');
CALL pg_temp.debe_fallar('RN-05', 'Porcentaje individual mayor que 100', '23514',
    $q$UPDATE composicion_vino SET porcentaje = 120 WHERE cod_vino = pg_temp.id('vino') AND id_cepa = pg_temp.id('cepa1')$q$);
CALL pg_temp.debe_funcionar('RN-05', 'Borrar un vino sin movimientos (su composición se va en cascada)',
    $q$INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega)
       VALUES ('TEST Borrable', 'blanco', 2023, 750, 12, 3000, '33999999001')$q$,
    $q$INSERT INTO composicion_vino SELECT cod_vino, pg_temp.id('cepa1'), 100 FROM vino WHERE nombre = 'TEST Borrable'$q$,
    $q$DELETE FROM vino WHERE nombre = 'TEST Borrable'$q$,
    'SET CONSTRAINTS trg_composicion_suma_100, trg_vino_requiere_composicion IMMEDIATE');

-- ---------------------------------------------------------------------
-- RN-06  El descuento depende del tipo de cliente: socio 10 %, distribuidor
--        20 %, exportador 30 %.
-- Mecanismo: fn_descuento_cliente + trigger trg_descuento_cliente + CHECK
--            ck_cliente_descuento (rango). Jerarquía: trg_subtipo_* y
--            trg_cliente_requiere_subtipo (diferido).
-- ---------------------------------------------------------------------
SELECT pg_temp.verificar('RN-06', 'Socio recibe 10 % automáticamente',
    (SELECT descuento = 10 FROM cliente WHERE id_cliente = pg_temp.id('socio'))) \gset
SELECT pg_temp.verificar('RN-06', 'Distribuidor recibe 20 % automáticamente',
    (SELECT descuento = 20 FROM cliente WHERE id_cliente = pg_temp.id('distribuidor'))) \gset
SELECT pg_temp.verificar('RN-06', 'Exportador recibe 30 % automáticamente',
    (SELECT descuento = 30 FROM cliente WHERE id_cliente = pg_temp.id('exportador'))) \gset
CALL pg_temp.debe_fallar('RN-06', 'Descuento fuera de rango (150 %)', '23514',
    $q$UPDATE cliente SET descuento = 150 WHERE id_cliente = pg_temp.id('socio')$q$);
CALL pg_temp.debe_fallar('RN-06', 'Cambiar el tipo de un cliente', 'P0001',
    $q$UPDATE cliente SET tipo = 'exportador' WHERE id_cliente = pg_temp.id('socio')$q$);
CALL pg_temp.debe_fallar('RN-06', 'Registrar a un socio en la tabla exportador (jerarquía disjunta)', 'P0001',
    $q$INSERT INTO exportador VALUES (pg_temp.id('socio'), 'TEST')$q$);
CALL pg_temp.debe_fallar('RN-06', 'Cliente sin fila en su subtabla (jerarquía total)', 'P0001',
    $q$INSERT INTO cliente (nombre_razon, tipo, tipo_documento, nro_documento, direccion, id_localidad)
       VALUES ('TEST Huérfano', 'distribuidor', 'DNI', 'TEST-9', 'TEST', pg_temp.id('localidad'))$q$,
    'SET CONSTRAINTS trg_cliente_requiere_subtipo IMMEDIATE');

-- ---------------------------------------------------------------------
-- RN-07  Un exportador puede tener varios permisos; el vencimiento es
--        posterior a la emisión.
-- Mecanismo: tabla permiso_exportacion (FK a exportador) + CHECK entre
--            columnas ck_permiso_fechas.
-- ---------------------------------------------------------------------
CALL pg_temp.debe_funcionar('RN-07', 'Exportador con dos permisos válidos',
    $q$INSERT INTO permiso_exportacion (codigo, id_cliente, fecha_emision, fecha_vencimiento)
       VALUES ('TEST-P1', pg_temp.id('exportador'), '2025-01-01', '2026-01-01'),
              ('TEST-P2', pg_temp.id('exportador'), '2025-06-01', '2027-06-01')$q$);
CALL pg_temp.debe_fallar('RN-07', 'Vencimiento anterior a la emisión', '23514',
    $q$INSERT INTO permiso_exportacion (codigo, id_cliente, fecha_emision, fecha_vencimiento)
       VALUES ('TEST-P3', pg_temp.id('exportador'), '2026-10-01', '2026-01-01')$q$);
CALL pg_temp.debe_fallar('RN-07', 'Vencimiento igual a la emisión', '23514',
    $q$INSERT INTO permiso_exportacion (codigo, id_cliente, fecha_emision, fecha_vencimiento)
       VALUES ('TEST-P4', pg_temp.id('exportador'), '2026-01-01', '2026-01-01')$q$);
CALL pg_temp.debe_fallar('RN-07', 'Permiso para un cliente que no es exportador', '23503',
    $q$INSERT INTO permiso_exportacion (codigo, id_cliente, fecha_emision, fecha_vencimiento)
       VALUES ('TEST-P5', pg_temp.id('socio'), '2025-01-01', '2026-01-01')$q$);

-- ---------------------------------------------------------------------
-- RN-08  El total del comprobante es la suma de sus renglones con el
--        descuento aplicado. No se carga a mano.
-- Mecanismo: fn_subtotal_renglon, fn_total_comprobante,
--            trg_completar_renglon_venta, trg_actualizar_stock_y_totales,
--            trg_proteger_renglon_venta, trg_proteger_importes,
--            CHECK ck_comprobante_total.
-- Venta: distribuidor (20 %) compra 2 botellas de $12.500 intentando
-- imponer precio $1 y descuento 0 → la base usa $12.500 y 20 %.
-- ---------------------------------------------------------------------
DO $$
DECLARE v BIGINT;
BEGIN
    INSERT INTO comprobante (id_cliente, id_sala) VALUES (pg_temp.id('distribuidor'), pg_temp.id('sala'))
    RETURNING nro INTO v;
    INSERT INTO ctx VALUES ('comprobante', v);
END $$;

CALL pg_temp.debe_funcionar('RN-08', 'Venta de 2 botellas enviando precio $1 y descuento 0',
    $q$INSERT INTO renglon_comprobante (nro, cod_vino, cantidad, precio_unitario, descuento_pct, subtotal)
       VALUES (pg_temp.id('comprobante'), pg_temp.id('vino'), 2, 1, 0, 1)$q$);
SELECT pg_temp.verificar('RN-08', 'El renglón usa el precio del vino y el descuento del cliente (12500 / 20 % / 20000)',
    (SELECT precio_unitario = 12500 AND descuento_pct = 20 AND subtotal = 20000
       FROM renglon_comprobante WHERE nro = pg_temp.id('comprobante')),
    (SELECT format('precio %s, desc %s, subtotal %s', precio_unitario, descuento_pct, subtotal)
       FROM renglon_comprobante WHERE nro = pg_temp.id('comprobante'))) \gset
SELECT pg_temp.verificar('RN-08', 'Cabecera recalculada: subtotal 25000, descuento 5000, total 20000',
    (SELECT subtotal = 25000 AND descuento = 5000 AND total = 20000
       FROM comprobante WHERE nro = pg_temp.id('comprobante')),
    (SELECT format('subtotal %s, descuento %s, total %s', subtotal, descuento, total)
       FROM comprobante WHERE nro = pg_temp.id('comprobante'))) \gset
CALL pg_temp.debe_fallar('RN-08', 'Cargar el total a mano en la cabecera', 'P0001',
    $q$UPDATE comprobante SET total = 1 WHERE nro = pg_temp.id('comprobante')$q$);
CALL pg_temp.debe_fallar('RN-08', 'Crear un comprobante con importes cargados', 'P0001',
    $q$INSERT INTO comprobante (id_cliente, id_sala, subtotal, descuento, total)
       VALUES (pg_temp.id('socio'), pg_temp.id('sala'), 100, 0, 100)$q$);
CALL pg_temp.debe_fallar('RN-08', 'Modificar la cantidad de un renglón emitido', 'P0001',
    $q$UPDATE renglon_comprobante SET cantidad = 1 WHERE nro = pg_temp.id('comprobante')$q$);
CALL pg_temp.debe_fallar('RN-08', 'Quitar un renglón suelto de un comprobante emitido', 'P0001',
    $q$DELETE FROM renglon_comprobante WHERE nro = pg_temp.id('comprobante')$q$);
CALL pg_temp.debe_funcionar('RN-08', 'Cambiar solo el descuento del renglón (consigna U1) recalcula todo',
    $q$UPDATE renglon_comprobante SET descuento_pct = 30 WHERE nro = pg_temp.id('comprobante')$q$);
SELECT pg_temp.verificar('RN-08', 'Tras el cambio: subtotal 25000, descuento 7500, total 17500',
    (SELECT subtotal = 25000 AND descuento = 7500 AND total = 17500
       FROM comprobante WHERE nro = pg_temp.id('comprobante')),
    (SELECT format('subtotal %s, descuento %s, total %s', subtotal, descuento, total)
       FROM comprobante WHERE nro = pg_temp.id('comprobante'))) \gset

-- ---------------------------------------------------------------------
-- RN-09  No se puede vender más de lo que hay en stock de la sala. El
--        stock nunca es negativo.
-- Mecanismo: trg_validar_stock_venta (BEFORE INSERT, con FOR UPDATE) +
--            CHECK ck_stock_sala_cantidad (cantidad >= 0).
-- Stock inicial 10; la venta de RN-08 se llevó 2 → quedan 8.
-- ---------------------------------------------------------------------
SELECT pg_temp.verificar('RN-09', 'La venta descontó el stock de la sala (10 - 2 = 8)',
    fn_stock_sala(pg_temp.id('sala')::INT, pg_temp.id('vino')::INT) = 8,
    'stock = ' || fn_stock_sala(pg_temp.id('sala')::INT, pg_temp.id('vino')::INT)) \gset
CALL pg_temp.debe_fallar('RN-09', 'Vender 9 botellas con stock 8', 'P0001',
    $q$WITH c AS (INSERT INTO comprobante (id_cliente, id_sala) VALUES (pg_temp.id('socio'), pg_temp.id('sala')) RETURNING nro)
       INSERT INTO renglon_comprobante (nro, cod_vino, cantidad) SELECT nro, pg_temp.id('vino'), 9 FROM c$q$);
CALL pg_temp.debe_fallar('RN-09', 'Vender un vino sin fila de stock en la sala', 'P0001',
    $q$INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega)
       VALUES ('TEST Sin stock', 'rosado', 2024, 750, 12, 5000, '33999999001')$q$,
    $q$INSERT INTO composicion_vino SELECT cod_vino, pg_temp.id('cepa1'), 100 FROM vino WHERE nombre = 'TEST Sin stock'$q$,
    $q$INSERT INTO renglon_comprobante (nro, cod_vino, cantidad)
       SELECT pg_temp.id('comprobante'), cod_vino, 1 FROM vino WHERE nombre = 'TEST Sin stock'$q$);
CALL pg_temp.debe_fallar('RN-09', 'Poner stock negativo directamente', '23514',
    $q$UPDATE stock_sala SET cantidad = -1 WHERE id_sala = pg_temp.id('sala') AND cod_vino = pg_temp.id('vino')$q$);
SELECT pg_temp.verificar('RN-09', 'Los intentos fallidos no tocaron el stock (sigue en 8)',
    fn_stock_sala(pg_temp.id('sala')::INT, pg_temp.id('vino')::INT) = 8) \gset

-- ---------------------------------------------------------------------
-- RN-10  Sólo un ingreso terminado impacta en el depósito y pasa a
--        procesado. en_confeccion → terminado → procesado, sin retroceso.
-- Mecanismo: ENUM estado_documento + trg_estado_ingreso + sp_procesar_ingreso.
-- Depósito inicial: 100.
-- ---------------------------------------------------------------------
DO $$
DECLARE v BIGINT;
BEGIN
    INSERT INTO ingreso (id_transportista, cuit_bodega) VALUES (pg_temp.id('transportista'), '33999999001')
    RETURNING cod_ingreso INTO v;
    INSERT INTO ctx VALUES ('ingreso', v);
END $$;

SELECT pg_temp.verificar('RN-10', 'El ingreso nace en_confeccion (DEFAULT)',
    (SELECT estado = 'en_confeccion' FROM ingreso WHERE cod_ingreso = pg_temp.id('ingreso'))) \gset
CALL pg_temp.debe_fallar('RN-10', 'Crear un ingreso directamente en estado procesado', 'P0001',
    $q$INSERT INTO ingreso (id_transportista, cuit_bodega, estado) VALUES (pg_temp.id('transportista'), '33999999001', 'procesado')$q$);
CALL pg_temp.debe_fallar('RN-10', 'Estado que no existe en el ENUM', '22P02',
    $q$UPDATE ingreso SET estado = 'anulado' WHERE cod_ingreso = pg_temp.id('ingreso')$q$);
CALL pg_temp.debe_fallar('RN-10', 'Terminar un ingreso sin renglones', 'P0001',
    $q$UPDATE ingreso SET estado = 'terminado' WHERE cod_ingreso = pg_temp.id('ingreso')$q$);
CALL pg_temp.debe_fallar('RN-10', 'Procesar un ingreso en confección', 'P0001',
    $q$CALL sp_procesar_ingreso(pg_temp.id('ingreso')::INT)$q$);
CALL pg_temp.debe_funcionar('RN-10', 'Cargar 120 botellas y terminar',
    $q$INSERT INTO renglon_ingreso VALUES (pg_temp.id('ingreso'), pg_temp.id('vino'), 120)$q$,
    $q$UPDATE ingreso SET estado = 'terminado' WHERE cod_ingreso = pg_temp.id('ingreso')$q$);
CALL pg_temp.debe_fallar('RN-10', 'Retroceder de terminado a en_confeccion', 'P0001',
    $q$UPDATE ingreso SET estado = 'en_confeccion' WHERE cod_ingreso = pg_temp.id('ingreso')$q$);
CALL pg_temp.debe_fallar('RN-10', 'Pasar a procesado con un UPDATE directo (sin mover stock)', 'P0001',
    $q$UPDATE ingreso SET estado = 'procesado' WHERE cod_ingreso = pg_temp.id('ingreso')$q$);
CALL pg_temp.debe_funcionar('RN-10', 'Procesar con sp_procesar_ingreso',
    $q$CALL sp_procesar_ingreso(pg_temp.id('ingreso')::INT)$q$);
SELECT pg_temp.verificar('RN-10', 'Depósito 100 + 120 = 220 y el ingreso quedó procesado',
    (SELECT cantidad = 220 FROM stock_deposito WHERE cod_vino = pg_temp.id('vino'))
    AND (SELECT estado = 'procesado' FROM ingreso WHERE cod_ingreso = pg_temp.id('ingreso')),
    (SELECT 'depósito = ' || cantidad FROM stock_deposito WHERE cod_vino = pg_temp.id('vino'))) \gset
CALL pg_temp.debe_fallar('RN-10', 'Procesar dos veces el mismo ingreso', 'P0001',
    $q$CALL sp_procesar_ingreso(pg_temp.id('ingreso')::INT)$q$);

-- ---------------------------------------------------------------------
-- RN-11  Igual que RN-10 para transferencias. La fecha de confección es la
--        actual y no se puede modificar.
-- Mecanismo: trg_estado_transferencia, trg_fecha_transferencia,
--            sp_procesar_transferencia. Depósito: 220; sala: 8.
-- ---------------------------------------------------------------------
DO $$
DECLARE v BIGINT;
BEGIN
    INSERT INTO transferencia (id_sala, fecha_confeccion) VALUES (pg_temp.id('sala'), '2000-01-01')
    RETURNING nro_solicitud INTO v;
    INSERT INTO ctx VALUES ('transf_ok', v);
    INSERT INTO transferencia (id_sala) VALUES (pg_temp.id('sala')) RETURNING nro_solicitud INTO v;
    INSERT INTO ctx VALUES ('transf_sin_stock', v);
END $$;

SELECT pg_temp.verificar('RN-11', 'Se envió fecha 2000-01-01 y la base guardó la fecha actual',
    (SELECT fecha_confeccion = CURRENT_DATE FROM transferencia WHERE nro_solicitud = pg_temp.id('transf_ok'))) \gset
CALL pg_temp.debe_fallar('RN-11', 'Modificar la fecha de confección', 'P0001',
    $q$UPDATE transferencia SET fecha_confeccion = CURRENT_DATE - 1 WHERE nro_solicitud = pg_temp.id('transf_ok')$q$);
CALL pg_temp.debe_funcionar('RN-11', 'Transferir 50 botellas: cargar, terminar y procesar',
    $q$INSERT INTO renglon_transferencia VALUES (pg_temp.id('transf_ok'), pg_temp.id('vino'), 50)$q$,
    $q$UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud = pg_temp.id('transf_ok')$q$,
    $q$CALL sp_procesar_transferencia(pg_temp.id('transf_ok')::INT)$q$);
SELECT pg_temp.verificar('RN-11', 'Depósito 220 - 50 = 170 y sala 8 + 50 = 58',
    (SELECT cantidad = 170 FROM stock_deposito WHERE cod_vino = pg_temp.id('vino'))
    AND fn_stock_sala(pg_temp.id('sala')::INT, pg_temp.id('vino')::INT) = 58,
    (SELECT format('depósito %s, sala %s', d.cantidad, fn_stock_sala(pg_temp.id('sala')::INT, pg_temp.id('vino')::INT))
       FROM stock_deposito d WHERE d.cod_vino = pg_temp.id('vino'))) \gset
CALL pg_temp.debe_fallar('RN-11', 'Pasar a procesado con un UPDATE directo', 'P0001',
    $q$INSERT INTO renglon_transferencia VALUES (pg_temp.id('transf_sin_stock'), pg_temp.id('vino'), 5000)$q$,
    $q$UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud = pg_temp.id('transf_sin_stock')$q$,
    $q$UPDATE transferencia SET estado = 'procesado' WHERE nro_solicitud = pg_temp.id('transf_sin_stock')$q$);
CALL pg_temp.debe_funcionar('RN-11', 'Preparar una transferencia de 5000 botellas (más que el depósito)',
    $q$INSERT INTO renglon_transferencia VALUES (pg_temp.id('transf_sin_stock'), pg_temp.id('vino'), 5000)$q$,
    $q$UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud = pg_temp.id('transf_sin_stock')$q$);
CALL pg_temp.debe_fallar('RN-11', 'Procesar sin stock suficiente en el depósito', 'P0001',
    $q$CALL sp_procesar_transferencia(pg_temp.id('transf_sin_stock')::INT)$q$);
SELECT pg_temp.verificar('RN-11', 'Sin cambios a medias: depósito 170, sala 58, transferencia sigue terminada',
    (SELECT cantidad = 170 FROM stock_deposito WHERE cod_vino = pg_temp.id('vino'))
    AND fn_stock_sala(pg_temp.id('sala')::INT, pg_temp.id('vino')::INT) = 58
    AND (SELECT estado = 'terminado' FROM transferencia WHERE nro_solicitud = pg_temp.id('transf_sin_stock'))) \gset

-- ---------------------------------------------------------------------
-- RN-12  Un ingreso o una transferencia que no está en confección no admite
--        agregar, modificar ni quitar renglones.
-- Mecanismo: trg_bloqueo_renglones_ingreso / _transferencia.
-- ---------------------------------------------------------------------
CALL pg_temp.debe_fallar('RN-12', 'Agregar un renglón a un ingreso procesado', 'P0001',
    $q$INSERT INTO renglon_ingreso VALUES (pg_temp.id('ingreso'), pg_temp.id('vino'), 10)$q$);
CALL pg_temp.debe_fallar('RN-12', 'Modificar la cantidad de un renglón de ingreso procesado', 'P0001',
    $q$UPDATE renglon_ingreso SET cantidad = 1 WHERE cod_ingreso = pg_temp.id('ingreso')$q$);
CALL pg_temp.debe_fallar('RN-12', 'Quitar un renglón de un ingreso procesado', 'P0001',
    $q$DELETE FROM renglon_ingreso WHERE cod_ingreso = pg_temp.id('ingreso')$q$);
CALL pg_temp.debe_fallar('RN-12', 'Modificar un renglón de una transferencia terminada', 'P0001',
    $q$UPDATE renglon_transferencia SET cantidad = 1 WHERE nro_solicitud = pg_temp.id('transf_sin_stock')$q$);
CALL pg_temp.debe_funcionar('RN-12', 'Borrar el ingreso completo: sus renglones se van en cascada (consigna D5)',
    $q$DELETE FROM ingreso WHERE cod_ingreso = pg_temp.id('ingreso')$q$);

-- ---------------------------------------------------------------------
-- RN-13  Todo cambio de precio queda auditado (fecha, usuario, precio
--        anterior y nuevo).
-- Mecanismo: trg_auditoria_precio (AFTER UPDATE, SECURITY DEFINER) +
--            tabla auditoria_precio. La API (app_rw) solo puede leerla.
-- (RN-01 intentó cambios de precio que fallaron: no deben quedar auditados.)
-- ---------------------------------------------------------------------
CALL pg_temp.debe_funcionar('RN-13', 'Cambiar el precio de 12500 a 13000',
    $q$UPDATE vino SET precio = 13000 WHERE cod_vino = pg_temp.id('vino')$q$);
SELECT pg_temp.verificar('RN-13', 'Se registró exactamente un cambio, con precios, fecha y usuario',
    (SELECT count(*) = 1 AND bool_and(precio_anterior = 12500 AND precio_nuevo = 13000
                                      AND fecha_hora IS NOT NULL AND usuario IS NOT NULL)
       FROM auditoria_precio WHERE cod_vino = pg_temp.id('vino')),
    (SELECT string_agg(format('%s→%s por %s', precio_anterior, precio_nuevo, usuario), '; ')
       FROM auditoria_precio WHERE cod_vino = pg_temp.id('vino'))) \gset
CALL pg_temp.debe_funcionar('RN-13', 'Cambiar otro dato del vino (nombre) no audita',
    $q$UPDATE vino SET nombre = 'TEST Malbec Reserva (renombrado)' WHERE cod_vino = pg_temp.id('vino')$q$);
SELECT pg_temp.verificar('RN-13', 'Sigue habiendo un solo registro de auditoría',
    (SELECT count(*) = 1 FROM auditoria_precio WHERE cod_vino = pg_temp.id('vino'))) \gset

DO $$
BEGIN
    IF pg_has_role(current_user, 'app_rw', 'MEMBER') THEN
        CALL pg_temp.debe_fallar('RN-13', 'La API (app_rw) no puede borrar la auditoría', '42501',
            'SET LOCAL ROLE app_rw',
            'DELETE FROM auditoria_precio');
        CALL pg_temp.debe_fallar('RN-13', 'La API (app_rw) no puede insertar auditoría falsa', '42501',
            'SET LOCAL ROLE app_rw',
            format('INSERT INTO auditoria_precio (cod_vino, precio_anterior, precio_nuevo) VALUES (%s, 1, 2)', pg_temp.id('vino')));
        CALL pg_temp.debe_funcionar('RN-13', 'La API (app_rw) cambia un precio y el trigger audita igual',
            'SET LOCAL ROLE app_rw',
            format('UPDATE vino SET precio = 13500 WHERE cod_vino = %s', pg_temp.id('vino')),
            'RESET ROLE');
        PERFORM pg_temp.verificar('RN-13', 'El cambio hecho por app_rw quedó auditado a nombre de la sesión',
            (SELECT count(*) = 2 FROM auditoria_precio WHERE cod_vino = pg_temp.id('vino')));
    ELSE
        INSERT INTO resultado (regla, caso, esperado, ok, detalle)
        VALUES ('RN-13', 'Permisos de app_rw sobre la auditoría', 'omitido', NULL,
                'ejecutar como superusuario para probar SET ROLE app_rw');
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- RN-14  No se puede borrar un transportista, una bodega ni un vino que
--        tengan movimientos asociados.
-- Mecanismo: FK con ON DELETE RESTRICT.
-- PostgreSQL 18 informa estas violaciones con SQLSTATE 23001
-- (restrict_violation); las versiones anteriores, con 23503. Se aceptan ambos.
-- ---------------------------------------------------------------------
CALL pg_temp.debe_fallar('RN-14', 'Borrar un vino con ventas', '23001|23503',
    $q$DELETE FROM vino WHERE cod_vino = pg_temp.id('vino')$q$);
CALL pg_temp.debe_fallar('RN-14', 'Borrar una bodega que elabora vinos', '23001|23503',
    $q$DELETE FROM bodega WHERE cuit = '33999999001'$q$);
CALL pg_temp.debe_fallar('RN-14', 'Borrar un transportista con ingresos', '23001|23503',
    $q$INSERT INTO ingreso (id_transportista, cuit_bodega) VALUES (pg_temp.id('transportista'), '33999999001')$q$,
    $q$DELETE FROM transportista WHERE id_transportista = pg_temp.id('transportista')$q$);
CALL pg_temp.debe_funcionar('RN-14', 'Borrar una bodega sin movimientos',
    $q$DELETE FROM bodega WHERE cuit = '33999999002'$q$);

-- ---------------------------------------------------------------------
-- RN-15  Cantidades, superficies, kilos y precios siempre positivos. La
--        graduación está entre 5 y 20.
-- Mecanismo: CHECK.
-- ---------------------------------------------------------------------
CALL pg_temp.debe_fallar('RN-15', 'Graduación 4.99', '23514',
    $q$UPDATE vino SET graduacion = 4.99 WHERE cod_vino = pg_temp.id('vino')$q$);
CALL pg_temp.debe_fallar('RN-15', 'Graduación 20.01', '23514',
    $q$UPDATE vino SET graduacion = 20.01 WHERE cod_vino = pg_temp.id('vino')$q$);
CALL pg_temp.debe_funcionar('RN-15', 'Graduación en los límites (5 y 20)',
    $q$UPDATE vino SET graduacion = 5 WHERE cod_vino = pg_temp.id('vino')$q$,
    $q$UPDATE vino SET graduacion = 20 WHERE cod_vino = pg_temp.id('vino')$q$);
CALL pg_temp.debe_fallar('RN-15', 'Cantidad 0 en un renglón de venta', '23514',
    $q$WITH c AS (INSERT INTO comprobante (id_cliente, id_sala) VALUES (pg_temp.id('socio'), pg_temp.id('sala')) RETURNING nro)
       INSERT INTO renglon_comprobante (nro, cod_vino, cantidad) SELECT nro, pg_temp.id('vino'), 0 FROM c$q$);
CALL pg_temp.debe_fallar('RN-15', 'Cantidad negativa en un renglón de transferencia', '23514',
    $q$WITH t AS (INSERT INTO transferencia (id_sala) VALUES (pg_temp.id('sala')) RETURNING nro_solicitud)
       INSERT INTO renglon_transferencia SELECT nro_solicitud, pg_temp.id('vino'), -3 FROM t$q$);
CALL pg_temp.debe_fallar('RN-15', 'Superficie de finca 0', '23514',
    $q$UPDATE finca SET superficie_ha = 0 WHERE id_finca = pg_temp.id('finca')$q$);
CALL pg_temp.debe_fallar('RN-15', 'Superficie de parcela negativa', '23514',
    $q$UPDATE parcela SET superficie_ha = -1 WHERE id_finca = pg_temp.id('finca')$q$);
CALL pg_temp.debe_fallar('RN-15', 'Kilos cosechados 0', '23514',
    $q$UPDATE lote_uva SET kg_cosechados = 0 WHERE id_finca = pg_temp.id('finca')$q$);
CALL pg_temp.debe_fallar('RN-15', 'Salario negativo', '23514',
    $q$UPDATE empleado SET salario = -100 WHERE cuit = '33999999201'$q$);
CALL pg_temp.debe_fallar('RN-15', 'CUIT con formato inválido (DOMAIN cuit_dom)', '23514',
    $q$INSERT INTO bodega (cuit, razon_social, domicilio) VALUES ('30-123456-X', 'TEST', 'TEST')$q$);

-- ---------------------------------------------------------------------
-- Cierre: con todos los constraint triggers diferidos en IMMEDIATE, los
-- datos que dejaron los casos exitosos deben ser consistentes (es lo que
-- pasaría al hacer COMMIT).
-- ---------------------------------------------------------------------
CALL pg_temp.debe_funcionar('GENERAL', 'Los datos de prueba pasan todas las validaciones diferidas',
    'SET CONSTRAINTS ALL IMMEDIATE');

-- =====================================================================
-- 3. RESULTADOS
-- =====================================================================
\echo
\echo '==================== DETALLE ===================='
SELECT n AS "#", regla, caso, esperado,
       CASE ok WHEN TRUE THEN 'OK' WHEN FALSE THEN '** FALLO **' ELSE 'omitido' END AS resultado,
       CASE WHEN ok THEN '' ELSE detalle END AS detalle
  FROM resultado
 ORDER BY n;

\echo '==================== RESUMEN POR REGLA ===================='
SELECT regla,
       count(*)                        AS casos,
       count(*) FILTER (WHERE ok)      AS ok,
       count(*) FILTER (WHERE NOT ok)  AS fallos
  FROM resultado
 GROUP BY regla
 ORDER BY regla;

SELECT format('TOTAL: %s casos · %s OK · %s FALLOS · %s omitidos',
              count(*), count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok),
              count(*) FILTER (WHERE ok IS NULL)) AS total
  FROM resultado;

-- Si hubo fallos, termina con error (útil para CI); igual se revierte todo.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM resultado WHERE ok = FALSE) THEN
        RAISE EXCEPTION 'Hay % casos de prueba FALLIDOS (ver detalle arriba)',
            (SELECT count(*) FROM resultado WHERE ok = FALSE);
    END IF;
END $$;

ROLLBACK;
