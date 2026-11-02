-- =====================================================================
-- 007_roles.sql  ·  Bodegas del Atuel  ·  PostgreSQL 14+
-- Etapa 2: roles con privilegios mínimos.
--
--   propietario   Dueño de todos los objetos. Aplica migraciones. NO lo usa la API.
--   app_rw        Rol de la API: DML sobre tablas + EXECUTE de funciones y
--                 procedimientos. No puede crear ni alterar objetos, ni
--                 tocar la auditoría salvo para leerla.
--   solo_lectura  Reportes: SELECT sobre tablas y vistas.
--
-- CONTRASEÑAS: no van en el repositorio. Los roles se crean sin contraseña
-- (no pueden iniciar sesión por red hasta tenerla) y se asignan aparte con
-- db/scripts/asignar_passwords.sql, tomando los valores de variables de
-- entorno (ver .env.example y el README).
--
-- Este script debe ejecutarlo un superusuario (o el dueño actual de los
-- objetos). Es idempotente: puede correrse más de una vez.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Creación de roles (idempotente, sin contraseña)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'propietario') THEN
        CREATE ROLE propietario LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN
        CREATE ROLE app_rw LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'solo_lectura') THEN
        CREATE ROLE solo_lectura LOGIN;
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- 2. Quitar privilegios públicos
--    Por defecto PUBLIC (cualquier rol) puede conectarse a la base y
--    ejecutar cualquier función. Se revoca todo y se otorga explícitamente.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO propietario, app_rw, solo_lectura', current_database());
    EXECUTE format('GRANT CREATE, TEMPORARY ON DATABASE %I TO propietario', current_database());
END $$;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS  IN SCHEMA public FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA public FROM PUBLIC;

-- ---------------------------------------------------------------------
-- 3. propietario: dueño del esquema y de todos los objetos
--    Se transfiere la propiedad de lo creado por 001..006. Ser dueño es lo
--    que le permite hacer ALTER/DROP; no hace falta darle GRANTs.
--    Las funciones SECURITY DEFINER (auditoría) pasan a ejecutarse como él.
-- ---------------------------------------------------------------------
ALTER SCHEMA public OWNER TO propietario;

DO $$
DECLARE
    r RECORD;
BEGIN
    -- Tablas, vistas, vistas materializadas y secuencias independientes
    FOR r IN
        SELECT c.relname,
               CASE c.relkind WHEN 'r' THEN 'TABLE' WHEN 'v' THEN 'VIEW'
                              WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'S' THEN 'SEQUENCE' END AS kind
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public'
           AND c.relkind IN ('r', 'v', 'm', 'S')
           -- las secuencias de columnas IDENTITY cambian de dueño con su tabla
           AND NOT EXISTS (SELECT 1 FROM pg_depend d
                            WHERE d.objid = c.oid AND d.deptype IN ('a', 'i')
                              AND c.relkind = 'S')
    LOOP
        EXECUTE format('ALTER %s public.%I OWNER TO propietario', r.kind, r.relname);
    END LOOP;

    -- Funciones y procedimientos
    FOR r IN
        SELECT p.oid::regprocedure AS firma,
               CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END AS kind
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
    LOOP
        EXECUTE format('ALTER %s %s OWNER TO propietario', r.kind, r.firma);
    END LOOP;

    -- Tipos ENUM y dominios
    FOR r IN
        SELECT t.typname,
               CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END AS kind
          FROM pg_type t
          JOIN pg_namespace n ON n.oid = t.typnamespace
         WHERE n.nspname = 'public'
           AND t.typtype IN ('e', 'd')
    LOOP
        EXECUTE format('ALTER %s public.%I OWNER TO propietario', r.kind, r.typname);
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 4. app_rw: rol de la API
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO app_rw;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_rw;
-- La auditoría solo la escribe el trigger (SECURITY DEFINER): la API la lee.
REVOKE INSERT, UPDATE, DELETE ON auditoria_precio FROM app_rw;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_rw;
GRANT EXECUTE ON ALL FUNCTIONS  IN SCHEMA public TO app_rw;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO app_rw;

-- ---------------------------------------------------------------------
-- 5. solo_lectura: reportes
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO solo_lectura;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO solo_lectura;
-- Funciones de cálculo (STABLE/IMMUTABLE) que usan las vistas y reportes.
GRANT EXECUTE ON FUNCTION fn_stock_sala(INTEGER, INTEGER),
                          fn_total_comprobante(INTEGER),
                          fn_descuento_cliente(tipo_cliente),
                          fn_antiguedad_anios(DATE),
                          fn_subtotal_renglon(INTEGER, NUMERIC, NUMERIC)
      TO solo_lectura;

-- ---------------------------------------------------------------------
-- 6. Privilegios por defecto para objetos FUTUROS
--    ALTER DEFAULT PRIVILEGES solo afecta objetos creados por el rol
--    indicado en FOR ROLE: como las migraciones siguientes (008_indices...)
--    las aplica propietario, se configura para él.
-- ---------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE propietario IN SCHEMA public
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE propietario IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE propietario IN SCHEMA public
    GRANT SELECT ON TABLES TO solo_lectura;
ALTER DEFAULT PRIVILEGES FOR ROLE propietario IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE propietario IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO app_rw;
