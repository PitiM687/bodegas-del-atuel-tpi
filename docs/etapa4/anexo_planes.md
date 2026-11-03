# Anexo · Planes de ejecución completos

PostgreSQL 18.6. Generado por `db/scripts/medir_indices.py` el 2026-11-03 10:36. Cada plan es `EXPLAIN (ANALYZE, BUFFERS)` de una ejecución con la caché ya caliente.


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
Limit  (cost=8938.25..8938.27 rows=10 width=46) (actual time=124.304..128.273 rows=10.00 loops=1)
  Buffers: shared hit=3881
  ->  Sort  (cost=8938.25..8940.10 rows=741 width=46) (actual time=124.303..128.270 rows=10.00 loops=1)
        Sort Key: (sum(r.cantidad)) DESC
        Sort Method: top-N heapsort  Memory: 25kB
        Buffers: shared hit=3881
        ->  Finalize GroupAggregate  (cost=8698.86..8922.23 rows=741 width=46) (actual time=123.415..128.132 rows=667.00 loops=1)
              Group Key: v.cod_vino
              Buffers: shared hit=3881
              ->  Gather Merge  (cost=8698.86..8905.93 rows=1778 width=46) (actual time=123.410..127.718 rows=1918.00 loops=1)
                    Workers Planned: 2
                    Workers Launched: 2
                    Buffers: shared hit=3881
                    ->  Sort  (cost=7698.83..7700.69 rows=741 width=46) (actual time=92.681..92.727 rows=639.33 loops=3)
                          Sort Key: v.cod_vino
                          Sort Method: quicksort  Memory: 67kB
                          Buffers: shared hit=3881
                          Worker 0:  Sort Method: quicksort  Memory: 64kB
                          Worker 1:  Sort Method: quicksort  Memory: 66kB
                          ->  Partial HashAggregate  (cost=7656.10..7663.51 rows=741 width=46) (actual time=92.421..92.525 rows=639.33 loops=3)
                                Group Key: v.cod_vino
                                Batches: 1  Memory Usage: 105kB
                                Buffers: shared hit=3867
                                Worker 0:  Batches: 1  Memory Usage: 105kB
                                Worker 1:  Batches: 1  Memory Usage: 105kB
                                ->  Hash Join  (cost=26.67..6581.15 rows=214990 width=42) (actual time=0.803..61.593 rows=171992.33 loops=3)
                                      Hash Cond: (r.cod_vino = v.cod_vino)
                                      Buffers: shared hit=3867
                                      ->  Parallel Seq Scan on renglon_comprobante r  (cost=0.00..5986.90 rows=214990 width=8) (actual time=0.009..13.785 rows=171992.33 loops=3)
                                            Buffers: shared hit=3837
                                      ->  Hash  (cost=17.41..17.41 rows=741 width=38) (actual time=0.783..0.783 rows=741.00 loops=3)
                                            Buckets: 1024  Batches: 1  Memory Usage: 60kB
                                            Buffers: shared hit=30
                                            ->  Seq Scan on vino v  (cost=0.00..17.41 rows=741 width=38) (actual time=0.530..0.643 rows=741.00 loops=3)
                                                  Buffers: shared hit=30
Planning:
  Buffers: shared hit=6
Planning Time: 0.228 ms
Execution Time: 128.368 ms
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
GroupAggregate  (cost=4159.18..4162.66 rows=3 width=12) (actual time=30.648..34.327 rows=2.00 loops=1)
  Group Key: cl.tipo
  Buffers: shared hit=1339
  ->  Gather Merge  (cost=4159.18..4162.49 rows=29 width=8) (actual time=30.634..34.314 rows=19.00 loops=1)
        Workers Planned: 1
        Workers Launched: 1
        Buffers: shared hit=1339
        ->  Sort  (cost=3159.17..3159.21 rows=17 width=8) (actual time=5.880..5.881 rows=9.50 loops=2)
              Sort Key: cl.tipo, cl.id_cliente
              Sort Method: quicksort  Memory: 25kB
              Buffers: shared hit=1339
              Worker 0:  Sort Method: quicksort  Memory: 25kB
              ->  Nested Loop  (cost=0.29..3158.82 rows=17 width=8) (actual time=5.789..5.834 rows=9.50 loops=2)
                    Buffers: shared hit=1324
                    ->  Parallel Seq Scan on comprobante c  (cost=0.00..3031.71 rows=17 width=4) (actual time=5.776..5.793 rows=9.50 loops=2)
                          Filter: ((id_sala = 1) AND (fecha > (CURRENT_DATE - 7)))
                          Rows Removed by Filter: 74990
                          Buffers: shared hit=1267
                    ->  Index Scan using cliente_pkey on cliente cl  (cost=0.29..7.48 rows=1 width=8) (actual time=0.004..0.004 rows=1.00 loops=19)
                          Index Cond: (id_cliente = c.id_cliente)
                          Index Searches: 19
                          Buffers: shared hit=57
Planning:
  Buffers: shared hit=7
Planning Time: 0.268 ms
Execution Time: 34.373 ms
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
Limit  (cost=290.09..290.10 rows=1 width=12) (actual time=0.399..0.400 rows=0.00 loops=1)
  Buffers: shared hit=76
  InitPlan 1
    ->  Limit  (cost=0.28..2.74 rows=1 width=6) (actual time=0.015..0.016 rows=1.00 loops=1)
          Buffers: shared hit=3
          ->  Index Scan Backward using uq_vino_nombre_anada_volumen on vino  (cost=0.28..44.67 rows=18 width=6) (actual time=0.015..0.015 rows=1.00 loops=1)
                Index Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
                Index Searches: 1
                Buffers: shared hit=3
  ->  Sort  (cost=287.35..287.36 rows=1 width=12) (actual time=0.399..0.399 rows=0.00 loops=1)
        Sort Key: (sum(r.cantidad)) DESC
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=76
        ->  GroupAggregate  (cost=287.32..287.34 rows=1 width=12) (actual time=0.397..0.398 rows=0.00 loops=1)
              Group Key: t.id_sala
              Buffers: shared hit=76
              ->  Sort  (cost=287.32..287.33 rows=1 width=8) (actual time=0.397..0.397 rows=0.00 loops=1)
                    Sort Key: t.id_sala
                    Sort Method: quicksort  Memory: 25kB
                    Buffers: shared hit=76
                    ->  Nested Loop  (cost=0.29..287.31 rows=1 width=8) (actual time=0.396..0.396 rows=0.00 loops=1)
                          Buffers: shared hit=76
                          ->  Seq Scan on transferencia t  (cost=0.00..102.84 rows=26 width=8) (actual time=0.344..0.348 rows=24.00 loops=1)
                                Filter: (fecha_confeccion >= (CURRENT_DATE - 15))
                                Rows Removed by Filter: 4424
                                Buffers: shared hit=25
                          ->  Index Scan using renglon_transferencia_pkey on renglon_transferencia r  (cost=0.29..7.07 rows=1 width=8) (actual time=0.001..0.001 rows=0.00 loops=24)
                                Index Cond: ((nro_solicitud = t.nro_solicitud) AND (cod_vino = (InitPlan 1).col1))
                                Index Searches: 24
                                Buffers: shared hit=48
Planning:
  Buffers: shared hit=12
Planning Time: 0.220 ms
Execution Time: 0.423 ms
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
Limit  (cost=83.65..83.66 rows=5 width=30) (actual time=0.486..0.488 rows=5.00 loops=1)
  Buffers: shared hit=26
  ->  Sort  (cost=83.65..83.71 rows=25 width=30) (actual time=0.485..0.487 rows=5.00 loops=1)
        Sort Key: (count(t.nro_solicitud)), s.id_sala
        Sort Method: top-N heapsort  Memory: 25kB
        Buffers: shared hit=26
        ->  GroupAggregate  (cost=82.79..83.23 rows=25 width=30) (actual time=0.456..0.474 rows=25.00 loops=1)
              Group Key: s.id_sala
              Buffers: shared hit=26
              ->  Sort  (cost=82.79..82.86 rows=25 width=26) (actual time=0.453..0.455 rows=25.00 loops=1)
                    Sort Key: s.id_sala
                    Sort Method: quicksort  Memory: 26kB
                    Buffers: shared hit=26
                    ->  Hash Right Join  (cost=1.56..82.21 rows=25 width=26) (actual time=0.430..0.444 rows=25.00 loops=1)
                          Hash Cond: (t.id_sala = s.id_sala)
                          Buffers: shared hit=26
                          ->  Seq Scan on transferencia t  (cost=0.00..80.60 rows=15 width=8) (actual time=0.404..0.408 rows=15.00 loops=1)
                                Filter: (estado <> 'procesado'::estado_documento)
                                Rows Removed by Filter: 4433
                                Buffers: shared hit=25
                          ->  Hash  (cost=1.25..1.25 rows=25 width=22) (actual time=0.022..0.023 rows=25.00 loops=1)
                                Buckets: 1024  Batches: 1  Memory Usage: 10kB
                                Buffers: shared hit=1
                                ->  Seq Scan on sala_venta s  (cost=0.00..1.25 rows=25 width=22) (actual time=0.012..0.016 rows=25.00 loops=1)
                                      Buffers: shared hit=1
Planning:
  Buffers: shared hit=4
Planning Time: 0.161 ms
Execution Time: 0.521 ms
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
Sort  (cost=3839.66..3839.72 rows=25 width=36) (actual time=39.146..43.473 rows=25.00 loops=1)
  Sort Key: (sum(total)) DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=1274
  ->  Finalize GroupAggregate  (cost=3833.66..3839.08 rows=25 width=36) (actual time=39.113..43.461 rows=25.00 loops=1)
        Group Key: id_sala
        Buffers: shared hit=1274
        ->  Gather Merge  (cost=3833.66..3838.45 rows=42 width=36) (actual time=39.101..43.430 rows=25.00 loops=1)
              Workers Planned: 1
              Workers Launched: 1
              Buffers: shared hit=1274
              ->  Sort  (cost=2833.65..2833.71 rows=25 width=36) (actual time=14.557..14.559 rows=12.50 loops=2)
                    Sort Key: id_sala
                    Sort Method: quicksort  Memory: 27kB
                    Buffers: shared hit=1274
                    Worker 0:  Sort Method: quicksort  Memory: 25kB
                    ->  Partial HashAggregate  (cost=2832.76..2833.07 rows=25 width=36) (actual time=14.535..14.541 rows=12.50 loops=2)
                          Group Key: id_sala
                          Batches: 1  Memory Usage: 32kB
                          Buffers: shared hit=1267
                          Worker 0:  Batches: 1  Memory Usage: 32kB
                          ->  Parallel Seq Scan on comprobante c  (cost=0.00..2811.12 rows=4328 width=12) (actual time=12.549..13.344 rows=3702.00 loops=2)
                                Filter: (fecha > (CURRENT_DATE - '3 mons'::interval))
                                Rows Removed by Filter: 71298
                                Buffers: shared hit=1267
Planning Time: 0.115 ms
Execution Time: 43.518 ms
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
Bitmap Heap Scan on vino v  (cost=4.52..747.79 rows=18 width=46) (actual time=0.161..1.097 rows=8.00 loops=1)
  Recheck Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
  Heap Blocks: exact=1
  Buffers: shared hit=106
  ->  Bitmap Index Scan on uq_vino_nombre_anada_volumen  (cost=0.00..4.52 rows=18 width=0) (actual time=0.019..0.020 rows=8.00 loops=1)
        Index Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
        Index Searches: 1
        Buffers: shared hit=2
  SubPlan 1
    ->  Index Scan using stock_deposito_pkey on stock_deposito d  (cost=0.28..8.29 rows=1 width=4) (actual time=0.002..0.002 rows=0.88 loops=8)
          Index Cond: (cod_vino = v.cod_vino)
          Index Searches: 8
          Buffers: shared hit=23
  SubPlan 2
    ->  Aggregate  (cost=32.42..32.43 rows=1 width=8) (actual time=0.129..0.130 rows=1.00 loops=8)
          Buffers: shared hit=80
          ->  Seq Scan on stock_sala s  (cost=0.00..32.40 rows=8 width=4) (actual time=0.095..0.126 rows=2.25 loops=8)
                Filter: (cod_vino = v.cod_vino)
                Rows Removed by Filter: 1790
                Buffers: shared hit=80
Planning Time: 0.121 ms
Execution Time: 1.124 ms
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
Aggregate  (cost=20207.52..20207.53 rows=1 width=8) (actual time=280.317..280.320 rows=1.00 loops=1)
  Buffers: shared hit=5385
  ->  Hash Right Anti Join  (cost=5388.79..20188.84 rows=7473 width=0) (actual time=279.538..280.126 rows=3572.00 loops=1)
        Hash Cond: (c.id_cliente = cl.id_cliente)
        Buffers: shared hit=5385
        ->  Hash Join  (cost=4667.79..15980.90 rows=363482 width=4) (actual time=37.554..231.800 rows=302150.00 loops=1)
              Hash Cond: (r.nro = c.nro)
              Buffers: shared hit=5114
              ->  Hash Join  (cost=25.79..10384.74 rows=363482 width=4) (actual time=0.174..113.659 rows=302150.00 loops=1)
                    Hash Cond: (r.cod_vino = v.cod_vino)
                    Buffers: shared hit=3847
                    ->  Seq Scan on renglon_comprobante r  (cost=0.00..8996.77 rows=515977 width=8) (actual time=0.013..29.495 rows=515977.00 loops=1)
                          Buffers: shared hit=3837
                    ->  Hash  (cost=19.26..19.26 rows=522 width=4) (actual time=0.154..0.154 rows=522.00 loops=1)
                          Buckets: 1024  Batches: 1  Memory Usage: 27kB
                          Buffers: shared hit=10
                          ->  Seq Scan on vino v  (cost=0.00..19.26 rows=522 width=4) (actual time=0.009..0.091 rows=522.00 loops=1)
                                Filter: (tipo = 'tinto'::tipo_vino)
                                Rows Removed by Filter: 219
                                Buffers: shared hit=10
              ->  Hash  (cost=2767.00..2767.00 rows=150000 width=8) (actual time=37.050..37.050 rows=150000.00 loops=1)
                    Buckets: 262144  Batches: 1  Memory Usage: 7908kB
                    Buffers: shared hit=1267
                    ->  Seq Scan on comprobante c  (cost=0.00..2767.00 rows=150000 width=8) (actual time=0.018..14.840 rows=150000.00 loops=1)
                          Buffers: shared hit=1267
        ->  Hash  (cost=471.00..471.00 rows=20000 width=4) (actual time=3.749..3.749 rows=20000.00 loops=1)
              Buckets: 32768  Batches: 1  Memory Usage: 960kB
              Buffers: shared hit=271
              ->  Seq Scan on cliente cl  (cost=0.00..471.00 rows=20000 width=4) (actual time=0.015..1.640 rows=20000.00 loops=1)
                    Buffers: shared hit=271
Planning:
  Buffers: shared hit=31
Planning Time: 0.573 ms
Execution Time: 281.152 ms
```

### HC · Historial de compras de un cliente (GET /clientes/{id}/comprobantes de la API)

```sql
SELECT c.nro, c.fecha, c.id_sala, c.total
  FROM comprobante c
 WHERE c.id_cliente = 143                               -- parámetro: cliente (49 compras)
 ORDER BY c.fecha DESC
```
```
Sort  (cost=3142.22..3142.25 rows=12 width=20) (actual time=9.038..9.041 rows=49.00 loops=1)
  Sort Key: fecha DESC
  Sort Method: quicksort  Memory: 26kB
  Buffers: shared hit=1267
  ->  Seq Scan on comprobante c  (cost=0.00..3142.00 rows=12 width=20) (actual time=0.115..9.025 rows=49.00 loops=1)
        Filter: (id_cliente = 143)
        Rows Removed by Filter: 149951
        Buffers: shared hit=1267
Planning Time: 0.071 ms
Execution Time: 9.060 ms
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
Limit  (cost=8938.25..8938.27 rows=10 width=46) (actual time=110.443..114.699 rows=10.00 loops=1)
  Buffers: shared hit=3881
  ->  Sort  (cost=8938.25..8940.10 rows=741 width=46) (actual time=110.442..114.697 rows=10.00 loops=1)
        Sort Key: (sum(r.cantidad)) DESC
        Sort Method: top-N heapsort  Memory: 25kB
        Buffers: shared hit=3881
        ->  Finalize GroupAggregate  (cost=8698.86..8922.23 rows=741 width=46) (actual time=109.632..114.557 rows=667.00 loops=1)
              Group Key: v.cod_vino
              Buffers: shared hit=3881
              ->  Gather Merge  (cost=8698.86..8905.93 rows=1778 width=46) (actual time=109.627..114.197 rows=1929.00 loops=1)
                    Workers Planned: 2
                    Workers Launched: 2
                    Buffers: shared hit=3881
                    ->  Sort  (cost=7698.83..7700.69 rows=741 width=46) (actual time=82.057..82.084 rows=643.00 loops=3)
                          Sort Key: v.cod_vino
                          Sort Method: quicksort  Memory: 67kB
                          Buffers: shared hit=3881
                          Worker 0:  Sort Method: quicksort  Memory: 66kB
                          Worker 1:  Sort Method: quicksort  Memory: 65kB
                          ->  Partial HashAggregate  (cost=7656.10..7663.51 rows=741 width=46) (actual time=81.802..81.902 rows=643.00 loops=3)
                                Group Key: v.cod_vino
                                Batches: 1  Memory Usage: 105kB
                                Buffers: shared hit=3867
                                Worker 0:  Batches: 1  Memory Usage: 105kB
                                Worker 1:  Batches: 1  Memory Usage: 105kB
                                ->  Hash Join  (cost=26.67..6581.15 rows=214990 width=42) (actual time=0.815..52.831 rows=171992.33 loops=3)
                                      Hash Cond: (r.cod_vino = v.cod_vino)
                                      Buffers: shared hit=3867
                                      ->  Parallel Seq Scan on renglon_comprobante r  (cost=0.00..5986.90 rows=214990 width=8) (actual time=0.009..9.104 rows=171992.33 loops=3)
                                            Buffers: shared hit=3837
                                      ->  Hash  (cost=17.41..17.41 rows=741 width=38) (actual time=0.796..0.796 rows=741.00 loops=3)
                                            Buckets: 1024  Batches: 1  Memory Usage: 60kB
                                            Buffers: shared hit=30
                                            ->  Seq Scan on vino v  (cost=0.00..17.41 rows=741 width=38) (actual time=0.564..0.675 rows=741.00 loops=3)
                                                  Buffers: shared hit=30
Planning:
  Buffers: shared hit=15
Planning Time: 0.292 ms
Execution Time: 114.819 ms
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
GroupAggregate  (cost=255.47..255.66 rows=3 width=12) (actual time=0.072..0.073 rows=2.00 loops=1)
  Group Key: cl.tipo
  Buffers: shared hit=63
  ->  Sort  (cost=255.47..255.52 rows=22 width=8) (actual time=0.067..0.068 rows=19.00 loops=1)
        Sort Key: cl.tipo, cl.id_cliente
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=63
        ->  Nested Loop  (cost=4.81..254.98 rows=22 width=8) (actual time=0.020..0.060 rows=19.00 loops=1)
              Buffers: shared hit=63
              ->  Bitmap Heap Scan on comprobante c  (cost=4.53..84.27 rows=22 width=4) (actual time=0.016..0.019 rows=19.00 loops=1)
                    Recheck Cond: ((id_sala = 1) AND (fecha > (CURRENT_DATE - 7)))
                    Heap Blocks: exact=4
                    Buffers: shared hit=6
                    ->  Bitmap Index Scan on ix_comprobante_sala_fecha  (cost=0.00..4.52 rows=22 width=0) (actual time=0.007..0.007 rows=19.00 loops=1)
                          Index Cond: ((id_sala = 1) AND (fecha > (CURRENT_DATE - 7)))
                          Index Searches: 1
                          Buffers: shared hit=2
              ->  Index Scan using cliente_pkey on cliente cl  (cost=0.29..7.76 rows=1 width=8) (actual time=0.002..0.002 rows=1.00 loops=19)
                    Index Cond: (id_cliente = c.id_cliente)
                    Index Searches: 19
                    Buffers: shared hit=57
Planning:
  Buffers: shared hit=14
Planning Time: 0.189 ms
Execution Time: 0.096 ms
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
Limit  (cost=165.38..165.38 rows=1 width=12) (actual time=0.390..0.391 rows=0.00 loops=1)
  Buffers: shared hit=34
  InitPlan 1
    ->  Limit  (cost=0.28..2.74 rows=1 width=6) (actual time=0.016..0.017 rows=1.00 loops=1)
          Buffers: shared hit=3
          ->  Index Scan Backward using uq_vino_nombre_anada_volumen on vino  (cost=0.28..44.67 rows=18 width=6) (actual time=0.016..0.016 rows=1.00 loops=1)
                Index Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
                Index Searches: 1
                Buffers: shared hit=3
  ->  Sort  (cost=162.64..162.64 rows=1 width=12) (actual time=0.390..0.391 rows=0.00 loops=1)
        Sort Key: (sum(r.cantidad)) DESC
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=34
        ->  GroupAggregate  (cost=162.61..162.63 rows=1 width=12) (actual time=0.388..0.389 rows=0.00 loops=1)
              Group Key: t.id_sala
              Buffers: shared hit=34
              ->  Sort  (cost=162.61..162.61 rows=1 width=8) (actual time=0.388..0.389 rows=0.00 loops=1)
                    Sort Key: t.id_sala
                    Sort Method: quicksort  Memory: 25kB
                    Buffers: shared hit=34
                    ->  Hash Join  (cost=59.69..162.60 rows=1 width=8) (actual time=0.387..0.387 rows=0.00 loops=1)
                          Hash Cond: (t.nro_solicitud = r.nro_solicitud)
                          Buffers: shared hit=34
                          ->  Seq Scan on transferencia t  (cost=0.00..102.84 rows=26 width=8) (actual time=0.346..0.349 rows=24.00 loops=1)
                                Filter: (fecha_confeccion >= (CURRENT_DATE - 15))
                                Rows Removed by Filter: 4424
                                Buffers: shared hit=25
                          ->  Hash  (cost=59.39..59.39 rows=24 width=8) (actual time=0.035..0.035 rows=11.00 loops=1)
                                Buckets: 1024  Batches: 1  Memory Usage: 9kB
                                Buffers: shared hit=9
                                ->  Bitmap Heap Scan on renglon_transferencia r  (cost=4.47..59.39 rows=24 width=8) (actual time=0.029..0.032 rows=11.00 loops=1)
                                      Recheck Cond: (cod_vino = (InitPlan 1).col1)
                                      Heap Blocks: exact=4
                                      Buffers: shared hit=9
                                      ->  Bitmap Index Scan on ix_renglon_transferencia_vino  (cost=0.00..4.46 rows=24 width=0) (actual time=0.022..0.022 rows=11.00 loops=1)
                                            Index Cond: (cod_vino = (InitPlan 1).col1)
                                            Index Searches: 1
                                            Buffers: shared hit=5
Planning:
  Buffers: shared hit=12
Planning Time: 0.244 ms
Execution Time: 0.419 ms
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
Limit  (cost=33.86..33.88 rows=5 width=30) (actual time=0.129..0.131 rows=5.00 loops=1)
  Buffers: shared hit=4
  ->  Sort  (cost=33.86..33.93 rows=25 width=30) (actual time=0.127..0.128 rows=5.00 loops=1)
        Sort Key: (count(t.nro_solicitud)), s.id_sala
        Sort Method: top-N heapsort  Memory: 25kB
        Buffers: shared hit=4
        ->  HashAggregate  (cost=33.20..33.45 rows=25 width=30) (actual time=0.108..0.113 rows=25.00 loops=1)
              Group Key: s.id_sala
              Batches: 1  Memory Usage: 32kB
              Buffers: shared hit=4
              ->  Hash Right Join  (cost=9.78..33.07 rows=25 width=26) (actual time=0.083..0.093 rows=25.00 loops=1)
                    Hash Cond: (t.id_sala = s.id_sala)
                    Buffers: shared hit=4
                    ->  Bitmap Heap Scan on transferencia t  (cost=8.21..31.46 rows=15 width=8) (actual time=0.029..0.031 rows=15.00 loops=1)
                          Recheck Cond: (estado <> 'procesado'::estado_documento)
                          Heap Blocks: exact=2
                          Buffers: shared hit=3
                          ->  Bitmap Index Scan on ix_transferencia_pendientes  (cost=0.00..8.21 rows=15 width=0) (actual time=0.012..0.012 rows=15.00 loops=1)
                                Index Searches: 1
                                Buffers: shared hit=1
                    ->  Hash  (cost=1.25..1.25 rows=25 width=22) (actual time=0.046..0.046 rows=25.00 loops=1)
                          Buckets: 1024  Batches: 1  Memory Usage: 10kB
                          Buffers: shared hit=1
                          ->  Seq Scan on sala_venta s  (cost=0.00..1.25 rows=25 width=22) (actual time=0.033..0.036 rows=25.00 loops=1)
                                Buffers: shared hit=1
Planning:
  Buffers: shared hit=4
Planning Time: 0.380 ms
Execution Time: 0.200 ms
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
Sort  (cost=1581.98..1582.05 rows=25 width=36) (actual time=6.507..6.509 rows=25.00 loops=1)
  Sort Key: (sum(total)) DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=117
  ->  HashAggregate  (cost=1581.09..1581.40 rows=25 width=36) (actual time=6.490..6.496 rows=25.00 loops=1)
        Group Key: id_sala
        Batches: 1  Memory Usage: 32kB
        Buffers: shared hit=117
        ->  Bitmap Heap Scan on comprobante c  (cost=13.92..1543.42 rows=7534 width=12) (actual time=1.754..3.822 rows=7404.00 loops=1)
              Recheck Cond: (fecha > (CURRENT_DATE - '3 mons'::interval))
              Rows Removed by Index Recheck: 6055
              Heap Blocks: lossy=115
              Buffers: shared hit=117
              ->  Bitmap Index Scan on ix_comprobante_fecha_brin  (cost=0.00..12.04 rows=15000 width=0) (actual time=0.021..0.021 rows=1150.00 loops=1)
                    Index Cond: (fecha > (CURRENT_DATE - '3 mons'::interval))
                    Index Searches: 1
                    Buffers: shared hit=2
Planning:
  Buffers: shared hit=1
Planning Time: 0.155 ms
Execution Time: 6.546 ms
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
Bitmap Heap Scan on vino v  (cost=4.52..425.54 rows=18 width=46) (actual time=0.050..0.137 rows=8.00 loops=1)
  Recheck Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
  Heap Blocks: exact=1
  Buffers: shared hit=56
  ->  Bitmap Index Scan on uq_vino_nombre_anada_volumen  (cost=0.00..4.52 rows=18 width=0) (actual time=0.024..0.024 rows=8.00 loops=1)
        Index Cond: (((nombre)::text = 'Malbec Reserva'::text) AND (volumen_ml = 750))
        Index Searches: 1
        Buffers: shared hit=2
  SubPlan 1
    ->  Index Scan using stock_deposito_pkey on stock_deposito d  (cost=0.28..8.29 rows=1 width=4) (actual time=0.002..0.002 rows=0.88 loops=8)
          Index Cond: (cod_vino = v.cod_vino)
          Index Searches: 8
          Buffers: shared hit=23
  SubPlan 2
    ->  Aggregate  (cost=14.52..14.53 rows=1 width=8) (actual time=0.008..0.009 rows=1.00 loops=8)
          Buffers: shared hit=30
          ->  Bitmap Heap Scan on stock_sala s  (cost=4.34..14.50 rows=8 width=4) (actual time=0.004..0.005 rows=2.25 loops=8)
                Recheck Cond: (cod_vino = v.cod_vino)
                Heap Blocks: exact=14
                Buffers: shared hit=30
                ->  Bitmap Index Scan on ix_stock_sala_vino  (cost=0.00..4.34 rows=8 width=0) (actual time=0.002..0.002 rows=2.25 loops=8)
                      Index Cond: (cod_vino = v.cod_vino)
                      Index Searches: 8
                      Buffers: shared hit=16
Planning Time: 0.154 ms
Execution Time: 0.167 ms
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
Aggregate  (cost=20190.55..20190.56 rows=1 width=8) (actual time=250.589..250.593 rows=1.00 loops=1)
  Buffers: shared hit=5385
  ->  Hash Right Anti Join  (cost=5388.79..20171.65 rows=7558 width=0) (actual time=249.889..250.417 rows=3572.00 loops=1)
        Hash Cond: (c.id_cliente = cl.id_cliente)
        Buffers: shared hit=5385
        ->  Hash Join  (cost=4667.79..15980.90 rows=363482 width=4) (actual time=34.983..204.765 rows=302150.00 loops=1)
              Hash Cond: (r.nro = c.nro)
              Buffers: shared hit=5114
              ->  Hash Join  (cost=25.79..10384.74 rows=363482 width=4) (actual time=0.156..97.996 rows=302150.00 loops=1)
                    Hash Cond: (r.cod_vino = v.cod_vino)
                    Buffers: shared hit=3847
                    ->  Seq Scan on renglon_comprobante r  (cost=0.00..8996.77 rows=515977 width=8) (actual time=0.017..25.518 rows=515977.00 loops=1)
                          Buffers: shared hit=3837
                    ->  Hash  (cost=19.26..19.26 rows=522 width=4) (actual time=0.134..0.134 rows=522.00 loops=1)
                          Buckets: 1024  Batches: 1  Memory Usage: 27kB
                          Buffers: shared hit=10
                          ->  Seq Scan on vino v  (cost=0.00..19.26 rows=522 width=4) (actual time=0.008..0.080 rows=522.00 loops=1)
                                Filter: (tipo = 'tinto'::tipo_vino)
                                Rows Removed by Filter: 219
                                Buffers: shared hit=10
              ->  Hash  (cost=2767.00..2767.00 rows=150000 width=8) (actual time=34.500..34.500 rows=150000.00 loops=1)
                    Buckets: 262144  Batches: 1  Memory Usage: 7908kB
                    Buffers: shared hit=1267
                    ->  Seq Scan on comprobante c  (cost=0.00..2767.00 rows=150000 width=8) (actual time=0.017..13.585 rows=150000.00 loops=1)
                          Buffers: shared hit=1267
        ->  Hash  (cost=471.00..471.00 rows=20000 width=4) (actual time=3.307..3.308 rows=20000.00 loops=1)
              Buckets: 32768  Batches: 1  Memory Usage: 960kB
              Buffers: shared hit=271
              ->  Seq Scan on cliente cl  (cost=0.00..471.00 rows=20000 width=4) (actual time=0.011..1.396 rows=20000.00 loops=1)
                    Buffers: shared hit=271
Planning:
  Buffers: shared hit=46
Planning Time: 0.618 ms
Execution Time: 251.313 ms
```

### HC · Historial de compras de un cliente (GET /clientes/{id}/comprobantes de la API)

```sql
SELECT c.nro, c.fecha, c.id_sala, c.total
  FROM comprobante c
 WHERE c.id_cliente = 143                               -- parámetro: cliente (49 compras)
 ORDER BY c.fecha DESC
```
```
Sort  (cost=49.25..49.28 rows=12 width=20) (actual time=0.059..0.061 rows=49.00 loops=1)
  Sort Key: fecha DESC
  Sort Method: quicksort  Memory: 26kB
  Buffers: shared hit=48
  ->  Bitmap Heap Scan on comprobante c  (cost=4.39..49.03 rows=12 width=20) (actual time=0.019..0.048 rows=49.00 loops=1)
        Recheck Cond: (id_cliente = 143)
        Heap Blocks: exact=46
        Buffers: shared hit=48
        ->  Bitmap Index Scan on ix_comprobante_cliente  (cost=0.00..4.38 rows=12 width=0) (actual time=0.008..0.008 rows=49.00 loops=1)
              Index Cond: (id_cliente = 143)
              Index Searches: 1
              Buffers: shared hit=2
Planning Time: 0.056 ms
Execution Time: 0.074 ms
```


## Borrar un vino sin movimientos (control de FK, RN-14)

`DELETE FROM vino WHERE cod_vino = <vino nuevo sin movimientos>` (se revierte)

### Antes
```
Delete on vino  (cost=0.28..8.29 rows=0 width=0) (actual time=0.043..0.043 rows=0.00 loops=1)
  Buffers: shared hit=5
  ->  Index Scan using vino_pkey on vino  (cost=0.28..8.29 rows=1 width=6) (actual time=0.015..0.016 rows=1.00 loops=1)
        Index Cond: (cod_vino = 752)
        Index Searches: 1
        Buffers: shared hit=3
Planning Time: 0.078 ms
Trigger for constraint composicion_vino_cod_vino_fkey: time=0.052 calls=1
Trigger for constraint vino_maridaje_cod_vino_fkey: time=0.029 calls=1
Trigger for constraint renglon_comprobante_cod_vino_fkey: time=36.327 calls=1
Trigger for constraint renglon_ingreso_cod_vino_fkey: time=0.419 calls=1
Trigger for constraint renglon_transferencia_cod_vino_fkey: time=0.989 calls=1
Trigger for constraint stock_sala_cod_vino_fkey: time=0.129 calls=1
Trigger for constraint stock_deposito_cod_vino_fkey: time=0.023 calls=1
Trigger for constraint auditoria_precio_cod_vino_fkey: time=0.330 calls=1
Execution Time: 38.367 ms
```
### Después
```
Delete on vino  (cost=0.28..8.29 rows=0 width=0) (actual time=0.022..0.022 rows=0.00 loops=1)
  Buffers: shared hit=5
  ->  Index Scan using vino_pkey on vino  (cost=0.28..8.29 rows=1 width=6) (actual time=0.009..0.009 rows=1.00 loops=1)
        Index Cond: (cod_vino = 753)
        Index Searches: 1
        Buffers: shared hit=3
Planning Time: 0.043 ms
Trigger for constraint composicion_vino_cod_vino_fkey: time=0.029 calls=1
Trigger for constraint vino_maridaje_cod_vino_fkey: time=0.019 calls=1
Trigger for constraint renglon_comprobante_cod_vino_fkey: time=0.067 calls=1
Trigger for constraint renglon_ingreso_cod_vino_fkey: time=0.312 calls=1
Trigger for constraint renglon_transferencia_cod_vino_fkey: time=0.071 calls=1
Trigger for constraint stock_sala_cod_vino_fkey: time=0.020 calls=1
Trigger for constraint stock_deposito_cod_vino_fkey: time=0.014 calls=1
Trigger for constraint auditoria_precio_cod_vino_fkey: time=0.333 calls=1
Execution Time: 0.902 ms
```


## Experimentos

### Índice compuesto en orden inverso (fecha, id_sala) · S3
```
GroupAggregate  (cost=317.58..317.86 rows=3 width=12) (actual time=0.065..0.067 rows=2.00 loops=1)
  Group Key: cl.tipo
  Buffers: shared hit=64
  ->  Sort  (cost=317.58..317.66 rows=33 width=8) (actual time=0.061..0.062 rows=19.00 loops=1)
        Sort Key: cl.tipo, cl.id_cliente
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=64
        ->  Nested Loop  (cost=0.59..316.75 rows=33 width=8) (actual time=0.014..0.054 rows=19.00 loops=1)
              Buffers: shared hit=64
              ->  Index Scan using ix_tmp_fecha_sala on comprobante c  (cost=0.30..74.68 rows=33 width=4) (actual time=0.010..0.015 rows=19.00 loops=1)
                    Index Cond: ((fecha > (CURRENT_DATE - 7)) AND (id_sala = 1))
                    Index Searches: 1
                    Buffers: shared hit=7
              ->  Index Scan using cliente_pkey on cliente cl  (cost=0.29..7.34 rows=1 width=8) (actual time=0.002..0.002 rows=1.00 loops=19)
                    Index Cond: (id_cliente = c.id_cliente)
                    Index Searches: 19
                    Buffers: shared hit=57
Planning:
  Buffers: shared hit=17
Planning Time: 0.188 ms
Execution Time: 0.087 ms
```
### Ventas mensuales de la sala 5 · (id_sala, fecha)
```
Sort  (cost=1700.88..1706.19 rows=2126 width=40) (actual time=5.970..5.973 rows=73.00 loops=1)
  Sort Key: (date_trunc('month'::text, (fecha)::timestamp with time zone))
  Sort Method: quicksort  Memory: 27kB
  Buffers: shared hit=1277
  ->  HashAggregate  (cost=1546.17..1583.38 rows=2126 width=40) (actual time=5.927..5.956 rows=73.00 loops=1)
        Group Key: date_trunc('month'::text, (fecha)::timestamp with time zone)
        Batches: 1  Memory Usage: 121kB
        Buffers: shared hit=1277
        ->  Bitmap Heap Scan on comprobante  (cost=110.42..1508.67 rows=7500 width=16) (actual time=0.366..4.168 rows=7533.00 loops=1)
              Recheck Cond: (id_sala = 5)
              Heap Blocks: exact=1264
              Buffers: shared hit=1277
              ->  Bitmap Index Scan on ix_comprobante_sala_fecha  (cost=0.00..108.55 rows=7500 width=0) (actual time=0.247..0.247 rows=7533.00 loops=1)
                    Index Cond: (id_sala = 5)
                    Index Searches: 1
                    Buffers: shared hit=13
Planning Time: 0.106 ms
Execution Time: 6.009 ms
```
### Ventas mensuales de la sala 5 · (fecha, id_sala)
```
Sort  (cost=3371.51..3376.82 rows=2126 width=40) (actual time=14.006..14.010 rows=73.00 loops=1)
  Sort Key: (date_trunc('month'::text, (fecha)::timestamp with time zone))
  Sort Method: quicksort  Memory: 27kB
  Buffers: shared hit=1267
  ->  HashAggregate  (cost=3216.80..3254.01 rows=2126 width=40) (actual time=13.961..13.991 rows=73.00 loops=1)
        Group Key: date_trunc('month'::text, (fecha)::timestamp with time zone)
        Batches: 1  Memory Usage: 121kB
        Buffers: shared hit=1267
        ->  Seq Scan on comprobante  (cost=0.00..3179.40 rows=7480 width=16) (actual time=0.015..12.163 rows=7533.00 loops=1)
              Filter: (id_sala = 5)
              Rows Removed by Filter: 142467
              Buffers: shared hit=1267
Planning Time: 0.109 ms
Execution Time: 14.043 ms
```
### B-tree sobre fecha · S8
```
Sort  (cost=257.41..257.47 rows=25 width=36) (actual time=3.049..3.050 rows=25.00 loops=1)
  Sort Key: (sum(total)) DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=72
  ->  HashAggregate  (cost=256.51..256.83 rows=25 width=36) (actual time=3.035..3.041 rows=25.00 loops=1)
        Group Key: id_sala
        Batches: 1  Memory Usage: 32kB
        Buffers: shared hit=72
        ->  Index Scan using ix_tmp_fecha_btree on comprobante c  (cost=0.30..220.25 rows=7254 width=12) (actual time=0.010..0.968 rows=7404.00 loops=1)
              Index Cond: (fecha > (CURRENT_DATE - '3 mons'::interval))
              Index Searches: 1
              Buffers: shared hit=72
Planning Time: 0.081 ms
Execution Time: 3.069 ms
```
### cliente (tipo) · socio (índice creado)
```
GroupAggregate  (cost=721.19..4182.32 rows=1 width=12) (actual time=40.400..40.402 rows=1.00 loops=1)
  Buffers: shared hit=1538
  ->  Hash Join  (cost=721.19..3882.03 rows=120112 width=4) (actual time=3.988..35.285 rows=119202.00 loops=1)
        Hash Cond: (c.id_cliente = cl.id_cliente)
        Buffers: shared hit=1538
        ->  Seq Scan on comprobante c  (cost=0.00..2767.00 rows=150000 width=4) (actual time=0.011..6.482 rows=150000.00 loops=1)
              Buffers: shared hit=1267
        ->  Hash  (cost=521.00..521.00 rows=16015 width=8) (actual time=3.935..3.936 rows=16015.00 loops=1)
              Buckets: 16384  Batches: 1  Memory Usage: 754kB
              Buffers: shared hit=271
              ->  Seq Scan on cliente cl  (cost=0.00..521.00 rows=16015 width=8) (actual time=0.007..2.242 rows=16015.00 loops=1)
                    Filter: (tipo = 'socio'::tipo_cliente)
                    Rows Removed by Filter: 3985
                    Buffers: shared hit=271
Planning:
  Buffers: shared hit=13
Planning Time: 0.251 ms
Execution Time: 40.521 ms
```
### cliente (tipo) · exportador (índice creado)
```
GroupAggregate  (cost=12.40..1649.27 rows=1 width=12) (actual time=3.170..3.171 rows=1.00 loops=1)
  Buffers: shared hit=2291
  ->  Nested Loop  (cost=12.40..1630.34 rows=7568 width=4) (actual time=0.062..2.819 rows=7917.00 loops=1)
        Buffers: shared hit=2291
        ->  Bitmap Heap Scan on cliente cl  (cost=12.11..295.72 rows=1009 width=8) (actual time=0.058..0.319 rows=1009.00 loops=1)
              Recheck Cond: (tipo = 'exportador'::tipo_cliente)
              Heap Blocks: exact=266
              Buffers: shared hit=268
              ->  Bitmap Index Scan on ix_tmp_cliente_tipo  (cost=0.00..11.85 rows=1009 width=0) (actual time=0.032..0.032 rows=1009.00 loops=1)
                    Index Cond: (tipo = 'exportador'::tipo_cliente)
                    Index Searches: 1
                    Buffers: shared hit=2
        ->  Index Only Scan using ix_comprobante_cliente on comprobante c  (cost=0.29..1.20 rows=12 width=4) (actual time=0.001..0.002 rows=7.85 loops=1009)
              Index Cond: (id_cliente = cl.id_cliente)
              Heap Fetches: 4
              Index Searches: 1009
              Buffers: shared hit=2023
Planning:
  Buffers: shared hit=13
Planning Time: 0.179 ms
Execution Time: 3.190 ms
```
### Estadísticas desactualizadas · antes de ANALYZE
```
Aggregate  (cost=23.65..23.66 rows=1 width=40) (actual time=14.390..14.391 rows=1.00 loops=1)
  Buffers: shared hit=490
  ->  Bitmap Heap Scan on comprobante  (cost=4.35..23.62 rows=5 width=8) (actual time=1.116..5.741 rows=60000.00 loops=1)
        Recheck Cond: ((id_sala = 1) AND (fecha = CURRENT_DATE))
        Heap Blocks: exact=442
        Buffers: shared hit=490
        ->  Bitmap Index Scan on ix_comprobante_sala_fecha  (cost=0.00..4.35 rows=5 width=0) (actual time=1.076..1.076 rows=60000.00 loops=1)
              Index Cond: ((id_sala = 1) AND (fecha = CURRENT_DATE))
              Index Searches: 1
              Buffers: shared hit=48
Planning:
  Buffers: shared hit=1
Planning Time: 0.107 ms
Execution Time: 14.417 ms
```
### Estadísticas desactualizadas · después de ANALYZE
```
Aggregate  (cost=2458.40..2458.41 rows=1 width=40) (actual time=14.239..14.239 rows=1.00 loops=1)
  Buffers: shared hit=490
  ->  Bitmap Heap Scan on comprobante  (cost=312.01..2360.98 rows=19484 width=6) (actual time=1.105..5.682 rows=60000.00 loops=1)
        Recheck Cond: ((id_sala = 1) AND (fecha = CURRENT_DATE))
        Heap Blocks: exact=442
        Buffers: shared hit=490
        ->  Bitmap Index Scan on ix_comprobante_sala_fecha  (cost=0.00..307.14 rows=19484 width=0) (actual time=1.066..1.066 rows=60000.00 loops=1)
              Index Cond: ((id_sala = 1) AND (fecha = CURRENT_DATE))
              Index Searches: 1
              Buffers: shared hit=48
Planning:
  Buffers: shared hit=1
Planning Time: 0.104 ms
Execution Time: 14.266 ms
```
