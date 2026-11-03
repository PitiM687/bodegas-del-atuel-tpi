#!/bin/bash
# =====================================================================
# docker/db/init/01_migraciones.sh
# Lo ejecuta la imagen oficial de PostgreSQL la PRIMERA vez que arranca el
# contenedor (volumen de datos vacío). Aplica las migraciones en orden y
# asigna las contraseñas de los roles tomándolas de variables de entorno.
# Si cualquier paso falla, el contenedor no termina de inicializarse.
# =====================================================================
set -euo pipefail

echo "== Bodegas del Atuel: aplicando migraciones =="
for f in /migrations/*.sql; do
    echo "-> $(basename "$f")"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -q -f "$f"
done

echo "-> contraseñas de los roles"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -q \
     -v propietario_pass="$PG_PROPIETARIO_PASSWORD" \
     -v app_rw_pass="$PG_APP_RW_PASSWORD" \
     -v solo_lectura_pass="$PG_SOLO_LECTURA_PASSWORD" \
     -f /scripts/asignar_passwords.sql

echo "== Base lista: $(psql -At --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'") tablas =="
