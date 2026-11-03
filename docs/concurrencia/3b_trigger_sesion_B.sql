-- Escenario 3 · El sistema real · Sesión B
\set QUIET on
\set VERBOSITY terse
\pset tuples_only on
\pset format unaligned
BEGIN;
INSERT INTO comprobante (id_cliente, id_sala) VALUES (:cliente, :sala) RETURNING nro \gset
SELECT format('%s  B  INSERT comprobante %s', to_char(clock_timestamp(), 'HH24:MI:SS.MS'), :nro);
SELECT format('%s  B  INSERT renglón (1 botella): espera a que A libere la fila de stock...', to_char(clock_timestamp(), 'HH24:MI:SS.MS'));
INSERT INTO renglon_comprobante (nro, cod_vino, cantidad) VALUES (:nro, :vino, 1);
\if :ERROR
    ROLLBACK;
    SELECT format('%s  B  RECHAZADA: %s -> ROLLBACK (no queda nada a medias)', to_char(clock_timestamp(), 'HH24:MI:SS.MS'), :'LAST_ERROR_MESSAGE');
\else
    COMMIT;
    SELECT format('%s  B  vendió (no debería ocurrir)', to_char(clock_timestamp(), 'HH24:MI:SS.MS'));
\endif
