-- Escenario 2 · CON SELECT ... FOR UPDATE · Sesión B
\set QUIET on
\pset tuples_only on
\pset format unaligned
BEGIN;
SELECT format('%s  B  SELECT ... FOR UPDATE (si A tiene la fila, espera)', to_char(clock_timestamp(), 'HH24:MI:SS.MS'));
SELECT cantidad AS leido FROM stock_sala WHERE id_sala = :sala AND cod_vino = :vino FOR UPDATE \gset
SELECT format('%s  B  obtuvo la fila -> %s botella(s). %s', to_char(clock_timestamp(), 'HH24:MI:SS.MS'), :leido,
              CASE WHEN :leido > 0 THEN 'Vendo.' ELSE 'Sin stock: la venta se rechaza.' END);
ROLLBACK;
SELECT format('%s  B  ROLLBACK', to_char(clock_timestamp(), 'HH24:MI:SS.MS'));
