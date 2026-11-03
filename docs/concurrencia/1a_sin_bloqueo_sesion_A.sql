-- Escenario 1 · SIN bloqueo · Sesión A
-- La "aplicación" lee el stock, decide y después escribe el valor que calculó
-- (leer → decidir → escribir). Nivel de aislamiento: READ COMMITTED (default).
\set QUIET on
\pset tuples_only on
\pset format unaligned
BEGIN;
SELECT format('%s  A  aislamiento: %s', to_char(clock_timestamp(), 'HH24:MI:SS.MS'), current_setting('transaction_isolation'));
SELECT cantidad AS leido FROM stock_sala WHERE id_sala = :sala AND cod_vino = :vino \gset
SELECT format('%s  A  SELECT cantidad  -> %s botella(s). Hay stock: vendo.', to_char(clock_timestamp(), 'HH24:MI:SS.MS'), :leido);
SELECT pg_sleep(2);   -- tiempo que tarda el usuario en confirmar la venta
UPDATE stock_sala SET cantidad = :leido - 1 WHERE id_sala = :sala AND cod_vino = :vino;
SELECT format('%s  A  UPDATE stock := %s - 1', to_char(clock_timestamp(), 'HH24:MI:SS.MS'), :leido);
COMMIT;
SELECT format('%s  A  COMMIT', to_char(clock_timestamp(), 'HH24:MI:SS.MS'));
