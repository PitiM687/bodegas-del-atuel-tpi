-- =====================================================================
-- 005_triggers.sql  ·  Bodegas del Atuel  ·  PostgreSQL 14+
-- Etapa 2: Triggers y Reglas de Negocio (RN-05, RN-08, RN-09, RN-10, RN-11, RN-12, RN-13)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. trg_validar_stock_venta (RN-09)
-- Tipo: BEFORE INSERT ON renglon_comprobante
-- Qué garantiza: Rechaza la venta si la sala no tiene stock suficiente.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_validar_stock_venta()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_id_sala     INTEGER;
    v_stock_disp  INTEGER;
BEGIN
    SELECT id_sala INTO v_id_sala FROM comprobante WHERE nro = NEW.nro;

    v_stock_disp := fn_stock_sala(v_id_sala, NEW.cod_vino);

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
-- 2. trg_actualizar_stock_y_totales (RN-08 y RN-09)
-- Tipo: AFTER INSERT ON renglon_comprobante
-- Qué garantiza: Descuenta el stock de la sala y recalcula el subtotal,
-- descuento y total en la cabecera del comprobante.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_actualizar_stock_y_totales()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_id_sala    INTEGER;
    v_subtotal   NUMERIC(14,2);
    v_descuento  NUMERIC(14,2);
    v_total      NUMERIC(14,2);
BEGIN
    SELECT id_sala INTO v_id_sala FROM comprobante WHERE nro = NEW.nro;

    UPDATE stock_sala
    SET cantidad = cantidad - NEW.cantidad
    WHERE id_sala = v_id_sala AND cod_vino = NEW.cod_vino;

    SELECT subtotal, descuento, total
    INTO v_subtotal, v_descuento, v_total
    FROM fn_total_comprobante(NEW.nro);

    UPDATE comprobante
    SET subtotal  = v_subtotal,
        descuento = v_descuento,
        total     = v_total
    WHERE nro = NEW.nro;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_actualizar_stock_y_totales
AFTER INSERT ON renglon_comprobante
FOR EACH ROW EXECUTE FUNCTION fn_trg_actualizar_stock_y_totales();

-- ---------------------------------------------------------------------
-- 3. trg_transicion_estados_documento (RN-10 y RN-11)
-- Tipo: BEFORE UPDATE ON ingreso / transferencia
-- Qué garantiza: Transiciones permitidas (en_confeccion -> terminado -> procesado).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_control_estados()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.estado = NEW.estado THEN
        RETURN NEW;
    END IF;

    IF OLD.estado = 'en_confeccion' AND NEW.estado = 'terminado' THEN
        RETURN NEW;
    ELSIF OLD.estado = 'terminado' AND NEW.estado = 'procesado' THEN
        RETURN NEW;
    ELSE
        RAISE EXCEPTION 'Transición de estado inválida: de "%" a "%". El ciclo permitido es en_confeccion -> terminado -> procesado sin retroceso. (RN-10 / RN-11)',
            OLD.estado, NEW.estado;
    END IF;
END;
$$;

CREATE TRIGGER trg_estado_ingreso
BEFORE UPDATE OF estado ON ingreso
FOR EACH ROW EXECUTE FUNCTION fn_trg_control_estados();

CREATE TRIGGER trg_estado_transferencia
BEFORE UPDATE OF estado ON transferencia
FOR EACH ROW EXECUTE FUNCTION fn_trg_control_estados();

-- ---------------------------------------------------------------------
-- 4. trg_bloqueo_renglones_documento (RN-12)
-- Tipo: BEFORE INSERT OR UPDATE OR DELETE ON renglon_ingreso / renglon_transferencia
-- Qué garantiza: Prohíbe modificar renglones si el documento no está "en_confeccion".
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_bloqueo_renglones_ingreso()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_estado estado_documento;
    v_cod    INTEGER;
BEGIN
    v_cod := CASE WHEN TG_OP = 'DELETE' THEN OLD.cod_ingreso ELSE NEW.cod_ingreso END;

    SELECT estado INTO v_estado FROM ingreso WHERE cod_ingreso = v_cod;

    IF v_estado IS DISTINCT FROM 'en_confeccion' THEN
        RAISE EXCEPTION 'No se pueden modificar los renglones de un ingreso que no está en confección (estado actual: %). (RN-12)',
            v_estado;
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
    v_nro    INTEGER;
BEGIN
    v_nro := CASE WHEN TG_OP = 'DELETE' THEN OLD.nro_solicitud ELSE NEW.nro_solicitud END;

    SELECT estado INTO v_estado FROM transferencia WHERE nro_solicitud = v_nro;

    IF v_estado IS DISTINCT FROM 'en_confeccion' THEN
        RAISE EXCEPTION 'No se pueden modificar los renglones de una transferencia que no está en confección (estado actual: %). (RN-12)',
            v_estado;
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_bloqueo_renglones_transferencia
BEFORE INSERT OR UPDATE OR DELETE ON renglon_transferencia
FOR EACH ROW EXECUTE FUNCTION fn_trg_bloqueo_renglones_transferencia();

-- ---------------------------------------------------------------------
-- 5. trg_fecha_transferencia (RN-11)
-- Tipo: BEFORE INSERT OR UPDATE ON transferencia
-- Qué garantiza: Establece la fecha de confección al día de hoy y prohíbe cambiarla.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_fecha_transferencia()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.fecha_confeccion := CURRENT_DATE;
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.fecha_confeccion IS DISTINCT FROM OLD.fecha_confeccion THEN
            RAISE EXCEPTION 'La fecha de confección de una transferencia no puede ser modificada. (RN-11)';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_fecha_transferencia
BEFORE INSERT OR UPDATE OF fecha_confeccion ON transferencia
FOR EACH ROW EXECUTE FUNCTION fn_trg_fecha_transferencia();

-- ---------------------------------------------------------------------
-- 6. trg_auditoria_precio (RN-13)
-- Tipo: AFTER UPDATE OF precio ON vino
-- Qué garantiza: Registra cambios de precio en auditoria_precio.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_auditoria_precio()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.precio IS DISTINCT FROM NEW.precio THEN
        INSERT INTO auditoria_precio (cod_vino, precio_anterior, precio_nuevo, fecha_hora, usuario)
        VALUES (OLD.cod_vino, OLD.precio, NEW.precio, now(), current_user);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_auditoria_precio
AFTER UPDATE OF precio ON vino
FOR EACH ROW EXECUTE FUNCTION fn_trg_auditoria_precio();

-- ---------------------------------------------------------------------
-- 7. trg_composicion_suma_100 (RN-05)
-- Tipo: CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED ON composicion_vino
-- Qué garantiza: Al hacer COMMIT, valida que los porcentajes sumen 100%.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_verificar_corte_100()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_cod_vino INTEGER;
    v_suma     NUMERIC(5,2);
BEGIN
    v_cod_vino := CASE WHEN TG_OP = 'DELETE' THEN OLD.cod_vino ELSE NEW.cod_vino END;

    SELECT COALESCE(SUM(porcentaje), 0) INTO v_suma
    FROM composicion_vino
    WHERE cod_vino = v_cod_vino;

    IF v_suma <> 100.00 THEN
        RAISE EXCEPTION 'La suma de porcentajes de corte para el vino % debe ser exactamente 100%% (suma actual: %). (RN-05)',
            v_cod_vino, v_suma;
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_composicion_suma_100
AFTER INSERT OR UPDATE OR DELETE ON composicion_vino
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fn_trg_verificar_corte_100();