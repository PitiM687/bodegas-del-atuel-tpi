# Resultados de las mediciones · Etapa 4

- Servidor: `PostgreSQL 18.6 on x86_64-windows, compiled by msvc-19.44.35229, 64-bit`
- Fecha: 2026-11-03 10:37 · usuario `propietario` · mediana de 5 ejecuciones con la caché caliente
- Generado por `db/scripts/medir_indices.py`. Planes completos: [anexo_planes.md](anexo_planes.md)

## 1. Tabla comparativa

| Consulta | Antes (ms) | Recorrido antes | Filas leídas | Buffers | Después (ms) | Recorrido después | Filas leídas | Buffers | Mejora |
|---|---:|---|---:|---:|---:|---|---:|---:|---:|
| **S1** Ranking de los 10 vinos más vendidos de la red | 116.1 | Seq Scan en renglon_comprobante<br>Seq Scan en vino | 518,200 | 3,881 | 116.2 | Seq Scan en renglon_comprobante<br>Seq Scan en vino | 518,200 | 3,881 | ×1.0 |
| **S3** Clientes de cada tipo que compraron en una sala en la última semana | 36.20 | Seq Scan en comprobante<br>Index Scan (cliente_pkey) en cliente | 150,018 | 1,339 | 0.109 | Bitmap Heap Scan en comprobante<br>Bitmap Index Scan (ix_comprobante_sala_fecha)<br>Index Scan (cliente_pkey) en cliente | 38 | 63 | ×332.1 |
| **S4** Top 5 de salas que más pidieron un vino por transferencia en los últimos 15 días | 0.428 | Index Scan (uq_vino_nombre_anada_volumen) en vino<br>Seq Scan en transferencia<br>Index Scan (renglon_transferencia_pkey) en renglon_transferencia | 4,449 | 76 | 0.430 | Index Scan (uq_vino_nombre_anada_volumen) en vino<br>Seq Scan en transferencia<br>Bitmap Heap Scan en renglon_transferencia<br>Bitmap Index Scan (ix_renglon_transferencia_vino) | 4,460 | 34 | ×1.0 |
| **S5** Salas con menor cantidad de transferencias pendientes | 0.354 | Seq Scan en transferencia<br>Seq Scan en sala_venta | 4,473 | 26 | 0.097 | Bitmap Heap Scan en transferencia<br>Bitmap Index Scan (ix_transferencia_pendientes)<br>Seq Scan en sala_venta | 40 | 4 | ×3.6 |
| **S8** Monto total de ventas por sala en el último trimestre | 43.33 | Seq Scan en comprobante | 150,000 | 1,274 | 5.02 | Bitmap Heap Scan en comprobante<br>Bitmap Index Scan (ix_comprobante_fecha_brin) | 13,459 | 117 | ×8.6 |
| **S9** Ficha de un vino: stock total (depósito + salas) | 1.08 | Bitmap Heap Scan en vino<br>Bitmap Index Scan (uq_vino_nombre_anada_volumen)<br>Index Scan (stock_deposito_pkey) en stock_deposito<br>Seq Scan en stock_sala | 14,353 | 106 | 0.211 | Bitmap Heap Scan en vino<br>Bitmap Index Scan (uq_vino_nombre_anada_volumen)<br>Index Scan (stock_deposito_pkey) en stock_deposito<br>Bitmap Heap Scan en stock_sala<br>Bitmap Index Scan (ix_stock_sala_vino) | 33 | 56 | ×5.1 |
| **S12** Clientes que nunca compraron un vino tinto (anti-join) | 291.3 | Seq Scan en renglon_comprobante<br>Seq Scan en vino<br>Seq Scan en comprobante<br>Seq Scan en cliente | 686,718 | 5,385 | 256.3 | Seq Scan en renglon_comprobante<br>Seq Scan en vino<br>Seq Scan en comprobante<br>Seq Scan en cliente | 686,718 | 5,385 | ×1.1 |
| **HC** Historial de compras de un cliente (GET /clientes/{id}/comprobantes de la API) | 10.10 | Seq Scan en comprobante | 150,000 | 1,267 | 0.128 | Bitmap Heap Scan en comprobante<br>Bitmap Index Scan (ix_comprobante_cliente) | 49 | 48 | ×78.9 |
| **RN-14** Borrar un vino sin movimientos (`DELETE FROM vino WHERE cod_vino = <vino nuevo sin movimientos>`, se revierte) | 35.39 | ModifyTable en vino<br>Index Scan (vino_pkey) en vino | 1 | 5 | 0.987 | ModifyTable en vino<br>Index Scan (vino_pkey) en vino | 1 | 5 | ×35.9 |

**Detalle del borrado de un vino (RN-14).** El `DELETE` en sí es instantáneo: el tiempo está en los triggers internos que controlan cada clave foránea que apunta a `vino`.

| Clave foránea controlada | Antes (ms) | Después (ms) |
|---|---:|---:|
| `renglon_comprobante_cod_vino_fkey` | 33.26 | 0.065 |
| `renglon_transferencia_cod_vino_fkey` | 0.947 | 0.063 |
| `renglon_ingreso_cod_vino_fkey` | 0.391 | 0.309 |
| `auditoria_precio_cod_vino_fkey` | 0.340 | 0.332 |
| `stock_sala_cod_vino_fkey` | 0.155 | 0.059 |
| `composicion_vino_cod_vino_fkey` | 0.103 | 0.078 |
| `vino_maridaje_cod_vino_fkey` | 0.083 | 0.021 |
| `stock_deposito_cod_vino_fkey` | 0.051 | 0.015 |

*Filas leídas*: filas que devolvieron los nodos de recorrido de tablas más las descartadas por el filtro. *Buffers*: páginas de 8 kB leídas (de caché o de disco).

## 2. Índices creados

| Índice | Definición | Tiempo de creación | Tamaño |
|---|---|---:|---:|
| `ix_comprobante_sala_fecha` | `comprobante (id_sala, fecha)` | 0.22 s | 1.9 MB |
| `ix_comprobante_fecha_brin` | `comprobante USING brin (fecha)` | 0.05 s | 24.0 kB |
| `ix_comprobante_cliente` | `comprobante (id_cliente)` | 0.17 s | 1.4 MB |
| `ix_renglon_comprobante_vino` | `renglon_comprobante (cod_vino)` | 0.29 s | 3.5 MB |
| `ix_stock_sala_vino` | `stock_sala (cod_vino)` | 0.00 s | 40.0 kB |
| `ix_renglon_transferencia_vino` | `renglon_transferencia (cod_vino) INCLUDE (cantidad)` | 0.01 s | 368.0 kB |
| `ix_transferencia_pendientes` | `transferencia (id_sala) WHERE estado <> 'procesado'` | 0.00 s | 16.0 kB |
| `ix_ingreso_pendientes` | `ingreso (cuit_bodega) WHERE estado <> 'procesado'` | 0.00 s | 16.0 kB |

Tamaño de las tablas: comprobante 9.9 MB, renglon_comprobante 30.0 MB.

## 3. Orden de columnas del índice compuesto (S3)

| Índice | Tiempo (ms) | Recorrido | Filas leídas | Buffers | Tamaño |
|---|---:|---|---:|---:|---:|
| `(id_sala, fecha)` (elegido) | 0.109 | Bitmap Heap Scan en comprobante<br>Bitmap Index Scan (ix_comprobante_sala_fecha)<br>Index Scan (cliente_pkey) en cliente | 38 | 63 | 1.9 MB |
| `(fecha, id_sala)` (descartado) | 0.087 | Index Scan (ix_tmp_fecha_sala) en comprobante<br>Index Scan (cliente_pkey) en cliente | 38 | 64 | 1.9 MB |

Segunda consulta: ventas mensuales de la sala 5 en toda su historia (la condición es solo `id_sala = 5`, como en `vw_ventas_mensuales_sala` filtrada por sala).

| Índice | Tiempo (ms) | Recorrido | Buffers |
|---|---:|---|---:|
| `(id_sala, fecha)` | 6.04 | Bitmap Heap Scan en comprobante<br>Bitmap Index Scan (ix_comprobante_sala_fecha) | 1,277 |
| `(fecha, id_sala)` | 15.75 | Seq Scan en comprobante | 1,267 |

## 4. BRIN vs. B-tree sobre comprobante.fecha (S8)

| Índice | Tiempo (ms) | Recorrido | Buffers | Tamaño |
|---|---:|---|---:|---:|
| BRIN (elegido) | 5.02 | Bitmap Heap Scan en comprobante<br>Bitmap Index Scan (ix_comprobante_fecha_brin) | 117 | 24.0 kB |
| B-tree | 3.05 | Index Scan (ix_tmp_fecha_btree) en comprobante | 72 | 1.0 MB |

## 5. Índice evaluado y descartado: cliente (tipo)

Distribución: socio 16,015 (80.1 %), distribuidor 2,976 (14.9 %), exportador 1,009 (5.0 %)

| Consulta | Sin índice (ms) | Con índice (ms) | Recorrido con el índice creado |
|---|---:|---:|---|
| Ventas de clientes `socio` | 39.92 | 44.11 | Seq Scan en comprobante<br>Seq Scan en cliente |
| Ventas de clientes `exportador` | 4.50 | 3.25 | Bitmap Heap Scan en cliente<br>Bitmap Index Scan (ix_tmp_cliente_tipo)<br>Index Only Scan (ix_comprobante_cliente) en comprobante |

Tamaño del índice: 152.0 kB.

## 6. El planificador no usa un índice existente

| Caso | Selectividad | Recorrido elegido | Tiempo (ms) |
|---|---|---|---:|
| S1: ranking de todos los vinos · existe `ix_renglon_comprobante_vino` | 100 % de los renglones | Seq Scan en renglon_comprobante<br>Seq Scan en vino | 116.2 |
| S12: clientes que nunca compraron tinto · existen `ix_comprobante_cliente` e `ix_renglon_comprobante_vino` | todas las ventas | Seq Scan en renglon_comprobante<br>Seq Scan en vino<br>Seq Scan en comprobante<br>Seq Scan en cliente | 256.3 |
| Ventas de clientes `socio` · existe `cliente (tipo)` (sección 5) | 80.1 % de los clientes | Seq Scan en comprobante<br>Seq Scan en cliente | 44.11 |

**Estadísticas desactualizadas.** Se insertan 60.000 comprobantes de la sala 1 con fecha de hoy (dentro de una transacción que se revierte) y se consulta `id_sala = 1 AND fecha = CURRENT_DATE` antes y después de `ANALYZE`.

| Momento | Nodo | Filas estimadas | Filas reales | Recorrido | Tiempo (ms) |
|---|---|---:|---:|---|---:|
| Sin ANALYZE | Bitmap Index Scan (ix_comprobante_sala_fecha) | 5 | 60,000 | Bitmap Heap Scan en comprobante<br>Bitmap Index Scan (ix_comprobante_sala_fecha) | 14.44 |
| Después de ANALYZE | Bitmap Index Scan (ix_comprobante_sala_fecha) | 19,484 | 60,000 | Bitmap Heap Scan en comprobante<br>Bitmap Index Scan (ix_comprobante_sala_fecha) | 14.24 |

## 7. Costo de escritura

Copia completa de cada tabla (`INSERT ... SELECT`) a una tabla nueva con la PK sola y con la PK más los índices de 008 que le corresponden. Mediana de 3 repeticiones.

| Tabla | Filas | Índices agregados | Sin índices (s) | Con índices (s) | Sobrecosto | Tamaño de los índices sin / con |
|---|---:|---|---:|---:|---:|---|
| comprobante | 150,000 | `(id_sala, fecha)`, `USING brin (fecha)`, `(id_cliente)` | 0.71 | 1.66 | +134 % | 3.2 MB / 8.5 MB |
| renglon_comprobante | 515,977 | `(cod_vino)` | 2.69 | 3.92 | +45 % | 11.1 MB / 15.6 MB |
