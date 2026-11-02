-- =====================================================================
-- 005_triggers.sql  ·  Bodegas del Atuel  ·  PostgreSQL 14+
-- Etapa 2: triggers que protegen las reglas de negocio.
--
-- Índice
--   A. Ventas
--      1. trg_completar_renglon_venta      BEFORE INSERT   renglon_comprobante  RN-06, RN-08
--      2. trg_validar_stock_venta          BEFORE INSERT   renglon_comprobante  RN-09
--      3. trg_actualizar_stock_y_totales   AFTER INS/UPD   renglon_comprobante  RN-08, RN-09
--      4. trg_proteger_renglon_venta       BEFORE UPD/DEL  renglon_comprobante  RN-08
--      5. trg_proteger_importes            BEFORE INS/UPD  comprobante          RN-08
--   B. Clientes
--      6. trg_descuento_cliente            BEFORE INS/UPD  cliente              RN-06
--      7. trg_subtipo_{socio,...}          BEFORE INS/UPD  socio/distrib./export.  jerarquía
--      8. trg_cliente_requiere_subtipo     CONSTRAINT (diferido)  cliente + subtipos  jerarquía
--   C. Ingresos y transferencias
--      9. trg_estado_{ingreso,transferencia}        BEFORE INS/UPD  RN-10, RN-11
--     10. trg_bloqueo_renglones_{ingreso,transf.}   BEFORE I/U/D    RN-12
--     11. trg_fecha_transferencia                   BEFORE INS/UPD  RN-11
--   D. Vinos
--     12. trg_auditoria_precio             AFTER UPDATE    vino                 RN-13
--     13. trg_composicion_suma_100 / trg_vino_requiere_composicion
--                                          CONSTRAINT (diferido)               RN-05
--
-- Orden de disparo: PostgreSQL ejecuta los triggers del mismo evento en
-- orden ALFABÉTICO de nombre. Por eso trg_completar_renglon_venta (que
-- completa precio y descuento) corre antes que trg_validar_stock_venta.
-- =====================================================================


-- #####################################################################
-- A. VENTAS
-- #####################################################################

-- ---------------------------------------------------------------------
-- 1. trg_completar_renglon_venta (RN-06, RN-08)
-- Tipo: BEFORE INSERT ON renglon_comprobante
-- Qué garantiza: el precio, el descuento y el subtotal del renglón NO los
-- carga quien inserta (API, front o psql): la base los toma de vino.precio
-- y cliente.descuento y calcula el subtotal con fn_subtotal_renglon.
-- Cualquier valor enviado en esas columnas se ignora y se reemplaza.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_completar_renglon_venta()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_descuento NUMERIC(5,2);
BEGIN
    SELECT v.precio INTO NEW.precio_unitario
      FROM vino v
     WHERE v.cod_vino = NEW.cod_vino;
    -- Si el vino no existe, la FK rechaza el INSERT más adelante.

    SELECT cl.descuento INTO v_descuento
      FROM comprobante c
      JOIN cliente cl ON cl.id_cliente = c.id_cliente
     WHERE c.nro = NEW.nro;

    NEW.descuento_pct := COALESCE(v_descuento, 0);
    NEW.subtotal      := fn_subtotal_renglon(NEW.cantidad, NEW.precio_unitario, NEW.descuento_pct);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_completar_renglon_venta
BEFORE INSERT ON renglon_comprobante
FOR EACH ROW EXECUTE FUNCTION fn_trg_completar_renglon_venta();

-- ---------------------------------------------------------------------
-- 2. trg_validar_stock_venta (RN-09)
-- Tipo: BEFORE INSERT ON renglon_comprobante
-- Qué garantiza: rechaza la venta si la sala no tiene stock suficiente.
-- Concurrencia: la fila de stock_sala se lee con FOR UPDATE. Si dos ventas
-- simultáneas piden la última botella, la segunda espera a que la primera
-- termine y recién entonces lee el stock actualizado (0) y es rechazada.
-- Además, el CHECK (cantidad >= 0) de stock_sala es la última barrera.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_validar_stock_venta()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_id_sala     INTEGER;
    v_stock_disp  INTEGER;
BEGIN
    SELECT id_sala INTO v_id_sala FROM comprobante WHERE nro = NEW.nro;

    SELECT cantidad INTO v_stock_disp
      FROM stock_sala
     WHERE id_sala = v_id_sala AND cod_vino = NEW.cod_vino
       FOR UPDATE;

    v_stock_disp := COALESCE(v_stock_disp, 0);

    IF v_stock_disp < NEW.cantidad THEN
        RAISE EXCEPTION 'Stock insuficiente del vino % en la sala % (disponible: %, solicitado: %). (RN-09)',
            NEW.cod_vino, v_id_sala, v_stock_disp, NEW.cantidad;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validar_stock_venta
BEFORE INSERT ON renglon_comprobante
FOR EACH ROW EXECUTE FUNCTION fn_trg_validar_stock_venta();

-- ---------------------------------------------------------------------
-- 3. trg_actualizar_stock_y_totales (RN-08, RN-09)
-- Tipo: AFTER INSERT OR UPDATE ON renglon_comprobante
-- Qué garantiza: al insertar descuenta el stock de la sala; en ambos casos
-- recalcula subtotal, descuento y total de la cabecera con fn_total_comprobante.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_actualizar_stock_y_totales()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_id_sala INTEGER;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT id_sala INTO v_id_sala FROM comprobante WHERE nro = NEW.nro;

        UPDATE stock_sala
           SET cantidad = cantidad - NEW.cantidad
         WHERE id_sala = v_id_sala AND cod_vino = NEW.cod_vino;
    END IF;

    UPDATE comprobante c
       SET subtotal  = t.subtotal,
           descuento = t.descuento,
           total     = t.total
      FROM fn_total_comprobante(NEW.nro) t
     WHERE c.nro = NEW.nro;

    RETURN NULL;   -- AFTER: el valor de retorno se ignora
END;
$$;

CREATE TRIGGER trg_actualizar_stock_y_totales
AFTER INSERT OR UPDATE ON renglon_comprobante
FOR EACH ROW EXECUTE FUNCTION fn_trg_actualizar_stock_y_totales();

-- ---------------------------------------------------------------------
-- 4. trg_proteger_renglon_venta (RN-08)
-- Tipo: BEFORE UPDATE OR DELETE ON renglon_comprobante
-- Qué garantiza: una venta emitida es un hecho histórico.
--   * UPDATE: solo se admite cambiar descuento_pct (lo necesita la consigna
--     U1); el subtotal se recalcula acá y la cabecera en el trigger 3.
--     Cambiar vino, cantidad o precio se rechaza.
--   * DELETE: no se puede quitar un renglón suelto. Solo se borra cuando se
--     borra el comprobante completo (ON DELETE CASCADE). En ese caso la
--     cabecera ya no existe al momento de disparar este trigger, y así se
--     distingue el borrado en cascada del borrado individual.
--     Borrar un comprobante es una depuración de historial (consigna D1):
--     NO devuelve stock a la sala.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_proteger_renglon_venta()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF EXISTS (SELECT 1 FROM comprobante WHERE nro = OLD.nro) THEN
            RAISE EXCEPTION 'No se puede quitar un renglón del comprobante %: una venta emitida no se modifica. Borre el comprobante completo. (RN-08)',
                OLD.nro;
        END IF;
        RETURN OLD;
    END IF;

    -- UPDATE
    IF NEW.nro             IS DISTINCT FROM OLD.nro
    OR NEW.cod_vino        IS DISTINCT FROM OLD.cod_vino
    OR NEW.cantidad        IS DISTINCT FROM OLD.cantidad
    OR NEW.precio_unitario IS DISTINCT FROM OLD.precio_unitario THEN
        RAISE EXCEPTION 'En un renglón de venta emitido solo puede modificarse el descuento aplicado. (RN-08)';
    END IF;

    NEW.subtotal := fn_subtotal_renglon(NEW.cantidad, NEW.precio_unitario, NEW.descuento_pct);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_proteger_renglon_venta
BEFORE UPDATE OR DELETE ON renglon_comprobante
FOR EACH ROW EXECUTE FUNCTION fn_trg_proteger_renglon_venta();

-- ---------------------------------------------------------------------
-- 5. trg_proteger_importes (RN-08)
-- Tipo: BEFORE INSERT OR UPDATE ON comprobante
-- Qué garantiza: subtotal, descuento y total "no se cargan a mano".
-- Los valores de la cabecera deben coincidir siempre con lo que calcula
-- fn_total_comprobante a partir de los renglones. Al insertar la cabecera
-- (todavía sin renglones) deben ser 0, que es su DEFAULT.
-- Tampoco se puede mover un comprobante con renglones a otra sala: el
-- stock ya se descontó de la sala original.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_proteger_importes()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    t RECORD;
BEGIN
    SELECT * INTO t FROM fn_total_comprobante(NEW.nro);

    IF (NEW.subtotal, NEW.descuento, NEW.total)
       IS DISTINCT FROM (t.subtotal, t.descuento, t.total) THEN
        RAISE EXCEPTION 'Los importes del comprobante % se calculan a partir de sus renglones y no se cargan a mano (esperado: subtotal %, descuento %, total %). (RN-08)',
            NEW.nro, t.subtotal, t.descuento, t.total;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.id_sala IS DISTINCT FROM OLD.id_sala
       AND EXISTS (SELECT 1 FROM renglon_comprobante WHERE nro = NEW.nro) THEN
        RAISE EXCEPTION 'No se puede cambiar la sala del comprobante %: el stock ya se descontó de la sala %. (RN-09)',
            NEW.nro, OLD.id_sala;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_proteger_importes
BEFORE INSERT OR UPDATE ON comprobante
FOR EACH ROW EXECUTE FUNCTION fn_trg_proteger_importes();


-- #####################################################################
-- B. CLIENTES
-- #####################################################################

-- ---------------------------------------------------------------------
-- 6. trg_descuento_cliente (RN-06)
-- Tipo: BEFORE INSERT OR UPDATE OF tipo ON cliente
-- Qué garantiza:
--   * Al dar de alta un cliente sin indicar descuento, lo inicializa con
--     fn_descuento_cliente(tipo): socio 10, distribuidor 20, exportador 30.
--     Se admite un valor explícito (consigna U6: exportadores al 35 %);
--     el CHECK ck_cliente_descuento mantiene el rango 0..100.
--   * El tipo de cliente no se puede cambiar: cambiaría de subtabla y
--     de descuento (decisión de diseño documentada en la Etapa 1).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_descuento_cliente()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.descuento IS NULL THEN
            NEW.descuento := fn_descuento_cliente(NEW.tipo);
        END IF;
    ELSIF NEW.tipo IS DISTINCT FROM OLD.tipo THEN
        RAISE EXCEPTION 'El tipo del cliente % no se puede cambiar (de % a %). Dé de alta un cliente nuevo. (RN-06)',
            OLD.id_cliente, OLD.tipo, NEW.tipo;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_descuento_cliente
BEFORE INSERT OR UPDATE OF tipo ON cliente
FOR EACH ROW EXECUTE FUNCTION fn_trg_descuento_cliente();

-- ---------------------------------------------------------------------
-- 7. trg_subtipo_socio / trg_subtipo_distribuidor / trg_subtipo_exportador
-- Tipo: BEFORE INSERT OR UPDATE ON cada tabla de subtipo
-- Qué garantiza: jerarquía DISJUNTA. Una fila en una subtabla debe
-- corresponder a un cliente de ese mismo tipo (un 'socio' no puede figurar
-- en exportador). El tipo esperado llega como argumento (TG_ARGV[0]).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_subtipo_cliente()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_tipo tipo_cliente;
BEGIN
    SELECT tipo INTO v_tipo FROM cliente WHERE id_cliente = NEW.id_cliente;
    -- Si el cliente no existe, la FK lo rechaza más adelante.

    IF FOUND AND v_tipo <> TG_ARGV[0]::tipo_cliente THEN
        RAISE EXCEPTION 'El cliente % es de tipo % y no puede registrarse como %. (jerarquía de clientes)',
            NEW.id_cliente, v_tipo, TG_ARGV[0];
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_subtipo_socio
BEFORE INSERT OR UPDATE ON socio
FOR EACH ROW EXECUTE FUNCTION fn_trg_subtipo_cliente('socio');

CREATE TRIGGER trg_subtipo_distribuidor
BEFORE INSERT OR UPDATE ON distribuidor
FOR EACH ROW EXECUTE FUNCTION fn_trg_subtipo_cliente('distribuidor');

CREATE TRIGGER trg_subtipo_exportador
BEFORE INSERT OR UPDATE ON exportador
FOR EACH ROW EXECUTE FUNCTION fn_trg_subtipo_cliente('exportador');

-- ---------------------------------------------------------------------
-- 8. trg_cliente_requiere_subtipo (jerarquía TOTAL)
-- Tipo: CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED
--       AFTER INSERT ON cliente  y  AFTER DELETE ON cada subtabla
-- Qué garantiza: al cerrar la transacción, todo cliente existente tiene su
-- fila en la subtabla que corresponde a su tipo. Es diferido para poder
-- insertar primero el cliente y después el subtipo en la misma transacción.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_verificar_subtipo_cliente()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_id   INTEGER := CASE WHEN TG_OP = 'DELETE' THEN OLD.id_cliente ELSE NEW.id_cliente END;
    v_tipo tipo_cliente;
    v_ok   BOOLEAN;
BEGIN
    SELECT tipo INTO v_tipo FROM cliente WHERE id_cliente = v_id;
    IF NOT FOUND THEN
        RETURN NULL;   -- el cliente se borró: no hay nada que verificar
    END IF;

    v_ok := CASE v_tipo
              WHEN 'socio'        THEN EXISTS (SELECT 1 FROM socio        WHERE id_cliente = v_id)
              WHEN 'distribuidor' THEN EXISTS (SELECT 1 FROM distribuidor WHERE id_cliente = v_id)
              WHEN 'exportador'   THEN EXISTS (SELECT 1 FROM exportador   WHERE id_cliente = v_id)
            END;

    IF NOT v_ok THEN
        RAISE EXCEPTION 'El cliente % es de tipo % pero no tiene su fila en la tabla %. (jerarquía de clientes)',
            v_id, v_tipo, v_tipo;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_cliente_requiere_subtipo
AFTER INSERT ON cliente
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_trg_verificar_subtipo_cliente();

CREATE CONSTRAINT TRIGGER trg_socio_requerido
AFTER DELETE ON socio
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_trg_verificar_subtipo_cliente();

CREATE CONSTRAINT TRIGGER trg_distribuidor_requerido
AFTER DELETE ON distribuidor
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_trg_verificar_subtipo_cliente();

CREATE CONSTRAINT TRIGGER trg_exportador_requerido
AFTER DELETE ON exportador
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_trg_verificar_subtipo_cliente();


-- #####################################################################
-- C. INGRESOS Y TRANSFERENCIAS
-- #####################################################################

-- ---------------------------------------------------------------------
-- 9. trg_estado_ingreso / trg_estado_transferencia (RN-10, RN-11)
-- Tipo: BEFORE INSERT OR UPDATE OF estado ON ingreso / transferencia
-- Qué garantiza:
--   * Un documento nace 'en_confeccion'.
--   * Transiciones válidas: en_confeccion -> terminado -> procesado, sin
--     retrocesos ni saltos.
--   * Para pasar a 'terminado' el documento debe tener al menos un renglón.
--   * A 'procesado' solo se llega a través de sp_procesar_ingreso /
--     sp_procesar_transferencia (que activan la variable de sesión
--     'bodegas.via_procedimiento'). Un UPDATE directo dejaría el documento
--     procesado sin haber movido stock, por eso se rechaza.
-- Una sola función sirve a ambas tablas: TG_TABLE_NAME indica cuál es.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_control_estados()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_regla TEXT := CASE TG_TABLE_NAME WHEN 'ingreso' THEN 'RN-10' ELSE 'RN-11' END;
    v_tiene_renglones BOOLEAN;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.estado <> 'en_confeccion' THEN
            RAISE EXCEPTION 'Un % se crea en estado en_confeccion, no en %. (%)',
                TG_TABLE_NAME, NEW.estado, v_regla;
        END IF;
        RETURN NEW;
    END IF;

    IF OLD.estado = NEW.estado THEN
        RETURN NEW;
    END IF;

    IF OLD.estado = 'en_confeccion' AND NEW.estado = 'terminado' THEN
        IF TG_TABLE_NAME = 'ingreso' THEN
            v_tiene_renglones := EXISTS (SELECT 1 FROM renglon_ingreso WHERE cod_ingreso = NEW.cod_ingreso);
        ELSE
            v_tiene_renglones := EXISTS (SELECT 1 FROM renglon_transferencia WHERE nro_solicitud = NEW.nro_solicitud);
        END IF;

        IF NOT v_tiene_renglones THEN
            RAISE EXCEPTION 'No se puede terminar un % sin renglones. (%)', TG_TABLE_NAME, v_regla;
        END IF;
        RETURN NEW;

    ELSIF OLD.estado = 'terminado' AND NEW.estado = 'procesado' THEN
        IF COALESCE(current_setting('bodegas.via_procedimiento', true), '') <> 'on' THEN
            RAISE EXCEPTION 'Un % solo pasa a procesado mediante su procedimiento (CALL sp_procesar_%), que es el que mueve el stock. (%)',
                TG_TABLE_NAME, TG_TABLE_NAME, v_regla;
        END IF;
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'Transición de estado inválida en %: de % a %. El ciclo es en_confeccion -> terminado -> procesado, sin retrocesos. (%)',
        TG_TABLE_NAME, OLD.estado, NEW.estado, v_regla;
END;
$$;

CREATE TRIGGER trg_estado_ingreso
BEFORE INSERT OR UPDATE OF estado ON ingreso
FOR EACH ROW EXECUTE FUNCTION fn_trg_control_estados();

CREATE TRIGGER trg_estado_transferencia
BEFORE INSERT OR UPDATE OF estado ON transferencia
FOR EACH ROW EXECUTE FUNCTION fn_trg_control_estados();

-- ---------------------------------------------------------------------
-- 10. trg_bloqueo_renglones_ingreso / _transferencia (RN-12)
-- Tipo: BEFORE INSERT OR UPDATE OR DELETE ON renglon_ingreso / renglon_transferencia
-- Qué garantiza: no se agregan, modifican ni quitan renglones de un
-- documento que no está 'en_confeccion'.
-- Excepción: si la cabecera ya no existe, el renglón se está borrando en
-- cascada junto con su documento (consigna D5: borrar ingresos procesados
-- antiguos) y se permite.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_bloqueo_renglones_ingreso()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_estado estado_documento;
    v_cod    INTEGER := CASE WHEN TG_OP = 'DELETE' THEN OLD.cod_ingreso ELSE NEW.cod_ingreso END;
BEGIN
    SELECT estado INTO v_estado FROM ingreso WHERE cod_ingreso = v_cod;

    IF NOT FOUND AND TG_OP = 'DELETE' THEN
        RETURN OLD;   -- borrado en cascada desde la cabecera
    END IF;

    IF v_estado IS DISTINCT FROM 'en_confeccion' THEN
        RAISE EXCEPTION 'No se pueden modificar los renglones del ingreso % porque no está en confección (estado: %). (RN-12)',
            v_cod, v_estado;
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_bloqueo_renglones_ingreso
BEFORE INSERT OR UPDATE OR DELETE ON renglon_ingreso
FOR EACH ROW EXECUTE FUNCTION fn_trg_bloqueo_renglones_ingreso();

CREATE OR REPLACE FUNCTION fn_trg_bloqueo_renglones_transferencia()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_estado estado_documento;
    v_nro    INTEGER := CASE WHEN TG_OP = 'DELETE' THEN OLD.nro_solicitud ELSE NEW.nro_solicitud END;
BEGIN
    SELECT estado INTO v_estado FROM transferencia WHERE nro_solicitud = v_nro;

    IF NOT FOUND AND TG_OP = 'DELETE' THEN
        RETURN OLD;   -- borrado en cascada desde la cabecera
    END IF;

    IF v_estado IS DISTINCT FROM 'en_confeccion' THEN
        RAISE EXCEPTION 'No se pueden modificar los renglones de la transferencia % porque no está en confección (estado: %). (RN-12)',
            v_nro, v_estado;
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_bloqueo_renglones_transferencia
BEFORE INSERT OR UPDATE OR DELETE ON renglon_transferencia
FOR EACH ROW EXECUTE FUNCTION fn_trg_bloqueo_renglones_transferencia();

-- ---------------------------------------------------------------------
-- 11. trg_fecha_transferencia (RN-11)
-- Tipo: BEFORE INSERT OR UPDATE OF fecha_confeccion ON transferencia
-- Qué garantiza: la fecha de confección es la actual (se ignora la enviada)
-- y no se puede modificar. Va en un trigger y no en un CHECK porque depende
-- de CURRENT_DATE (un CHECK así se rompería al restaurar un backup).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_fecha_transferencia()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.fecha_confeccion := CURRENT_DATE;
    ELSIF NEW.fecha_confeccion IS DISTINCT FROM OLD.fecha_confeccion THEN
        RAISE EXCEPTION 'La fecha de confección de la transferencia % no se puede modificar. (RN-11)',
            OLD.nro_solicitud;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_fecha_transferencia
BEFORE INSERT OR UPDATE OF fecha_confeccion ON transferencia
FOR EACH ROW EXECUTE FUNCTION fn_trg_fecha_transferencia();


-- #####################################################################
-- D. VINOS
-- #####################################################################

-- ---------------------------------------------------------------------
-- 12. trg_auditoria_precio (RN-13)
-- Tipo: AFTER UPDATE OF precio ON vino
-- Qué garantiza: todo cambio de precio queda registrado con fecha y hora,
-- usuario, precio anterior y nuevo.
-- SECURITY DEFINER: la función se ejecuta con los permisos de su dueño
-- (propietario). Así el rol de la API no necesita INSERT sobre
-- auditoria_precio y no puede adulterar la auditoría (ver 007_roles.sql).
-- Usuario registrado: el usuario de la aplicación si la API lo informa con
-- SET LOCAL bodegas.usuario_app = '...'; si no, el rol de la sesión
-- (session_user, porque dentro de SECURITY DEFINER current_user sería el dueño).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_auditoria_precio()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF OLD.precio IS DISTINCT FROM NEW.precio THEN
        INSERT INTO auditoria_precio (cod_vino, precio_anterior, precio_nuevo, fecha_hora, usuario)
        VALUES (OLD.cod_vino, OLD.precio, NEW.precio, now(),
                COALESCE(NULLIF(current_setting('bodegas.usuario_app', true), ''), session_user));
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_auditoria_precio
AFTER UPDATE OF precio ON vino
FOR EACH ROW EXECUTE FUNCTION fn_trg_auditoria_precio();

-- ---------------------------------------------------------------------
-- 13. trg_composicion_suma_100 / trg_vino_requiere_composicion (RN-05)
-- Tipo: CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED
-- Qué garantiza: al cerrar la transacción, la composición de cada vino
-- suma exactamente 100. Se dispara:
--   * sobre composicion_vino (alta, cambio o baja de una cepa del corte);
--   * sobre vino al insertarlo: un vino nuevo debe darse de alta con su
--     composición en la misma transacción.
-- Es diferido porque un corte 85/15 se carga en dos INSERT: después del
-- primero la suma es 85 y sería rechazada si se validara en el acto.
-- Si el vino ya no existe (se borró y la composición se fue en cascada),
-- no hay nada que validar.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_verificar_corte_100()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_cod_vino INTEGER := CASE WHEN TG_OP = 'DELETE' THEN OLD.cod_vino ELSE NEW.cod_vino END;
    v_suma     NUMERIC;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vino WHERE cod_vino = v_cod_vino) THEN
        RETURN NULL;
    END IF;

    SELECT COALESCE(SUM(porcentaje), 0) INTO v_suma
      FROM composicion_vino
     WHERE cod_vino = v_cod_vino;

    IF v_suma <> 100 THEN
        RAISE EXCEPTION 'La composición del vino % debe sumar exactamente 100%% (suma actual: %). (RN-05)',
            v_cod_vino, v_suma;
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_composicion_suma_100
AFTER INSERT OR UPDATE OR DELETE ON composicion_vino
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_trg_verificar_corte_100();

CREATE CONSTRAINT TRIGGER trg_vino_requiere_composicion
AFTER INSERT ON vino
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_trg_verificar_corte_100();
