# Anexo · Planes de ejecución completos

PostgreSQL 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1). Generado por `db/scripts/medir_indices.py` el 2026-11-03 13:05. Cada plan es `EXPLAIN (ANALYZE, BUFFERS)` de una ejecución con la caché ya caliente.


## Antes (solo PK y UNIQUE)

### S1 · Ranking de los 10 vinos más vendidos de la red

```sql
SELECT v.cod_vino, v.nombre, v.anada, v.volumen_ml, SUM(r.cantidad) AS botellas
  FROM renglon_comprobante r
  JOIN vino v USING (cod_vino)
 GROUP BY v.cod_vino, v.nombre, v.anada, v.volumen_ml
 ORDER BY botellas DESC
 LIMIT 10
```
```
Limit  (cost=8902.60..8902.63 rows=10 width=46) (actual time=117.569..117.685 rows=10 loops=1)
  Buffers: shared hit=3881
  ->  Sort  (cost=8902.60..8904.45 rows=741 width=46) (actual time=117.566..117.680 rows=10 loops=1)
        Sort Key: (sum(r.cantidad)) DESC
        Sort Method: top-N heapsort  Memory: 25kB
        Buffers: shared hit=3881
        ->  Finalize GroupAggregate  (cost=8698.86..8886.59 rows=741 width=46) (actual time=116.638..117.499 rows=667 loops=1)
              Group Key: v.cod_vino
              Buffers: shared hit=3881
              ->  Gather Merge  (cost=8698.86..8871.77 rows=1482 width=46) (actual time=116.622..117.173 rows=1975 loops=1)
                    Workers Planned: 2
                    Workers Launched: 2
                    Buffers: shared hit=3881
                    ->  Sort  (cost=7698.83..7700.69 rows=741 width=46) (actual time=108.885..108.953 rows=658 loops=3)
                          Sort Key: v.cod_vino
                          Sort Method: quicksort  Memory: 72kB
                          Buffers: shared hit=3881
                          Worker 0:  Sort Method: quicksort  Memory: 72kB
                          Worker 1:  Sort Method: quicksort  Memory: 72kB
                          ->  Partial HashAggregate  (cost=7656.10..7663.51 rows=741 width=46) (actual time=108.547..108.668 rows=658 loops=3)
                                Group Key: v.cod_vino
                                Batches: 1  Memory Usage: 169kB
                                Buffers: shared hit=3867
                                Worker 0:  Batches: 1  Memory Usage: 169kB
                                Worker 1:  Batches: 1  Memory Usage: 169kB
                                ->  Hash Join  (cost=26.67..6581.15 rows=214990 width=42) (actual time=0.234..75.441 rows=171992 loops=3)
                                      Hash Cond: (r.cod_vino = v.cod_vino)
                                      Buffers: shared hit=3867
                                      ->  Parallel Seq Scan on renglon_comprobante r  (cost=0.00..5986.90 rows=214990 width=8) (actual time=0.007..23.098 rows=171992 loops=3)
                                            Buffers: shared hit=3837
                                      ->  Hash  (cost=17.41..17.41 rows=741 width=38) (actual time=0.216..0.217 rows=741 loops=3)
                                            Buckets: 1024  Batches: 1  Memory Usage: 60kB
                                            Buffers: shared hit=30
                                            ->  Seq Scan on vino v  (cost=0.00..17.41 rows=741 width=38) (actual time=0.009..0.102 rows=741 loops=3)
                                                  Buffers: shared hit=30
Planning:
  Buffers: shared hit=13
Planning Time: 0.349 ms
Execution Time: 117.744 ms
```

### S3 · Clientes de cada tipo que compraron en una sala en la última semana

```sql
SELECT cl.tipo, COUNT(DISTINCT cl.id_cliente) AS clientes
  FROM comprobante c
  JOIN cliente cl USING (id_cliente)
 WHERE c.id_sala = 1                                   -- parámetro: sala
   AND c.fecha > CURRENT_DATE - 7
 GROUP BY cl.tipo
```
```
GroupAggregate  (cost=4143.49..4143.69 rows=3 width=12) (actual time=4.019..5.223 rows=2 loops=1)
  Group Key: cl.tipo
  Buffers: shared hit=1325
  ->  Sort  (cost=4143.49..4143.55 rows=23 width=8) (actual time=4.012..5.214 rows=19 loops=1)
        Sort Key: cl.tipo, cl.id_cliente
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=1325
        ->  Gather  (cost=1000.29..4142.97 rows=23 width=8) (actual time=3.881..5.204 rows=19 loops=1)
              Workers Planned: 1
              Workers Launched: 1
              Buffers: shared hit=1325
              ->  Nested Loop  (cost=0.29..3140.67 rows=14 width=8) (actual time=2.948..2.978 rows=10 loops=2)
                    Buffers: shared hit=1325
                    ->  Parallel Seq Scan on comprobante c  (cost=0.00..3031.71 rows=14 width=4) (actual time=2.932..2.942 rows=10 loops=2)
                          Filter: ((id_sala = 1) AND (fecha > (CURRENT_DATE - 7)))
                          Rows Removed by Filter: 74990
                          Buffers: shared hit=1267
                    ->  Index Scan using cliente_pkey on cliente cl  (cost=0.29..7.78 rows=1 width=8) (actual time=0.003..0.003 rows=1 loops=19)
                          Index Cond: (id_cliente = c.id_cliente)
                          Buffers: shared hit=58
Planning:
  Buffers: shared hit=7
Planning Time: 0.129 ms
Execution Time: 5.272 ms
```

### S4 · Top 5 de salas que más pidieron un vino por transferencia en los últimos 15 días

```sql
SELECT t.id_sala, SUM(r.cantidad) AS botellas_solicitadas
  FROM renglon_transferencia r
  JOIN transferencia t USING (nro_solicitud)
 WHERE r.cod_vino = (SELECT cod_vino FROM vino        -- parámetro: vino
                      WHERE nombre = 'Malbec Reserva' AND volumen_ml = 750
                      ORDER BY anada DESC LIMIT 1)
   AND t.fecha_confeccion >= CURRENT_DATE - 15
 GROUP BY t.id_sala
 ORDER BY botellas_solicitadas DESC
 LIMIT 5
```
```
Limit  (cost=290.10..290.10 rows=1 width=12) (actual time=0.233..0.234 rows=0 loops=1)
  Buffers: shared hit=76
  InitPlan 1 (returns $0)
    ->  Limit  (cost=0.28..2.74 rows=1 width=6) (actual time=0.006..0.007 rows=1 loops=1)
          Buffers: shared hit=3
          ->  Index Scan Backward using uq_vino_nombre_anada_volumen on vino  (cost=0.28..44.69 rows=18 width=6) (actual time=0.006..0.006 rows=1 loops=1)
                Index Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
                Buffers: shared hit=3
  ->  Sort  (cost=287.35..287.36 rows=1 width=12) (actual time=0.233..0.233 rows=0 loops=1)
        Sort Key: (sum(r.cantidad)) DESC
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=76
        ->  GroupAggregate  (cost=287.32..287.34 rows=1 width=12) (actual time=0.231..0.231 rows=0 loops=1)
              Group Key: t.id_sala
              Buffers: shared hit=76
              ->  Sort  (cost=287.32..287.33 rows=1 width=8) (actual time=0.231..0.231 rows=0 loops=1)
                    Sort Key: t.id_sala
                    Sort Method: quicksort  Memory: 25kB
                    Buffers: shared hit=76
                    ->  Nested Loop  (cost=0.29..287.31 rows=1 width=8) (actual time=0.229..0.230 rows=0 loops=1)
                          Buffers: shared hit=76
                          ->  Seq Scan on transferencia t  (cost=0.00..102.84 rows=26 width=8) (actual time=0.206..0.208 rows=24 loops=1)
                                Filter: (fecha_confeccion >= (CURRENT_DATE - 15))
                                Rows Removed by Filter: 4424
                                Buffers: shared hit=25
                          ->  Index Scan using renglon_transferencia_pkey on renglon_transferencia r  (cost=0.29..7.07 rows=1 width=8) (actual time=0.000..0.000 rows=0 loops=24)
                                Index Cond: ((nro_solicitud = t.nro_solicitud) AND (cod_vino = $0))
                                Buffers: shared hit=48
Planning:
  Buffers: shared hit=12
Planning Time: 0.203 ms
Execution Time: 0.250 ms
```

### S5 · Salas con menor cantidad de transferencias pendientes

```sql
SELECT s.id_sala, s.calle, s.numero, COUNT(t.nro_solicitud) AS pendientes
  FROM sala_venta s
  LEFT JOIN transferencia t ON t.id_sala = s.id_sala AND t.estado <> 'procesado'
 GROUP BY s.id_sala, s.calle, s.numero
 ORDER BY pendientes, s.id_sala
 LIMIT 5
```
```
Limit  (cost=83.65..83.66 rows=5 width=30) (actual time=0.149..0.150 rows=5 loops=1)
  Buffers: shared hit=26
  ->  Sort  (cost=83.65..83.71 rows=25 width=30) (actual time=0.149..0.149 rows=5 loops=1)
        Sort Key: (count(t.nro_solicitud)), s.id_sala
        Sort Method: top-N heapsort  Memory: 25kB
        Buffers: shared hit=26
        ->  GroupAggregate  (cost=82.79..83.23 rows=25 width=30) (actual time=0.137..0.144 rows=25 loops=1)
              Group Key: s.id_sala
              Buffers: shared hit=26
              ->  Sort  (cost=82.79..82.86 rows=25 width=26) (actual time=0.135..0.137 rows=25 loops=1)
                    Sort Key: s.id_sala
                    Sort Method: quicksort  Memory: 26kB
                    Buffers: shared hit=26
                    ->  Hash Right Join  (cost=1.56..82.21 rows=25 width=26) (actual time=0.126..0.132 rows=25 loops=1)
                          Hash Cond: (t.id_sala = s.id_sala)
                          Buffers: shared hit=26
                          ->  Seq Scan on transferencia t  (cost=0.00..80.60 rows=15 width=8) (actual time=0.117..0.119 rows=15 loops=1)
                                Filter: (estado <> 'procesado'::estado_documento)
                                Rows Removed by Filter: 4433
                                Buffers: shared hit=25
                          ->  Hash  (cost=1.25..1.25 rows=25 width=22) (actual time=0.007..0.007 rows=25 loops=1)
                                Buckets: 1024  Batches: 1  Memory Usage: 10kB
                                Buffers: shared hit=1
                                ->  Seq Scan on sala_venta s  (cost=0.00..1.25 rows=25 width=22) (actual time=0.002..0.004 rows=25 loops=1)
                                      Buffers: shared hit=1
Planning:
  Buffers: shared hit=7
Planning Time: 0.064 ms
Execution Time: 0.162 ms
```

### S8 · Monto total de ventas por sala en el último trimestre

```sql
SELECT c.id_sala, SUM(c.total) AS monto_total
  FROM comprobante c
 WHERE c.fecha > CURRENT_DATE - INTERVAL '3 months'
 GROUP BY c.id_sala
 ORDER BY monto_total DESC
```
```
Sort  (cost=3836.88..3836.94 rows=25 width=36) (actual time=7.428..8.963 rows=25 loops=1)
  Sort Key: (sum(total)) DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=1274
  ->  Finalize GroupAggregate  (cost=3832.92..3836.30 rows=25 width=36) (actual time=7.351..8.950 rows=25 loops=1)
        Group Key: id_sala
        Buffers: shared hit=1274
        ->  Gather Merge  (cost=3832.92..3835.80 rows=25 width=36) (actual time=7.341..8.890 rows=50 loops=1)
              Workers Planned: 1
              Workers Launched: 1
              Buffers: shared hit=1274
              ->  Sort  (cost=2832.91..2832.97 rows=25 width=36) (actual time=6.132..6.134 rows=25 loops=2)
                    Sort Key: id_sala
                    Sort Method: quicksort  Memory: 27kB
                    Buffers: shared hit=1274
                    Worker 0:  Sort Method: quicksort  Memory: 27kB
                    ->  Partial HashAggregate  (cost=2832.02..2832.33 rows=25 width=36) (actual time=6.111..6.118 rows=25 loops=2)
                          Group Key: id_sala
                          Batches: 1  Memory Usage: 32kB
                          Buffers: shared hit=1267
                          Worker 0:  Batches: 1  Memory Usage: 32kB
                          ->  Parallel Seq Scan on comprobante c  (cost=0.00..2811.12 rows=4180 width=12) (actual time=4.972..5.397 rows=3702 loops=2)
                                Filter: (fecha > (CURRENT_DATE - '3 mons'::interval))
                                Rows Removed by Filter: 71298
                                Buffers: shared hit=1267
Planning Time: 0.063 ms
Execution Time: 8.991 ms
```

### S9 · Ficha de un vino: stock total (depósito + salas)

```sql
SELECT v.cod_vino, v.nombre, v.anada,
       COALESCE((SELECT d.cantidad FROM stock_deposito d WHERE d.cod_vino = v.cod_vino), 0) AS deposito,
       COALESCE((SELECT SUM(s.cantidad) FROM stock_sala s WHERE s.cod_vino = v.cod_vino), 0) AS salas
  FROM vino v
 WHERE v.nombre = 'Malbec Reserva' AND v.volumen_ml = 750; -- parámetro: vino
```
```
Bitmap Heap Scan on vino v  (cost=4.52..747.79 rows=18 width=46) (actual time=0.072..0.514 rows=8 loops=1)
  Recheck Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
  Heap Blocks: exact=1
  Buffers: shared hit=106
  ->  Bitmap Index Scan on uq_vino_nombre_anada_volumen  (cost=0.00..4.52 rows=18 width=0) (actual time=0.006..0.006 rows=8 loops=1)
        Index Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
        Buffers: shared hit=2
  SubPlan 1
    ->  Index Scan using stock_deposito_pkey on stock_deposito d  (cost=0.28..8.29 rows=1 width=4) (actual time=0.001..0.001 rows=1 loops=8)
          Index Cond: (cod_vino = v.cod_vino)
          Buffers: shared hit=23
  SubPlan 2
    ->  Aggregate  (cost=32.42..32.43 rows=1 width=8) (actual time=0.061..0.061 rows=1 loops=8)
          Buffers: shared hit=80
          ->  Seq Scan on stock_sala s  (cost=0.00..32.40 rows=8 width=4) (actual time=0.044..0.058 rows=2 loops=8)
                Filter: (cod_vino = v.cod_vino)
                Rows Removed by Filter: 1790
                Buffers: shared hit=80
Planning Time: 0.065 ms
Execution Time: 0.531 ms
```

### S12 · Clientes que nunca compraron un vino tinto (anti-join)

```sql
SELECT COUNT(*) AS clientes_sin_tintos
  FROM cliente cl
 WHERE NOT EXISTS (SELECT 1
                     FROM comprobante c
                     JOIN renglon_comprobante r USING (nro)
                     JOIN vino v USING (cod_vino)
                    WHERE c.id_cliente = cl.id_cliente
                      AND v.tipo = 'tinto')
```
```
Aggregate  (cost=20174.17..20174.18 rows=1 width=8) (actual time=219.428..219.435 rows=1 loops=1)
  Buffers: shared hit=5385
  ->  Hash Right Anti Join  (cost=5388.79..20155.07 rows=7640 width=0) (actual time=218.689..219.259 rows=3572 loops=1)
        Hash Cond: (c.id_cliente = cl.id_cliente)
        Buffers: shared hit=5385
        ->  Hash Join  (cost=4667.79..15980.90 rows=363482 width=4) (actual time=33.915..179.579 rows=302150 loops=1)
              Hash Cond: (r.nro = c.nro)
              Buffers: shared hit=5114
              ->  Hash Join  (cost=25.79..10384.74 rows=363482 width=4) (actual time=0.170..85.704 rows=302150 loops=1)
                    Hash Cond: (r.cod_vino = v.cod_vino)
                    Buffers: shared hit=3847
                    ->  Seq Scan on renglon_comprobante r  (cost=0.00..8996.77 rows=515977 width=8) (actual time=0.004..29.089 rows=515977 loops=1)
                          Buffers: shared hit=3837
                    ->  Hash  (cost=19.26..19.26 rows=522 width=4) (actual time=0.158..0.159 rows=522 loops=1)
                          Buckets: 1024  Batches: 1  Memory Usage: 27kB
                          Buffers: shared hit=10
                          ->  Seq Scan on vino v  (cost=0.00..19.26 rows=522 width=4) (actual time=0.006..0.116 rows=522 loops=1)
                                Filter: (tipo = 'tinto'::tipo_vino)
                                Rows Removed by Filter: 219
                                Buffers: shared hit=10
              ->  Hash  (cost=2767.00..2767.00 rows=150000 width=8) (actual time=33.514..33.515 rows=150000 loops=1)
                    Buckets: 262144  Batches: 1  Memory Usage: 7908kB
                    Buffers: shared hit=1267
                    ->  Seq Scan on comprobante c  (cost=0.00..2767.00 rows=150000 width=8) (actual time=0.006..12.178 rows=150000 loops=1)
                          Buffers: shared hit=1267
        ->  Hash  (cost=471.00..471.00 rows=20000 width=4) (actual time=3.196..3.197 rows=20000 loops=1)
              Buckets: 32768  Batches: 1  Memory Usage: 960kB
              Buffers: shared hit=271
              ->  Seq Scan on cliente cl  (cost=0.00..471.00 rows=20000 width=4) (actual time=0.004..1.534 rows=20000 loops=1)
                    Buffers: shared hit=271
Planning:
  Buffers: shared hit=31
Planning Time: 0.437 ms
Execution Time: 219.525 ms
```

### HC · Historial de compras de un cliente (GET /clientes/{id}/comprobantes de la API)

```sql
SELECT c.nro, c.fecha, c.id_sala, c.total
  FROM comprobante c
 WHERE c.id_cliente = 143                               -- parámetro: cliente (49 compras)
 ORDER BY c.fecha DESC
```
```
Sort  (cost=3143.41..3143.54 rows=50 width=20) (actual time=6.974..6.977 rows=49 loops=1)
  Sort Key: fecha DESC
  Sort Method: quicksort  Memory: 27kB
  Buffers: shared hit=1267
  ->  Seq Scan on comprobante c  (cost=0.00..3142.00 rows=50 width=20) (actual time=0.097..6.947 rows=49 loops=1)
        Filter: (id_cliente = 143)
        Rows Removed by Filter: 149951
        Buffers: shared hit=1267
Planning Time: 0.049 ms
Execution Time: 6.992 ms
```


## Después (con 008_indices.sql)

### S1 · Ranking de los 10 vinos más vendidos de la red

```sql
SELECT v.cod_vino, v.nombre, v.anada, v.volumen_ml, SUM(r.cantidad) AS botellas
  FROM renglon_comprobante r
  JOIN vino v USING (cod_vino)
 GROUP BY v.cod_vino, v.nombre, v.anada, v.volumen_ml
 ORDER BY botellas DESC
 LIMIT 10
```
```
Limit  (cost=8902.60..8902.63 rows=10 width=46) (actual time=113.437..115.426 rows=10 loops=1)
  Buffers: shared hit=3881
  ->  Sort  (cost=8902.60..8904.45 rows=741 width=46) (actual time=113.435..115.422 rows=10 loops=1)
        Sort Key: (sum(r.cantidad)) DESC
        Sort Method: top-N heapsort  Memory: 25kB
        Buffers: shared hit=3881
        ->  Finalize GroupAggregate  (cost=8698.86..8886.59 rows=741 width=46) (actual time=112.887..115.317 rows=667 loops=1)
              Group Key: v.cod_vino
              Buffers: shared hit=3881
              ->  Gather Merge  (cost=8698.86..8871.77 rows=1482 width=46) (actual time=112.880..115.097 rows=1972 loops=1)
                    Workers Planned: 2
                    Workers Launched: 2
                    Buffers: shared hit=3881
                    ->  Sort  (cost=7698.83..7700.69 rows=741 width=46) (actual time=108.376..108.412 rows=657 loops=3)
                          Sort Key: v.cod_vino
                          Sort Method: quicksort  Memory: 71kB
                          Buffers: shared hit=3881
                          Worker 0:  Sort Method: quicksort  Memory: 72kB
                          Worker 1:  Sort Method: quicksort  Memory: 72kB
                          ->  Partial HashAggregate  (cost=7656.10..7663.51 rows=741 width=46) (actual time=108.065..108.189 rows=657 loops=3)
                                Group Key: v.cod_vino
                                Batches: 1  Memory Usage: 105kB
                                Buffers: shared hit=3867
                                Worker 0:  Batches: 1  Memory Usage: 169kB
                                Worker 1:  Batches: 1  Memory Usage: 169kB
                                ->  Hash Join  (cost=26.67..6581.15 rows=214990 width=42) (actual time=0.252..67.173 rows=171992 loops=3)
                                      Hash Cond: (r.cod_vino = v.cod_vino)
                                      Buffers: shared hit=3867
                                      ->  Parallel Seq Scan on renglon_comprobante r  (cost=0.00..5986.90 rows=214990 width=8) (actual time=0.007..20.511 rows=171992 loops=3)
                                            Buffers: shared hit=3837
                                      ->  Hash  (cost=17.41..17.41 rows=741 width=38) (actual time=0.234..0.235 rows=741 loops=3)
                                            Buckets: 1024  Batches: 1  Memory Usage: 60kB
                                            Buffers: shared hit=30
                                            ->  Seq Scan on vino v  (cost=0.00..17.41 rows=741 width=38) (actual time=0.008..0.098 rows=741 loops=3)
                                                  Buffers: shared hit=30
Planning:
  Buffers: shared hit=22
Planning Time: 0.331 ms
Execution Time: 115.475 ms
```

### S3 · Clientes de cada tipo que compraron en una sala en la última semana

```sql
SELECT cl.tipo, COUNT(DISTINCT cl.id_cliente) AS clientes
  FROM comprobante c
  JOIN cliente cl USING (id_cliente)
 WHERE c.id_sala = 1                                   -- parámetro: sala
   AND c.fecha > CURRENT_DATE - 7
 GROUP BY cl.tipo
```
```
GroupAggregate  (cost=294.45..294.68 rows=3 width=12) (actual time=0.055..0.056 rows=2 loops=1)
  Group Key: cl.tipo
  Buffers: shared hit=63
  ->  Sort  (cost=294.45..294.52 rows=26 width=8) (actual time=0.049..0.050 rows=19 loops=1)
        Sort Key: cl.tipo, cl.id_cliente
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=63
        ->  Nested Loop  (cost=4.85..293.84 rows=26 width=8) (actual time=0.011..0.042 rows=19 loops=1)
              Buffers: shared hit=63
              ->  Bitmap Heap Scan on comprobante c  (cost=4.57..97.91 rows=26 width=4) (actual time=0.008..0.012 rows=19 loops=1)
                    Recheck Cond: ((id_sala = 1) AND (fecha > (CURRENT_DATE - 7)))
                    Heap Blocks: exact=4
                    Buffers: shared hit=6
                    ->  Bitmap Index Scan on ix_comprobante_sala_fecha  (cost=0.00..4.56 rows=26 width=0) (actual time=0.005..0.005 rows=19 loops=1)
                          Index Cond: ((id_sala = 1) AND (fecha > (CURRENT_DATE - 7)))
                          Buffers: shared hit=2
              ->  Index Scan using cliente_pkey on cliente cl  (cost=0.29..7.54 rows=1 width=8) (actual time=0.001..0.001 rows=1 loops=19)
                    Index Cond: (id_cliente = c.id_cliente)
                    Buffers: shared hit=57
Planning:
  Buffers: shared hit=14
Planning Time: 0.146 ms
Execution Time: 0.074 ms
```

### S4 · Top 5 de salas que más pidieron un vino por transferencia en los últimos 15 días

```sql
SELECT t.id_sala, SUM(r.cantidad) AS botellas_solicitadas
  FROM renglon_transferencia r
  JOIN transferencia t USING (nro_solicitud)
 WHERE r.cod_vino = (SELECT cod_vino FROM vino        -- parámetro: vino
                      WHERE nombre = 'Malbec Reserva' AND volumen_ml = 750
                      ORDER BY anada DESC LIMIT 1)
   AND t.fecha_confeccion >= CURRENT_DATE - 15
 GROUP BY t.id_sala
 ORDER BY botellas_solicitadas DESC
 LIMIT 5
```
```
Limit  (cost=165.38..165.39 rows=1 width=12) (actual time=0.369..0.371 rows=0 loops=1)
  Buffers: shared hit=34
  InitPlan 1 (returns $0)
    ->  Limit  (cost=0.28..2.74 rows=1 width=6) (actual time=0.012..0.013 rows=1 loops=1)
          Buffers: shared hit=3
          ->  Index Scan Backward using uq_vino_nombre_anada_volumen on vino  (cost=0.28..44.69 rows=18 width=6) (actual time=0.012..0.012 rows=1 loops=1)
                Index Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
                Buffers: shared hit=3
  ->  Sort  (cost=162.64..162.64 rows=1 width=12) (actual time=0.369..0.370 rows=0 loops=1)
        Sort Key: (sum(r.cantidad)) DESC
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=34
        ->  GroupAggregate  (cost=162.61..162.63 rows=1 width=12) (actual time=0.366..0.368 rows=0 loops=1)
              Group Key: t.id_sala
              Buffers: shared hit=34
              ->  Sort  (cost=162.61..162.61 rows=1 width=8) (actual time=0.366..0.367 rows=0 loops=1)
                    Sort Key: t.id_sala
                    Sort Method: quicksort  Memory: 25kB
                    Buffers: shared hit=34
                    ->  Hash Join  (cost=59.69..162.60 rows=1 width=8) (actual time=0.363..0.364 rows=0 loops=1)
                          Hash Cond: (t.nro_solicitud = r.nro_solicitud)
                          Buffers: shared hit=34
                          ->  Seq Scan on transferencia t  (cost=0.00..102.84 rows=26 width=8) (actual time=0.321..0.325 rows=24 loops=1)
                                Filter: (fecha_confeccion >= (CURRENT_DATE - 15))
                                Rows Removed by Filter: 4424
                                Buffers: shared hit=25
                          ->  Hash  (cost=59.39..59.39 rows=24 width=8) (actual time=0.032..0.033 rows=11 loops=1)
                                Buckets: 1024  Batches: 1  Memory Usage: 9kB
                                Buffers: shared hit=9
                                ->  Bitmap Heap Scan on renglon_transferencia r  (cost=4.47..59.39 rows=24 width=8) (actual time=0.024..0.029 rows=11 loops=1)
                                      Recheck Cond: (cod_vino = $0)
                                      Heap Blocks: exact=4
                                      Buffers: shared hit=9
                                      ->  Bitmap Index Scan on ix_renglon_transferencia_vino  (cost=0.00..4.46 rows=24 width=0) (actual time=0.020..0.020 rows=11 loops=1)
                                            Index Cond: (cod_vino = $0)
                                            Buffers: shared hit=5
Planning:
  Buffers: shared hit=12
Planning Time: 0.283 ms
Execution Time: 0.404 ms
```

### S5 · Salas con menor cantidad de transferencias pendientes

```sql
SELECT s.id_sala, s.calle, s.numero, COUNT(t.nro_solicitud) AS pendientes
  FROM sala_venta s
  LEFT JOIN transferencia t ON t.id_sala = s.id_sala AND t.estado <> 'procesado'
 GROUP BY s.id_sala, s.calle, s.numero
 ORDER BY pendientes, s.id_sala
 LIMIT 5
```
```
Limit  (cost=33.86..33.88 rows=5 width=30) (actual time=0.068..0.070 rows=5 loops=1)
  Buffers: shared hit=4
  ->  Sort  (cost=33.86..33.93 rows=25 width=30) (actual time=0.068..0.069 rows=5 loops=1)
        Sort Key: (count(t.nro_solicitud)), s.id_sala
        Sort Method: top-N heapsort  Memory: 25kB
        Buffers: shared hit=4
        ->  HashAggregate  (cost=33.20..33.45 rows=25 width=30) (actual time=0.034..0.039 rows=25 loops=1)
              Group Key: s.id_sala
              Batches: 1  Memory Usage: 24kB
              Buffers: shared hit=4
              ->  Hash Right Join  (cost=9.78..33.07 rows=25 width=26) (actual time=0.017..0.027 rows=25 loops=1)
                    Hash Cond: (t.id_sala = s.id_sala)
                    Buffers: shared hit=4
                    ->  Bitmap Heap Scan on transferencia t  (cost=8.21..31.46 rows=15 width=8) (actual time=0.005..0.007 rows=15 loops=1)
                          Recheck Cond: (estado <> 'procesado'::estado_documento)
                          Heap Blocks: exact=2
                          Buffers: shared hit=3
                          ->  Bitmap Index Scan on ix_transferencia_pendientes  (cost=0.00..8.21 rows=15 width=0) (actual time=0.002..0.002 rows=15 loops=1)
                                Buffers: shared hit=1
                    ->  Hash  (cost=1.25..1.25 rows=25 width=22) (actual time=0.010..0.010 rows=25 loops=1)
                          Buckets: 1024  Batches: 1  Memory Usage: 10kB
                          Buffers: shared hit=1
                          ->  Seq Scan on sala_venta s  (cost=0.00..1.25 rows=25 width=22) (actual time=0.002..0.005 rows=25 loops=1)
                                Buffers: shared hit=1
Planning:
  Buffers: shared hit=7
Planning Time: 0.105 ms
Execution Time: 0.110 ms
```

### S8 · Monto total de ventas por sala en el último trimestre

```sql
SELECT c.id_sala, SUM(c.total) AS monto_total
  FROM comprobante c
 WHERE c.fecha > CURRENT_DATE - INTERVAL '3 months'
 GROUP BY c.id_sala
 ORDER BY monto_total DESC
```
```
Sort  (cost=1581.75..1581.81 rows=25 width=36) (actual time=4.628..4.630 rows=25 loops=1)
  Sort Key: (sum(total)) DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=117
  ->  HashAggregate  (cost=1580.86..1581.17 rows=25 width=36) (actual time=4.607..4.615 rows=25 loops=1)
        Group Key: id_sala
        Batches: 1  Memory Usage: 32kB
        Buffers: shared hit=117
        ->  Bitmap Heap Scan on comprobante c  (cost=13.91..1543.41 rows=7490 width=12) (actual time=0.952..2.370 rows=7404 loops=1)
              Recheck Cond: (fecha > (CURRENT_DATE - '3 mons'::interval))
              Rows Removed by Index Recheck: 6055
              Heap Blocks: lossy=115
              Buffers: shared hit=117
              ->  Bitmap Index Scan on ix_comprobante_fecha_brin  (cost=0.00..12.04 rows=15000 width=0) (actual time=0.010..0.011 rows=1150 loops=1)
                    Index Cond: (fecha > (CURRENT_DATE - '3 mons'::interval))
                    Buffers: shared hit=2
Planning:
  Buffers: shared hit=1
Planning Time: 0.092 ms
Execution Time: 4.658 ms
```

### S9 · Ficha de un vino: stock total (depósito + salas)

```sql
SELECT v.cod_vino, v.nombre, v.anada,
       COALESCE((SELECT d.cantidad FROM stock_deposito d WHERE d.cod_vino = v.cod_vino), 0) AS deposito,
       COALESCE((SELECT SUM(s.cantidad) FROM stock_sala s WHERE s.cod_vino = v.cod_vino), 0) AS salas
  FROM vino v
 WHERE v.nombre = 'Malbec Reserva' AND v.volumen_ml = 750; -- parámetro: vino
```
```
Bitmap Heap Scan on vino v  (cost=4.52..425.54 rows=18 width=46) (actual time=0.017..0.060 rows=8 loops=1)
  Recheck Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
  Heap Blocks: exact=1
  Buffers: shared hit=56
  ->  Bitmap Index Scan on uq_vino_nombre_anada_volumen  (cost=0.00..4.52 rows=18 width=0) (actual time=0.007..0.007 rows=8 loops=1)
        Index Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
        Buffers: shared hit=2
  SubPlan 1
    ->  Index Scan using stock_deposito_pkey on stock_deposito d  (cost=0.28..8.29 rows=1 width=4) (actual time=0.001..0.001 rows=1 loops=8)
          Index Cond: (cod_vino = v.cod_vino)
          Buffers: shared hit=23
  SubPlan 2
    ->  Aggregate  (cost=14.52..14.53 rows=1 width=8) (actual time=0.004..0.004 rows=1 loops=8)
          Buffers: shared hit=30
          ->  Bitmap Heap Scan on stock_sala s  (cost=4.34..14.50 rows=8 width=4) (actual time=0.002..0.003 rows=2 loops=8)
                Recheck Cond: (cod_vino = v.cod_vino)
                Heap Blocks: exact=14
                Buffers: shared hit=30
                ->  Bitmap Index Scan on ix_stock_sala_vino  (cost=0.00..4.34 rows=8 width=0) (actual time=0.001..0.001 rows=2 loops=8)
                      Index Cond: (cod_vino = v.cod_vino)
                      Buffers: shared hit=16
Planning Time: 0.098 ms
Execution Time: 0.082 ms
```

### S12 · Clientes que nunca compraron un vino tinto (anti-join)

```sql
SELECT COUNT(*) AS clientes_sin_tintos
  FROM cliente cl
 WHERE NOT EXISTS (SELECT 1
                     FROM comprobante c
                     JOIN renglon_comprobante r USING (nro)
                     JOIN vino v USING (cod_vino)
                    WHERE c.id_cliente = cl.id_cliente
                      AND v.tipo = 'tinto')
```
```
Aggregate  (cost=20180.77..20180.78 rows=1 width=8) (actual time=237.293..237.300 rows=1 loops=1)
  Buffers: shared hit=5385
  ->  Hash Right Anti Join  (cost=5388.79..20161.75 rows=7607 width=0) (actual time=236.662..237.143 rows=3572 loops=1)
        Hash Cond: (c.id_cliente = cl.id_cliente)
        Buffers: shared hit=5385
        ->  Hash Join  (cost=4667.79..15980.90 rows=363482 width=4) (actual time=38.079..196.570 rows=302150 loops=1)
              Hash Cond: (r.nro = c.nro)
              Buffers: shared hit=5114
              ->  Hash Join  (cost=25.79..10384.74 rows=363482 width=4) (actual time=0.137..97.087 rows=302150 loops=1)
                    Hash Cond: (r.cod_vino = v.cod_vino)
                    Buffers: shared hit=3847
                    ->  Seq Scan on renglon_comprobante r  (cost=0.00..8996.77 rows=515977 width=8) (actual time=0.007..32.070 rows=515977 loops=1)
                          Buffers: shared hit=3837
                    ->  Hash  (cost=19.26..19.26 rows=522 width=4) (actual time=0.122..0.123 rows=522 loops=1)
                          Buckets: 1024  Batches: 1  Memory Usage: 27kB
                          Buffers: shared hit=10
                          ->  Seq Scan on vino v  (cost=0.00..19.26 rows=522 width=4) (actual time=0.006..0.080 rows=522 loops=1)
                                Filter: (tipo = 'tinto'::tipo_vino)
                                Rows Removed by Filter: 219
                                Buffers: shared hit=10
              ->  Hash  (cost=2767.00..2767.00 rows=150000 width=8) (actual time=37.746..37.746 rows=150000 loops=1)
                    Buckets: 262144  Batches: 1  Memory Usage: 7908kB
                    Buffers: shared hit=1267
                    ->  Seq Scan on comprobante c  (cost=0.00..2767.00 rows=150000 width=8) (actual time=0.008..14.275 rows=150000 loops=1)
                          Buffers: shared hit=1267
        ->  Hash  (cost=471.00..471.00 rows=20000 width=4) (actual time=2.853..2.854 rows=20000 loops=1)
              Buckets: 32768  Batches: 1  Memory Usage: 960kB
              Buffers: shared hit=271
              ->  Seq Scan on cliente cl  (cost=0.00..471.00 rows=20000 width=4) (actual time=0.003..1.430 rows=20000 loops=1)
                    Buffers: shared hit=271
Planning:
  Buffers: shared hit=46
Planning Time: 0.419 ms
Execution Time: 237.368 ms
```

### HC · Historial de compras de un cliente (GET /clientes/{id}/comprobantes de la API)

```sql
SELECT c.nro, c.fecha, c.id_sala, c.total
  FROM comprobante c
 WHERE c.id_cliente = 143                               -- parámetro: cliente (49 compras)
 ORDER BY c.fecha DESC
```
```
Sort  (cost=205.09..205.24 rows=60 width=20) (actual time=0.054..0.057 rows=49 loops=1)
  Sort Key: fecha DESC
  Sort Method: quicksort  Memory: 27kB
  Buffers: shared hit=48
  ->  Bitmap Heap Scan on comprobante c  (cost=4.76..203.31 rows=60 width=20) (actual time=0.014..0.043 rows=49 loops=1)
        Recheck Cond: (id_cliente = 143)
        Heap Blocks: exact=46
        Buffers: shared hit=48
        ->  Bitmap Index Scan on ix_comprobante_cliente  (cost=0.00..4.75 rows=60 width=0) (actual time=0.007..0.007 rows=49 loops=1)
              Index Cond: (id_cliente = 143)
              Buffers: shared hit=2
Planning Time: 0.041 ms
Execution Time: 0.070 ms
```


## Borrar un vino sin movimientos (control de FK, RN-14)

`DELETE FROM vino WHERE cod_vino = <vino nuevo sin movimientos>` (se revierte)

### Antes
```
Delete on vino  (cost=0.28..8.29 rows=0 width=0) (actual time=0.043..0.043 rows=0 loops=1)
  Buffers: shared hit=5
  ->  Index Scan using vino_pkey on vino  (cost=0.28..8.29 rows=1 width=6) (actual time=0.015..0.017 rows=1 loops=1)
        Index Cond: (cod_vino = 793)
        Buffers: shared hit=3
Planning Time: 0.056 ms
Trigger for constraint composicion_vino_cod_vino_fkey: time=0.039 calls=1
Trigger for constraint vino_maridaje_cod_vino_fkey: time=0.018 calls=1
Trigger for constraint renglon_comprobante_cod_vino_fkey: time=31.022 calls=1
Trigger for constraint renglon_ingreso_cod_vino_fkey: time=0.294 calls=1
Trigger for constraint renglon_transferencia_cod_vino_fkey: time=0.944 calls=1
Trigger for constraint stock_sala_cod_vino_fkey: time=0.127 calls=1
Trigger for constraint stock_deposito_cod_vino_fkey: time=0.085 calls=1
Trigger for constraint auditoria_precio_cod_vino_fkey: time=0.299 calls=1
Execution Time: 32.897 ms
```
### Después
```
Delete on vino  (cost=0.28..8.29 rows=0 width=0) (actual time=0.055..0.055 rows=0 loops=1)
  Buffers: shared hit=5
  ->  Index Scan using vino_pkey on vino  (cost=0.28..8.29 rows=1 width=6) (actual time=0.040..0.041 rows=1 loops=1)
        Index Cond: (cod_vino = 794)
        Buffers: shared hit=3
Planning Time: 0.038 ms
Trigger for constraint composicion_vino_cod_vino_fkey: time=0.026 calls=1
Trigger for constraint vino_maridaje_cod_vino_fkey: time=0.009 calls=1
Trigger for constraint renglon_comprobante_cod_vino_fkey: time=0.050 calls=1
Trigger for constraint renglon_ingreso_cod_vino_fkey: time=0.216 calls=1
Trigger for constraint renglon_transferencia_cod_vino_fkey: time=0.045 calls=1
Trigger for constraint stock_sala_cod_vino_fkey: time=0.012 calls=1
Trigger for constraint stock_deposito_cod_vino_fkey: time=0.010 calls=1
Trigger for constraint auditoria_precio_cod_vino_fkey: time=0.231 calls=1
Execution Time: 0.669 ms
```


## Experimentos

### Índice compuesto en orden inverso (fecha, id_sala) · S3
```
GroupAggregate  (cost=280.18..280.43 rows=3 width=12) (actual time=0.085..0.087 rows=2 loops=1)
  Group Key: cl.tipo
  Buffers: shared hit=64
  ->  Sort  (cost=280.18..280.25 rows=29 width=8) (actual time=0.077..0.079 rows=19 loops=1)
        Sort Key: cl.tipo, cl.id_cliente
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=64
        ->  Nested Loop  (cost=0.59..279.48 rows=29 width=8) (actual time=0.012..0.068 rows=19 loops=1)
              Buffers: shared hit=64
              ->  Index Scan using ix_tmp_fecha_sala on comprobante c  (cost=0.30..62.63 rows=29 width=4) (actual time=0.007..0.014 rows=19 loops=1)
                    Index Cond: ((fecha > (CURRENT_DATE - 7)) AND (id_sala = 1))
                    Buffers: shared hit=7
              ->  Index Scan using cliente_pkey on cliente cl  (cost=0.29..7.48 rows=1 width=8) (actual time=0.002..0.002 rows=1 loops=19)
                    Index Cond: (id_cliente = c.id_cliente)
                    Buffers: shared hit=57
Planning:
  Buffers: shared hit=17
Planning Time: 0.196 ms
Execution Time: 0.109 ms
```
### Ventas mensuales de la sala 5 · (id_sala, fecha)
```
Sort  (cost=1702.25..1707.57 rows=2128 width=40) (actual time=4.365..4.369 rows=73 loops=1)
  Sort Key: (date_trunc('month'::text, (fecha)::timestamp with time zone))
  Sort Method: quicksort  Memory: 28kB
  Buffers: shared hit=1277
  ->  HashAggregate  (cost=1547.38..1584.62 rows=2128 width=40) (actual time=4.322..4.350 rows=73 loops=1)
        Group Key: date_trunc('month'::text, (fecha)::timestamp with time zone)
        Batches: 1  Memory Usage: 145kB
        Buffers: shared hit=1277
        ->  Bitmap Heap Scan on comprobante  (cost=110.73..1509.68 rows=7540 width=16) (actual time=0.344..3.080 rows=7533 loops=1)
              Recheck Cond: (id_sala = 5)
              Heap Blocks: exact=1264
              Buffers: shared hit=1277
              ->  Bitmap Index Scan on ix_comprobante_sala_fecha  (cost=0.00..108.84 rows=7540 width=0) (actual time=0.212..0.212 rows=7533 loops=1)
                    Index Cond: (id_sala = 5)
                    Buffers: shared hit=13
Planning Time: 0.066 ms
Execution Time: 4.409 ms
```
### Ventas mensuales de la sala 5 · (fecha, id_sala)
```
Sort  (cost=3371.71..3377.02 rows=2126 width=40) (actual time=14.277..14.283 rows=73 loops=1)
  Sort Key: (date_trunc('month'::text, (fecha)::timestamp with time zone))
  Sort Method: quicksort  Memory: 28kB
  Buffers: shared hit=1267
  ->  HashAggregate  (cost=3217.00..3254.21 rows=2126 width=40) (actual time=14.227..14.259 rows=73 loops=1)
        Group Key: date_trunc('month'::text, (fecha)::timestamp with time zone)
        Batches: 1  Memory Usage: 145kB
        Buffers: shared hit=1267
        ->  Seq Scan on comprobante  (cost=0.00..3179.50 rows=7500 width=16) (actual time=0.012..12.280 rows=7533 loops=1)
              Filter: (id_sala = 5)
              Rows Removed by Filter: 142467
              Buffers: shared hit=1267
Planning Time: 0.138 ms
Execution Time: 14.316 ms
```
### B-tree sobre fecha · S8
```
Sort  (cost=260.66..260.72 rows=25 width=36) (actual time=4.681..4.682 rows=25 loops=1)
  Sort Key: (sum(total)) DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=72
  ->  HashAggregate  (cost=259.76..260.08 rows=25 width=36) (actual time=4.665..4.670 rows=25 loops=1)
        Group Key: id_sala
        Batches: 1  Memory Usage: 32kB
        Buffers: shared hit=72
        ->  Index Scan using ix_tmp_fecha_btree on comprobante c  (cost=0.30..223.00 rows=7354 width=12) (actual time=0.010..1.025 rows=7404 loops=1)
              Index Cond: (fecha > (CURRENT_DATE - '3 mons'::interval))
              Buffers: shared hit=72
Planning Time: 0.070 ms
Execution Time: 4.702 ms
```
### cliente (tipo) · socio (índice creado)
```
GroupAggregate  (cost=721.19..4182.32 rows=1 width=12) (actual time=38.070..38.074 rows=1 loops=1)
  Buffers: shared hit=1538
  ->  Hash Join  (cost=721.19..3882.03 rows=120112 width=4) (actual time=3.172..32.415 rows=119202 loops=1)
        Hash Cond: (c.id_cliente = cl.id_cliente)
        Buffers: shared hit=1538
        ->  Seq Scan on comprobante c  (cost=0.00..2767.00 rows=150000 width=4) (actual time=0.004..8.325 rows=150000 loops=1)
              Buffers: shared hit=1267
        ->  Hash  (cost=521.00..521.00 rows=16015 width=8) (actual time=3.154..3.156 rows=16015 loops=1)
              Buckets: 16384  Batches: 1  Memory Usage: 754kB
              Buffers: shared hit=271
              ->  Seq Scan on cliente cl  (cost=0.00..521.00 rows=16015 width=8) (actual time=0.003..1.670 rows=16015 loops=1)
                    Filter: (tipo = 'socio'::tipo_cliente)
                    Rows Removed by Filter: 3985
                    Buffers: shared hit=271
Planning:
  Buffers: shared hit=13
Planning Time: 0.203 ms
Execution Time: 38.113 ms
```
### cliente (tipo) · exportador (índice creado)
```
GroupAggregate  (cost=12.40..1641.27 rows=1 width=12) (actual time=2.853..2.854 rows=1 loops=1)
  Buffers: shared hit=2287
  ->  Nested Loop  (cost=12.40..1622.34 rows=7568 width=4) (actual time=0.060..2.451 rows=7917 loops=1)
        Buffers: shared hit=2287
        ->  Bitmap Heap Scan on cliente cl  (cost=12.11..295.72 rows=1009 width=8) (actual time=0.056..0.314 rows=1009 loops=1)
              Recheck Cond: (tipo = 'exportador'::tipo_cliente)
              Heap Blocks: exact=266
              Buffers: shared hit=268
              ->  Bitmap Index Scan on ix_tmp_cliente_tipo  (cost=0.00..11.85 rows=1009 width=0) (actual time=0.029..0.029 rows=1009 loops=1)
                    Index Cond: (tipo = 'exportador'::tipo_cliente)
                    Buffers: shared hit=2
        ->  Index Only Scan using ix_comprobante_cliente on comprobante c  (cost=0.29..1.19 rows=12 width=4) (actual time=0.001..0.001 rows=8 loops=1009)
              Index Cond: (id_cliente = cl.id_cliente)
              Heap Fetches: 0
              Buffers: shared hit=2019
Planning:
  Buffers: shared hit=13
Planning Time: 0.153 ms
Execution Time: 2.877 ms
```
### Estadísticas desactualizadas · antes de ANALYZE
```
Aggregate  (cost=23.65..23.66 rows=1 width=40) (actual time=10.892..10.893 rows=1 loops=1)
  Buffers: shared hit=490
  ->  Bitmap Heap Scan on comprobante  (cost=4.35..23.62 rows=5 width=8) (actual time=0.884..5.094 rows=60000 loops=1)
        Recheck Cond: ((id_sala = 1) AND (fecha = CURRENT_DATE))
        Heap Blocks: exact=442
        Buffers: shared hit=490
        ->  Bitmap Index Scan on ix_comprobante_sala_fecha  (cost=0.00..4.35 rows=5 width=0) (actual time=0.844..0.844 rows=60000 loops=1)
              Index Cond: ((id_sala = 1) AND (fecha = CURRENT_DATE))
              Buffers: shared hit=48
Planning:
  Buffers: shared hit=1
Planning Time: 0.069 ms
Execution Time: 10.914 ms
```
### Estadísticas desactualizadas · después de ANALYZE
```
Aggregate  (cost=2462.00..2462.01 rows=1 width=40) (actual time=10.526..10.527 rows=1 loops=1)
  Buffers: shared hit=490
  ->  Bitmap Heap Scan on comprobante  (cost=313.14..2364.03 rows=19594 width=6) (actual time=0.871..4.957 rows=60000 loops=1)
        Recheck Cond: ((id_sala = 1) AND (fecha = CURRENT_DATE))
        Heap Blocks: exact=442
        Buffers: shared hit=490
        ->  Bitmap Index Scan on ix_comprobante_sala_fecha  (cost=0.00..308.24 rows=19594 width=0) (actual time=0.833..0.833 rows=60000 loops=1)
              Index Cond: ((id_sala = 1) AND (fecha = CURRENT_DATE))
              Buffers: shared hit=48
Planning:
  Buffers: shared hit=1
Planning Time: 0.067 ms
Execution Time: 10.545 ms
```
