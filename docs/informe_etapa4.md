# Informe · Etapa 4 — Índices y rendimiento

**TPI Bases de Datos · Bodegas del Atuel · UTN FRSR · 2026**

| Entregable | Archivo |
|---|---|
| Índices | [`db/migrations/008_indices.sql`](../db/migrations/008_indices.sql) |
| Consultas medidas | [`docs/etapa4/consultas_medidas.sql`](etapa4/consultas_medidas.sql) |
| Script de medición | [`db/scripts/medir_indices.py`](../db/scripts/medir_indices.py) |
| Resultados completos (generados) | [`docs/etapa4/resultados.md`](etapa4/resultados.md) |
| **Anexo: planes completos** | [`docs/etapa4/anexo_planes.md`](etapa4/anexo_planes.md) |

> **Corrida de referencia:** PostgreSQL 18.6 (Windows 10, x64), usuario `propietario`, 03/11/2026. Todos los números salen de `resultados.md`, que genera el script.

---

## 1. Resultado

| Criterio de aceptación | Resultado |
|---|---|
| Al menos 5 índices, con los tipos pedidos y justificados | ✅ 8 índices: **compuesto** (1), **parciales** (2), **sobre claves foráneas** (4, uno con **INCLUDE**) y **BRIN** (1). Justificación en la sección 4 y en los comentarios de `008_indices.sql` |
| Mejora medida en al menos 3 consultas | ✅ 6 consultas mejoran: S3 ×332, historial de un cliente ×79, borrado de un vino (RN-14) ×36, S8 ×8,6, S9 ×5,1, S5 ×3,6 |
| Índice descartado explicado | ✅ `cliente (tipo)`, el orden `(fecha, id_sala)` y un B-tree sobre `fecha` (secciones 6 y 7) |
| Costo de escritura | ✅ Sección 8: con sus índices, la carga de `comprobante` tarda 2,3 veces más y la de `renglon_comprobante`, 1,5 veces más |
| Caso en que el planificador no usa un índice | ✅ Sección 9: baja selectividad (S1, S12, `tipo = 'socio'`) y estadísticas desactualizadas |
| Planes completos en un anexo | ✅ [`anexo_planes.md`](etapa4/anexo_planes.md) |

---

## 2. Metodología

1. **Datos y motor:** la base cargada con `seed_db.py` (semilla 42): 150.000 comprobantes, 515.977 renglones y 20.000 clientes, en **PostgreSQL 18.6**.
2. **Consultas:** se tomaron de la sección 8 del enunciado las que recorren tablas grandes o las que usa la API (sección 3). Están en `consultas_medidas.sql`, con valores concretos del dataset y fechas relativas a `CURRENT_DATE`.
3. **Antes:** `medir_indices.py` borra los índices de `008_indices.sql` (quedan solo las PK y los UNIQUE), ejecuta `VACUUM (ANALYZE)` y mide cada consulta con `EXPLAIN (ANALYZE, BUFFERS)`.
4. **Diseño:** los índices se decidieron leyendo esos planes (sección 3).
5. **Después:** crea los índices midiendo el tiempo y el tamaño de cada uno, ejecuta `ANALYZE` y repite las mediciones.
6. **Cómo se mide:** cada consulta se ejecuta una vez para calentar la caché y luego **5 veces**; se informa la **mediana** del *Execution Time*. Así se compara el trabajo del plan y no la velocidad del disco. También se informan las **filas leídas** (filas devueltas más filas descartadas por los filtros) y los **buffers** (páginas de 8 kB tocadas), que no dependen de la máquina.
7. **Experimentos:** orden de columnas, BRIN contra B-tree, el índice descartado, los casos en que el índice no se usa y el costo de escritura (secciones 6 a 9).

Todo es reproducible con un solo comando (sección 11).

---

## 3. Diagnóstico: qué mostraban los planes sin índices

| Consulta | Plan sin índices | Problema |
|---|---|---|
| **S3** clientes por tipo que compraron en la sala 1 la última semana | `Seq Scan` en `comprobante`: lee 150.000 filas y descarta 149.981 | Filtro por sala y fecha sin índice |
| **S8** ventas por sala en el último trimestre | `Seq Scan` en `comprobante`: lee 150.000 filas para usar ~7.400 (4,9 %) | Filtro por rango de fechas sin índice |
| **HC** historial de compras de un cliente (API) | `Seq Scan` en `comprobante`: 150.000 filas para encontrar 49 | `id_cliente` es FK y PostgreSQL **no** la indexa |
| **S9** ficha de un vino | `Seq Scan` en `stock_sala` repetido una vez por vino: 14.352 filas leídas | La PK es `(id_sala, cod_vino)`: no sirve para buscar por `cod_vino` |
| **S5** salas con menos transferencias pendientes | `Seq Scan` en `transferencia` para quedarse con 15 de 4.448 | Se buscan muy pocas filas con una condición fija (`estado <> 'procesado'`) |
| **S4** salas que más pidieron un vino en 15 días | `Seq Scan` en `transferencia` (4.448 filas, 25 páginas) | Tablas chicas: el recorrido secuencial ya es barato |
| **RN-14** borrar un vino sin movimientos | El `DELETE` usa la PK, pero el trigger de la FK `renglon_comprobante_cod_vino_fkey` recorre los 516.000 renglones para comprobar que no haya ventas | FK sin índice en la tabla hija |
| **S1** ranking de vinos y **S12** clientes sin tintos | `Seq Scan` de toda `renglon_comprobante` + agregación o anti-join por hash | La consulta **necesita** todas las filas (sección 9) |

Dato que decidió el tipo de índice sobre `fecha`: `pg_stats.correlation` de `comprobante.fecha` = **1,0**. Las filas están físicamente ordenadas por fecha porque los comprobantes se graban en orden cronológico.

---

## 4. Índices creados y justificación

| # | Índice | Tipo pedido | Para qué | Justificación |
|---|---|---|---|---|
| 1 | `ix_comprobante_sala_fecha` **ON comprobante (id_sala, fecha)** | **Compuesto** | S3, `vw_ventas_mensuales_sala`, ventas de una sala por período | Las consultas filtran por sala (igualdad) y por fecha (rango). Orden justificado en la sección 6 |
| 2 | `ix_comprobante_fecha_brin` **USING brin (fecha)** | **BRIN** (otro tipo) | S8, D1, reportes por período | Correlación 1,0 con el orden físico. Ocupa **24 kB** contra 1 MB de un B-tree (sección 7) |
| 3 | `ix_comprobante_cliente` **(id_cliente)** | **Sobre clave foránea** | Historial de un cliente, S12, D4 y D6 (`NOT EXISTS` por cliente), borrar un cliente | Sin índice, cada búsqueda por cliente recorre los 150.000 comprobantes |
| 4 | `ix_renglon_comprobante_vino` **(cod_vino)** | **Sobre clave foránea** | Borrar un vino (RN-14), S2, ventas de un vino | La PK `(nro, cod_vino)` empieza por `nro`. Sin este índice, el control de RN-14 recorre 516.000 renglones |
| 5 | `ix_stock_sala_vino` **(cod_vino)** | **Sobre clave foránea** | S9, S6, `vw_stock_total_vino` | La PK `(id_sala, cod_vino)` no sirve para buscar un vino en todas las salas |
| 6 | `ix_renglon_transferencia_vino` **(cod_vino) INCLUDE (cantidad)** | **Sobre clave foránea + INCLUDE** | S4, borrar un vino | La cantidad viaja en la hoja del índice y permite *Index Only Scan* cuando solo se necesita `SUM(cantidad)`. Va en `INCLUDE` y no como segunda clave porque no se busca ni se ordena por ella |
| 7 | `ix_transferencia_pendientes` **(id_sala) WHERE estado <> 'procesado'** | **Parcial** | S5, `vw_documentos_pendientes`, tablero del front | Solo indexa las ~15 transferencias pendientes entre 4.448: ocupa 16 kB y no se toca al modificar transferencias ya procesadas |
| 8 | `ix_ingreso_pendientes` **(cuit_bodega) WHERE estado <> 'procesado'** | **Parcial** | `vw_documentos_pendientes`, endpoint de ingresos | Mismo criterio que el anterior |

Tamaños y tiempos de creación: [`resultados.md` §2](etapa4/resultados.md). El índice más grande es `ix_renglon_comprobante_vino` (3,5 MB, frente a 30 MB de la tabla); ninguno tarda más de 0,3 s en crearse y los 8 juntos, menos de 0,8 s.

---

## 5. Tabla comparativa (antes / después)

Mediana de 5 ejecuciones. Planes completos en el [anexo](etapa4/anexo_planes.md).

| Consulta | Antes | Recorrido antes | Filas leídas | Después | Recorrido después | Filas leídas | Mejora |
|---|---:|---|---:|---:|---|---:|---:|
| **S3** clientes por tipo, sala 1, última semana | 36,2 ms | Seq Scan `comprobante` | 150.018 | 0,109 ms | Bitmap Index Scan `ix_comprobante_sala_fecha` | 38 | **×332** |
| **HC** historial de un cliente | 10,1 ms | Seq Scan `comprobante` | 150.000 | 0,128 ms | Bitmap Index Scan `ix_comprobante_cliente` | 49 | **×79** |
| **RN-14** borrar un vino sin movimientos | 35,4 ms | Index Scan `vino_pkey`; el control de la FK recorre `renglon_comprobante` entera | 1 + control FK | 0,99 ms | Index Scan `vino_pkey`; el control de la FK usa `ix_renglon_comprobante_vino` | 1 + control FK | **×36** |
| **S8** ventas por sala, último trimestre | 43,3 ms | Seq Scan `comprobante` | 150.000 | 5,02 ms | Bitmap Index Scan `ix_comprobante_fecha_brin` | 13.459 | **×8,6** |
| **S9** ficha de un vino | 1,08 ms | Seq Scan `stock_sala` (×8) | 14.353 | 0,211 ms | Bitmap Index Scan `ix_stock_sala_vino` | 33 | **×5,1** |
| **S5** salas con menos pendientes | 0,354 ms | Seq Scan `transferencia` | 4.473 | 0,097 ms | Bitmap Index Scan `ix_transferencia_pendientes` | 40 | **×3,6** |
| **S4** salas que más pidieron un vino | 0,428 ms | Seq Scan `transferencia` | 4.449 | 0,430 ms | Seq Scan `transferencia` + Bitmap `ix_renglon_transferencia_vino` | 4.460 | ×1,0 |
| **S12** clientes sin tintos | 291 ms | Seq Scan de 4 tablas | 686.718 | 256 ms | Seq Scan de 4 tablas | 686.718 | ×1,1 |
| **S1** ranking de vinos | 116 ms | Seq Scan `renglon_comprobante` | 518.200 | 116 ms | Seq Scan `renglon_comprobante` | 518.200 | ×1,0 |

**Lectura de la tabla**

- **Las búsquedas muy selectivas mejoran entre 36 y 332 veces** (S3, HC, RN-14): pasan de leer toda la tabla a leer solo las filas que necesitan. Los buffers bajan en la misma proporción: S3 pasa de 1.339 páginas a 63.
- **RN-14 es la mejora menos visible y más importante.** El `DELETE` de un vino no hace ninguna consulta, pero PostgreSQL controla cada FK que apunta a `vino`, y la de `renglon_comprobante` pasa de 33,3 ms a 0,065 ms ([`resultados.md`](etapa4/resultados.md), detalle del borrado). Es la razón por la que el enunciado pide indexar las claves foráneas.
- **S8 mejora ×8,6**: el BRIN saltea los bloques fuera del último trimestre y lee 117 páginas en lugar de 1.274. No llega a los valores de S3 porque el trimestre es el 4,9 % de la tabla (~7.400 comprobantes), y dentro de cada bloque del rango tiene que volver a verificar todas las filas (*Rows Removed by Index Recheck*): lee 13.459 filas para quedarse con 7.400.
- **S4 no mejora** (0,43 ms en ambos casos). `transferencia` tiene 4.448 filas en 25 páginas: recorrerla entera cuesta menos que entrar a un índice. El índice 6 igual se justifica por la FK (borrar un vino) y por el crecimiento de la tabla.
- **S1 y S12 no mejoran y no deben mejorar:** son el caso de la sección 9.

---

## 6. Orden de las columnas del índice compuesto

Se eligió **`(id_sala, fecha)`**: primero la columna que se compara por **igualdad** y después la de **rango**.

- **Por qué.** Un B-tree compuesto ordena primero por la primera columna. Con `(id_sala, fecha)` todas las entradas de la sala 1 quedan **contiguas y ordenadas por fecha**, así que "sala 1 desde hace 7 días" es **un único tramo** del índice. Con `(fecha, id_sala)`, el rango de fechas abarca **todas las salas** y la condición sobre la sala se evalúa entrada por entrada.
- **Además,** `(id_sala, fecha)` sirve para consultas que filtran **solo por sala**, porque la sala es el prefijo del índice. Con `(fecha, id_sala)` eso no es posible: el prefijo es la fecha.

Medición (`resultados.md` §3):

| Consulta | `(id_sala, fecha)` | `(fecha, id_sala)` |
|---|---|---|
| S3: sala 1, última semana | 0,109 ms · Bitmap Index Scan | 0,087 ms · Index Scan |
| Ventas mensuales de la sala 5 en toda su historia (`WHERE id_sala = 5`) | **6,0 ms · Bitmap Index Scan** | **15,8 ms · Seq Scan** (el índice no sirve) |

Con un rango corto (S3) los dos órdenes rinden igual (0,1 ms; la diferencia de 0,02 ms es ruido): la semana tiene apenas ~480 comprobantes de todas las salas, así que recorrer ese tramo del índice es barato en cualquier orden. En cambio, para "todas las ventas de una sala" el orden inverso **no se puede usar** y el planificador vuelve al recorrido secuencial: **2,6 veces más lento**. Incluso en PostgreSQL 18, con *skip scan*, el planificador prefirió recorrer la tabla antes que saltar por las 2.192 fechas distintas del índice `(fecha, id_sala)`.

> **PostgreSQL 18** incorpora el *skip scan* en B-tree: puede usar `(id_sala, fecha)` aun cuando la consulta filtra solo por fecha, "saltando" por cada uno de los 25 valores de sala. Es otro argumento para poner primero la columna de **pocos valores distintos** y comparación por igualdad.

---

## 7. BRIN contra B-tree sobre `comprobante.fecha`

| Índice | S8 | Buffers | Tamaño |
|---|---:|---:|---:|
| **BRIN** (elegido) | 5,0 ms | 117 | **24 kB** |
| B-tree (evaluado) | 3,0 ms | 72 | 1,0 MB |

El B-tree es algo más rápido para S8, porque va directo a las filas del rango, mientras que el BRIN lee bloques enteros de 128 páginas y vuelve a verificar cada fila. Se eligió **BRIN** igual, porque:

- es **40 veces más chico** (24 kB contra 1 MB) y su tamaño casi no crece con la tabla;
- **su mantenimiento al insertar es prácticamente nulo**, y `comprobante` es la tabla que más se escribe (cada venta);
- `comprobante` crece siempre al final y en orden de fecha: es el caso ideal de BRIN, y la correlación se mantiene con el tiempo;
- la diferencia es de unos 2 ms en un reporte trimestral, irrelevante para el uso real.

Si la tabla dejara de estar ordenada por fecha (por ejemplo, por cargas retroactivas masivas o actualizaciones que muevan filas), el BRIN perdería efectividad. Habría que reevaluarlo mirando `pg_stats.correlation`.

---

## 8. Costo de escritura

Se copió cada tabla grande completa (`INSERT ... SELECT`) a una tabla nueva **con la PK sola** y **con la PK más los índices de 008** que le corresponden. Mediana de 3 repeticiones (`resultados.md` §7).

| Tabla | Filas | Índices agregados | Sin índices | Con índices | Sobrecosto | Espacio de índices |
|---|---:|---|---:|---:|---:|---|
| `comprobante` | 150.000 | `(id_sala, fecha)`, BRIN `(fecha)`, `(id_cliente)` | 0,71 s | 1,66 s | **+134 %** | 3,2 MB → 8,5 MB |
| `renglon_comprobante` | 515.977 | `(cod_vino)` | 2,69 s | 3,92 s | **+45 %** | 11,1 MB → 15,6 MB |

**Interpretación**

- Cada índice B-tree se actualiza **en cada INSERT**, con una inserción ordenada en su árbol y su registro en el WAL. En `comprobante` hay que mantener tres índices además de la PK, y por eso la carga tarda 2,3 veces más. En `renglon_comprobante` se agrega uno solo y el sobrecosto es del 45 %.
- **En operación normal el costo es imperceptible:** una venta inserta 1 comprobante y 3 o 4 renglones, así que mantener los índices suma microsegundos. Las consultas que se aceleran (historial del cliente, ventas por sala, borrado de vinos) se ejecutan mucho más seguido que lo que cuesta mantenerlos.
- **En la carga masiva el costo sí importa.** Para cargas grandes conviene **borrar los índices secundarios, cargar y recrearlos**: crear los 8 índices sobre las tablas llenas tarda menos de 0,8 s en total (`resultados.md` §2), mucho menos que mantenerlos fila por fila durante la carga.
- El BRIN casi no suma costo: el sobrecosto de `comprobante` lo explican los dos B-tree.

---

## 9. Casos en que el planificador NO usa un índice existente

### 9.1 Baja selectividad: la consulta necesita casi toda la tabla

| Consulta | Índice disponible | Fracción de filas necesarias | Plan elegido |
|---|---|---|---|
| **S1** ranking de los 10 vinos más vendidos | `ix_renglon_comprobante_vino` | 100 % de los renglones | **Seq Scan** + HashAggregate |
| **S12** clientes que nunca compraron tinto | `ix_comprobante_cliente`, `ix_renglon_comprobante_vino` | Todas las ventas (los tintos son ~58 % de los renglones) | **Seq Scan** + Hash Anti Join |
| Ventas de clientes `tipo = 'socio'` | `cliente (tipo)` (creado para el experimento) | 80 % de los clientes | **Seq Scan** |

**Causa.** El planificador estima el costo de cada plan. Recorrer la tabla secuencialmente lee cada página **una sola vez y en orden**. Usar el índice implica leer el índice y además **saltar de página en página** en la tabla, a veces más de una vez por página. Cuando la consulta necesita una fracción grande de las filas, el recorrido secuencial es más barato y el planificador lo elige, **aunque el índice exista**. Es la decisión correcta: S1 tarda lo mismo con y sin índice (116 ms en ambos casos), y en el caso de `socio` el índice no se usa.

### 9.2 Estadísticas desactualizadas

Dentro de una transacción que después se revierte, se insertaron **60.000 comprobantes** de la sala 1 con fecha de hoy y se consultó `WHERE id_sala = 1 AND fecha = CURRENT_DATE`:

| Momento | Filas estimadas | Filas reales |
|---|---:|---:|
| Sin `ANALYZE` | **5** | 60.000 |
| Después de `ANALYZE` | ~19.500 | 60.000 |

Con las estadísticas viejas, el planificador cree que la consulta devuelve 5 filas: **se equivoca por un factor de 12.000**. Acá el plan elegido (Bitmap Index Scan) resulta razonable igual. Pero en una consulta con joins, una estimación así lleva a elegir un *Nested Loop* pensado para 5 filas que termina ejecutándose 60.000 veces. Por eso el script de carga ejecuta `ANALYZE` al terminar y `008_indices.sql` lo ejecuta después de crear los índices. En operación, `autovacuum` actualiza las estadísticas cuando cambia una fracción suficiente de la tabla (por defecto, el 10 %).

Después de `ANALYZE` la estimación queda en ~19.500 y no en 60.000, porque `ANALYZE` trabaja con una **muestra** de la tabla y la combinación de dos columnas (`id_sala` y `fecha`) se estima suponiendo que son independientes. Si hiciera falta, PostgreSQL permite crear estadísticas extendidas (`CREATE STATISTICS ... (dependencies)`) sobre ese par de columnas.

---

## 10. Índices evaluados y descartados

| Índice | Motivo |
|---|---|
| **`cliente (tipo)`** | Columna de **3 valores** con distribución muy desigual (80 % socios, 15 % distribuidores, 5 % exportadores). Para `socio` el planificador **no lo usa** (sección 9.1). Para `exportador` sí lo usa, pero la ganancia es de poco más de 1 ms (4,5 → 3,3 ms) y el índice ocupa 152 kB y se mantiene en cada alta de cliente. No compensa. |
| **`comprobante (fecha, id_sala)`** | Orden inverso del compuesto: no sirve para filtrar solo por sala (sección 6). |
| **B-tree `comprobante (fecha)`** | Algo más rápido para S8 que el BRIN, pero 40 veces más grande y más caro de mantener (sección 7). |
| **`renglon_comprobante (cod_vino) INCLUDE (cantidad)`** para S1 | S1 necesita sumar **todos** los renglones. Un *Index Only Scan* recorrería un índice casi del tamaño de la tabla sin evitar trabajo. Se dejó el índice sobre `cod_vino` sin `INCLUDE`, que es el que hace falta para la FK. |

---

## 11. Cómo reproducir

Con la base cargada (`db/seed/README.md`):

```powershell
$env:PGHOST="localhost"; $env:PGDATABASE="bodegas_atuel"; $env:PGUSER="propietario"; $env:PGPASSWORD="..."
python db/scripts/medir_indices.py
```

El script:
- deja la base **con los índices de 008 creados**;
- regenera `docs/etapa4/resultados.md` y `docs/etapa4/anexo_planes.md`;
- tarda menos de un minuto;
- no modifica datos: todos los experimentos que escriben se revierten o usan tablas temporales que se borran al final.

Para aplicar solo los índices sin medir:

```bash
psql -U propietario -d bodegas_atuel -v ON_ERROR_STOP=1 -f db/migrations/008_indices.sql
```
