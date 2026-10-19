-- =====================================================
-- 1. PRIMERA CARGA (datos originales)
-- =====================================================
CALL MotorsPasz_DW.sp_etl_motorspasz(NULL);


-- =====================================================
-- 2. DATOS SUCIOS DE PRUEBA EN EL OLTP
-- =====================================================
-- Uno por cada regla del relevamiento, mas algunos datos
-- validos para que los filtros tengan variedad.
USE MotorsPasz;
SET @legajo_actual = 4;

-- Regla 3: venta a un cliente generico sin CUIT valido
INSERT INTO Clientes (CUITCliente, id_tipo_cliente, RazonSocial, Telefono, Email, LimiteCredito)
VALUES ('00-00000000-0', 3, 'CONSUMIDOR FINAL', NULL, NULL, 0);

INSERT INTO Comprobante_Venta (CUITCliente, id_tipo_documento, id_comprobante_origen,
                               nroComprobante, CAE, fechaEmision, montoTotal)
VALUES ('00-00000000-0', 2, NULL, '0002-00009001', '7412000090019', '2026-09-15', 230000);
SET @comp_generico = LAST_INSERT_ID();

INSERT INTO Detalle_Comprobante_Venta (idComprobanteVenta, linea, idVenta, SKU, cantidad, precioUnitario, subtotal)
VALUES (@comp_generico, 1, NULL, 'BOM-VOLT-003', 2, 115000, 230000);

-- Regla 1: orden de produccion con fechas invertidas
-- (el control es anterior a la orden)
INSERT INTO OrdenProduccion (nroOrden, fecha, estado, idEmpleado, SKU_Motor, cantidad, idProductoBOM)
VALUES ('OP-PRUEBA-001', '2026-09-20', 'COMPLETADA', 7, 'BOM-VOLT-001', 10, 1);
SET @op_invertida = LAST_INSERT_ID();

INSERT INTO Control_Produccion (idProduccion, idEmpleado, detalle, id_estado, fecha)
VALUES (@op_invertida, 24, 'Ensayos de rigidez dieléctrica y balanceo aprobados', 1, '2026-09-10');

-- Regla 2: motor terminado registrado con costo nulo
INSERT INTO Articulos (SKU, id_tipo_articulo, descripcion, costoUnitario, precioVenta, stockMinimo)
VALUES ('BOM-PRUEBA-001', 1, 'Motor de prueba sin costo cargado', 0, 150000, 5);

INSERT INTO OrdenProduccion (nroOrden, fecha, estado, idEmpleado, SKU_Motor, cantidad, idProductoBOM)
VALUES ('OP-PRUEBA-002', '2026-09-21', 'COMPLETADA', 7, 'BOM-PRUEBA-001', 8, 1);
SET @op_sin_costo = LAST_INSERT_ID();

INSERT INTO Control_Produccion (idProduccion, idEmpleado, detalle, id_estado, fecha)
VALUES (@op_sin_costo, 24, 'Ensayos de rigidez dieléctrica y balanceo aprobados', 1, '2026-09-23');

-- Regla 4: OC vencida con un remanente minimo
-- (100 pedidas, faltan 3; el proveedor entrega en dias)
INSERT INTO OrdenCompra (idProveedor, idEmpleado, fecha, costoFinal, estado)
VALUES (1, 4, '2026-05-04', 100000, 'PENDIENTE');
SET @oc_vencida = LAST_INSERT_ID();

INSERT INTO Detalle_OrdenCompra (idCompra, linea, SKU, cantidad, cantidad_pendiente, precio, subtotal)
SELECT @oc_vencida, 1, SKU, 100, 3, 1000, 100000
FROM Proveedor_Articulo WHERE idProveedor = 1 LIMIT 1;

-- Venta ANULADA que ya tenia factura: no debe contar
-- como facturacion (2 lineas del comprobante 2).
UPDATE OrdenVenta SET estado = 'ANULADA' WHERE idVenta = 2;

-- Datos VALIDOS para que el filtro por causa tenga
-- mas de un valor: dos rechazos con otras causas.
INSERT INTO OrdenProduccion (nroOrden, fecha, estado, idEmpleado, SKU_Motor, cantidad, idProductoBOM)
VALUES ('OP-PRUEBA-003', '2026-09-25', 'COMPLETADA', 7, 'BOM-VOLT-002', 20, 2);
SET @op_electrica = LAST_INSERT_ID();

INSERT INTO Control_Produccion (idProduccion, idEmpleado, detalle, id_estado, fecha)
VALUES (@op_electrica, 24, 'Falla de aislación en ensayo de rigidez dieléctrica', 4, '2026-09-27');

INSERT INTO OrdenProduccion (nroOrden, fecha, estado, idEmpleado, SKU_Motor, cantidad, idProductoBOM)
VALUES ('OP-PRUEBA-004', '2026-10-01', 'COMPLETADA', 46, 'BOM-AMPE-001', 15, 1);
SET @op_bobinado = LAST_INSERT_ID();

INSERT INTO Control_Produccion (idProduccion, idEmpleado, detalle, id_estado, fecha)
VALUES (@op_bobinado, 24, 'Bobinado con espiras en cortocircuito', 4, '2026-10-03');

-- Dato VALIDO: nota de credito que resta facturacion
INSERT INTO Comprobante_Venta (CUITCliente, id_tipo_documento, id_comprobante_origen,
                               nroComprobante, CAE, fechaEmision, montoTotal)
VALUES ('30-71000001-9', 3, 1, '0002-00009002', '7412000090029', '2026-06-25', 230000);
SET @nc = LAST_INSERT_ID();

INSERT INTO Detalle_Comprobante_Venta (idComprobanteVenta, linea, idVenta, SKU, cantidad, precioUnitario, subtotal)
VALUES (@nc, 1, 1, 'BOM-VOLT-003', 2, 115000, 230000);

-- Dato VALIDO: dos componentes quedan por debajo del
-- stock minimo, para que la alerta de quiebre muestre algo.
UPDATE Stock_Fisico SET cantidad = 5 WHERE id_stock = 54;   -- CMP-PLAQ-005 (minimo 15)
UPDATE Stock_Fisico SET cantidad = 8 WHERE id_stock = 52;   -- CMP-PLAQ-004 (minimo 15)


-- =====================================================
-- 3. SEGUNDA CARGA (con los datos sucios)
-- =====================================================
CALL MotorsPasz_DW.sp_etl_motorspasz('2026-10-17');

USE MotorsPasz_DW;

-- Corridas del ETL
SELECT * FROM etl_ejecucion ORDER BY id_ejecucion;

-- Que se descarto y por que: las 4 reglas y la venta
-- anulada (7 filas; el motor sin costo aparece en su
-- control y en su orden de produccion)
SELECT d.tabla_origen, d.clave_origen, d.motivo
FROM etl_descartes d
WHERE d.id_ejecucion = (SELECT MAX(id_ejecucion) FROM etl_ejecucion);

-- El cliente generico no llega a la dimension
SELECT * FROM dim_cliente WHERE cuit = '00-00000000-0';

-- Causas de rechazo disponibles para el filtro
SELECT * FROM dim_resultado_control;


-- =====================================================
-- 4. KPIs DESDE EL DW (lo mismo que calcula Power BI)
-- =====================================================

-- KPI 1: Facturacion Neta por mes y segmento
SELECT t.anio_mes, c.segmento, SUM(f.importe_neto) AS facturacion_neta
FROM fact_facturacion f
INNER JOIN dim_tiempo t ON t.sk_tiempo = f.sk_tiempo
INNER JOIN dim_cliente c ON c.sk_cliente = f.sk_cliente
GROUP BY t.anio_mes, c.segmento
ORDER BY t.anio_mes DESC, c.segmento;

-- KPI 2: Tasa de Rechazo por linea y causa
SELECT l.linea, r.causa,
       SUM(f.cantidad_ensamblada) AS ensamblados,
       SUM(f.cantidad_rechazada) AS rechazados
FROM fact_calidad f
INNER JOIN dim_linea_produccion l ON l.sk_linea = f.sk_linea
INNER JOIN dim_resultado_control r ON r.sk_resultado = f.sk_resultado
GROUP BY l.linea, r.causa;

SELECT ROUND(SUM(cantidad_rechazada) * 100 / SUM(cantidad_ensamblada), 2) AS tasa_rechazo_pct
FROM fact_calidad;

-- KPI 3: Quiebre de stock de componentes en la ultima foto
SELECT COUNT(DISTINCT CASE WHEN s.bajo_punto_pedido = 1 THEN s.sk_articulo END) AS en_quiebre,
       COUNT(DISTINCT s.sk_articulo) AS total_componentes,
       ROUND(COUNT(DISTINCT CASE WHEN s.bajo_punto_pedido = 1 THEN s.sk_articulo END) * 100
             / COUNT(DISTINCT s.sk_articulo), 2) AS porcentaje_quiebre
FROM fact_stock s
INNER JOIN dim_articulo a ON a.sk_articulo = s.sk_articulo
WHERE a.categoria = 'Componente'
  AND s.sk_tiempo = (SELECT MAX(sk_tiempo) FROM fact_stock);

-- Componentes en quiebre por proveedor
SELECT p.razon_social, a.sku, s.stock_disponible, s.stock_minimo, s.faltante, s.pendiente_recepcion
FROM fact_stock s
INNER JOIN dim_articulo a ON a.sk_articulo = s.sk_articulo
INNER JOIN dim_proveedor p ON p.sk_proveedor = s.sk_proveedor
WHERE s.bajo_punto_pedido = 1
  AND s.sk_tiempo = (SELECT MAX(sk_tiempo) FROM fact_stock);


-- Datos para los graficos del tablero
-- Motores vendidos por mes (las notas de credito restan)
SELECT t.anio_mes, SUM(f.cantidad_neta) AS motores_vendidos
FROM fact_facturacion f
INNER JOIN dim_tiempo t ON t.sk_tiempo = f.sk_tiempo
INNER JOIN dim_articulo a ON a.sk_articulo = f.sk_articulo
WHERE a.categoria = 'Motor terminado'
GROUP BY t.anio_mes
ORDER BY t.anio_mes DESC;

-- Stock valorizado por tipo de articulo (ultima foto,
-- cada articulo una sola vez aunque tenga 2 proveedores)
SELECT a.tipo_articulo, SUM(x.valor) AS stock_valorizado
FROM (SELECT sk_articulo, MAX(valor_disponible) AS valor
      FROM fact_stock
      WHERE sk_tiempo = (SELECT MAX(sk_tiempo) FROM fact_stock)
      GROUP BY sk_articulo) x
INNER JOIN dim_articulo a ON a.sk_articulo = x.sk_articulo
GROUP BY a.tipo_articulo
ORDER BY stock_valorizado DESC;

-- Gasto en compras por mes
SELECT t.anio_mes, SUM(c.importe_neto) AS compras_netas
FROM fact_compras c
INNER JOIN dim_tiempo t ON t.sk_tiempo = c.sk_tiempo
GROUP BY t.anio_mes
ORDER BY t.anio_mes DESC;


-- =====================================================
-- 5. RESTO DE LAS ESTRELLAS
-- =====================================================

-- Despachos y recepciones fuera de plazo
SELECT 'Despachos a clientes' AS proceso, COUNT(*) AS lineas,
       SUM(entregado_tarde) AS tarde,
       ROUND(AVG(dias_desde_venta), 1) AS dias_promedio
FROM fact_despachos
UNION ALL
SELECT 'Recepciones de proveedores', COUNT(*), SUM(entregado_tarde),
       ROUND(AVG(dias_desde_oc), 1)
FROM fact_recepciones;

-- Pedidos de venta por estado
SELECT estado, COUNT(*) AS lineas, SUM(cantidad_pendiente) AS unidades_pendientes
FROM fact_pedidos_venta
GROUP BY estado;

-- Ordenes de produccion por estado (incluye las que
-- todavia no tienen control)
SELECT estado, COUNT(*) AS ordenes, SUM(tiene_control) AS con_control
FROM fact_produccion
GROUP BY estado;

-- Devoluciones por motivo
SELECT 'Cliente' AS origen, motivo_devolucion, SUM(cantidad) AS unidades, SUM(importe) AS importe
FROM fact_devoluciones_venta
GROUP BY motivo_devolucion
UNION ALL
SELECT 'Proveedor', motivo_devolucion, SUM(cantidad), SUM(importe)
FROM fact_devoluciones_compra
GROUP BY motivo_devolucion;


-- =====================================================
-- 6. SE PUEDE VOLVER A CORRER SIN ERRORES
-- =====================================================
-- Misma fecha de corte: los totales no se duplican.
CALL MotorsPasz_DW.sp_etl_motorspasz('2026-10-17');
SELECT COUNT(*) AS lineas_facturacion FROM fact_facturacion;

-- Otra fecha de corte: se agrega una foto nueva de stock
-- y quedan las dos (historia).
CALL MotorsPasz_DW.sp_etl_motorspasz('2026-10-18');
SELECT sk_tiempo, COUNT(*) AS filas FROM fact_stock GROUP BY sk_tiempo;
