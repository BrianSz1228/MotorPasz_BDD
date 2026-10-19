
USE MotorsPasz_DW;

-- Regla 3 en un solo lugar: un cliente es valido si
-- tiene CUIT con formato NN-NNNNNNNN-N, no es un CUIT
-- comodin (todo ceros) y no es un cliente generico.
DROP FUNCTION IF EXISTS fn_cliente_valido;

DELIMITER //

CREATE FUNCTION fn_cliente_valido(p_cuit VARCHAR(15), p_razon_social VARCHAR(100))
RETURNS TINYINT
DETERMINISTIC
BEGIN
    IF p_cuit IS NULL OR p_razon_social IS NULL
       OR TRIM(p_cuit) NOT REGEXP '^[0-9]{2}-[0-9]{8}-[0-9]$'
       OR SUBSTRING(TRIM(p_cuit), 4, 8) = '00000000'
       OR UPPER(p_razon_social) LIKE '%CONSUMIDOR FINAL%'
       OR UPPER(p_razon_social) LIKE '%GENERICO%' THEN
        RETURN 0;
    END IF;
    RETURN 1;
END //

DELIMITER ;

DROP PROCEDURE IF EXISTS sp_etl_motorspasz;

DELIMITER //

CREATE PROCEDURE sp_etl_motorspasz(IN p_fecha_corte DATE)
BEGIN
    DECLARE v_id_ejecucion INT;
    DECLARE v_fecha_corte DATE;
    DECLARE v_desde DATE;
    DECLARE v_hasta DATE;
    DECLARE v_sk_corte INT;
    DECLARE v_filas_fact INT DEFAULT 0;
    DECLARE v_filas_cal INT DEFAULT 0;
    DECLARE v_filas_stock INT DEFAULT 0;
    DECLARE v_filas_desc INT DEFAULT 0;
    DECLARE v_filas_compras INT DEFAULT 0;
    DECLARE v_filas_ped INT DEFAULT 0;
    DECLARE v_filas_desp INT DEFAULT 0;
    DECLARE v_filas_dev_v INT DEFAULT 0;
    DECLARE v_filas_oc INT DEFAULT 0;
    DECLARE v_filas_rec INT DEFAULT 0;
    DECLARE v_filas_dev_c INT DEFAULT 0;
    DECLARE v_filas_prod INT DEFAULT 0;
    DECLARE v_error VARCHAR(500);
    DECLARE v_safe_updates INT;

    -- Regla 4: porcentaje del pedido por debajo del cual
    -- un remanente de una OC vencida se ignora.
    DECLARE v_umbral_remanente DECIMAL(5,2) DEFAULT 0.10;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error = MESSAGE_TEXT;
        ROLLBACK;
        UPDATE etl_ejecucion
        SET fin = NOW(), estado = 'ERROR', mensaje = v_error
        WHERE id_ejecucion = v_id_ejecucion;
        SET SQL_SAFE_UPDATES = v_safe_updates;
        SELECT v_id_ejecucion AS id_ejecucion, 'ERROR' AS estado, v_error AS mensaje;
    END;

    SET v_fecha_corte = IFNULL(p_fecha_corte, CURDATE());
    SET v_sk_corte = DATE_FORMAT(v_fecha_corte, '%Y%m%d') + 0;

    -- dim_tiempo cubre mas de 1000 dias
    SET SESSION cte_max_recursion_depth = 10000;

    -- Workbench trae activado "safe updates", que bloquea
    -- los UPDATE/DELETE de staging (no filtran por clave).
    -- Se apaga mientras corre el SP y al final se deja
    -- como estaba.
    SET v_safe_updates = @@SQL_SAFE_UPDATES;
    SET SQL_SAFE_UPDATES = 0;

    -- La corrida se registra fuera de la transaccion para
    -- que quede aunque despues haya ROLLBACK.
    INSERT INTO etl_ejecucion (fecha_corte, inicio, estado)
    VALUES (v_fecha_corte, NOW(), 'EN CURSO');
    SET v_id_ejecucion = LAST_INSERT_ID();

    START TRANSACTION;

    DELETE FROM stg_facturacion;
    DELETE FROM stg_calidad;
    DELETE FROM stg_stock;
    DELETE FROM stg_compras;
    DELETE FROM stg_ordenes_compra;
    DELETE FROM stg_pedidos_venta;
    DELETE FROM stg_despachos;
    DELETE FROM stg_devoluciones_venta;
    DELETE FROM stg_recepciones;
    DELETE FROM stg_devoluciones_compra;
    DELETE FROM stg_produccion;


    -- =================================================
    -- E) EXTRACCION
    -- =================================================
    -- LEFT JOIN a proposito: si falta un dato relacionado
    -- la fila igual entra a staging y la marca la curaduria.

    -- Lineas de comprobantes de venta. Los remitos
    -- (multiplicador 0) no son facturacion y no se extraen.
    INSERT INTO stg_facturacion
    SELECT cv.idComprobanteVenta, d.linea, cv.nroComprobante, cv.fechaEmision,
           cv.CUITCliente, c.RazonSocial, cv.id_tipo_documento, td.multiplicador,
           ov.estado, d.SKU, d.cantidad, d.precioUnitario, d.subtotal, a.costoUnitario, NULL
    FROM MotorsPasz.Comprobante_Venta cv
    INNER JOIN MotorsPasz.Detalle_Comprobante_Venta d ON d.idComprobanteVenta = cv.idComprobanteVenta
    LEFT JOIN MotorsPasz.Clientes c ON c.CUITCliente = cv.CUITCliente
    LEFT JOIN MotorsPasz.Tipo_Documento td ON td.id_tipo_documento = cv.id_tipo_documento
    LEFT JOIN MotorsPasz.OrdenVenta ov ON ov.idVenta = d.idVenta
    LEFT JOIN MotorsPasz.Articulos a ON a.SKU = d.SKU
    WHERE td.multiplicador IS NULL OR td.multiplicador <> 0;

    -- Controles de calidad con su orden de produccion.
    -- El turno del operario de la orden es la linea.
    INSERT INTO stg_calidad
    SELECT cp.idControl, op.idProduccion, op.nroOrden, op.fecha, cp.fecha,
           op.SKU_Motor, a.costoUnitario, op.cantidad, e.idTurno,
           cp.id_estado, cp.detalle, NULL, NULL, NULL
    FROM MotorsPasz.Control_Produccion cp
    LEFT JOIN MotorsPasz.OrdenProduccion op ON op.idProduccion = cp.idProduccion
    LEFT JOIN MotorsPasz.Articulos a ON a.SKU = op.SKU_Motor
    LEFT JOIN MotorsPasz.Empleado e ON e.Legajo = op.idEmpleado;

    -- Stock por articulo y proveedor asignado.
    -- Los motores no tienen proveedor: van con el 0
    -- (Fabricacion propia).
    INSERT INTO stg_stock
    SELECT a.SKU, IFNULL(pa.idProveedor, 0),
           IFNULL(s.disponible, 0), IFNULL(s.no_disponible, 0),
           a.stockMinimo, NULL
    FROM MotorsPasz.Articulos a
    LEFT JOIN MotorsPasz.Proveedor_Articulo pa ON pa.SKU = a.SKU
    LEFT JOIN (SELECT SKU,
                      SUM(CASE WHEN id_estado = 1 THEN cantidad ELSE 0 END) AS disponible,
                      SUM(CASE WHEN id_estado <> 1 THEN cantidad ELSE 0 END) AS no_disponible
               FROM MotorsPasz.Stock_Fisico
               GROUP BY SKU) s ON s.SKU = a.SKU;

    -- Lineas de comprobantes de compra (facturas y notas de
    -- credito de proveedores). Los remitos no se extraen.
    INSERT INTO stg_compras
    SELECT cc.idComprobanteCompra, d.linea, cc.nroComprobanteProveedor, cc.fechaEmision,
           cc.idProveedor, CASE WHEN p.idProveedor IS NULL THEN 0 ELSE 1 END,
           cc.id_tipo_documento, td.multiplicador,
           d.SKU, CASE WHEN a.SKU IS NULL THEN 0 ELSE 1 END,
           d.cantidad, d.precioUnitario, d.subtotal, NULL
    FROM MotorsPasz.Comprobante_Compra cc
    INNER JOIN MotorsPasz.Detalle_Comprobante_Compra d ON d.idComprobanteCompra = cc.idComprobanteCompra
    LEFT JOIN MotorsPasz.Proveedores p ON p.idProveedor = cc.idProveedor
    LEFT JOIN MotorsPasz.Tipo_Documento td ON td.id_tipo_documento = cc.id_tipo_documento
    LEFT JOIN MotorsPasz.Articulos a ON a.SKU = d.SKU
    WHERE td.multiplicador IS NULL OR td.multiplicador <> 0;

    -- Lineas de ordenes de compra (todas)
    INSERT INTO stg_ordenes_compra
    SELECT oc.idCompra, d.linea, oc.fecha, oc.idProveedor,
           CASE WHEN p.idProveedor IS NULL THEN 0 ELSE 1 END, p.tiempoEstimadoEntrega,
           oc.idEmpleado, oc.estado,
           d.SKU, CASE WHEN a.SKU IS NULL THEN 0 ELSE 1 END,
           d.cantidad, d.cantidad_pendiente, d.precio, d.subtotal, 0, NULL
    FROM MotorsPasz.OrdenCompra oc
    INNER JOIN MotorsPasz.Detalle_OrdenCompra d ON d.idCompra = oc.idCompra
    LEFT JOIN MotorsPasz.Proveedores p ON p.idProveedor = oc.idProveedor
    LEFT JOIN MotorsPasz.Articulos a ON a.SKU = d.SKU;

    -- Lineas de ordenes de venta (pedidos)
    INSERT INTO stg_pedidos_venta
    SELECT ov.idVenta, d.linea, ov.fechaVenta, ov.CUITCliente, c.RazonSocial,
           ov.estado, ov.tiempoEntrega,
           d.SKU, CASE WHEN a.SKU IS NULL THEN 0 ELSE 1 END,
           d.cantidad, d.cantidad_pendiente, d.precio, d.subtotal, NULL
    FROM MotorsPasz.OrdenVenta ov
    INNER JOIN MotorsPasz.Detalle_OrdenVenta d ON d.idVenta = ov.idVenta
    LEFT JOIN MotorsPasz.Clientes c ON c.CUITCliente = ov.CUITCliente
    LEFT JOIN MotorsPasz.Articulos a ON a.SKU = d.SKU;

    -- Lineas de remitos de egreso con su orden de venta
    INSERT INTO stg_despachos
    SELECT r.idRemitoEgreso, d.linea, r.nroRemito, r.fechaDespacho,
           r.CUITCliente, c.RazonSocial,
           d.idVenta, ov.fechaVenta, ov.tiempoEntrega,
           d.SKU, CASE WHEN a.SKU IS NULL THEN 0 ELSE 1 END,
           d.cantidadDespachada, NULL
    FROM MotorsPasz.Remito_Egreso r
    INNER JOIN MotorsPasz.Detalle_Remito_Egreso d ON d.idRemitoEgreso = r.idRemitoEgreso
    LEFT JOIN MotorsPasz.Clientes c ON c.CUITCliente = r.CUITCliente
    LEFT JOIN MotorsPasz.OrdenVenta ov ON ov.idVenta = d.idVenta
    LEFT JOIN MotorsPasz.Articulos a ON a.SKU = d.SKU;

    -- Devoluciones de clientes. El precio sale de la
    -- linea de la orden de venta con el mismo SKU.
    INSERT INTO stg_devoluciones_venta
    SELECT dv.idDevolucionVenta, d.linea, dv.fecha, dv.idVenta,
           CASE WHEN ov.idVenta IS NULL THEN 0 ELSE 1 END,
           ov.CUITCliente, c.RazonSocial, dv.idEmpleado, d.id_estado, dv.motivo,
           d.SKU, CASE WHEN a.SKU IS NULL THEN 0 ELSE 1 END,
           d.cantidad, IFNULL(pv.precio, a.precioVenta), NULL
    FROM MotorsPasz.Devolucion_Venta dv
    INNER JOIN MotorsPasz.Detalle_Devolucion_Venta d ON d.idDevolucionVenta = dv.idDevolucionVenta
    LEFT JOIN MotorsPasz.OrdenVenta ov ON ov.idVenta = dv.idVenta
    LEFT JOIN MotorsPasz.Clientes c ON c.CUITCliente = ov.CUITCliente
    LEFT JOIN MotorsPasz.Articulos a ON a.SKU = d.SKU
    LEFT JOIN (SELECT idVenta, SKU, MAX(precio) AS precio
               FROM MotorsPasz.Detalle_OrdenVenta
               GROUP BY idVenta, SKU) pv ON pv.idVenta = dv.idVenta AND pv.SKU = d.SKU;

    -- Lineas de remitos de ingreso con su OC y su
    -- control de recepcion
    INSERT INTO stg_recepciones
    SELECT r.idRemitoIngreso, d.linea, r.nroRemitoProveedor, r.fechaRecepcion,
           r.idProveedor, CASE WHEN p.idProveedor IS NULL THEN 0 ELSE 1 END,
           d.idCompra, oc.fecha, p.tiempoEstimadoEntrega,
           d.SKU, CASE WHEN a.SKU IS NULL THEN 0 ELSE 1 END,
           d.cantidadRecibida, cr.id_estado, cr.idEmpleado, cr.cantidad_evaluada, NULL
    FROM MotorsPasz.Remito_Ingreso r
    INNER JOIN MotorsPasz.Detalle_Remito_Ingreso d ON d.idRemitoIngreso = r.idRemitoIngreso
    LEFT JOIN MotorsPasz.Proveedores p ON p.idProveedor = r.idProveedor
    LEFT JOIN MotorsPasz.OrdenCompra oc ON oc.idCompra = d.idCompra
    LEFT JOIN MotorsPasz.Articulos a ON a.SKU = d.SKU
    LEFT JOIN MotorsPasz.Control_Recepcion cr
           ON cr.idRemitoIngreso = d.idRemitoIngreso AND cr.linea_remito = d.linea;

    -- Devoluciones a proveedores. El precio sale de la
    -- linea de la OC con el mismo SKU.
    INSERT INTO stg_devoluciones_compra
    SELECT dc.idDevolucionCompra, d.linea, dc.fecha, dc.idCompra, oc.idProveedor,
           dc.idEmpleado, dc.motivo,
           d.SKU, CASE WHEN a.SKU IS NULL THEN 0 ELSE 1 END,
           d.cantidad, IFNULL(pc.precio, a.costoUnitario), NULL
    FROM MotorsPasz.Devolucion_Compra dc
    INNER JOIN MotorsPasz.Detalle_Devolucion_Compra d ON d.idDevolucionCompra = dc.idDevolucionCompra
    LEFT JOIN MotorsPasz.OrdenCompra oc ON oc.idCompra = dc.idCompra
    LEFT JOIN MotorsPasz.Articulos a ON a.SKU = d.SKU
    LEFT JOIN (SELECT idCompra, SKU, MAX(precio) AS precio
               FROM MotorsPasz.Detalle_OrdenCompra
               GROUP BY idCompra, SKU) pc ON pc.idCompra = dc.idCompra AND pc.SKU = d.SKU;

    -- Ordenes de produccion (con y sin control)
    INSERT INTO stg_produccion
    SELECT op.idProduccion, op.nroOrden, op.fecha, op.estado, op.idEmpleado, e.idTurno,
           op.SKU_Motor, a.costoUnitario, op.cantidad,
           CASE WHEN EXISTS (SELECT 1 FROM MotorsPasz.Control_Produccion cp
                             WHERE cp.idProduccion = op.idProduccion) THEN 1 ELSE 0 END,
           NULL
    FROM MotorsPasz.OrdenProduccion op
    LEFT JOIN MotorsPasz.Articulos a ON a.SKU = op.SKU_Motor
    LEFT JOIN MotorsPasz.Empleado e ON e.Legajo = op.idEmpleado;


    -- =================================================
    -- T) TRANSFORMACION Y CURADURIA
    -- =================================================
    -- Cada UPDATE es una regla. Solo marca filas que
    -- todavia no tienen motivo, asi queda el primero
    -- que fallo.

    -- ---------- Homogeneizacion ----------
    UPDATE stg_facturacion
    SET cuit = TRIM(cuit), razon_social = TRIM(razon_social);

    UPDATE stg_pedidos_venta
    SET cuit = TRIM(cuit), razon_social = TRIM(razon_social);

    UPDATE stg_despachos
    SET cuit = TRIM(cuit), razon_social = TRIM(razon_social);

    UPDATE stg_devoluciones_venta
    SET cuit = TRIM(cuit), razon_social = TRIM(razon_social);

    UPDATE stg_calidad SET detalle = TRIM(detalle);

    -- ---------- Facturacion ----------
    -- Regla 3: cliente generico o sin CUIT valido
    UPDATE stg_facturacion
    SET motivo_descarte = 'Cliente generico o sin CUIT valido'
    WHERE motivo_descarte IS NULL
      AND fn_cliente_valido(cuit, razon_social) = 0;

    UPDATE stg_facturacion
    SET motivo_descarte = 'Venta anulada'
    WHERE motivo_descarte IS NULL
      AND estado_venta = 'ANULADA';

    UPDATE stg_facturacion
    SET motivo_descarte = 'Comprobante sin fecha o sin tipo'
    WHERE motivo_descarte IS NULL
      AND (fecha_emision IS NULL OR multiplicador IS NULL);

    UPDATE stg_facturacion
    SET motivo_descarte = 'Cantidad o importe invalido'
    WHERE motivo_descarte IS NULL
      AND (cantidad IS NULL OR cantidad <= 0
           OR precio_unitario IS NULL OR precio_unitario <= 0
           OR subtotal IS NULL OR subtotal <= 0);

    UPDATE stg_facturacion
    SET motivo_descarte = 'Articulo inexistente'
    WHERE motivo_descarte IS NULL
      AND costo_unitario IS NULL;

    -- ---------- Calidad ----------
    UPDATE stg_calidad
    SET motivo_descarte = 'Control sin orden de produccion'
    WHERE motivo_descarte IS NULL
      AND id_produccion IS NULL;

    UPDATE stg_calidad
    SET motivo_descarte = 'Orden o control sin fecha'
    WHERE motivo_descarte IS NULL
      AND (fecha_orden IS NULL OR fecha_control IS NULL);

    -- Regla 1: el control no puede ser anterior a la orden
    UPDATE stg_calidad
    SET motivo_descarte = 'Fechas invertidas (control antes que la orden)'
    WHERE motivo_descarte IS NULL
      AND fecha_control < fecha_orden;

    -- Regla 2: motor terminado con costo nulo
    UPDATE stg_calidad
    SET motivo_descarte = 'Motor terminado con costo nulo'
    WHERE motivo_descarte IS NULL
      AND (costo_motor IS NULL OR costo_motor <= 0);

    UPDATE stg_calidad
    SET motivo_descarte = 'Cantidad invalida'
    WHERE motivo_descarte IS NULL
      AND (cantidad IS NULL OR cantidad <= 0);

    UPDATE stg_calidad
    SET motivo_descarte = 'Orden sin operario o turno'
    WHERE motivo_descarte IS NULL
      AND id_turno IS NULL;

    -- Solo 1 (Disponible = aprobado) y 4 (Danado / Scrap =
    -- rechazado) son resultados de un control terminado.
    UPDATE stg_calidad
    SET motivo_descarte = 'Control sin resultado definido'
    WHERE motivo_descarte IS NULL
      AND (id_estado IS NULL OR id_estado NOT IN (1, 4));

    -- Enriquecimiento: resultado y causa del rechazo a
    -- partir del texto libre del control.
    UPDATE stg_calidad
    SET resultado = CASE WHEN id_estado = 4 THEN 'Rechazado' ELSE 'Aprobado' END,
        causa = CASE
            WHEN id_estado <> 4 THEN 'Sin falla'
            WHEN detalle IS NULL OR detalle = '' THEN 'Sin especificar'
            WHEN LOWER(detalle) LIKE '%vibraci%' OR LOWER(detalle) LIKE '%ruido%'
                 OR LOWER(detalle) LIKE '%balanceo%' THEN 'Vibracion / Ruido'
            WHEN LOWER(detalle) LIKE '%bobin%' THEN 'Bobinado'
            WHEN LOWER(detalle) LIKE '%diel%' OR LOWER(detalle) LIKE '%aislac%'
                 OR LOWER(detalle) LIKE '%electr%' OR LOWER(detalle) LIKE '%cortocircuito%' THEN 'Electrica'
            WHEN LOWER(detalle) LIKE '%fuga%' OR LOWER(detalle) LIKE '%estanq%'
                 OR LOWER(detalle) LIKE '%presi%' THEN 'Hermeticidad / Fugas'
            WHEN LOWER(detalle) LIKE '%temperatura%' OR LOWER(detalle) LIKE '%recalent%' THEN 'Temperatura'
            ELSE 'Otra'
        END
    WHERE motivo_descarte IS NULL;

    -- ---------- Stock ----------
    UPDATE stg_stock
    SET motivo_descarte = 'Stock negativo'
    WHERE motivo_descarte IS NULL
      AND (stock_disponible < 0 OR stock_no_disponible < 0);

    UPDATE stg_stock
    SET motivo_descarte = 'Articulo sin stock minimo'
    WHERE motivo_descarte IS NULL
      AND stock_minimo IS NULL;

    -- ---------- Ordenes de compra ----------
    UPDATE stg_ordenes_compra
    SET motivo_descarte = 'OC sin proveedor valido'
    WHERE motivo_descarte IS NULL
      AND proveedor_existe = 0;

    UPDATE stg_ordenes_compra
    SET motivo_descarte = 'OC sin fecha'
    WHERE motivo_descarte IS NULL
      AND fecha_oc IS NULL;

    UPDATE stg_ordenes_compra
    SET motivo_descarte = 'Cantidad o importe invalido'
    WHERE motivo_descarte IS NULL
      AND (cantidad IS NULL OR cantidad <= 0
           OR precio IS NULL OR precio <= 0
           OR cantidad_pendiente IS NULL OR cantidad_pendiente < 0);

    UPDATE stg_ordenes_compra
    SET motivo_descarte = 'Pendiente mayor a lo pedido'
    WHERE motivo_descarte IS NULL
      AND cantidad_pendiente > cantidad;

    UPDATE stg_ordenes_compra
    SET motivo_descarte = 'Articulo inexistente'
    WHERE motivo_descarte IS NULL
      AND articulo_existe = 0;

    -- Regla 4: vencida = ya paso la fecha de la OC mas los
    -- dias de entrega del proveedor. Si ademas lo que falta
    -- es menos del umbral, ese remanente no cuenta como
    -- pendiente. La linea de la OC sigue siendo valida:
    -- no se descarta, se ignora solo el remanente.
    UPDATE stg_ordenes_compra
    SET remanente_ignorado = 1
    WHERE motivo_descarte IS NULL
      AND cantidad_pendiente > 0
      AND DATE_ADD(fecha_oc, INTERVAL IFNULL(dias_entrega, 0) DAY) < v_fecha_corte
      AND cantidad_pendiente < cantidad * v_umbral_remanente;

    -- ---------- Pedidos de venta ----------
    UPDATE stg_pedidos_venta
    SET motivo_descarte = 'Cliente generico o sin CUIT valido'
    WHERE motivo_descarte IS NULL
      AND fn_cliente_valido(cuit, razon_social) = 0;

    UPDATE stg_pedidos_venta
    SET motivo_descarte = 'Pedido sin fecha'
    WHERE motivo_descarte IS NULL
      AND fecha_venta IS NULL;

    UPDATE stg_pedidos_venta
    SET motivo_descarte = 'Cantidad o importe invalido'
    WHERE motivo_descarte IS NULL
      AND (cantidad IS NULL OR cantidad <= 0
           OR precio IS NULL OR precio <= 0
           OR cantidad_pendiente IS NULL OR cantidad_pendiente < 0);

    UPDATE stg_pedidos_venta
    SET motivo_descarte = 'Pendiente mayor a lo pedido'
    WHERE motivo_descarte IS NULL
      AND cantidad_pendiente > cantidad;

    UPDATE stg_pedidos_venta
    SET motivo_descarte = 'Articulo inexistente'
    WHERE motivo_descarte IS NULL
      AND articulo_existe = 0;

    -- ---------- Despachos ----------
    UPDATE stg_despachos
    SET motivo_descarte = 'Cliente generico o sin CUIT valido'
    WHERE motivo_descarte IS NULL
      AND fn_cliente_valido(cuit, razon_social) = 0;

    UPDATE stg_despachos
    SET motivo_descarte = 'Despacho sin orden de venta'
    WHERE motivo_descarte IS NULL
      AND fecha_venta IS NULL;

    UPDATE stg_despachos
    SET motivo_descarte = 'Despacho sin fecha'
    WHERE motivo_descarte IS NULL
      AND fecha_despacho IS NULL;

    UPDATE stg_despachos
    SET motivo_descarte = 'Fechas invertidas (despacho antes que la venta)'
    WHERE motivo_descarte IS NULL
      AND fecha_despacho < fecha_venta;

    UPDATE stg_despachos
    SET motivo_descarte = 'Cantidad invalida'
    WHERE motivo_descarte IS NULL
      AND (cantidad IS NULL OR cantidad <= 0);

    UPDATE stg_despachos
    SET motivo_descarte = 'Articulo inexistente'
    WHERE motivo_descarte IS NULL
      AND articulo_existe = 0;

    -- ---------- Devoluciones de clientes ----------
    UPDATE stg_devoluciones_venta
    SET motivo_descarte = 'Devolucion sin orden de venta'
    WHERE motivo_descarte IS NULL
      AND venta_existe = 0;

    UPDATE stg_devoluciones_venta
    SET motivo_descarte = 'Cliente generico o sin CUIT valido'
    WHERE motivo_descarte IS NULL
      AND fn_cliente_valido(cuit, razon_social) = 0;

    UPDATE stg_devoluciones_venta
    SET motivo_descarte = 'Devolucion sin fecha'
    WHERE motivo_descarte IS NULL
      AND fecha IS NULL;

    UPDATE stg_devoluciones_venta
    SET motivo_descarte = 'Cantidad invalida'
    WHERE motivo_descarte IS NULL
      AND (cantidad IS NULL OR cantidad <= 0);

    UPDATE stg_devoluciones_venta
    SET motivo_descarte = 'Articulo inexistente'
    WHERE motivo_descarte IS NULL
      AND articulo_existe = 0;

    -- ---------- Recepciones ----------
    UPDATE stg_recepciones
    SET motivo_descarte = 'Recepcion sin proveedor valido'
    WHERE motivo_descarte IS NULL
      AND proveedor_existe = 0;

    UPDATE stg_recepciones
    SET motivo_descarte = 'Recepcion sin orden de compra'
    WHERE motivo_descarte IS NULL
      AND fecha_oc IS NULL;

    UPDATE stg_recepciones
    SET motivo_descarte = 'Recepcion sin fecha'
    WHERE motivo_descarte IS NULL
      AND fecha_recepcion IS NULL;

    UPDATE stg_recepciones
    SET motivo_descarte = 'Fechas invertidas (recepcion antes que la OC)'
    WHERE motivo_descarte IS NULL
      AND fecha_recepcion < fecha_oc;

    UPDATE stg_recepciones
    SET motivo_descarte = 'Cantidad invalida'
    WHERE motivo_descarte IS NULL
      AND (cantidad IS NULL OR cantidad <= 0);

    UPDATE stg_recepciones
    SET motivo_descarte = 'Articulo inexistente'
    WHERE motivo_descarte IS NULL
      AND articulo_existe = 0;

    -- ---------- Devoluciones a proveedores ----------
    UPDATE stg_devoluciones_compra
    SET motivo_descarte = 'Devolucion sin orden de compra'
    WHERE motivo_descarte IS NULL
      AND id_proveedor IS NULL;

    UPDATE stg_devoluciones_compra
    SET motivo_descarte = 'Devolucion sin fecha'
    WHERE motivo_descarte IS NULL
      AND fecha IS NULL;

    UPDATE stg_devoluciones_compra
    SET motivo_descarte = 'Cantidad invalida'
    WHERE motivo_descarte IS NULL
      AND (cantidad IS NULL OR cantidad <= 0);

    UPDATE stg_devoluciones_compra
    SET motivo_descarte = 'Articulo inexistente'
    WHERE motivo_descarte IS NULL
      AND articulo_existe = 0;

    -- ---------- Produccion ----------
    UPDATE stg_produccion
    SET motivo_descarte = 'Orden sin fecha'
    WHERE motivo_descarte IS NULL
      AND fecha IS NULL;

    -- Regla 2: motor terminado con costo nulo
    UPDATE stg_produccion
    SET motivo_descarte = 'Motor terminado con costo nulo'
    WHERE motivo_descarte IS NULL
      AND (costo_motor IS NULL OR costo_motor <= 0);

    UPDATE stg_produccion
    SET motivo_descarte = 'Cantidad invalida'
    WHERE motivo_descarte IS NULL
      AND (cantidad IS NULL OR cantidad <= 0);

    UPDATE stg_produccion
    SET motivo_descarte = 'Orden sin operario o turno'
    WHERE motivo_descarte IS NULL
      AND id_turno IS NULL;

    -- ---------- Compras ----------
    UPDATE stg_compras
    SET motivo_descarte = 'Compra sin proveedor valido'
    WHERE motivo_descarte IS NULL
      AND proveedor_existe = 0;

    UPDATE stg_compras
    SET motivo_descarte = 'Comprobante sin fecha o sin tipo'
    WHERE motivo_descarte IS NULL
      AND (fecha_emision IS NULL OR multiplicador IS NULL);

    UPDATE stg_compras
    SET motivo_descarte = 'Cantidad o importe invalido'
    WHERE motivo_descarte IS NULL
      AND (cantidad IS NULL OR cantidad <= 0
           OR precio_unitario IS NULL OR precio_unitario <= 0
           OR subtotal IS NULL OR subtotal <= 0);

    UPDATE stg_compras
    SET motivo_descarte = 'Articulo inexistente'
    WHERE motivo_descarte IS NULL
      AND articulo_existe = 0;

    -- ---------- Registro de descartes ----------
    INSERT INTO etl_descartes (id_ejecucion, tabla_origen, clave_origen, motivo, fecha_registro)
    SELECT v_id_ejecucion, 'Detalle_Comprobante_Venta',
           CONCAT(id_comprobante, '-', linea), motivo_descarte, NOW()
    FROM stg_facturacion WHERE motivo_descarte IS NOT NULL;

    INSERT INTO etl_descartes (id_ejecucion, tabla_origen, clave_origen, motivo, fecha_registro)
    SELECT v_id_ejecucion, 'Control_Produccion',
           CONCAT(id_control), motivo_descarte, NOW()
    FROM stg_calidad WHERE motivo_descarte IS NOT NULL;

    INSERT INTO etl_descartes (id_ejecucion, tabla_origen, clave_origen, motivo, fecha_registro)
    SELECT v_id_ejecucion, 'Stock_Fisico',
           CONCAT(sku, '-', id_proveedor), motivo_descarte, NOW()
    FROM stg_stock WHERE motivo_descarte IS NOT NULL;

    -- En las OC tambien se registra el remanente ignorado
    -- por la regla 4 (la linea queda, el remanente no).
    INSERT INTO etl_descartes (id_ejecucion, tabla_origen, clave_origen, motivo, fecha_registro)
    SELECT v_id_ejecucion, 'Detalle_OrdenCompra',
           CONCAT(id_compra, '-', linea),
           IFNULL(motivo_descarte, 'OC vencida con remanente minimo'), NOW()
    FROM stg_ordenes_compra
    WHERE motivo_descarte IS NOT NULL OR remanente_ignorado = 1;

    INSERT INTO etl_descartes (id_ejecucion, tabla_origen, clave_origen, motivo, fecha_registro)
    SELECT v_id_ejecucion, 'Detalle_OrdenVenta',
           CONCAT(id_venta, '-', linea), motivo_descarte, NOW()
    FROM stg_pedidos_venta WHERE motivo_descarte IS NOT NULL;

    INSERT INTO etl_descartes (id_ejecucion, tabla_origen, clave_origen, motivo, fecha_registro)
    SELECT v_id_ejecucion, 'Detalle_Remito_Egreso',
           CONCAT(id_remito, '-', linea), motivo_descarte, NOW()
    FROM stg_despachos WHERE motivo_descarte IS NOT NULL;

    INSERT INTO etl_descartes (id_ejecucion, tabla_origen, clave_origen, motivo, fecha_registro)
    SELECT v_id_ejecucion, 'Detalle_Devolucion_Venta',
           CONCAT(id_devolucion, '-', linea), motivo_descarte, NOW()
    FROM stg_devoluciones_venta WHERE motivo_descarte IS NOT NULL;

    INSERT INTO etl_descartes (id_ejecucion, tabla_origen, clave_origen, motivo, fecha_registro)
    SELECT v_id_ejecucion, 'Detalle_Remito_Ingreso',
           CONCAT(id_remito, '-', linea), motivo_descarte, NOW()
    FROM stg_recepciones WHERE motivo_descarte IS NOT NULL;

    INSERT INTO etl_descartes (id_ejecucion, tabla_origen, clave_origen, motivo, fecha_registro)
    SELECT v_id_ejecucion, 'Detalle_Devolucion_Compra',
           CONCAT(id_devolucion, '-', linea), motivo_descarte, NOW()
    FROM stg_devoluciones_compra WHERE motivo_descarte IS NOT NULL;

    INSERT INTO etl_descartes (id_ejecucion, tabla_origen, clave_origen, motivo, fecha_registro)
    SELECT v_id_ejecucion, 'OrdenProduccion',
           CONCAT(id_produccion), motivo_descarte, NOW()
    FROM stg_produccion WHERE motivo_descarte IS NOT NULL;

    INSERT INTO etl_descartes (id_ejecucion, tabla_origen, clave_origen, motivo, fecha_registro)
    SELECT v_id_ejecucion, 'Detalle_Comprobante_Compra',
           CONCAT(id_comprobante, '-', linea), motivo_descarte, NOW()
    FROM stg_compras WHERE motivo_descarte IS NOT NULL;

    SELECT COUNT(*) INTO v_filas_desc
    FROM etl_descartes WHERE id_ejecucion = v_id_ejecucion;


    -- =================================================
    -- L) CARGA
    -- =================================================

    -- ---------- Dimension Tiempo ----------
    -- Rango: anios completos, desde el 1/1 del anio mas
    -- viejo de los datos hasta el 31/12 del mas nuevo
    -- (o del anio de la fecha de corte si es mayor).
    SELECT LEAST(IFNULL(MIN(f), v_fecha_corte), v_fecha_corte),
           GREATEST(IFNULL(MAX(f), v_fecha_corte), v_fecha_corte)
    INTO v_desde, v_hasta
    FROM (SELECT fecha_emision AS f FROM stg_facturacion WHERE motivo_descarte IS NULL
          UNION ALL
          SELECT fecha_control FROM stg_calidad WHERE motivo_descarte IS NULL
          UNION ALL
          SELECT fecha_emision FROM stg_compras WHERE motivo_descarte IS NULL
          UNION ALL
          SELECT fecha_oc FROM stg_ordenes_compra WHERE motivo_descarte IS NULL
          UNION ALL
          SELECT fecha_venta FROM stg_pedidos_venta WHERE motivo_descarte IS NULL
          UNION ALL
          SELECT fecha_despacho FROM stg_despachos WHERE motivo_descarte IS NULL
          UNION ALL
          SELECT fecha FROM stg_devoluciones_venta WHERE motivo_descarte IS NULL
          UNION ALL
          SELECT fecha_recepcion FROM stg_recepciones WHERE motivo_descarte IS NULL
          UNION ALL
          SELECT fecha FROM stg_devoluciones_compra WHERE motivo_descarte IS NULL
          UNION ALL
          SELECT fecha FROM stg_produccion WHERE motivo_descarte IS NULL) fechas;

    SET v_desde = MAKEDATE(YEAR(v_desde), 1);
    SET v_hasta = MAKEDATE(YEAR(v_hasta) + 1, 1) - INTERVAL 1 DAY;

    INSERT IGNORE INTO dim_tiempo
    WITH RECURSIVE calendario AS (
        SELECT v_desde AS fecha
        UNION ALL
        SELECT DATE_ADD(fecha, INTERVAL 1 DAY) FROM calendario WHERE fecha < v_hasta
    )
    SELECT DATE_FORMAT(fecha, '%Y%m%d') + 0,
           fecha,
           YEAR(fecha),
           QUARTER(fecha),
           MONTH(fecha),
           ELT(MONTH(fecha), 'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio',
               'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'),
           DATE_FORMAT(fecha, '%Y-%m'),
           DAY(fecha),
           WEEKDAY(fecha) + 1,
           ELT(WEEKDAY(fecha) + 1, 'Lunes', 'Martes', 'Miercoles', 'Jueves', 'Viernes',
               'Sabado', 'Domingo'),
           CASE WHEN WEEKDAY(fecha) >= 5 THEN 1 ELSE 0 END
    FROM calendario;

    -- ---------- Resto de dimensiones (upsert) ----------
    -- Ubicacion: la direccion principal (si hubiera mas
    -- de una marcada como principal, la de menor id).
    INSERT INTO dim_cliente (cuit, razon_social, segmento, provincia, localidad)
    SELECT TRIM(c.CUITCliente), TRIM(c.RazonSocial), IFNULL(tc.tipo_cliente, 'Sin segmento'),
           IFNULL(NULLIF(TRIM(d.provincia), ''), 'Sin dato'),
           IFNULL(NULLIF(TRIM(d.localidad), ''), 'Sin dato')
    FROM MotorsPasz.Clientes c
    LEFT JOIN MotorsPasz.Tipo_Cliente tc ON tc.id_tipo_cliente = c.id_tipo_cliente
    LEFT JOIN (SELECT CUITCliente, MIN(id_direccion) AS id_direccion
               FROM MotorsPasz.Direccion_Cliente
               WHERE es_principal = TRUE
               GROUP BY CUITCliente) dp ON dp.CUITCliente = c.CUITCliente
    LEFT JOIN MotorsPasz.Direccion d ON d.id_direccion = dp.id_direccion
    -- misma regla 3: los clientes genericos no entran
    WHERE fn_cliente_valido(c.CUITCliente, c.RazonSocial) = 1
    ON DUPLICATE KEY UPDATE razon_social = VALUES(razon_social),
                            segmento = VALUES(segmento),
                            provincia = VALUES(provincia),
                            localidad = VALUES(localidad);

    INSERT INTO dim_articulo (sku, descripcion, tipo_articulo, categoria,
                              costo_unitario, precio_venta, stock_minimo)
    SELECT a.SKU, a.descripcion, IFNULL(t.tipo_articulo, 'Sin tipo'),
           CASE WHEN t.tipo_articulo = 'Bomba Terminada' THEN 'Motor terminado' ELSE 'Componente' END,
           a.costoUnitario, a.precioVenta, a.stockMinimo
    FROM MotorsPasz.Articulos a
    LEFT JOIN MotorsPasz.Tipo_Articulo t ON t.id_tipo_articulo = a.id_tipo_articulo
    ON DUPLICATE KEY UPDATE descripcion = VALUES(descripcion),
                            tipo_articulo = VALUES(tipo_articulo),
                            categoria = VALUES(categoria),
                            costo_unitario = VALUES(costo_unitario),
                            precio_venta = VALUES(precio_venta),
                            stock_minimo = VALUES(stock_minimo);

    INSERT IGNORE INTO dim_proveedor (id_proveedor, cuit, razon_social, dias_entrega)
    VALUES (0, NULL, 'Fabricacion propia', NULL);

    INSERT INTO dim_proveedor (id_proveedor, cuit, razon_social, dias_entrega)
    SELECT idProveedor, CUIT, razonSocial, tiempoEstimadoEntrega
    FROM MotorsPasz.Proveedores
    ON DUPLICATE KEY UPDATE cuit = VALUES(cuit),
                            razon_social = VALUES(razon_social),
                            dias_entrega = VALUES(dias_entrega);

    INSERT INTO dim_tipo_comprobante (id_tipo_documento, codigo, nombre, multiplicador)
    SELECT id_tipo_documento, codigo, nombre, multiplicador
    FROM MotorsPasz.Tipo_Documento
    WHERE multiplicador <> 0
    ON DUPLICATE KEY UPDATE codigo = VALUES(codigo),
                            nombre = VALUES(nombre),
                            multiplicador = VALUES(multiplicador);

    INSERT INTO dim_linea_produccion (id_turno, linea, hora_entrada, hora_salida)
    SELECT idTurno,
           CONCAT('Turno ', TIME_FORMAT(horaEntrada, '%H:%i'), ' a ', TIME_FORMAT(horaSalida, '%H:%i')),
           horaEntrada, horaSalida
    FROM MotorsPasz.TurnoTrabajo
    ON DUPLICATE KEY UPDATE linea = VALUES(linea),
                            hora_entrada = VALUES(hora_entrada),
                            hora_salida = VALUES(hora_salida);

    INSERT IGNORE INTO dim_resultado_control (resultado, causa)
    SELECT DISTINCT resultado, causa
    FROM stg_calidad
    WHERE motivo_descarte IS NULL;

    INSERT IGNORE INTO dim_empleado (legajo, nombre_completo, cargo, nivel_acceso, turno, area)
    VALUES (0, 'Sin asignar', 'Sin dato', 'Sin dato', 'Sin dato', 'Sin dato');

    INSERT INTO dim_empleado (legajo, nombre_completo, cargo, nivel_acceso, turno, area)
    SELECT e.Legajo, CONCAT(TRIM(e.apellido), ', ', TRIM(e.nombre)),
           IFNULL(r.cargo, 'Sin dato'), IFNULL(r.nivelAcceso, 'Sin dato'),
           IFNULL(CONCAT('Turno ', TIME_FORMAT(t.horaEntrada, '%H:%i'), ' a ',
                         TIME_FORMAT(t.horaSalida, '%H:%i')), 'Sin dato'),
           IFNULL(t.area, 'Sin dato')
    FROM MotorsPasz.Empleado e
    LEFT JOIN MotorsPasz.Rol r ON r.idRol = e.idRol
    LEFT JOIN MotorsPasz.TurnoTrabajo t ON t.idTurno = e.idTurno
    ON DUPLICATE KEY UPDATE nombre_completo = VALUES(nombre_completo),
                            cargo = VALUES(cargo),
                            nivel_acceso = VALUES(nivel_acceso),
                            turno = VALUES(turno),
                            area = VALUES(area);

    INSERT IGNORE INTO dim_estado_stock (id_estado, estado)
    VALUES (0, 'Sin dato');

    INSERT INTO dim_estado_stock (id_estado, estado)
    SELECT id_estado, estado
    FROM MotorsPasz.Estado_Stock
    ON DUPLICATE KEY UPDATE estado = VALUES(estado);

    -- ---------- Hechos: Facturacion ----------
    DELETE FROM fact_facturacion;

    INSERT INTO fact_facturacion
    SELECT s.id_comprobante, s.linea, s.nro_comprobante,
           t.sk_tiempo, c.sk_cliente, a.sk_articulo, tc.sk_tipo_comprobante,
           s.cantidad, s.cantidad * s.multiplicador, s.precio_unitario,
           s.subtotal,
           s.subtotal * s.multiplicador,
           s.cantidad * s.costo_unitario * s.multiplicador,
           (s.subtotal - s.cantidad * s.costo_unitario) * s.multiplicador
    FROM stg_facturacion s
    INNER JOIN dim_tiempo t ON t.fecha = s.fecha_emision
    INNER JOIN dim_cliente c ON c.cuit = s.cuit
    INNER JOIN dim_articulo a ON a.sku = s.sku
    INNER JOIN dim_tipo_comprobante tc ON tc.id_tipo_documento = s.id_tipo_documento
    WHERE s.motivo_descarte IS NULL;

    SET v_filas_fact = ROW_COUNT();

    -- ---------- Hechos: Calidad ----------
    DELETE FROM fact_calidad;

    INSERT INTO fact_calidad
    SELECT s.id_control, s.id_produccion, s.nro_orden,
           t.sk_tiempo, a.sk_articulo, l.sk_linea, r.sk_resultado,
           s.cantidad,
           CASE WHEN s.resultado = 'Rechazado' THEN s.cantidad ELSE 0 END,
           CASE WHEN s.resultado = 'Rechazado' THEN 1 ELSE 0 END,
           DATEDIFF(s.fecha_control, s.fecha_orden)
    FROM stg_calidad s
    INNER JOIN dim_tiempo t ON t.fecha = s.fecha_control
    INNER JOIN dim_articulo a ON a.sku = s.sku_motor
    INNER JOIN dim_linea_produccion l ON l.id_turno = s.id_turno
    INNER JOIN dim_resultado_control r ON r.resultado = s.resultado AND r.causa = s.causa
    WHERE s.motivo_descarte IS NULL;

    SET v_filas_cal = ROW_COUNT();

    -- ---------- Hechos: Stock (foto de la fecha de corte) ----------
    DELETE FROM fact_stock WHERE sk_tiempo = v_sk_corte;

    INSERT INTO fact_stock
    SELECT v_sk_corte, a.sk_articulo, p.sk_proveedor,
           s.stock_disponible,
           s.stock_no_disponible,
           s.stock_minimo,
           s.stock_disponible * IFNULL(a.costo_unitario, 0),
           GREATEST(s.stock_minimo - s.stock_disponible, 0),
           CASE WHEN s.stock_disponible < s.stock_minimo THEN 1 ELSE 0 END,
           IFNULL(oc.pendiente, 0)
    FROM stg_stock s
    INNER JOIN dim_articulo a ON a.sku = s.sku
    INNER JOIN dim_proveedor p ON p.id_proveedor = s.id_proveedor
    LEFT JOIN (SELECT sku, id_proveedor, SUM(cantidad_pendiente) AS pendiente
               FROM stg_ordenes_compra
               WHERE motivo_descarte IS NULL
                 AND remanente_ignorado = 0
                 AND cantidad_pendiente > 0
               GROUP BY sku, id_proveedor) oc
           ON oc.sku = s.sku AND oc.id_proveedor = s.id_proveedor
    WHERE s.motivo_descarte IS NULL;

    SET v_filas_stock = ROW_COUNT();

    -- ---------- Hechos: Compras ----------
    DELETE FROM fact_compras;

    INSERT INTO fact_compras
    SELECT s.id_comprobante, s.linea, s.nro_comprobante,
           t.sk_tiempo, p.sk_proveedor, a.sk_articulo, tc.sk_tipo_comprobante,
           s.cantidad, s.precio_unitario,
           s.subtotal,
           s.subtotal * s.multiplicador
    FROM stg_compras s
    INNER JOIN dim_tiempo t ON t.fecha = s.fecha_emision
    INNER JOIN dim_proveedor p ON p.id_proveedor = s.id_proveedor
    INNER JOIN dim_articulo a ON a.sku = s.sku
    INNER JOIN dim_tipo_comprobante tc ON tc.id_tipo_documento = s.id_tipo_documento
    WHERE s.motivo_descarte IS NULL;

    SET v_filas_compras = ROW_COUNT();

    -- Los empleados y estados que no se encuentran van al
    -- miembro 'Sin asignar' / 'Sin dato' (clave 0).

    -- ---------- Hechos: Pedidos de venta ----------
    DELETE FROM fact_pedidos_venta;

    INSERT INTO fact_pedidos_venta
    SELECT s.id_venta, s.linea,
           t.sk_tiempo, c.sk_cliente, a.sk_articulo,
           IFNULL(s.estado, 'Sin dato'),
           s.cantidad, s.cantidad - s.cantidad_pendiente, s.cantidad_pendiente,
           s.precio, s.cantidad * s.precio,
           s.dias_entrega
    FROM stg_pedidos_venta s
    INNER JOIN dim_tiempo t ON t.fecha = s.fecha_venta
    INNER JOIN dim_cliente c ON c.cuit = s.cuit
    INNER JOIN dim_articulo a ON a.sku = s.sku
    WHERE s.motivo_descarte IS NULL;

    SET v_filas_ped = ROW_COUNT();

    -- ---------- Hechos: Despachos ----------
    DELETE FROM fact_despachos;

    INSERT INTO fact_despachos
    SELECT s.id_remito, s.linea, s.nro_remito, s.id_venta,
           t.sk_tiempo, c.sk_cliente, a.sk_articulo,
           s.cantidad,
           DATEDIFF(s.fecha_despacho, s.fecha_venta),
           s.dias_entrega,
           CASE WHEN s.dias_entrega IS NOT NULL
                 AND DATEDIFF(s.fecha_despacho, s.fecha_venta) > s.dias_entrega
                THEN 1 ELSE 0 END
    FROM stg_despachos s
    INNER JOIN dim_tiempo t ON t.fecha = s.fecha_despacho
    INNER JOIN dim_cliente c ON c.cuit = s.cuit
    INNER JOIN dim_articulo a ON a.sku = s.sku
    WHERE s.motivo_descarte IS NULL;

    SET v_filas_desp = ROW_COUNT();

    -- ---------- Hechos: Devoluciones de clientes ----------
    DELETE FROM fact_devoluciones_venta;

    INSERT INTO fact_devoluciones_venta
    SELECT s.id_devolucion, s.linea, s.id_venta,
           t.sk_tiempo, c.sk_cliente, a.sk_articulo,
           IFNULL(e.sk_empleado, e0.sk_empleado),
           IFNULL(es.sk_estado, es0.sk_estado),
           s.motivo,
           s.cantidad, s.cantidad * IFNULL(s.precio, 0)
    FROM stg_devoluciones_venta s
    INNER JOIN dim_tiempo t ON t.fecha = s.fecha
    INNER JOIN dim_cliente c ON c.cuit = s.cuit
    INNER JOIN dim_articulo a ON a.sku = s.sku
    INNER JOIN dim_empleado e0 ON e0.legajo = 0
    INNER JOIN dim_estado_stock es0 ON es0.id_estado = 0
    LEFT JOIN dim_empleado e ON e.legajo = s.id_empleado
    LEFT JOIN dim_estado_stock es ON es.id_estado = s.id_estado
    WHERE s.motivo_descarte IS NULL;

    SET v_filas_dev_v = ROW_COUNT();

    -- ---------- Hechos: Ordenes de compra ----------
    DELETE FROM fact_ordenes_compra;

    INSERT INTO fact_ordenes_compra
    SELECT s.id_compra, s.linea,
           t.sk_tiempo, p.sk_proveedor, a.sk_articulo,
           IFNULL(e.sk_empleado, e0.sk_empleado),
           IFNULL(s.estado, 'Sin dato'),
           s.cantidad,
           s.cantidad - s.cantidad_pendiente,
           CASE WHEN s.remanente_ignorado = 1 THEN 0 ELSE s.cantidad_pendiente END,
           s.precio, s.cantidad * s.precio,
           CASE WHEN s.remanente_ignorado = 0
                 AND s.cantidad_pendiente > 0
                 AND DATE_ADD(s.fecha_oc, INTERVAL IFNULL(s.dias_entrega, 0) DAY) < v_fecha_corte
                THEN 1 ELSE 0 END
    FROM stg_ordenes_compra s
    INNER JOIN dim_tiempo t ON t.fecha = s.fecha_oc
    INNER JOIN dim_proveedor p ON p.id_proveedor = s.id_proveedor
    INNER JOIN dim_articulo a ON a.sku = s.sku
    INNER JOIN dim_empleado e0 ON e0.legajo = 0
    LEFT JOIN dim_empleado e ON e.legajo = s.id_empleado
    WHERE s.motivo_descarte IS NULL;

    SET v_filas_oc = ROW_COUNT();

    -- ---------- Hechos: Recepciones ----------
    DELETE FROM fact_recepciones;

    INSERT INTO fact_recepciones
    SELECT s.id_remito, s.linea, s.nro_remito, s.id_compra,
           t.sk_tiempo, p.sk_proveedor, a.sk_articulo,
           IFNULL(es.sk_estado, es0.sk_estado),
           IFNULL(e.sk_empleado, e0.sk_empleado),
           s.cantidad, IFNULL(s.cantidad_evaluada, 0),
           DATEDIFF(s.fecha_recepcion, s.fecha_oc),
           s.dias_entrega,
           CASE WHEN s.dias_entrega IS NOT NULL
                 AND DATEDIFF(s.fecha_recepcion, s.fecha_oc) > s.dias_entrega
                THEN 1 ELSE 0 END
    FROM stg_recepciones s
    INNER JOIN dim_tiempo t ON t.fecha = s.fecha_recepcion
    INNER JOIN dim_proveedor p ON p.id_proveedor = s.id_proveedor
    INNER JOIN dim_articulo a ON a.sku = s.sku
    INNER JOIN dim_empleado e0 ON e0.legajo = 0
    INNER JOIN dim_estado_stock es0 ON es0.id_estado = 0
    LEFT JOIN dim_empleado e ON e.legajo = s.id_empleado
    LEFT JOIN dim_estado_stock es ON es.id_estado = s.id_estado
    WHERE s.motivo_descarte IS NULL;

    SET v_filas_rec = ROW_COUNT();

    -- ---------- Hechos: Devoluciones a proveedores ----------
    DELETE FROM fact_devoluciones_compra;

    INSERT INTO fact_devoluciones_compra
    SELECT s.id_devolucion, s.linea, s.id_compra,
           t.sk_tiempo, p.sk_proveedor, a.sk_articulo,
           IFNULL(e.sk_empleado, e0.sk_empleado),
           s.motivo,
           s.cantidad, s.cantidad * IFNULL(s.precio, 0)
    FROM stg_devoluciones_compra s
    INNER JOIN dim_tiempo t ON t.fecha = s.fecha
    INNER JOIN dim_proveedor p ON p.id_proveedor = s.id_proveedor
    INNER JOIN dim_articulo a ON a.sku = s.sku
    INNER JOIN dim_empleado e0 ON e0.legajo = 0
    LEFT JOIN dim_empleado e ON e.legajo = s.id_empleado
    WHERE s.motivo_descarte IS NULL;

    SET v_filas_dev_c = ROW_COUNT();

    -- ---------- Hechos: Produccion ----------
    DELETE FROM fact_produccion;

    INSERT INTO fact_produccion
    SELECT s.id_produccion, s.nro_orden,
           t.sk_tiempo, a.sk_articulo, l.sk_linea,
           IFNULL(e.sk_empleado, e0.sk_empleado),
           IFNULL(s.estado, 'Sin dato'),
           s.cantidad, s.cantidad * s.costo_motor,
           s.tiene_control
    FROM stg_produccion s
    INNER JOIN dim_tiempo t ON t.fecha = s.fecha
    INNER JOIN dim_articulo a ON a.sku = s.sku_motor
    INNER JOIN dim_linea_produccion l ON l.id_turno = s.id_turno
    INNER JOIN dim_empleado e0 ON e0.legajo = 0
    LEFT JOIN dim_empleado e ON e.legajo = s.id_empleado
    WHERE s.motivo_descarte IS NULL;

    SET v_filas_prod = ROW_COUNT();

    COMMIT;

    UPDATE etl_ejecucion
    SET fin = NOW(), estado = 'OK',
        filas_facturacion = v_filas_fact,
        filas_calidad = v_filas_cal,
        filas_stock = v_filas_stock,
        filas_compras = v_filas_compras,
        filas_pedidos_venta = v_filas_ped,
        filas_despachos = v_filas_desp,
        filas_devoluciones_venta = v_filas_dev_v,
        filas_ordenes_compra = v_filas_oc,
        filas_recepciones = v_filas_rec,
        filas_devoluciones_compra = v_filas_dev_c,
        filas_produccion = v_filas_prod,
        filas_descartadas = v_filas_desc,
        mensaje = 'Carga completa'
    WHERE id_ejecucion = v_id_ejecucion;

    SET SQL_SAFE_UPDATES = v_safe_updates;

    SELECT * FROM etl_ejecucion WHERE id_ejecucion = v_id_ejecucion;
END //

DELIMITER ;
