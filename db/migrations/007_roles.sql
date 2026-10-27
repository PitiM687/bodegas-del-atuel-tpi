-- =====================================================================
-- 007_roles.sql  ·  Bodegas del Atuel  ·  PostgreSQL 14+
-- Etapa 2: Seguridad y Control de Acceso Basado en Roles (RBAC)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Creación idempotente de roles del sistema
-- ---------------------------------------------------------------------
DO $$
BEGIN
    -- Rol Administrador / Propietario
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'propietario') THEN
        CREATE ROLE propietario WITH LOGIN PASSWORD 'PropietarioPass2026!';
    END IF;

    -- Rol Aplicación API (Lectura y Escritura)
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN
        CREATE ROLE app_rw WITH LOGIN PASSWORD 'AppRwPass2026!';
    END IF;

    -- Rol Analista / Auditor (Solo Lectura)
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'solo_lectura') THEN
        CREATE ROLE solo_lectura WITH LOGIN PASSWORD 'SoloLecturaPass2026!';
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- 2. Permisos sobre el esquema public
-- ---------------------------------------------------------------------
GRANT ALL ON SCHEMA public TO propietario;
GRANT USAGE ON SCHEMA public TO app_rw;
GRANT USAGE ON SCHEMA public TO solo_lectura;

-- ---------------------------------------------------------------------
-- 3. Permisos para ROL: propietario (Control Total)
-- ---------------------------------------------------------------------
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO propietario;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO propietario;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO propietario;
GRANT ALL PRIVILEGES ON ALL PROCEDURES IN SCHEMA public TO propietario;

-- ---------------------------------------------------------------------
-- 4. Permisos para ROL: app_rw (API Backend - DML y Ejecución)
-- ---------------------------------------------------------------------
-- Otorgar SELECT, INSERT, UPDATE, DELETE en todas las tablas y vistas actuales
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_rw;

-- Otorgar uso de secuencias para inserciones con claves autonuméricas
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_rw;

-- Otorgar ejecución de funciones de negocio y procedimientos transaccionales
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_rw;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO app_rw;

-- ---------------------------------------------------------------------
-- 5. Permisos para ROL: solo_lectura (Reportes y Monitoreo)
-- ---------------------------------------------------------------------
-- Otorgar SELECT exclusivo en tablas y vistas
GRANT SELECT ON ALL TABLES IN SCHEMA public TO solo_lectura;

-- Permitir consultar el estado de secuencias pero sin modificarlas
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO solo_lectura;

-- ---------------------------------------------------------------------
-- 6. Configuración de privilegios por defecto (Default Privileges)
-- Garantiza que tablas/vistas futuras hereden automáticamente los permisos.
-- ---------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO propietario;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO solo_lectura;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON ROUTINES TO app_rw;