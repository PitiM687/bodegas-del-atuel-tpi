-- =====================================================================
-- 008_indices.sql  ·  Bodegas del Atuel  ·  PostgreSQL 14+
-- Etapa 4: índices diseñados a partir de los planes de ejecución.
--
-- Punto de partida (EXPLAIN (ANALYZE, BUFFERS) con solo PK y UNIQUE):
--   * comprobante (150.000 filas) se recorría entero (Seq Scan) para
--     filtrar por sala y fecha (S3), por fecha (S8) y por cliente (historial
--     de compras de la API y anti-joins por cliente).
--   * stock_sala se recorría entero una vez por vino (S9): su PK empieza
--     por id_sala y no sirve para buscar por cod_vino.
--   * transferencia y renglon_transferencia se recorrían enteras para
--     encontrar los pendientes (S5) y los pedidos de un vino (S4).
--   * PostgreSQL NO crea índices sobre las claves foráneas: borrar un vino
--     (RN-14) obligaba a recorrer los 516.000 renglones de venta para
--     comprobar que no tuviera ventas.
--
-- Mediciones antes/después, índices descartados, costo de escritura y el
-- caso en que el planificador no usa un índice: docs/informe_etapa4.md.
--
-- Nota: los nombres siguen el patrón ix_<tabla>_<columnas>. Nada en los
-- comentarios usa punto y coma, porque db/scripts/medir_indices.py separa
-- las sentencias por ese carácter.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. COMPUESTO · comprobante (id_sala, fecha)
-- Consultas: S3 (clientes que compraron en una sala en la última semana),
--            vw_ventas_mensuales_sala, ventas de una sala por período.
-- Orden de columnas: primero la columna de IGUALDAD (id_sala = ?) y después
-- la de RANGO (fecha > ?). Así las filas de una sala quedan contiguas y
-- ordenadas por fecha, y el rango se resuelve en un único tramo del índice.
-- Con el orden inverso (fecha, id_sala), el rango de fechas abarca todas
-- las salas y el filtro por sala se aplica entrada por entrada (medido en
-- el informe).
-- ---------------------------------------------------------------------
CREATE INDEX ix_comprobante_sala_fecha
    ON comprobante (id_sala, fecha);

-- ---------------------------------------------------------------------
-- 2. BRIN · comprobante (fecha)
-- Consultas: S8 (ventas del último trimestre), D1 (comprobantes con más de
--            5 años), reportes por período sobre toda la red.
-- Por qué BRIN: los comprobantes se graban en orden cronológico, así que
-- el orden físico de la tabla sigue a la fecha (pg_stats.correlation = 1).
-- Un BRIN guarda solo el mínimo y el máximo de cada bloque de 128 páginas:
-- ocupa unos pocos KB frente a varios MB de un B-tree y permite saltear
-- los bloques fuera del rango. Para un rango que no es pequeño (el último
-- trimestre es ~5 % de la tabla) rinde casi como un B-tree.
-- ---------------------------------------------------------------------
CREATE INDEX ix_comprobante_fecha_brin
    ON comprobante USING brin (fecha);

-- ---------------------------------------------------------------------
-- 3. CLAVE FORÁNEA · comprobante (id_cliente)
-- Consultas: historial de compras de un cliente (API), S12 y D4/D6
--            (clientes que nunca compraron: NOT EXISTS por cliente).
-- También acelera el control de la FK al borrar un cliente: sin este
-- índice, borrar un cliente recorre los 150.000 comprobantes.
-- ---------------------------------------------------------------------
CREATE INDEX ix_comprobante_cliente
    ON comprobante (id_cliente);

-- ---------------------------------------------------------------------
-- 4. CLAVE FORÁNEA · renglon_comprobante (cod_vino)
-- La PK es (nro, cod_vino): sirve para buscar por comprobante, no por vino.
-- Consultas: borrar un vino (RN-14, ON DELETE RESTRICT). Sin el índice, el
--            control de la FK recorre los 516.000 renglones. También S2
--            (división relacional) y las ventas de un vino.
-- ---------------------------------------------------------------------
CREATE INDEX ix_renglon_comprobante_vino
    ON renglon_comprobante (cod_vino);

-- ---------------------------------------------------------------------
-- 5. CLAVE FORÁNEA · stock_sala (cod_vino)
-- La PK es (id_sala, cod_vino): no sirve para buscar un vino en todas las
-- salas.
-- Consultas: S9 (ficha de un vino, stock total), S6, vw_stock_total_vino,
--            control de la FK al borrar un vino.
-- ---------------------------------------------------------------------
CREATE INDEX ix_stock_sala_vino
    ON stock_sala (cod_vino);

-- ---------------------------------------------------------------------
-- 6. CLAVE FORÁNEA + INCLUDE · renglon_transferencia (cod_vino) INCLUDE (cantidad)
-- Consulta: S4 (salas que más pidieron un vino en los últimos 15 días).
-- La búsqueda es por cod_vino y la consulta solo necesita además la
-- cantidad: con INCLUDE la cantidad viaja en la hoja del índice y la
-- consulta puede resolverse con un Index Only Scan, sin leer la tabla.
-- La cantidad va en INCLUDE y no como segunda columna clave porque no se
-- busca ni se ordena por ella: no tiene sentido mantener el índice ordenado
-- por ese valor.
-- ---------------------------------------------------------------------
CREATE INDEX ix_renglon_transferencia_vino
    ON renglon_transferencia (cod_vino) INCLUDE (cantidad);

-- ---------------------------------------------------------------------
-- 7. PARCIAL · transferencia (id_sala) WHERE estado <> 'procesado'
-- Consultas: S5 (salas con menos transferencias pendientes),
--            vw_documentos_pendientes, tablero del front.
-- Solo indexa las transferencias pendientes: son unas pocas decenas entre
-- miles. El índice es mínimo y no hay que actualizarlo cuando se
-- modifica una transferencia ya procesada, porque esas filas no están en
-- el índice.
-- El planificador lo usa cuando la consulta repite la condición
-- estado <> 'procesado'.
-- ---------------------------------------------------------------------
CREATE INDEX ix_transferencia_pendientes
    ON transferencia (id_sala)
    WHERE estado <> 'procesado';

-- ---------------------------------------------------------------------
-- 8. PARCIAL · ingreso (cuit_bodega) WHERE estado <> 'procesado'
-- Mismo criterio que el anterior para los ingresos pendientes
-- (vw_documentos_pendientes, endpoint de ingresos de la API).
-- ---------------------------------------------------------------------
CREATE INDEX ix_ingreso_pendientes
    ON ingreso (cuit_bodega)
    WHERE estado <> 'procesado';

-- Las estadísticas se actualizan después de crear los índices.
ANALYZE comprobante, renglon_comprobante, stock_sala, renglon_transferencia, transferencia, ingreso;
