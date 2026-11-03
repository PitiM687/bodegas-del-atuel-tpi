-- =====================================================================
-- docs/etapa4/consultas_medidas.sql · Bodegas del Atuel · Etapa 4
-- Consultas de la sección 8 elegidas para medir el efecto de los índices.
-- Cada bloque empieza con una línea  -- @ID | título | consigna
-- (la usa db/scripts/medir_indices.py para medirlas con
--  EXPLAIN (ANALYZE, BUFFERS) antes y después de 008_indices.sql).
--
-- Los parámetros (sala, vino, bodega, cliente) se fijan con valores del
-- dataset generado con semilla 42; están marcados con  -- parámetro.
-- Las fechas son relativas a CURRENT_DATE, como pide el enunciado.
-- =====================================================================

-- @S1 | Ranking de los 10 vinos más vendidos de la red | S1
SELECT v.cod_vino, v.nombre, v.anada, v.volumen_ml, SUM(r.cantidad) AS botellas
  FROM renglon_comprobante r
  JOIN vino v USING (cod_vino)
 GROUP BY v.cod_vino, v.nombre, v.anada, v.volumen_ml
 ORDER BY botellas DESC
 LIMIT 10;

-- @S3 | Clientes de cada tipo que compraron en una sala en la última semana | S3
SELECT cl.tipo, COUNT(DISTINCT cl.id_cliente) AS clientes
  FROM comprobante c
  JOIN cliente cl USING (id_cliente)
 WHERE c.id_sala = 1                                   -- parámetro: sala
   AND c.fecha > CURRENT_DATE - 7
 GROUP BY cl.tipo;

-- @S4 | Top 5 de salas que más pidieron un vino por transferencia en los últimos 15 días | S4
SELECT t.id_sala, SUM(r.cantidad) AS botellas_solicitadas
  FROM renglon_transferencia r
  JOIN transferencia t USING (nro_solicitud)
 WHERE r.cod_vino = (SELECT cod_vino FROM vino        -- parámetro: vino
                      WHERE nombre = 'Malbec Reserva' AND volumen_ml = 750
                      ORDER BY anada DESC LIMIT 1)
   AND t.fecha_confeccion >= CURRENT_DATE - 15
 GROUP BY t.id_sala
 ORDER BY botellas_solicitadas DESC
 LIMIT 5;

-- @S5 | Salas con menor cantidad de transferencias pendientes | S5
SELECT s.id_sala, s.calle, s.numero, COUNT(t.nro_solicitud) AS pendientes
  FROM sala_venta s
  LEFT JOIN transferencia t ON t.id_sala = s.id_sala AND t.estado <> 'procesado'
 GROUP BY s.id_sala, s.calle, s.numero
 ORDER BY pendientes, s.id_sala
 LIMIT 5;

-- @S8 | Monto total de ventas por sala en el último trimestre | S8
SELECT c.id_sala, SUM(c.total) AS monto_total
  FROM comprobante c
 WHERE c.fecha > CURRENT_DATE - INTERVAL '3 months'
 GROUP BY c.id_sala
 ORDER BY monto_total DESC;

-- @S9 | Ficha de un vino: stock total (depósito + salas) | S9
SELECT v.cod_vino, v.nombre, v.anada,
       COALESCE((SELECT d.cantidad FROM stock_deposito d WHERE d.cod_vino = v.cod_vino), 0) AS deposito,
       COALESCE((SELECT SUM(s.cantidad) FROM stock_sala s WHERE s.cod_vino = v.cod_vino), 0) AS salas
  FROM vino v
 WHERE v.nombre = 'Malbec Reserva' AND v.volumen_ml = 750; -- parámetro: vino

-- @S12 | Clientes que nunca compraron un vino tinto (anti-join) | S12
SELECT COUNT(*) AS clientes_sin_tintos
  FROM cliente cl
 WHERE NOT EXISTS (SELECT 1
                     FROM comprobante c
                     JOIN renglon_comprobante r USING (nro)
                     JOIN vino v USING (cod_vino)
                    WHERE c.id_cliente = cl.id_cliente
                      AND v.tipo = 'tinto');

-- @HC | Historial de compras de un cliente (GET /clientes/{id}/comprobantes de la API) | API
SELECT c.nro, c.fecha, c.id_sala, c.total
  FROM comprobante c
 WHERE c.id_cliente = 143                               -- parámetro: cliente (49 compras)
 ORDER BY c.fecha DESC;
