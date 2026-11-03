# Carga masiva · `db/seed/`

Genera y carga un dataset **coherente y reproducible** de Bodegas del Atuel: 30 tablas, 150.000 comprobantes y unos 516.000 renglones de venta. El detalle de cómo se generan los datos, la estrategia frente a los triggers y los resultados está en [`docs/informe_etapa3.md`](../../docs/informe_etapa3.md).

## Contenido

| Archivo | Qué es |
|---|---|
| `seed_db.py` | Script de carga (Python + psycopg2 + Faker, sin ORM) |
| `requirements.txt` | Versiones fijas de las dependencias (necesarias para reproducir los mismos datos) |
| `cepas.csv`, `maridajes.csv`, `departamentos.csv`, `localidades.csv` | Catálogos reales (no se generan al azar) |
| `dump_completo.sql.gz` | Volcado de la base ya cargada (semilla 42, fecha de referencia 2026-11-01) |

## Requisitos

- PostgreSQL 14 o superior (probado en 16 y 18.6) con la base creada y las migraciones `db/migrations/001` a `007` aplicadas.
- Python 3.10 o superior.
- Los roles de `007_roles.sql` con contraseña asignada (`db/scripts/asignar_passwords.sql`).

## Pasos

Desde la raíz del repositorio.

### 1. Crear la base y aplicar las migraciones

**PowerShell (Windows)**
```powershell
psql -U postgres -c "DROP DATABASE IF EXISTS bodegas_atuel WITH (FORCE)" -c "CREATE DATABASE bodegas_atuel"
Get-ChildItem db\migrations\*.sql | Sort-Object Name | ForEach-Object {
    psql -U postgres -d bodegas_atuel -v ON_ERROR_STOP=1 -f $_.FullName
}
psql -U postgres -d bodegas_atuel -v propietario_pass=CLAVE1 -v app_rw_pass=CLAVE2 -v solo_lectura_pass=CLAVE3 -f db\scripts\asignar_passwords.sql
```

**bash (Linux / macOS)**
```bash
psql -U postgres -c "DROP DATABASE IF EXISTS bodegas_atuel WITH (FORCE)" -c "CREATE DATABASE bodegas_atuel"
for f in db/migrations/*.sql; do psql -U postgres -d bodegas_atuel -v ON_ERROR_STOP=1 -f "$f"; done
psql -U postgres -d bodegas_atuel -v propietario_pass=CLAVE1 -v app_rw_pass=CLAVE2 -v solo_lectura_pass=CLAVE3 -f db/scripts/asignar_passwords.sql
```

### 2. Instalar las dependencias

```bash
python -m venv venv
venv\Scripts\activate          # Windows   (Linux/macOS: source venv/bin/activate)
pip install -r db/seed/requirements.txt
```

### 3. Configurar la conexión

El script usa las variables de entorno estándar de PostgreSQL (`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`). Conviene ejecutarlo como **`propietario`**, el dueño de las tablas (necesita poder hacer `TRUNCATE` y `ALTER TABLE ... DISABLE TRIGGER USER`).

```powershell
$env:PGHOST="localhost"; $env:PGDATABASE="bodegas_atuel"; $env:PGUSER="propietario"; $env:PGPASSWORD="CLAVE1"
```

Si existe un archivo `.env` en la raíz del repo (ver `.env.example`), el script lo lee, pero las variables ya definidas en el entorno tienen prioridad. **El `.env` nunca se sube al repositorio.**

### 4. Ejecutar

```bash
python db/seed/seed_db.py
```

Opciones:

| Opción | Efecto |
|---|---|
| `--fecha-ref AAAA-MM-DD` | Último día simulado (por defecto `2026-11-01`). Para que las consultas con `CURRENT_DATE` ("última semana", "último trimestre") encuentren datos recientes, usar la fecha del día de la demo. |
| `--reporte RUTA.md` | Escribe un reporte en Markdown con filas por tabla, tiempos, la medición fila por fila vs. lotes y las consultas de control. |
| `--sin-benchmark` | Omite la medición fila por fila vs. lotes (unos segundos menos). |

**Duración:** alrededor de 1 minuto. El script:

1. Vacía las 30 tablas (`TRUNCATE ... RESTART IDENTITY CASCADE`).
2. Carga los catálogos desde CSV.
3. Genera los datos maestros (bodegas, salas, empleados, vinos, fincas, clientes…).
4. Simula 6 años de operación (ingresos, transferencias y ventas).
5. Mide la inserción fila por fila vs. `execute_values` vs. `COPY`.
6. Carga los movimientos con los triggers de usuario deshabilitados y los vuelve a habilitar.
7. Ejecuta 19 consultas de control. **Si alguna falla, revierte toda la carga** y la base queda como estaba.

Todo ocurre en **una sola transacción**: o se carga todo o no se carga nada.

### 5. Verificar

```bash
psql -U postgres -d bodegas_atuel -f tests/db_tests.sql
```

Resultado esperado: `TOTAL: 92 casos · 92 OK · 0 FALLOS`.

## Reproducibilidad

Con la misma semilla (`SEED = 42`), la misma `--fecha-ref` y las versiones de `requirements.txt`, dos ejecuciones producen **exactamente los mismos datos** (verificado comparando huellas md5 de las tablas).

## Volcado y restauración

```bash
# Generar
pg_dump -U postgres -d bodegas_atuel | gzip -9 > db/seed/dump_completo.sql.gz

# Restaurar en una base nueva (los roles propietario, app_rw y solo_lectura deben existir)
createdb -U postgres bodegas_restore
gunzip -c db/seed/dump_completo.sql.gz | psql -U postgres -d bodegas_restore
```

En Windows sin `gunzip`, descomprimir con 7-Zip y ejecutar `psql -U postgres -d bodegas_restore -f dump_completo.sql`.

## Problemas frecuentes

| Mensaje | Causa y solución |
|---|---|
| `must be owner of table ...` | Se ejecutó con un rol que no es dueño de las tablas. Usar `propietario` (o `postgres`). |
| `password authentication failed` | Revisar `PGUSER` / `PGPASSWORD`, o asignar las contraseñas con `db/scripts/asignar_passwords.sql`. |
| `relation "..." does not exist` | Faltan migraciones: aplicar `001` a `007` en orden. |
| `ERROR: Las consultas de control encontraron inconsistencias` | No debería ocurrir con el script sin modificar. La carga se revirtió; el detalle de qué control falló está en la salida. |
