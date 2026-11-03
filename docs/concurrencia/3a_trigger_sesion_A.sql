-- Escenario 3 · El sistema real: venta por INSERT en renglon_comprobante · Sesión A
-- No hay FOR UPDATE en la aplicación: lo hace el trigger trg_validar_stock_venta (RN-09).
\set QUIET on
\set VERBOSITY terse
\pset tuples_only on
\pset format unaligned
BEGIN;
INSERT INTO comprobante (id_cliente, id_sala) VALUES (:cliente, :sala) RETURNING nro \gset
SELECT format('%s  A  INSERT comprobante %s', to_char(clock_timestamp(), 'HH24:MI:SS.MS'), :nro);
INSERT INTO renglon_comprobante (nro, cod_vino, cantidad) VALUES (:nro, :vino, 1);
SELECT format('%s  A  INSERT renglón (1 botella): el trigger bloqueó la fila de stock y la descontó', to_char(clock_timestamp(), 'HH24:MI:SS.MS'));
SELECT pg_sleep(2);
COMMIT;
SELECT format('%s  A  COMMIT', to_char(clock_timestamp(), 'HH24:MI:SS.MS'));
