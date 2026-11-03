# Trazabilidad: regla de negocio → mecanismo → caso de prueba

**TPI Bases de Datos · Bodegas del Atuel · Etapa 2**

Cada regla del enunciado (sección 4) está protegida por al menos un mecanismo **dentro de la base de datos** y tiene casos en [`tests/db_tests.sql`](../tests/db_tests.sql). Los números de caso son los que imprime la suite en la columna `#`.

```bash
psql -U postgres -d bodegas_atuel -f tests/db_tests.sql
# TOTAL: 92 casos · 92 OK · 0 FALLOS · 0 omitidos   (PostgreSQL 18.6)
```

Tipos de caso: **debe fallar** (se indica el SQLSTATE esperado), **debe funcionar** o **verifica** (consulta sobre el estado resultante).

---

## 1. Tabla de trazabilidad

| Regla | Enunciado | Mecanismo en la base | Dónde | Casos |
|---|---|---|---|---|
| **RN-01** | El precio de un vino es único para toda la red y mayor que cero | Atributo `vino.precio` (no existe precio por sala) + `CHECK ck_vino_precio (precio > 0)` | 001, 002 | **1** verifica que solo `vino` tiene precio de lista · **2** precio 0 → `23514` · **3** precio negativo → `23514` |
| **RN-02** | Una sala pertenece a una sola localidad; cada localidad tiene un único encargado regional | FK `sala_venta.id_localidad NOT NULL` · `localidad.encargado_regional NOT NULL` (3FN: el encargado depende solo de la localidad) | 001 | **4** sala sin localidad → `23502` · **5** localidad inexistente → `23503` · **6** localidad sin encargado → `23502` · **7** verifica que `sala_venta` no tiene encargado |
| **RN-03** | Cada empleado trabaja en una sola sala | FK `empleado.id_sala NOT NULL` + PK por CUIT | 001 | **8** alta OK · **9** sin sala → `23502` · **10** mismo CUIT en otra sala → `23505` |
| **RN-04** | Una parcela tiene una sola cepa y se cosecha como máximo una vez por campaña | FK `parcela.id_cepa NOT NULL` + `UNIQUE uq_lote_parcela_campania (id_finca, nro_parcela, campania)` | 001, 002 | **11** parcela sin cepa → `23502` · **12** primera cosecha OK · **13** segunda cosecha misma campaña → `23505` · **14** otra campaña OK |
| **RN-05** | Los porcentajes de corte de un vino suman exactamente 100 | `CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED`: `trg_composicion_suma_100` (en `composicion_vino`) y `trg_vino_requiere_composicion` (en `vino`) + `CHECK ck_composicion_porcentaje (0 < % ≤ 100)` | 002, 005 | **15** corte 85/15 OK · **16** suma 80 → `P0001` · **17** vino sin composición → `P0001` · **18** quitar una cepa → `P0001` · **19** porcentaje 120 → `23514` · **20** borrar un vino sin movimientos OK |
| **RN-06** | Descuento según el tipo de cliente: socio 10 %, distribuidor 20 %, exportador 30 % | `fn_descuento_cliente(tipo)` + trigger `trg_descuento_cliente` (completa el descuento, impide cambiar el tipo) + `CHECK ck_cliente_descuento (0..100)`. Jerarquía: `trg_subtipo_*` (disjunta) y `trg_cliente_requiere_subtipo` (total, diferido) | 002, 003, 005 | **21–23** 10/20/30 % automáticos · **24** descuento 150 → `23514` · **25** cambiar el tipo → `P0001` · **26** socio en `exportador` → `P0001` · **27** cliente sin subtipo → `P0001` |
| **RN-07** | Un exportador puede tener varios permisos; el vencimiento es posterior a la emisión | Tabla `permiso_exportacion` (FK a `exportador`) + **CHECK entre columnas** `ck_permiso_fechas (fecha_vencimiento > fecha_emision)` | 001, 002 | **28** dos permisos OK · **29** vencimiento anterior → `23514` · **30** vencimiento igual → `23514` · **31** permiso a un no exportador → `23503` |
| **RN-08** | El total es la suma de los renglones con el descuento aplicado; no se carga a mano | `fn_subtotal_renglon`, `fn_total_comprobante` · triggers `trg_completar_renglon_venta` (precio y descuento los pone la base), `trg_actualizar_stock_y_totales` (recalcula la cabecera), `trg_proteger_renglon_venta`, `trg_proteger_importes` · **CHECK entre columnas** `ck_comprobante_total (total = subtotal − descuento)` | 002, 003, 005 | **32** venta enviando precio $1 OK · **33** renglón con precio y descuento reales · **34** cabecera recalculada · **35** total a mano → `P0001` · **36** cabecera con importes → `P0001` · **37** cambiar cantidad → `P0001` · **38** quitar renglón → `P0001` · **39–40** cambiar solo el descuento recalcula (U1) |
| **RN-09** | No se vende más de lo que hay en stock; el stock nunca es negativo | Trigger `trg_validar_stock_venta` (BEFORE INSERT, con `FOR UPDATE`) + `CHECK ck_stock_sala_cantidad (cantidad >= 0)` y `ck_stock_deposito_cantidad` | 002, 005 | **41** la venta descuenta stock · **42** vender 9 con 8 → `P0001` · **43** vino sin stock en la sala → `P0001` · **44** stock negativo → `23514` · **45** los fallos no tocaron el stock. Concurrencia: [`concurrencia/`](concurrencia/README.md) |
| **RN-10** | Solo un ingreso terminado impacta en el depósito y pasa a procesado; sin retrocesos | `ENUM estado_documento` + `DEFAULT 'en_confeccion'` + trigger `trg_estado_ingreso` (transiciones; a `procesado` solo vía SP) + procedimiento `sp_procesar_ingreso` | 001, 004, 005 | **46** nace en confección · **47** nacer procesado → `P0001` · **48** estado inexistente → `22P02` · **49** terminar sin renglones → `P0001` · **50** procesar en confección → `P0001` · **51** terminar OK · **52** retroceder → `P0001` · **53** `UPDATE` directo a procesado → `P0001` · **54–55** procesar con el SP acredita el depósito · **56** procesar dos veces → `P0001` |
| **RN-11** | Igual que RN-10 para transferencias; la fecha de confección es la actual y no se modifica | Trigger `trg_fecha_transferencia` + `trg_estado_transferencia` + procedimiento `sp_procesar_transferencia` (valida existencia y stock vino por vino, bloquea con `FOR UPDATE`, todo o nada) | 004, 005 | **57** fecha enviada ignorada → hoy · **58** modificar la fecha → `P0001` · **59–60** transferir mueve depósito → sala · **61** `UPDATE` directo a procesado → `P0001` · **63** procesar sin stock → `P0001` · **64** sin cambios a medias |
| **RN-12** | Un documento que no está en confección no admite agregar, modificar ni quitar renglones | Triggers `trg_bloqueo_renglones_ingreso` y `trg_bloqueo_renglones_transferencia` (permiten el borrado en cascada desde la cabecera) | 005 | **65** agregar → `P0001` · **66** modificar → `P0001` · **67** quitar → `P0001` · **68** en transferencia → `P0001` · **69** borrar el ingreso completo OK (D5) |
| **RN-13** | Todo cambio de precio queda auditado (fecha, usuario, precio anterior y nuevo) | Trigger `trg_auditoria_precio` (AFTER UPDATE, `SECURITY DEFINER`) + tabla `auditoria_precio` + permisos: `app_rw` solo puede leerla | 001, 005, 007 | **70–71** un cambio = un registro completo · **72–73** cambiar otro dato no audita · **74** la API no puede borrar la auditoría → `42501` · **75** ni insertar una falsa → `42501` · **76–77** un cambio hecho por la API queda auditado |
| **RN-14** | No se puede borrar un transportista, una bodega ni un vino con movimientos | FK con `ON DELETE RESTRICT` (22 FK con RESTRICT; `CASCADE` solo en renglones, subtipos, parcelas, análisis y composición) | 001 | **78** vino con ventas · **79** bodega con vinos · **80** transportista con ingresos → `23001` (PostgreSQL 18) / `23503` (14–17) · **81** bodega sin movimientos OK |
| **RN-15** | Cantidades, superficies, kilos y precios positivos; graduación entre 5 y 20 | `CHECK` en `vino`, `renglon_*`, `finca`, `parcela`, `lote_uva`, `empleado`, `stock_*`, `analisis_calidad` + `DOMAIN cuit_dom` | 001, 002 | **82** graduación 4,99 · **83** 20,01 → `23514` · **84** límites 5 y 20 OK · **85–86** cantidades 0 y negativas · **87–88** superficies · **89** kilos · **90** salario · **91** CUIT inválido → `23514` |
| — | Consistencia final | Todos los constraint triggers diferidos | 005 | **92** `SET CONSTRAINTS ALL IMMEDIATE` sobre los datos de prueba OK |

Archivos: `001_esquema.sql`, `002_constraints.sql`, `003_funciones.sql`, `004_procedimientos.sql`, `005_triggers.sql` y `007_roles.sql`, en `db/migrations/`.

---

## 2. Mínimos de la Etapa 2

Conteos tomados del catálogo de PostgreSQL (`pg_constraint`, `pg_proc`, `pg_trigger`, …) después de aplicar las migraciones.

| Elemento | Mínimo exigido | Implementado |
|---|---|---|
| PRIMARY KEY | En todas las tablas | ✅ 30 de 30 tablas (claves compuestas en renglones, stock, composición y parcela) |
| FOREIGN KEY | Todas las relaciones, con ON DELETE / ON UPDATE justificados | ✅ 35 FK: 22 `RESTRICT` y 13 `CASCADE`, todas `ON UPDATE CASCADE` (justificación en el documento de la Etapa 1, §4.5) |
| NOT NULL | Todo atributo obligatorio | ✅ |
| UNIQUE | 4 además de las PK | ✅ 9: `(nombre, anada, volumen_ml)` en vino · `(parcela, campania)` en lote · `(tipo_documento, nro_documento)` en cliente · CUIT de transportista · código de permiso · nombre de cepa · nombre de maridaje · `(nombre, provincia)` en localidad y en departamento |
| CHECK | 8, al menos uno entre columnas | ✅ 28, dos entre columnas: `ck_permiso_fechas` y `ck_comprobante_total` |
| DEFAULT | 3 | ✅ 13 (estado `en_confeccion`, fechas `CURRENT_DATE`, importes 0, stock 0, `now()` y `current_user` en la auditoría) |
| Tipos propios | 1 ENUM y 1 DOMAIN | ✅ 6 ENUM (`estado_documento`, `tipo_vino`, `tipo_cepa`, `tipo_cliente`, `tipo_documento`, `dia_semana`) y 1 DOMAIN (`cuit_dom`) |
| Funciones | 4 | ✅ 5: `fn_total_comprobante`, `fn_stock_sala`, `fn_descuento_cliente`, `fn_antiguedad_anios`, `fn_subtotal_renglon` (con volatilidad declarada) |
| Procedimientos | 2 transaccionales | ✅ `sp_procesar_ingreso`, `sp_procesar_transferencia` |
| Triggers | 6 con propósitos distintos: al menos uno BEFORE, uno AFTER y un constraint trigger diferido | ✅ 21 (15 comunes + 6 constraint triggers diferidos): BEFORE (validar stock, completar renglón, estados, fecha, bloqueo de renglones, descuento, subtipos, importes), AFTER (stock y totales, auditoría) y diferidos (corte = 100, jerarquía de clientes) |
| Vistas | 3 | ✅ `vw_stock_total_vino`, `vw_ventas_mensuales_sala`, `vw_documentos_pendientes` |
| Roles | 3 con privilegios mínimos | ✅ `propietario` (dueño de los objetos), `app_rw` (API: DML + EXECUTE, solo lectura de la auditoría), `solo_lectura`; `REVOKE` de los privilegios públicos |

---

## 3. ¿Dónde va cada regla?

Criterio aplicado (guía de la sección 7 del enunciado), con la justificación de cada caso.

| Tipo de regla | Herramienta | Reglas del TP | Por qué esa herramienta |
|---|---|---|---|
| Valor válido de una sola fila, siempre igual | `NOT NULL`, `CHECK`, `DOMAIN` | RN-01, RN-07, RN-15 y la parte "por fila" de RN-05, RN-06 y RN-09 | Se evalúa con los datos de la propia fila, sin consultar nada más: es lo más barato y no se puede saltear |
| Existencia de un dato relacionado | `FOREIGN KEY` | RN-02, RN-03, RN-14 | Es exactamente lo que garantiza una FK; con `RESTRICT` además protege el historial |
| Unicidad | `UNIQUE` / `PRIMARY KEY` | RN-04, RN-03 | La unicidad entre filas solo se puede garantizar con un índice único, incluso con concurrencia |
| Depende de otras filas o tablas | Trigger | RN-05, RN-06 (jerarquía), RN-08, RN-09, RN-12 | Un `CHECK` no puede consultar otras filas. RN-05 es diferido porque un corte 85/15 se carga en dos `INSERT` y la suma solo es válida al final de la transacción |
| Depende de la fecha actual | Trigger | RN-11 (fecha de confección) | `CURRENT_DATE` en un `CHECK` cambiaría de resultado con el tiempo y rompería la restauración de un backup |
| Transiciones de estado | `ENUM` + trigger | RN-10, RN-11 | El ENUM impide valores inválidos; el trigger compara el estado anterior con el nuevo, cosa que un `CHECK` no puede hacer |
| Cálculo usado en varios lugares | Función | RN-06 (`fn_descuento_cliente`), RN-08 (`fn_subtotal_renglon`, `fn_total_comprobante`) | Una sola fórmula para triggers, consultas de control y reportes: no hay dos implementaciones que puedan diferir |
| Operación de varios pasos, todo o nada | Procedimiento | RN-10, RN-11 (`sp_procesar_*`) | Valida, bloquea con `FOR UPDATE`, mueve stock y cambia el estado en la misma transacción; si algo falla se revierte todo |
| Auditoría | Trigger `AFTER` + permisos | RN-13 | `AFTER` registra solo cambios que realmente ocurrieron. `SECURITY DEFINER` y los permisos impiden que la API adultere la auditoría |
| Formato, experiencia de usuario y autorización | API y front | Mensajes, validación previa, permisos por pantalla | No son reglas del dominio: la base igual rechaza lo inválido aunque el front no lo valide |

Además de lo que pide la guía, se decidió lo siguiente:

- **Los importes no los calcula nadie fuera de la base.** Los triggers ignoran el precio, el descuento y el subtotal que envía el cliente y los calculan ellos (RN-08). Así se cumple la "regla de oro" del enunciado aunque alguien inserte directamente con `psql`.
- **A `procesado` solo se llega por el procedimiento.** Sin esto, un `UPDATE estado = 'procesado'` dejaría el documento procesado sin mover stock. El trigger de estados solo acepta ese cambio cuando el SP activa la variable de transacción `bodegas.via_procedimiento`.
