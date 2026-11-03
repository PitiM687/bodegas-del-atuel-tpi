# Bodegas del Atuel · TPI Bases de Datos

**UTN Facultad Regional San Rafael · Ingeniería en Sistemas · 3.° año · 2026**

Sistema de gestión y distribución de una empresa vitivinícola: producción de uva, bodegas y vinos, clientes con descuentos por tipo, ventas en salas, stock en salas y depósito central, ingresos y transferencias.

**Motor:** PostgreSQL 18.6 (compatible con 14 o superior) · **Carga de datos:** Python 3.10 + psycopg2 + Faker · **Sin ORM:** todo el SQL está escrito a mano.

---

## Estado del proyecto

| Etapa | Estado | Entregables |
|---|---|---|
| 1. Modelado | ✅ Terminada | DER ([PDF](docs/proyecto%20integrador.pdf), [fuente .dbml](docs/der_bodegas_del_atuel.dbml)), [documento de modelado](docs/TPI%20Bodegas%20del%20Atuel%20–%20Etapa%201%20Modelado.docx), [`001_esquema.sql`](db/migrations/001_esquema.sql) |
| 2. Integridad y lógica en la base | ✅ Terminada | [`002`](db/migrations/002_constraints.sql) a [`007`](db/migrations/007_roles.sql), [92 pruebas](tests/db_tests.sql), [trazabilidad](docs/trazabilidad.md), [concurrencia](docs/concurrencia/README.md) |
| 3. Carga masiva | ✅ Terminada | [`seed_db.py`](db/seed/seed_db.py), [instrucciones](db/seed/README.md), [informe](docs/informe_etapa3.md), [dump](db/seed/dump_completo.sql.gz) |
| 4. Índices y rendimiento | ✅ Terminada | [`008_indices.sql`](db/migrations/008_indices.sql), [informe](docs/informe_etapa4.md), [planes completos](docs/etapa4/anexo_planes.md) |
| 5. Consultas SQL | ⏳ Próxima | `consultas/insert.sql`, `update.sql`, `delete.sql`, `select.sql` |
| 6. API REST | ⏳ Pendiente | |
| 7. Front | ⏳ Pendiente | |
| 8. Despliegue en la nube | ⏳ Pendiente | |
| 9. Documentación y defensa | ⏳ Pendiente | |

---

## Qué se hizo

### Etapa 1 · Modelado
- 30 tablas en 3FN.
- **Jerarquía de clientes:** supertipo `cliente` y subtipos `socio`, `distribuidor` y `exportador`. Se eligió esta opción porque `comprobante` necesita una sola FK a cliente y los permisos de exportación solo existen para exportadores.
- **Parcela** es una entidad débil, con clave `(finca, nro_parcela)`.
- **Dos dependencias transitivas** resueltas: el encargado regional va en `localidad` (no en la sala) y la provincia en `departamento` (no en la finca).
- **Tipos:** dinero con `NUMERIC`, estados con `ENUM` y CUIT con un `DOMAIN` de 11 dígitos.

### Etapa 2 · Las reglas viven en la base
Cada regla de negocio RN-01 a RN-15 tiene su mecanismo en la base y casos de prueba. La [tabla de trazabilidad](docs/trazabilidad.md) muestra regla → mecanismo → caso.

| Mínimo exigido | Implementado |
|---|---|
| 4 UNIQUE · 8 CHECK (uno entre columnas) · 3 DEFAULT | 9 UNIQUE · 28 CHECK (2 entre columnas) · 13 DEFAULT |
| 1 ENUM y 1 DOMAIN | 6 ENUM y 1 DOMAIN |
| 4 funciones · 2 procedimientos | 5 funciones · 2 procedimientos transaccionales |
| 6 triggers (BEFORE, AFTER y constraint trigger diferido) | 21 triggers (6 diferidos) |
| 3 vistas · 3 roles | 3 vistas · 3 roles con privilegios mínimos |

Decisiones principales:
- **Los importes los calcula la base, no quien inserta.** El renglón toma el precio de `vino` y el descuento del cliente, y la cabecera se recalcula sola. Si alguien intenta vender un vino de $12.500 a $1, la base usa $12.500. Cargar un total a mano da error.
- **A `procesado` solo se llega por el procedimiento.** Un `UPDATE estado = 'procesado'` directo dejaría un ingreso procesado sin mover stock, así que la base lo rechaza.
- **Concurrencia:** el trigger de venta bloquea la fila de stock (`FOR UPDATE`, nivel READ COMMITTED). Con dos sesiones vendiendo la última botella al mismo tiempo, la segunda espera y es rechazada. La [demostración](docs/concurrencia/README.md) compara tres escenarios: sin bloqueo, con `FOR UPDATE` y con el trigger.
- **Pruebas:** [`tests/db_tests.sql`](tests/db_tests.sql) tiene **92 casos**. Cada caso que debe fallar verifica el código de error exacto (SQLSTATE). Resultado: **92/92 en PostgreSQL 18.6**.
- **Seguridad:** la API va a usar el rol `app_rw`, que no es dueño de las tablas ni puede alterar la auditoría. Las contraseñas no están en el repositorio.

### Etapa 3 · Carga masiva
- **Las 30 tablas con datos:** 150.000 comprobantes, 515.977 renglones, 20.000 clientes, más fincas, lotes, análisis, ingresos, transferencias, etc.
- **Datos coherentes.** El script **simula 6 años de operación día por día**: las bodegas reponen el depósito, las salas piden transferencias y las ventas solo consumen stock disponible. Los precios suben cada semestre y cada aumento queda auditado.
- **19 consultas de control en 0**, incluida la conciliación exacta "ingresos − transferencias − ventas = stock".
- **Reproducible:** semilla 42 y fecha de referencia fija. Dos ejecuciones generan datos idénticos.
- **Fila por fila contra lotes:** `execute_values` es **8 veces** más rápido y `COPY`, **52 veces**.

### Etapa 4 · Índices (medido en PostgreSQL 18.6)
8 índices: compuesto, 2 parciales, 4 sobre claves foráneas (uno con `INCLUDE`) y un BRIN.

| Consulta | Antes | Después | Mejora |
|---|---:|---:|---:|
| S3: clientes que compraron en una sala la última semana | 36,2 ms | 0,11 ms | ×332 |
| Historial de compras de un cliente | 10,1 ms | 0,13 ms | ×79 |
| Borrar un vino (control de la FK, RN-14) | 35,4 ms | 0,99 ms | ×36 |
| S8: ventas por sala del último trimestre (BRIN) | 43,3 ms | 5,0 ms | ×8,6 |

El [informe](docs/informe_etapa4.md) también incluye:
- el orden de columnas del índice compuesto;
- la comparación BRIN contra B-tree;
- un índice evaluado y descartado (`cliente(tipo)`);
- el costo de escritura de los índices;
- los casos en que el planificador no usa un índice existente.

---

## Cómo levantarlo con Docker (recomendado)

Requisito: Docker Desktop. Desde la raíz del repositorio:

```powershell
copy .env.example .env        # y completar las 4 contraseñas (PGPASSWORD y las de los 3 roles)
docker compose up -d          # crea la base y aplica las migraciones 001 a 008 (solo la primera vez)
docker compose logs db        # tiene que aparecer "Base lista: 30 tablas"
docker compose --profile seed run --rm seed                                  # carga masiva (~1 minuto)
docker compose exec db psql -U postgres -d bodegas_atuel -f /tests/db_tests.sql   # TOTAL: 92 casos · 92 OK
```

- La base queda en `localhost:5432` (o en el puerto de `DB_PORT`), y se puede abrir con pgAdmin o DBeaver.
- Para empezar de cero: `docker compose down -v` borra el contenedor **y los datos**. Las migraciones solo se aplican cuando el volumen está vacío.
- Las migraciones se aplican con `docker/db/init/01_migraciones.sh`, que es el mismo orden que la instalación manual.

## Cómo verificarlo sin Docker (5 minutos)

Requisitos: PostgreSQL 14+ y Python 3.10+. Desde la raíz del repositorio, en PowerShell:

```powershell
# 1. Base desde cero: migraciones 001 a 008
psql -U postgres -c "DROP DATABASE IF EXISTS bodegas_atuel WITH (FORCE)" -c "CREATE DATABASE bodegas_atuel"
Get-ChildItem db\migrations\*.sql | Sort-Object Name | % { psql -U postgres -d bodegas_atuel -v ON_ERROR_STOP=1 -f $_.FullName }
psql -U postgres -d bodegas_atuel -v propietario_pass=CLAVE1 -v app_rw_pass=CLAVE2 -v solo_lectura_pass=CLAVE3 -f db\scripts\asignar_passwords.sql

# 2. Datos (alrededor de 1 minuto)
python -m venv venv; .\venv\Scripts\pip install -r db\seed\requirements.txt
$env:PGHOST="localhost"; $env:PGDATABASE="bodegas_atuel"; $env:PGUSER="propietario"; $env:PGPASSWORD="CLAVE1"
.\venv\Scripts\python db\seed\seed_db.py

# 3. Pruebas de las reglas de negocio -> TOTAL: 92 casos · 92 OK
psql -U postgres -d bodegas_atuel -f tests\db_tests.sql
```

Alternativa sin Python: restaurar el dump con los datos ya cargados.

```powershell
psql -U postgres -c "CREATE DATABASE bodegas_atuel"
# descomprimir db\seed\dump_completo.sql.gz (por ejemplo, con 7-Zip) y ejecutar:
psql -U postgres -d bodegas_atuel -f dump_completo.sql
```

Para restaurar el dump tienen que existir los roles dueños de los objetos. Se crean una sola vez por servidor:

```powershell
psql -U postgres -c "CREATE ROLE propietario LOGIN" -c "CREATE ROLE app_rw LOGIN" -c "CREATE ROLE solo_lectura LOGIN"
```

---

## Qué sigue

| Etapa | Plan |
|---|---|
| **5. Consultas SQL** | Resolver U1–U6, I1–I6, D1–D6 y S1–S12 en `consultas/`. Cada sentencia que modifica datos se prueba en una transacción (estado antes → sentencia → estado después → `ROLLBACK`). Las consultas avanzadas usan CTE, funciones de ventana y `NOT EXISTS`. El dataset ya tiene datos para todas las consignas. |
| **6. API REST** | Propuesta: **Python + FastAPI + psycopg2** con pool de conexiones, una capa de acceso a datos con SQL parametrizado y conexión con el rol `app_rw`. Los errores de PostgreSQL se traducen a HTTP por SQLSTATE (`P0001` → 409, `23514` → 422; `23001`/`23503` → 409 para RN-14). Además: OpenAPI automático, 8 o más pruebas automáticas y un servicio más en `docker-compose.yml`. |
| **7. Front** | HTML/JS simple que consume solo la API: catálogo, alta de vino con composición, nueva venta, transferencias y tablero. |
| **8. Nube** | Comparar Neon, Supabase y Render. Requisitos: HTTPS, `sslmode=require`, acceso restringido, secretos en el proveedor, y backup y restauración probados. |
| **9. Defensa** | Informe final, README completo y demo en vivo. |

---

## Preguntas para los docentes

1. **Modalidad.** El enunciado pide grupos de 3 a 4 integrantes y penaliza un historial de Git de un solo autor. Estoy haciendo el trabajo solo: ¿se puede presentar individualmente? ¿Cambia algún requisito o la evaluación?
2. **"Último trimestre" y "último mes"** (S7, S8, I1). Los interpreté como los últimos 3 meses o 30 días contados desde `CURRENT_DATE`, no como el trimestre o mes calendario anterior. ¿Es correcto?
3. **Consigna U6** (subir al 35 % el descuento de los exportadores con más de 3 permisos). Por eso el descuento se guarda en cada cliente, inicializado según su tipo, y no se calcula siempre desde el tipo. ¿Está bien esa decisión?
4. **Consigna D1** (borrar comprobantes de más de 5 años). Lo traté como una depuración de historial: borrar un comprobante **no devuelve** el stock a la sala. Un renglón suelto de una venta emitida no se puede borrar. ¿Es la interpretación esperada?
5. **Consigna U1** (recalcular los totales aplicando el descuento del tipo de cliente). En un renglón ya emitido solo se permite cambiar el descuento, y los totales se recalculan solos. ¿Alcanza con eso?
6. **API:** ¿hay algún lenguaje o framework preferido, o va bien Python + FastAPI?
7. **Dump en el repositorio.** El volcado comprimido pesa 6,2 MB. ¿Lo dejo en el repositorio o alcanza con las instrucciones para generarlo?

---

## Estructura

```
docker-compose.yml   base de datos (y, en las próximas etapas, API y front)
docker/db/init/      script que aplica las migraciones al crear el contenedor
db/
  migrations/   001_esquema … 008_indices (se aplican en orden)
  scripts/      asignar_passwords.sql, medir_indices.py
  seed/         seed_db.py, catálogos CSV, requirements.txt, dump_completo.sql.gz
tests/          db_tests.sql (92 casos RN-01 a RN-15)
docs/           DER, informes por etapa, trazabilidad, concurrencia/, etapa4/
consultas/      (Etapa 5)
```
