-- Escenario 2 · CON SELECT ... FOR UPDATE · Sesión A (Anexo A.8 del enunciado)
\set QUIET on
\pset tuples_only on
\pset format unaligned
BEGIN;
SELECT format('%s  A  aislamiento: %s', to_char(clock_timestamp(), 'HH24:MI:SS.MS'), current_setting('transaction_isolation'));
SELECT cantidad AS leido FROM stock_sala WHERE id_sala = :sala AND cod_vino = :vino FOR UPDATE \gset
SELECT format('%s  A  SELECT ... FOR UPDATE -> %s botella(s). Fila bloqueada. Vendo.', to_char(clock_timestamp(), 'HH24:MI:SS.MS'), :leido);
SELECT pg_sleep(2);
UPDATE stock_sala SET cantidad = cantidad - 1 WHERE id_sala = :sala AND cod_vino = :vino;
SELECT format('%s  A  UPDATE stock := stock - 1', to_char(clock_timestamp(), 'HH24:MI:SS.MS'));
COMMIT;
SELECT format('%s  A  COMMIT (libera el bloqueo)', to_char(clock_timestamp(), 'HH24:MI:SS.MS'));
