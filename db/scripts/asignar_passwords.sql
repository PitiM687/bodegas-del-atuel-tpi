-- =====================================================================
-- db/scripts/asignar_passwords.sql
-- Asigna las contraseñas de los roles SIN escribirlas en el repositorio.
-- Los valores llegan como variables de psql (-v), leídas del entorno:
--
--   psql -d bodegas_atuel \
--        -v propietario_pass="$PG_PROPIETARIO_PASSWORD" \
--        -v app_rw_pass="$PG_APP_RW_PASSWORD" \
--        -v solo_lectura_pass="$PG_SOLO_LECTURA_PASSWORD" \
--        -f db/scripts/asignar_passwords.sql
--
-- En PowerShell:  -v app_rw_pass="$env:PG_APP_RW_PASSWORD"  (idem el resto)
-- La sintaxis :'variable' hace que psql la inserte como literal entre
-- comillas, escapada correctamente.
-- =====================================================================
\set ON_ERROR_STOP on

ALTER ROLE propietario  PASSWORD :'propietario_pass';
ALTER ROLE app_rw       PASSWORD :'app_rw_pass';
ALTER ROLE solo_lectura PASSWORD :'solo_lectura_pass';
