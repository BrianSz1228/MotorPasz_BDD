USE MotorsPasz;

DROP VIEW IF EXISTS vw_catalogo_vendedor;
DROP VIEW IF EXISTS vw_clientes_comercial;
DROP VIEW IF EXISTS vw_stock_deposito;
DROP VIEW IF EXISTS vw_produccion_supervisor;
DROP VIEW IF EXISTS vw_ordenes_produccion;
DROP VIEW IF EXISTS vw_rentabilidad_articulos;
DROP VIEW IF EXISTS vw_stock_valorizado;
DROP VIEW IF EXISTS vw_kpi_facturacion_mensual;
DROP VIEW IF EXISTS vw_kpi_facturacion_total_mensual;
DROP VIEW IF EXISTS vw_kpi_tasa_rechazo;
DROP VIEW IF EXISTS vw_kpi_quiebre_stock;

DROP TRIGGER IF EXISTS trg_articulos_cambio_precio;
DROP TRIGGER IF EXISTS trg_articulos_borrado;
DROP TRIGGER IF EXISTS trg_articulos_precio_minimo;
DROP TRIGGER IF EXISTS trg_bom_cambio_cantidad;
DROP TRIGGER IF EXISTS trg_stock_no_negativo_insert;
DROP TRIGGER IF EXISTS trg_stock_no_negativo_update;
DROP TRIGGER IF EXISTS trg_stock_cambios;
DROP TRIGGER IF EXISTS trg_stock_borrado;
DROP TRIGGER IF EXISTS trg_stock_alta;
DROP TRIGGER IF EXISTS trg_ventas_cambio_estado;

DROP PROCEDURE IF EXISTS sp_registrar_venta;
DROP PROCEDURE IF EXISTS sp_agregar_linea_venta;
DROP PROCEDURE IF EXISTS sp_despachar_venta;
DROP PROCEDURE IF EXISTS sp_actualizar_precio_bomba;
DROP PROCEDURE IF EXISTS sp_cerrar_orden_produccion;
DROP PROCEDURE IF EXISTS sp_consultar_stock_articulo;
DROP PROCEDURE IF EXISTS sp_marcar_scrap;
DROP PROCEDURE IF EXISTS sp_anular_venta;



-- =====================================================
-- 1. VISTAS
-- =====================================================

-- ---------- VENDEDOR ----------

-- Catalogo de motores con precio de venta y stock disponible.
-- No muestra costo ni proveedores.
CREATE VIEW vw_catalogo_vendedor AS
SELECT a.SKU,
       a.descripcion,
       a.precioVenta,
       IFNULL(SUM(s.cantidad), 0) AS stock_disponible
FROM Articulos a
LEFT JOIN Stock_Fisico s ON s.SKU = a.SKU AND s.id_estado = 1
WHERE a.id_tipo_articulo = 1
GROUP BY a.SKU, a.descripcion, a.precioVenta;


-- Clientes con su contacto, direccion principal y limite de credito.
CREATE VIEW vw_clientes_comercial AS
SELECT c.CUITCliente,
       c.RazonSocial,
       tc.tipo_cliente,
       c.Telefono,
       c.Email,
       d.localidad,
       d.provincia,
       c.LimiteCredito
FROM Clientes c
INNER JOIN Tipo_Cliente tc ON tc.id_tipo_cliente = c.id_tipo_cliente
LEFT JOIN Direccion_Cliente dc ON dc.CUITCliente = c.CUITCliente AND dc.es_principal = TRUE
LEFT JOIN Direccion d ON d.id_direccion = dc.id_direccion;


-- ---------- GESTOR DE STOCK ----------

-- Donde esta cada articulo, en que estado y cuanto hay.
-- Sin costos ni precios.
CREATE VIEW vw_stock_deposito AS
SELECT s.id_stock,
       a.SKU,
       a.descripcion,
       ta.tipo_articulo,
       u.sector,
       u.pasillo,
       u.estante,
       e.estado,
       s.cantidad,
       a.stockMinimo
FROM Stock_Fisico s
INNER JOIN Articulos a ON a.SKU = s.SKU
INNER JOIN Tipo_Articulo ta ON ta.id_tipo_articulo = a.id_tipo_articulo
INNER JOIN Ubicacion u ON u.id_ubicacion = s.id_ubicacion
INNER JOIN Estado_Stock e ON e.id_estado = s.id_estado;


-- ---------- SUPERVISOR DE PRODUCCION ----------

-- Que hay que fabricar y que componentes hacen falta.
-- Solo ordenes EN_PROCESO. Sin clientes ni costos.
CREATE VIEW vw_produccion_supervisor AS
SELECT op.idProduccion,
       op.nroOrden,
       op.fecha,
       op.SKU_Motor,
       op.cantidad AS motores_a_fabricar,
       d.SKU_Componente,
       a.descripcion AS componente,
       d.cantidad AS cantidad_por_motor,
       d.cantidad * op.cantidad AS cantidad_necesaria
FROM OrdenProduccion op
INNER JOIN Detalle_BOM d ON d.idProductoBOM = op.idProductoBOM
INNER JOIN Articulos a ON a.SKU = d.SKU_Componente
WHERE op.estado = 'EN_PROCESO';


-- Todas las ordenes con su control de calidad (si ya tiene).
CREATE VIEW vw_ordenes_produccion AS
SELECT op.idProduccion,
       op.nroOrden,
       op.fecha,
       op.estado,
       op.SKU_Motor,
       op.cantidad,
       e.apellido AS responsable,
       cp.fecha AS fecha_control,
       es.estado AS resultado_control,
       cp.detalle AS detalle_control
FROM OrdenProduccion op
INNER JOIN Empleado e ON e.Legajo = op.idEmpleado
LEFT JOIN Control_Produccion cp ON cp.idProduccion = op.idProduccion
LEFT JOIN Estado_Stock es ON es.id_estado = cp.id_estado;


-- ---------- GERENCIA ----------

-- Margen de cada articulo (precio - costo).
CREATE VIEW vw_rentabilidad_articulos AS
SELECT a.SKU,
       a.descripcion,
       ta.tipo_articulo,
       a.costoUnitario,
       a.precioVenta,
       a.precioVenta - a.costoUnitario AS margen,
       ROUND((a.precioVenta - a.costoUnitario) * 100 / a.precioVenta, 2) AS margen_pct
FROM Articulos a
INNER JOIN Tipo_Articulo ta ON ta.id_tipo_articulo = a.id_tipo_articulo;


-- Stock valorizado por grupo de articulos (Tipo_Articulo).
-- Valor = cantidad x costo unitario.
-- No cuenta lo que esta en Scrap (id_estado 4).
CREATE VIEW vw_stock_valorizado AS
SELECT ta.tipo_articulo AS grupo,
       COUNT(DISTINCT a.SKU) AS articulos,
       SUM(s.cantidad) AS unidades,
       SUM(s.cantidad * a.costoUnitario) AS valor_al_costo
FROM Stock_Fisico s
INNER JOIN Articulos a ON a.SKU = s.SKU
INNER JOIN Tipo_Articulo ta ON ta.id_tipo_articulo = a.id_tipo_articulo
WHERE s.id_estado <> 4
GROUP BY ta.tipo_articulo;


-- KPI 1: facturacion neta por mes y tipo de cliente.
-- Facturas y ND suman, NC restan (multiplicador 1 / -1).
-- Los remitos tienen multiplicador 0 y se excluyen.
CREATE VIEW vw_kpi_facturacion_mensual AS
SELECT YEAR(cv.fechaEmision) AS anio,
       MONTH(cv.fechaEmision) AS mes,
       tc.tipo_cliente,
       COUNT(*) AS comprobantes,
       SUM(cv.montoTotal * td.multiplicador) AS facturacion_neta
FROM Comprobante_Venta cv
INNER JOIN Tipo_Documento td ON td.id_tipo_documento = cv.id_tipo_documento
INNER JOIN Clientes c ON c.CUITCliente = cv.CUITCliente
INNER JOIN Tipo_Cliente tc ON tc.id_tipo_cliente = c.id_tipo_cliente
WHERE td.multiplicador <> 0
GROUP BY YEAR(cv.fechaEmision), MONTH(cv.fechaEmision), tc.tipo_cliente
ORDER BY anio, mes, tc.tipo_cliente;


-- KPI 1 (total): facturacion neta de todo el mes,
-- sin separar por tipo de cliente.
CREATE VIEW vw_kpi_facturacion_total_mensual AS
SELECT YEAR(cv.fechaEmision) AS anio,
       MONTH(cv.fechaEmision) AS mes,
       COUNT(*) AS comprobantes,
       SUM(cv.montoTotal * td.multiplicador) AS facturacion_neta
FROM Comprobante_Venta cv
INNER JOIN Tipo_Documento td ON td.id_tipo_documento = cv.id_tipo_documento
WHERE td.multiplicador <> 0
GROUP BY YEAR(cv.fechaEmision), MONTH(cv.fechaEmision)
ORDER BY anio, mes;


-- KPI 2: tasa de rechazo en calidad por modelo de motor.
-- En Control_Produccion el rechazo es id_estado = 4.
CREATE VIEW vw_kpi_tasa_rechazo AS
SELECT op.SKU_Motor,
       SUM(op.cantidad) AS motores_controlados,
       SUM(CASE WHEN cp.id_estado = 4 THEN op.cantidad ELSE 0 END) AS motores_rechazados,
       ROUND(SUM(CASE WHEN cp.id_estado = 4 THEN op.cantidad ELSE 0 END) * 100
             / SUM(op.cantidad), 2) AS porcentaje_rechazo
FROM Control_Produccion cp
INNER JOIN OrdenProduccion op ON op.idProduccion = cp.idProduccion
GROUP BY op.SKU_Motor;


-- KPI 3: alerta de quiebre de stock.
-- Articulos con stock disponible menor al minimo.
-- Tambien la usa el Gestor de Stock para reponer.
CREATE VIEW vw_kpi_quiebre_stock AS
SELECT a.SKU,
       a.descripcion,
       a.stockMinimo,
       IFNULL(SUM(s.cantidad), 0) AS stock_disponible,
       a.stockMinimo - IFNULL(SUM(s.cantidad), 0) AS faltante
FROM Articulos a
LEFT JOIN Stock_Fisico s ON s.SKU = a.SKU AND s.id_estado = 1
GROUP BY a.SKU, a.descripcion, a.stockMinimo
HAVING IFNULL(SUM(s.cantidad), 0) < a.stockMinimo;


-- =====================================================
-- 2. TABLA DE AUDITORIA
-- =====================================================
-- La tabla Auditoria del DDL no tiene la accion
-- (INSERT / UPDATE / DELETE), por eso se crea una nueva.
CREATE TABLE IF NOT EXISTS Log_Auditoria (
    id_log INT AUTO_INCREMENT PRIMARY KEY,
    tabla VARCHAR(50) NOT NULL,
    id_registro VARCHAR(100) NOT NULL,
    campo VARCHAR(50),
    accion VARCHAR(10) NOT NULL,     -- INSERT, UPDATE o DELETE
    valor_anterior VARCHAR(255),
    valor_nuevo VARCHAR(255),
    legajo INT,                      -- empleado (@legajo_actual)
    usuario_bd VARCHAR(100),         -- usuario de MySQL
    fecha DATETIME DEFAULT CURRENT_TIMESTAMP
);


-- =====================================================
-- 3. TRIGGERS
-- =====================================================
DELIMITER //

-- Articulos: cambio de precio de venta o costo
CREATE TRIGGER trg_articulos_cambio_precio
AFTER UPDATE ON Articulos
FOR EACH ROW
BEGIN
    IF OLD.precioVenta <> NEW.precioVenta THEN
        INSERT INTO Log_Auditoria (tabla, id_registro, campo, accion,
                                   valor_anterior, valor_nuevo, legajo, usuario_bd)
        VALUES ('Articulos', NEW.SKU, 'precioVenta', 'UPDATE',
                OLD.precioVenta, NEW.precioVenta, @legajo_actual, USER());
    END IF;

    IF OLD.costoUnitario <> NEW.costoUnitario THEN
        INSERT INTO Log_Auditoria (tabla, id_registro, campo, accion,
                                   valor_anterior, valor_nuevo, legajo, usuario_bd)
        VALUES ('Articulos', NEW.SKU, 'costoUnitario', 'UPDATE',
                OLD.costoUnitario, NEW.costoUnitario, @legajo_actual, USER());
    END IF;
END //


-- Articulos: borrado
CREATE TRIGGER trg_articulos_borrado
AFTER DELETE ON Articulos
FOR EACH ROW
BEGIN
    INSERT INTO Log_Auditoria (tabla, id_registro, campo, accion,
                               valor_anterior, valor_nuevo, legajo, usuario_bd)
    VALUES ('Articulos', OLD.SKU, NULL, 'DELETE',
            CONCAT(OLD.descripcion, ' / costo: ', OLD.costoUnitario,
                   ' / precio: ', OLD.precioVenta),
            NULL, @legajo_actual, USER());
END //


-- BOM: cambio en la cantidad de un componente
CREATE TRIGGER trg_bom_cambio_cantidad
AFTER UPDATE ON Detalle_BOM
FOR EACH ROW
BEGIN
    IF OLD.cantidad <> NEW.cantidad THEN
        INSERT INTO Log_Auditoria (tabla, id_registro, campo, accion,
                                   valor_anterior, valor_nuevo, legajo, usuario_bd)
        VALUES ('Detalle_BOM',
                CONCAT('BOM ', NEW.idProductoBOM, ' linea ', NEW.linea),
                'cantidad', 'UPDATE',
                OLD.cantidad, NEW.cantidad, @legajo_actual, USER());
    END IF;
END //


-- Bombas: el precio de venta no puede quedar
-- debajo del costo de su BOM (regla de margen).
-- Frena cualquier UPDATE, no solo el del SP.
-- Si la bomba tiene varias versiones de BOM
-- se toma la primera.
CREATE TRIGGER trg_articulos_precio_minimo
BEFORE UPDATE ON Articulos
FOR EACH ROW
BEGIN
    DECLARE v_costo_bom DECIMAL(12,2);

    IF NEW.id_tipo_articulo = 1 AND OLD.precioVenta <> NEW.precioVenta THEN
        SELECT SUM(d.cantidad * c.costoUnitario) INTO v_costo_bom
        FROM BOM b
        INNER JOIN Detalle_BOM d ON d.idProductoBOM = b.idProductoBOM
        INNER JOIN Articulos c ON c.SKU = d.SKU_Componente
        WHERE b.SKU_Principal = NEW.SKU
          AND b.idProductoBOM = (SELECT MIN(idProductoBOM) FROM BOM
                                 WHERE SKU_Principal = NEW.SKU);

        IF NEW.precioVenta < v_costo_bom THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El precio queda por debajo del costo de la BOM';
        END IF;
    END IF;
END //


-- Stock: no puede quedar negativo (alta)
CREATE TRIGGER trg_stock_no_negativo_insert
BEFORE INSERT ON Stock_Fisico
FOR EACH ROW
BEGIN
    IF NEW.cantidad < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El stock no puede ser negativo';
    END IF;
END //


-- Stock: no puede quedar negativo (modificacion)
CREATE TRIGGER trg_stock_no_negativo_update
BEFORE UPDATE ON Stock_Fisico
FOR EACH ROW
BEGIN
    IF NEW.cantidad < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El stock no puede ser negativo';
    END IF;
END //


-- Stock: alta de un registro nuevo
-- (ej. la primera vez que un articulo pasa a Scrap)
CREATE TRIGGER trg_stock_alta
AFTER INSERT ON Stock_Fisico
FOR EACH ROW
BEGIN
    INSERT INTO Log_Auditoria (tabla, id_registro, campo, accion,
                               valor_anterior, valor_nuevo, legajo, usuario_bd)
    VALUES ('Stock_Fisico', CONCAT(NEW.id_stock, ' - ', NEW.SKU), NULL, 'INSERT',
            NULL,
            CONCAT('cantidad: ', NEW.cantidad, ' / estado: ', NEW.id_estado,
                   ' / ubicacion: ', NEW.id_ubicacion),
            @legajo_actual, USER());
END //


-- Stock: cambio de cantidad, estado (ej. Scrap) o ubicacion
CREATE TRIGGER trg_stock_cambios
AFTER UPDATE ON Stock_Fisico
FOR EACH ROW
BEGIN
    IF OLD.cantidad <> NEW.cantidad THEN
        INSERT INTO Log_Auditoria (tabla, id_registro, campo, accion,
                                   valor_anterior, valor_nuevo, legajo, usuario_bd)
        VALUES ('Stock_Fisico', CONCAT(NEW.id_stock, ' - ', NEW.SKU), 'cantidad', 'UPDATE',
                OLD.cantidad, NEW.cantidad, @legajo_actual, USER());
    END IF;

    IF OLD.id_estado <> NEW.id_estado THEN
        INSERT INTO Log_Auditoria (tabla, id_registro, campo, accion,
                                   valor_anterior, valor_nuevo, legajo, usuario_bd)
        VALUES ('Stock_Fisico', CONCAT(NEW.id_stock, ' - ', NEW.SKU), 'id_estado', 'UPDATE',
                OLD.id_estado, NEW.id_estado, @legajo_actual, USER());
    END IF;

    IF OLD.id_ubicacion <> NEW.id_ubicacion THEN
        INSERT INTO Log_Auditoria (tabla, id_registro, campo, accion,
                                   valor_anterior, valor_nuevo, legajo, usuario_bd)
        VALUES ('Stock_Fisico', CONCAT(NEW.id_stock, ' - ', NEW.SKU), 'id_ubicacion', 'UPDATE',
                OLD.id_ubicacion, NEW.id_ubicacion, @legajo_actual, USER());
    END IF;
END //


-- Stock: borrado (guarda como estaba)
CREATE TRIGGER trg_stock_borrado
AFTER DELETE ON Stock_Fisico
FOR EACH ROW
BEGIN
    INSERT INTO Log_Auditoria (tabla, id_registro, campo, accion,
                               valor_anterior, valor_nuevo, legajo, usuario_bd)
    VALUES ('Stock_Fisico', CONCAT(OLD.id_stock, ' - ', OLD.SKU), NULL, 'DELETE',
            CONCAT('cantidad: ', OLD.cantidad, ' / estado: ', OLD.id_estado,
                   ' / ubicacion: ', OLD.id_ubicacion),
            NULL, @legajo_actual, USER());
END //


-- Ventas: cambio de estado
-- (PENDIENTE, PARCIAL, COMPLETADA o ANULADA)
CREATE TRIGGER trg_ventas_cambio_estado
AFTER UPDATE ON OrdenVenta
FOR EACH ROW
BEGIN
    IF OLD.estado <> NEW.estado THEN
        INSERT INTO Log_Auditoria (tabla, id_registro, campo, accion,
                                   valor_anterior, valor_nuevo, legajo, usuario_bd)
        VALUES ('OrdenVenta', NEW.idVenta, 'estado', 'UPDATE',
                OLD.estado, NEW.estado, @legajo_actual, USER());
    END IF;
END //


-- =====================================================
-- 4. STORED PROCEDURES
-- =====================================================

-- SP 1: registrar una venta (Vendedor)
-- Crea la venta con su primer producto.
-- El precio sale de Articulos, el vendedor no lo cambia.
-- El stock se descuenta recien al despachar.
CREATE PROCEDURE sp_registrar_venta(
    IN p_cuit VARCHAR(13),
    IN p_sku VARCHAR(50),
    IN p_cantidad INT,
    IN p_tiempo_entrega INT,
    IN p_legajo INT,
    OUT p_id_venta INT,
    OUT p_mensaje VARCHAR(255)
)
BEGIN
    DECLARE v_cliente INT;
    DECLARE v_articulo INT;
    DECLARE v_precio DECIMAL(12,2);
    DECLARE v_stock INT;
    DECLARE v_limite DECIMAL(12,2);
    DECLARE v_usado DECIMAL(12,2);
    DECLARE v_total DECIMAL(12,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_id_venta = NULL;
        SET p_mensaje = 'Error: no se pudo registrar la venta';
    END;

    SET @legajo_actual = p_legajo;
    SET p_id_venta = NULL;

    -- datos para validar
    SELECT COUNT(*) INTO v_cliente FROM Clientes WHERE CUITCliente = p_cuit;
    SELECT COUNT(*) INTO v_articulo FROM Articulos WHERE SKU = p_sku;
    SELECT precioVenta INTO v_precio FROM Articulos WHERE SKU = p_sku;

    SELECT IFNULL(SUM(cantidad), 0) INTO v_stock
    FROM Stock_Fisico
    WHERE SKU = p_sku AND id_estado = 1;

    -- credito: lo que ya debe + esta venta
    SELECT IFNULL(LimiteCredito, 0) INTO v_limite
    FROM Clientes WHERE CUITCliente = p_cuit;

    SELECT IFNULL(SUM(precioFinal), 0) INTO v_usado
    FROM OrdenVenta
    WHERE CUITCliente = p_cuit AND estado IN ('PENDIENTE', 'PARCIAL');

    SET v_total = v_precio * p_cantidad;

    -- validaciones
    IF p_cantidad <= 0 THEN
        SET p_mensaje = 'La cantidad tiene que ser mayor a 0';
    ELSEIF v_cliente = 0 THEN
        SET p_mensaje = 'El cliente no existe';
    ELSEIF v_articulo = 0 THEN
        SET p_mensaje = 'El articulo no existe';
    ELSEIF v_stock < p_cantidad THEN
        SET p_mensaje = 'No hay stock suficiente';
    ELSEIF v_usado + v_total > v_limite THEN
        SET p_mensaje = 'La venta supera el credito del cliente';
    ELSE
        START TRANSACTION;

        INSERT INTO OrdenVenta (CUITCliente, fechaVenta, estado, precioFinal, tiempoEntrega)
        VALUES (p_cuit, CURDATE(), 'PENDIENTE', v_total, p_tiempo_entrega);

        SET p_id_venta = LAST_INSERT_ID();

        INSERT INTO Detalle_OrdenVenta (idVenta, linea, SKU, cantidad, cantidad_pendiente, precio, subtotal)
        VALUES (p_id_venta, 1, p_sku, p_cantidad, p_cantidad, v_precio, v_total);

        COMMIT;
        SET p_mensaje = 'Venta registrada';
    END IF;
END //


-- SP 2: agregar un producto a una venta PENDIENTE (Vendedor)
-- Mismos controles que el SP 1 y actualiza el total.
CREATE PROCEDURE sp_agregar_linea_venta(
    IN p_id_venta INT,
    IN p_sku VARCHAR(50),
    IN p_cantidad INT,
    IN p_legajo INT,
    OUT p_mensaje VARCHAR(255)
)
BEGIN
    DECLARE v_estado VARCHAR(50);
    DECLARE v_cuit VARCHAR(15);
    DECLARE v_articulo INT;
    DECLARE v_precio DECIMAL(12,2);
    DECLARE v_stock INT;
    DECLARE v_limite DECIMAL(12,2);
    DECLARE v_usado DECIMAL(12,2);
    DECLARE v_subtotal DECIMAL(12,2);
    DECLARE v_linea INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_mensaje = 'Error: no se pudo agregar el producto';
    END;

    SET @legajo_actual = p_legajo;

    -- datos para validar
    SELECT estado, CUITCliente INTO v_estado, v_cuit
    FROM OrdenVenta WHERE idVenta = p_id_venta;

    SELECT COUNT(*) INTO v_articulo FROM Articulos WHERE SKU = p_sku;
    SELECT precioVenta INTO v_precio FROM Articulos WHERE SKU = p_sku;

    SELECT IFNULL(SUM(cantidad), 0) INTO v_stock
    FROM Stock_Fisico
    WHERE SKU = p_sku AND id_estado = 1;

    SELECT IFNULL(LimiteCredito, 0) INTO v_limite
    FROM Clientes WHERE CUITCliente = v_cuit;

    SELECT IFNULL(SUM(precioFinal), 0) INTO v_usado
    FROM OrdenVenta
    WHERE CUITCliente = v_cuit AND estado IN ('PENDIENTE', 'PARCIAL');

    SET v_subtotal = v_precio * p_cantidad;

    -- validaciones
    IF p_cantidad <= 0 THEN
        SET p_mensaje = 'La cantidad tiene que ser mayor a 0';
    ELSEIF v_estado IS NULL THEN
        SET p_mensaje = 'La venta no existe';
    ELSEIF v_estado <> 'PENDIENTE' THEN
        SET p_mensaje = 'Solo se puede agregar a ventas PENDIENTES';
    ELSEIF v_articulo = 0 THEN
        SET p_mensaje = 'El articulo no existe';
    ELSEIF v_stock < p_cantidad THEN
        SET p_mensaje = 'No hay stock suficiente';
    ELSEIF v_usado + v_subtotal > v_limite THEN
        SET p_mensaje = 'La venta supera el credito del cliente';
    ELSE
        START TRANSACTION;

        SELECT MAX(linea) + 1 INTO v_linea
        FROM Detalle_OrdenVenta WHERE idVenta = p_id_venta;

        INSERT INTO Detalle_OrdenVenta (idVenta, linea, SKU, cantidad, cantidad_pendiente, precio, subtotal)
        VALUES (p_id_venta, v_linea, p_sku, p_cantidad, p_cantidad, v_precio, v_subtotal);

        UPDATE OrdenVenta
        SET precioFinal = precioFinal + v_subtotal
        WHERE idVenta = p_id_venta;

        COMMIT;
        SET p_mensaje = 'Producto agregado';
    END IF;
END //


-- SP 3: despachar una linea de una venta (Gestor de Stock)
-- Hace el remito (cabecera + detalle), descuenta el stock
-- de la ubicacion, lo anota en AjusteStock y cambia el
-- estado de la venta a PARCIAL o COMPLETADA.
CREATE PROCEDURE sp_despachar_venta(
    IN p_id_venta INT,
    IN p_linea INT,
    IN p_cantidad INT,
    IN p_id_ubicacion INT,
    IN p_nro_remito VARCHAR(50),
    IN p_legajo INT,
    OUT p_mensaje VARCHAR(255)
)
BEGIN
    DECLARE v_estado VARCHAR(50);
    DECLARE v_cuit VARCHAR(15);
    DECLARE v_sku VARCHAR(50);
    DECLARE v_pendiente INT;
    DECLARE v_id_stock INT;
    DECLARE v_stock INT;
    DECLARE v_id_remito INT;
    DECLARE v_total_pendiente INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_mensaje = 'Error: no se pudo despachar';
    END;

    SET @legajo_actual = p_legajo;

    -- datos para validar
    SELECT estado, CUITCliente INTO v_estado, v_cuit
    FROM OrdenVenta WHERE idVenta = p_id_venta;

    SELECT SKU, cantidad_pendiente INTO v_sku, v_pendiente
    FROM Detalle_OrdenVenta
    WHERE idVenta = p_id_venta AND linea = p_linea;

    SELECT id_stock, cantidad INTO v_id_stock, v_stock
    FROM Stock_Fisico
    WHERE SKU = v_sku AND id_ubicacion = p_id_ubicacion AND id_estado = 1
    LIMIT 1;

    -- validaciones
    IF p_cantidad <= 0 THEN
        SET p_mensaje = 'La cantidad tiene que ser mayor a 0';
    ELSEIF v_estado IS NULL THEN
        SET p_mensaje = 'La venta no existe';
    ELSEIF v_estado NOT IN ('PENDIENTE', 'PARCIAL') THEN
        SET p_mensaje = 'La venta no esta pendiente de despacho';
    ELSEIF v_sku IS NULL THEN
        SET p_mensaje = 'La linea de la venta no existe';
    ELSEIF p_cantidad > v_pendiente THEN
        SET p_mensaje = 'Se quiere despachar mas de lo pendiente';
    ELSEIF v_id_stock IS NULL OR v_stock < p_cantidad THEN
        SET p_mensaje = 'No hay stock suficiente en esa ubicacion';
    ELSE
        START TRANSACTION;

        -- remito
        INSERT INTO Remito_Egreso (CUITCliente, nroRemito, fechaDespacho)
        VALUES (v_cuit, p_nro_remito, CURDATE());

        SET v_id_remito = LAST_INSERT_ID();

        INSERT INTO Detalle_Remito_Egreso (idRemitoEgreso, linea, idVenta, SKU, cantidadDespachada)
        VALUES (v_id_remito, 1, p_id_venta, v_sku, p_cantidad);

        -- stock
        UPDATE Stock_Fisico
        SET cantidad = cantidad - p_cantidad
        WHERE id_stock = v_id_stock;

        INSERT INTO AjusteStock (idEmpleado, SKU, id_ubicacion, id_documento_origen, tabla_origen,
                                 fecha, tipoMovimiento, motivo, cantidad)
        VALUES (p_legajo, v_sku, p_id_ubicacion, p_id_venta, 'Orden_Venta',
                CURDATE(), 'EGRESO', CONCAT('Despacho remito ', p_nro_remito), p_cantidad);

        -- pendiente y estado de la venta
        UPDATE Detalle_OrdenVenta
        SET cantidad_pendiente = cantidad_pendiente - p_cantidad
        WHERE idVenta = p_id_venta AND linea = p_linea;

        SELECT SUM(cantidad_pendiente) INTO v_total_pendiente
        FROM Detalle_OrdenVenta WHERE idVenta = p_id_venta;

        IF v_total_pendiente = 0 THEN
            UPDATE OrdenVenta SET estado = 'COMPLETADA' WHERE idVenta = p_id_venta;
        ELSE
            UPDATE OrdenVenta SET estado = 'PARCIAL' WHERE idVenta = p_id_venta;
        END IF;

        COMMIT;
        SET p_mensaje = 'Despacho registrado';
    END IF;
END //


-- SP 4: actualizar el precio de una bomba (Gerencia)
-- Valida que sea una bomba y que el precio sea mayor a 0.
-- Si el precio queda debajo del costo de la BOM, lo frena
-- el trigger trg_articulos_precio_minimo y entra el HANDLER.
CREATE PROCEDURE sp_actualizar_precio_bomba(
    IN p_sku VARCHAR(50),
    IN p_precio_nuevo DECIMAL(12,2),
    IN p_legajo INT,
    OUT p_mensaje VARCHAR(255)
)
BEGIN
    DECLARE v_tipo INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_mensaje = 'Error: el precio no puede quedar debajo del costo de la BOM';
    END;

    SET @legajo_actual = p_legajo;

    SELECT id_tipo_articulo INTO v_tipo
    FROM Articulos WHERE SKU = p_sku;

    IF p_precio_nuevo <= 0 THEN
        SET p_mensaje = 'El precio tiene que ser mayor a 0';
    ELSEIF v_tipo IS NULL THEN
        SET p_mensaje = 'El articulo no existe';
    ELSEIF v_tipo <> 1 THEN
        SET p_mensaje = 'El articulo no es una bomba';
    ELSE
        START TRANSACTION;

        UPDATE Articulos
        SET precioVenta = p_precio_nuevo
        WHERE SKU = p_sku;

        COMMIT;
        SET p_mensaje = 'Precio actualizado';
    END IF;
END //


-- SP 5: cerrar una orden de produccion (Supervisor)
-- Es la operacion mas critica segun el relevamiento:
--   1. La orden tiene que estar EN_PROCESO.
--   2. Tiene que haber stock de todos los componentes.
--   3. Recorre la BOM con un WHILE y descuenta cada componente.
--   4. Registra el control de calidad:
--      APROBADO: los motores entran al stock Disponible.
--      RECHAZADO: no entran, queda la causa.
--   5. Deja la orden COMPLETADA.
CREATE PROCEDURE sp_cerrar_orden_produccion(
    IN p_id_produccion INT,
    IN p_estado_revision VARCHAR(20),  -- 'APROBADO' o 'RECHAZADO'
    IN p_detalle VARCHAR(255),         -- resultado o causa del rechazo
    IN p_legajo INT,                   -- empleado que hizo el control
    OUT p_mensaje VARCHAR(255)
)
BEGIN
    DECLARE v_estado VARCHAR(50);
    DECLARE v_nro VARCHAR(50);
    DECLARE v_motor VARCHAR(50);
    DECLARE v_cantidad INT;
    DECLARE v_bom INT;
    DECLARE v_faltantes INT;
    DECLARE v_lineas INT;
    DECLARE v_i INT DEFAULT 1;
    DECLARE v_componente VARCHAR(50);
    DECLARE v_necesario INT;
    DECLARE v_id_stock INT;
    DECLARE v_ubicacion INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_mensaje = 'Error: no se pudo cerrar la orden';
    END;

    SET @legajo_actual = p_legajo;

    -- datos de la orden
    SELECT estado, nroOrden, SKU_Motor, cantidad, idProductoBOM
    INTO v_estado, v_nro, v_motor, v_cantidad, v_bom
    FROM OrdenProduccion
    WHERE idProduccion = p_id_produccion;

    -- componentes que no alcanzan (se toma la ubicacion con mas stock)
    SELECT COUNT(*) INTO v_faltantes
    FROM Detalle_BOM d
    WHERE d.idProductoBOM = v_bom
      AND d.cantidad * v_cantidad > (SELECT IFNULL(MAX(s.cantidad), 0)
                                     FROM Stock_Fisico s
                                     WHERE s.SKU = d.SKU_Componente AND s.id_estado = 1);

    SELECT COUNT(*) INTO v_lineas FROM Detalle_BOM WHERE idProductoBOM = v_bom;

    -- validaciones
    IF v_estado IS NULL THEN
        SET p_mensaje = 'La orden de produccion no existe';
    ELSEIF v_estado <> 'EN_PROCESO' THEN
        SET p_mensaje = 'La orden no esta EN_PROCESO';
    ELSEIF p_estado_revision NOT IN ('APROBADO', 'RECHAZADO') THEN
        SET p_mensaje = 'El estado de revision tiene que ser APROBADO o RECHAZADO';
    ELSEIF v_faltantes > 0 THEN
        SET p_mensaje = 'Falta stock de componentes para cerrar la orden';
    ELSE
        START TRANSACTION;

        -- descuento los componentes, linea por linea de la BOM
        WHILE v_i <= v_lineas DO
            SELECT SKU_Componente, cantidad * v_cantidad
            INTO v_componente, v_necesario
            FROM Detalle_BOM
            WHERE idProductoBOM = v_bom AND linea = v_i;

            SELECT id_stock, id_ubicacion INTO v_id_stock, v_ubicacion
            FROM Stock_Fisico
            WHERE SKU = v_componente AND id_estado = 1
            ORDER BY cantidad DESC
            LIMIT 1;

            UPDATE Stock_Fisico
            SET cantidad = cantidad - v_necesario
            WHERE id_stock = v_id_stock;

            INSERT INTO AjusteStock (idEmpleado, SKU, id_ubicacion, id_documento_origen, tabla_origen,
                                     fecha, tipoMovimiento, motivo, cantidad)
            VALUES (p_legajo, v_componente, v_ubicacion, p_id_produccion, 'Orden_Produccion',
                    CURDATE(), 'EGRESO', CONCAT('Consumo ', v_nro), v_necesario);

            SET v_i = v_i + 1;
        END WHILE;

        -- control de calidad
        CASE p_estado_revision
            WHEN 'APROBADO' THEN
                INSERT INTO Control_Produccion (idProduccion, idEmpleado, detalle, id_estado, fecha)
                VALUES (p_id_produccion, p_legajo, p_detalle, 1, CURDATE());

                -- los motores entran a Producto Terminado (ubicacion 5)
                SET v_id_stock = NULL;
                SELECT id_stock INTO v_id_stock
                FROM Stock_Fisico
                WHERE SKU = v_motor AND id_estado = 1 AND id_ubicacion = 5
                LIMIT 1;

                IF v_id_stock IS NULL THEN
                    INSERT INTO Stock_Fisico (SKU, id_estado, id_ubicacion, cantidad)
                    VALUES (v_motor, 1, 5, v_cantidad);
                ELSE
                    UPDATE Stock_Fisico
                    SET cantidad = cantidad + v_cantidad
                    WHERE id_stock = v_id_stock;
                END IF;

                INSERT INTO AjusteStock (idEmpleado, SKU, id_ubicacion, id_documento_origen, tabla_origen,
                                         fecha, tipoMovimiento, motivo, cantidad)
                VALUES (p_legajo, v_motor, 5, p_id_produccion, 'Orden_Produccion',
                        CURDATE(), 'INGRESO', CONCAT('Alta de ', v_nro), v_cantidad);

            WHEN 'RECHAZADO' THEN
                -- queda la causa y los motores no entran al stock
                INSERT INTO Control_Produccion (idProduccion, idEmpleado, detalle, id_estado, fecha)
                VALUES (p_id_produccion, p_legajo, p_detalle, 4, CURDATE());
        END CASE;

        UPDATE OrdenProduccion
        SET estado = 'COMPLETADA'
        WHERE idProduccion = p_id_produccion;

        COMMIT;
        SET p_mensaje = 'Orden de produccion cerrada';
    END IF;
END //


-- SP 6: consultar el stock de un articulo (Gestor de Stock)
-- Devuelve el stock disponible y si hay que reponer
-- (si esta por debajo del stock minimo).
-- Es solo una consulta, no cambia datos.
CREATE PROCEDURE sp_consultar_stock_articulo(
    IN p_sku VARCHAR(50),
    OUT p_stock INT,
    OUT p_mensaje VARCHAR(255)
)
BEGIN
    DECLARE v_existe INT;
    DECLARE v_minimo INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET p_stock = NULL;
        SET p_mensaje = 'Error: no se pudo consultar el stock';
    END;

    SELECT COUNT(*) INTO v_existe FROM Articulos WHERE SKU = p_sku;
    SELECT stockMinimo INTO v_minimo FROM Articulos WHERE SKU = p_sku;

    SELECT IFNULL(SUM(cantidad), 0) INTO p_stock
    FROM Stock_Fisico
    WHERE SKU = p_sku AND id_estado = 1;

    IF v_existe = 0 THEN
        SET p_stock = NULL;
        SET p_mensaje = 'El articulo no existe';
    ELSEIF p_stock < v_minimo THEN
        SET p_mensaje = 'REPONER';
    ELSE
        SET p_mensaje = 'OK';
    END IF;
END //


-- SP 7: marcar mercaderia rota como Scrap (Gestor de Stock)
-- Saca unidades del stock Disponible de una ubicacion
-- y las pasa al sector Scrap (ubicacion 8, estado 4).
-- Queda anotado en AjusteStock y en Log_Auditoria (triggers).
CREATE PROCEDURE sp_marcar_scrap(
    IN p_sku VARCHAR(50),
    IN p_id_ubicacion INT,
    IN p_cantidad INT,
    IN p_motivo VARCHAR(255),
    IN p_legajo INT,
    OUT p_mensaje VARCHAR(255)
)
BEGIN
    DECLARE v_id_stock INT;
    DECLARE v_stock INT;
    DECLARE v_id_scrap INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_mensaje = 'Error: no se pudo pasar a Scrap';
    END;

    SET @legajo_actual = p_legajo;

    -- stock disponible en esa ubicacion
    SELECT id_stock, cantidad INTO v_id_stock, v_stock
    FROM Stock_Fisico
    WHERE SKU = p_sku AND id_ubicacion = p_id_ubicacion AND id_estado = 1
    LIMIT 1;

    -- registro de Scrap de ese articulo (si ya existe)
    SELECT id_stock INTO v_id_scrap
    FROM Stock_Fisico
    WHERE SKU = p_sku AND id_ubicacion = 8 AND id_estado = 4
    LIMIT 1;

    IF p_cantidad <= 0 THEN
        SET p_mensaje = 'La cantidad tiene que ser mayor a 0';
    ELSEIF v_id_stock IS NULL THEN
        SET p_mensaje = 'No hay stock disponible de ese articulo en esa ubicacion';
    ELSEIF v_stock < p_cantidad THEN
        SET p_mensaje = 'No hay tantas unidades para pasar a Scrap';
    ELSE
        START TRANSACTION;

        -- resto del disponible
        UPDATE Stock_Fisico
        SET cantidad = cantidad - p_cantidad
        WHERE id_stock = v_id_stock;

        -- sumo en Scrap
        IF v_id_scrap IS NULL THEN
            INSERT INTO Stock_Fisico (SKU, id_estado, id_ubicacion, cantidad)
            VALUES (p_sku, 4, 8, p_cantidad);
        ELSE
            UPDATE Stock_Fisico
            SET cantidad = cantidad + p_cantidad
            WHERE id_stock = v_id_scrap;
        END IF;

        INSERT INTO AjusteStock (idEmpleado, SKU, id_ubicacion, id_documento_origen, tabla_origen,
                                 fecha, tipoMovimiento, motivo, cantidad)
        VALUES (p_legajo, p_sku, p_id_ubicacion, NULL, 'Scrap',
                CURDATE(), 'EGRESO', p_motivo, p_cantidad);

        COMMIT;
        SET p_mensaje = 'Mercaderia pasada a Scrap';
    END IF;
END //


-- SP 8: anular una venta (Vendedor)
-- Es la baja de una venta. No se borra, queda con
-- estado ANULADA para no perder el registro.
-- Solo se anulan ventas PENDIENTES que todavia no
-- tengan nada despachado. Al quedar ANULADA deja
-- de contar para el credito del cliente.
CREATE PROCEDURE sp_anular_venta(
    IN p_id_venta INT,
    IN p_legajo INT,
    OUT p_mensaje VARCHAR(255)
)
BEGIN
    DECLARE v_estado VARCHAR(50);
    DECLARE v_despachado INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_mensaje = 'Error: no se pudo anular la venta';
    END;

    SET @legajo_actual = p_legajo;

    SELECT estado INTO v_estado
    FROM OrdenVenta WHERE idVenta = p_id_venta;

    -- unidades que ya salieron (cantidad - pendiente)
    SELECT IFNULL(SUM(cantidad - cantidad_pendiente), 0) INTO v_despachado
    FROM Detalle_OrdenVenta WHERE idVenta = p_id_venta;

    IF v_estado IS NULL THEN
        SET p_mensaje = 'La venta no existe';
    ELSEIF v_estado <> 'PENDIENTE' THEN
        SET p_mensaje = 'Solo se pueden anular ventas PENDIENTES';
    ELSEIF v_despachado > 0 THEN
        SET p_mensaje = 'La venta ya tiene unidades despachadas';
    ELSE
        START TRANSACTION;

        UPDATE OrdenVenta
        SET estado = 'ANULADA'
        WHERE idVenta = p_id_venta;

        COMMIT;
        SET p_mensaje = 'Venta anulada';
    END IF;
END //

DELIMITER ;


-- =====================================================
-- 5. SEGURIDAD (roles por perfil)
-- =====================================================
-- Un rol por cada perfil del relevamiento. Cada uno
-- ve solo sus vistas y ejecuta solo sus SP, sin
-- acceso directo a las tablas.

CREATE ROLE IF NOT EXISTS 'rol_vendedor';
CREATE ROLE IF NOT EXISTS 'rol_gestor_stock';
CREATE ROLE IF NOT EXISTS 'rol_supervisor';
CREATE ROLE IF NOT EXISTS 'rol_gerencia';

-- ---------- VENDEDOR ----------
GRANT SELECT ON MotorsPasz.vw_catalogo_vendedor TO 'rol_vendedor';
GRANT SELECT ON MotorsPasz.vw_clientes_comercial TO 'rol_vendedor';
GRANT EXECUTE ON PROCEDURE MotorsPasz.sp_registrar_venta TO 'rol_vendedor';
GRANT EXECUTE ON PROCEDURE MotorsPasz.sp_agregar_linea_venta TO 'rol_vendedor';
GRANT EXECUTE ON PROCEDURE MotorsPasz.sp_anular_venta TO 'rol_vendedor';

-- ---------- GESTOR DE STOCK ----------
GRANT SELECT ON MotorsPasz.vw_stock_deposito TO 'rol_gestor_stock';
GRANT SELECT ON MotorsPasz.vw_kpi_quiebre_stock TO 'rol_gestor_stock';
GRANT EXECUTE ON PROCEDURE MotorsPasz.sp_despachar_venta TO 'rol_gestor_stock';
GRANT EXECUTE ON PROCEDURE MotorsPasz.sp_consultar_stock_articulo TO 'rol_gestor_stock';
GRANT EXECUTE ON PROCEDURE MotorsPasz.sp_marcar_scrap TO 'rol_gestor_stock';

-- ---------- SUPERVISOR DE PRODUCCION ----------
GRANT SELECT ON MotorsPasz.vw_produccion_supervisor TO 'rol_supervisor';
GRANT SELECT ON MotorsPasz.vw_ordenes_produccion TO 'rol_supervisor';
GRANT EXECUTE ON PROCEDURE MotorsPasz.sp_cerrar_orden_produccion TO 'rol_supervisor';

-- ---------- GERENCIA ----------
-- Lectura de toda la base (rentabilidad, KPIs, auditoria)
-- y el cambio de precios.
GRANT SELECT ON MotorsPasz.* TO 'rol_gerencia';
GRANT EXECUTE ON PROCEDURE MotorsPasz.sp_actualizar_precio_bomba TO 'rol_gerencia';



-- ---------- USUARIOS ----------
-- Un usuario por rol (contraseña 1234).
-- SET DEFAULT ROLE hace que el rol quede activo
-- apenas el usuario se conecta.
CREATE USER IF NOT EXISTS 'vendedor1'@'%' IDENTIFIED BY '1234';
CREATE USER IF NOT EXISTS 'gestor_stock1'@'%' IDENTIFIED BY '1234';
CREATE USER IF NOT EXISTS 'supervisor1'@'%' IDENTIFIED BY '1234';
CREATE USER IF NOT EXISTS 'gerente1'@'%' IDENTIFIED BY '1234';

GRANT 'rol_vendedor' TO 'vendedor1'@'%';
GRANT 'rol_gestor_stock' TO 'gestor_stock1'@'%';
GRANT 'rol_supervisor' TO 'supervisor1'@'%';
GRANT 'rol_gerencia' TO 'gerente1'@'%';

SET DEFAULT ROLE 'rol_vendedor' TO 'vendedor1'@'%';
SET DEFAULT ROLE 'rol_gestor_stock' TO 'gestor_stock1'@'%';
SET DEFAULT ROLE 'rol_supervisor' TO 'supervisor1'@'%';
SET DEFAULT ROLE 'rol_gerencia' TO 'gerente1'@'%';
