-- =====================================================
-- MOTORS PASZ S.A. - ENTREGA 4: PROCESAMIENTO DE DATOS
-- Hecho por: Jorge Pazos
-- =====================================================
-- Este script se corre DESPUES del DDL y del DML.
-- Tiene:
--   1. Vistas (una por cada rol del relevamiento + los 3 indicadores del gerente)
--   2. Tabla de auditoria
--   3. Triggers
--   4. Stored procedures (registrar venta y cerrar orden de produccion)
--   5. Pruebas (estan comentadas al final)
--
-- Los roles salen del relevamiento: Vendedor, Gestor de Stock,
-- Supervisor de Produccion y Gerencia.
--
-- Ids que uso de las tablas parametricas (los cargamos en el DML):
--   Estado_Stock:  1 = Disponible, 4 = Dañado / Scrap
--   Tipo_Articulo: 1 = Bomba Terminada (los motores)
--   Ubicacion:     5 = Producto Terminado
-- =====================================================

USE MotorsPasz;


-- =====================================================
-- 1. VISTAS
-- =====================================================

-- Vista para el VENDEDOR
-- Ve el catalogo de motores con el precio de venta y el stock disponible.
-- NO ve el costo ni los proveedores (lo pidio la gerencia en el relevamiento).
CREATE OR REPLACE VIEW vw_catalogo_vendedor AS
SELECT a.SKU,
       a.descripcion,
       a.precioVenta,
       IFNULL(SUM(s.cantidad), 0) AS stock_disponible
FROM Articulos a
LEFT JOIN Stock_Fisico s ON s.SKU = a.SKU AND s.id_estado = 1
WHERE a.id_tipo_articulo = 1
GROUP BY a.SKU, a.descripcion, a.precioVenta;


-- Vista para el SUPERVISOR DE PRODUCCION
-- Muestra que hay que fabricar: la orden, el motor, cuantos, la fecha
-- y los componentes de la BOM que se necesitan.
-- No muestra clientes ni costos ni ganancias.
CREATE OR REPLACE VIEW vw_produccion_supervisor AS
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
JOIN Detalle_BOM d ON d.idProductoBOM = op.idProductoBOM
JOIN Articulos a ON a.SKU = d.SKU_Componente
WHERE op.estado = 'EN_PROCESO';


-- Vista para el GESTOR DE STOCK
-- Muestra donde esta cada articulo, en que estado y cuanto hay.
-- No muestra costos ni precios.
CREATE OR REPLACE VIEW vw_stock_deposito AS
SELECT s.id_stock,
       a.SKU,
       a.descripcion,
       u.sector,
       u.pasillo,
       u.estante,
       e.estado,
       s.cantidad
FROM Stock_Fisico s
JOIN Articulos a ON a.SKU = s.SKU
JOIN Ubicacion u ON u.id_ubicacion = s.id_ubicacion
JOIN Estado_Stock e ON e.id_estado = s.id_estado;


-- Vistas para la GERENCIA: los 3 indicadores que pidio el dueño

-- Indicador 1: Facturacion neta por mes y por tipo de cliente
-- Las facturas y notas de debito suman y las notas de credito restan.
-- Para eso usamos el multiplicador de Tipo_Documento (1 o -1).
-- Los remitos tienen multiplicador 0 asi que no suman nada.
CREATE OR REPLACE VIEW vw_kpi_facturacion_mensual AS
SELECT YEAR(cv.fechaEmision) AS anio,
       MONTH(cv.fechaEmision) AS mes,
       tc.tipo_cliente,
       SUM(cv.montoTotal * td.multiplicador) AS facturacion_neta
FROM Comprobante_Venta cv
JOIN Tipo_Documento td ON td.id_tipo_documento = cv.id_tipo_documento
JOIN Clientes c ON c.CUITCliente = cv.CUITCliente
JOIN Tipo_Cliente tc ON tc.id_tipo_cliente = c.id_tipo_cliente
GROUP BY YEAR(cv.fechaEmision), MONTH(cv.fechaEmision), tc.tipo_cliente;


-- Indicador 2: Tasa de rechazo en calidad por modelo de motor
-- Cuenta cuantos motores se controlaron y cuantos se rechazaron
-- (en Control_Produccion el rechazo se guarda con id_estado = 4).
CREATE OR REPLACE VIEW vw_kpi_tasa_rechazo AS
SELECT op.SKU_Motor,
       SUM(op.cantidad) AS motores_controlados,
       SUM(CASE WHEN cp.id_estado = 4 THEN op.cantidad ELSE 0 END) AS motores_rechazados,
       ROUND(SUM(CASE WHEN cp.id_estado = 4 THEN op.cantidad ELSE 0 END) * 100 / SUM(op.cantidad), 2) AS porcentaje_rechazo
FROM Control_Produccion cp
JOIN OrdenProduccion op ON op.idProduccion = cp.idProduccion
GROUP BY op.SKU_Motor;


-- Indicador 3: Alerta de quiebre de stock
-- Articulos que tienen menos stock disponible que el stock minimo.
-- Tambien le sirve al Gestor de Stock para saber que hay que reponer.
CREATE OR REPLACE VIEW vw_kpi_quiebre_stock AS
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
-- En el DDL ya estaba la tabla "Auditoria" pero no tiene donde guardar
-- la accion (INSERT / UPDATE / DELETE) que pide la consigna,
-- por eso hice una tabla nueva.
CREATE TABLE IF NOT EXISTS Log_Cambios (
    id_log INT AUTO_INCREMENT PRIMARY KEY,
    tabla VARCHAR(50) NOT NULL,
    accion VARCHAR(10) NOT NULL,          -- INSERT, UPDATE o DELETE
    id_registro VARCHAR(50),              -- clave del registro que cambio
    campo VARCHAR(50),                    -- columna que cambio
    valor_anterior VARCHAR(255),
    valor_nuevo VARCHAR(255),
    usuario VARCHAR(100),                 -- usuario de MySQL que hizo el cambio
    fecha DATETIME DEFAULT CURRENT_TIMESTAMP
);


-- =====================================================
-- 3. TRIGGERS
-- =====================================================
-- Segun el relevamiento lo que hay que auditar es:
--   - cambios en el precio de venta y en el costo
--   - cambios en las cantidades de la BOM
--   - ajustes de inventario (cambios de cantidad, marcar mercaderia rota, borrados)
-- Ademas agregue un trigger para que el stock nunca quede negativo.

DELIMITER //

-- Trigger 1: cambios de precio de venta y de costo
DROP TRIGGER IF EXISTS trg_articulos_precios //
CREATE TRIGGER trg_articulos_precios
AFTER UPDATE ON Articulos
FOR EACH ROW
BEGIN
    IF OLD.precioVenta <> NEW.precioVenta THEN
        INSERT INTO Log_Cambios (tabla, accion, id_registro, campo, valor_anterior, valor_nuevo, usuario)
        VALUES ('Articulos', 'UPDATE', NEW.SKU, 'precioVenta', OLD.precioVenta, NEW.precioVenta, USER());
    END IF;

    IF OLD.costoUnitario <> NEW.costoUnitario THEN
        INSERT INTO Log_Cambios (tabla, accion, id_registro, campo, valor_anterior, valor_nuevo, usuario)
        VALUES ('Articulos', 'UPDATE', NEW.SKU, 'costoUnitario', OLD.costoUnitario, NEW.costoUnitario, USER());
    END IF;
END //


-- Trigger 2: cambios en las cantidades de la BOM
-- (si alguien cambia por error cuantos componentes lleva un motor)
DROP TRIGGER IF EXISTS trg_bom_cantidad //
CREATE TRIGGER trg_bom_cantidad
AFTER UPDATE ON Detalle_BOM
FOR EACH ROW
BEGIN
    IF OLD.cantidad <> NEW.cantidad THEN
        INSERT INTO Log_Cambios (tabla, accion, id_registro, campo, valor_anterior, valor_nuevo, usuario)
        VALUES ('Detalle_BOM', 'UPDATE', CONCAT('BOM ', NEW.idProductoBOM, ' linea ', NEW.linea),
                'cantidad', OLD.cantidad, NEW.cantidad, USER());
    END IF;
END //


-- Trigger 3: cambios de stock (cantidad o estado)
-- El cambio de estado es por ejemplo cuando se marca mercaderia como rota (Scrap)
DROP TRIGGER IF EXISTS trg_stock_cambios //
CREATE TRIGGER trg_stock_cambios
AFTER UPDATE ON Stock_Fisico
FOR EACH ROW
BEGIN
    IF OLD.cantidad <> NEW.cantidad THEN
        INSERT INTO Log_Cambios (tabla, accion, id_registro, campo, valor_anterior, valor_nuevo, usuario)
        VALUES ('Stock_Fisico', 'UPDATE', CONCAT(NEW.id_stock, ' - ', NEW.SKU), 'cantidad',
                OLD.cantidad, NEW.cantidad, USER());
    END IF;

    IF OLD.id_estado <> NEW.id_estado THEN
        INSERT INTO Log_Cambios (tabla, accion, id_registro, campo, valor_anterior, valor_nuevo, usuario)
        VALUES ('Stock_Fisico', 'UPDATE', CONCAT(NEW.id_stock, ' - ', NEW.SKU), 'id_estado',
                OLD.id_estado, NEW.id_estado, USER());
    END IF;
END //


-- Trigger 4: borrado de registros de stock
-- Guarda como estaba el registro antes de borrarlo
DROP TRIGGER IF EXISTS trg_stock_borrado //
CREATE TRIGGER trg_stock_borrado
AFTER DELETE ON Stock_Fisico
FOR EACH ROW
BEGIN
    INSERT INTO Log_Cambios (tabla, accion, id_registro, campo, valor_anterior, valor_nuevo, usuario)
    VALUES ('Stock_Fisico', 'DELETE', CONCAT(OLD.id_stock, ' - ', OLD.SKU), NULL,
            CONCAT('cantidad: ', OLD.cantidad, ' / estado: ', OLD.id_estado, ' / ubicacion: ', OLD.id_ubicacion),
            NULL, USER());
END //


-- Trigger 5 y 6: el stock nunca puede ser negativo (regla del relevamiento)
-- Si alguien intenta dejarlo en negativo se cancela la operacion.
DROP TRIGGER IF EXISTS trg_stock_no_negativo_insert //
CREATE TRIGGER trg_stock_no_negativo_insert
BEFORE INSERT ON Stock_Fisico
FOR EACH ROW
BEGIN
    IF NEW.cantidad < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El stock no puede ser negativo';
    END IF;
END //

DROP TRIGGER IF EXISTS trg_stock_no_negativo_update //
CREATE TRIGGER trg_stock_no_negativo_update
BEFORE UPDATE ON Stock_Fisico
FOR EACH ROW
BEGIN
    IF NEW.cantidad < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El stock no puede ser negativo';
    END IF;
END //


-- =====================================================
-- 4. STORED PROCEDURES
-- =====================================================
-- Los dos usan START TRANSACTION / COMMIT y un HANDLER:
-- si pasa cualquier error se hace ROLLBACK (no queda nada a medias)
-- y con RESIGNAL se muestra el error para saber que paso.


-- SP 1: Registrar una venta (lo usa el Vendedor)
-- Crea la orden de venta con un producto.
-- Antes de guardar controla:
--   - que la cantidad sea mayor a 0
--   - que el cliente y el articulo existan
--   - que haya stock disponible suficiente
--   - que el total no supere el limite de credito del cliente
-- El precio sale de la tabla Articulos (el vendedor no lo puede cambiar).
-- El stock NO se descuenta aca, se descuenta cuando se despacha con el remito.
DROP PROCEDURE IF EXISTS sp_registrar_venta //
CREATE PROCEDURE sp_registrar_venta(
    IN p_cuit VARCHAR(13),
    IN p_sku VARCHAR(50),
    IN p_cantidad INT,
    IN p_tiempo_entrega INT
)
BEGIN
    DECLARE v_existe INT;
    DECLARE v_stock INT;
    DECLARE v_precio DECIMAL(12,2);
    DECLARE v_total DECIMAL(12,2);
    DECLARE v_limite DECIMAL(12,2);
    DECLARE v_id_venta INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    IF p_cantidad <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad tiene que ser mayor a 0';
    END IF;

    -- el cliente existe?
    SELECT COUNT(*) INTO v_existe FROM Clientes WHERE CUITCliente = p_cuit;
    IF v_existe = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El cliente no existe';
    END IF;

    -- el articulo existe?
    SELECT COUNT(*) INTO v_existe FROM Articulos WHERE SKU = p_sku;
    IF v_existe = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El articulo no existe';
    END IF;

    -- hay stock disponible?
    SELECT IFNULL(SUM(cantidad), 0) INTO v_stock
    FROM Stock_Fisico
    WHERE SKU = p_sku AND id_estado = 1;

    IF v_stock < p_cantidad THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No hay stock suficiente para esa venta';
    END IF;

    -- calculo el total con el precio de venta del articulo
    SELECT precioVenta INTO v_precio FROM Articulos WHERE SKU = p_sku;
    SET v_total = v_precio * p_cantidad;

    -- el total no puede pasar el limite de credito del cliente
    SELECT IFNULL(LimiteCredito, 0) INTO v_limite FROM Clientes WHERE CUITCliente = p_cuit;
    IF v_total > v_limite THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta supera el limite de credito del cliente';
    END IF;

    -- si paso todos los controles guardo la cabecera y el detalle
    INSERT INTO OrdenVenta (CUITCliente, fechaVenta, estado, precioFinal, tiempoEntrega)
    VALUES (p_cuit, CURDATE(), 'PENDIENTE', v_total, p_tiempo_entrega);

    SET v_id_venta = LAST_INSERT_ID();

    INSERT INTO Detalle_OrdenVenta (idVenta, linea, SKU, cantidad, cantidad_pendiente, precio, subtotal)
    VALUES (v_id_venta, 1, p_sku, p_cantidad, p_cantidad, v_precio, v_total);

    COMMIT;

    SELECT 'Venta registrada' AS mensaje, v_id_venta AS idVenta;
END //


-- SP 2: Cerrar una orden de produccion (lo usa el Supervisor de Produccion)
-- Es la operacion mas critica segun el relevamiento. Hace esto:
--   1. Controla que la orden exista y que este EN_PROCESO
--   2. Recorre la BOM del motor y descuenta del stock cada componente
--      (cantidad de la BOM x cantidad de motores).
--      Si falta algun componente tira error y el ROLLBACK deshace todo,
--      incluso los componentes que ya se habian descontado.
--   3. Registra el control de calidad:
--      - aprobado (p_aprobado = 1): los motores entran al stock Disponible
--      - rechazado (p_aprobado = 0): los motores NO entran al stock (bloqueo de calidad)
--   4. Deja la orden como COMPLETADA
DROP PROCEDURE IF EXISTS sp_cerrar_orden_produccion //
CREATE PROCEDURE sp_cerrar_orden_produccion(
    IN p_id_produccion INT,
    IN p_aprobado INT,              -- 1 = aprobado, 0 = rechazado
    IN p_detalle VARCHAR(255),      -- resultado de la prueba o causa del rechazo
    IN p_legajo INT                 -- empleado que hizo el control
)
BEGIN
    DECLARE v_existe INT;
    DECLARE v_estado VARCHAR(50);
    DECLARE v_motor VARCHAR(50);
    DECLARE v_cantidad INT;
    DECLARE v_bom INT;
    DECLARE v_total_lineas INT;
    DECLARE i INT DEFAULT 1;
    DECLARE v_componente VARCHAR(50);
    DECLARE v_necesario INT;
    DECLARE v_id_stock INT;
    DECLARE v_mensaje VARCHAR(255);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- 1. controlo la orden
    SELECT COUNT(*) INTO v_existe FROM OrdenProduccion WHERE idProduccion = p_id_produccion;
    IF v_existe = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La orden de produccion no existe';
    END IF;

    SELECT estado, SKU_Motor, cantidad, idProductoBOM
    INTO v_estado, v_motor, v_cantidad, v_bom
    FROM OrdenProduccion
    WHERE idProduccion = p_id_produccion;

    IF v_estado <> 'EN_PROCESO' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La orden no esta EN_PROCESO';
    END IF;

    -- 2. descuento los componentes de la BOM
    -- las lineas de la BOM estan numeradas 1, 2, 3... asi que las recorro con un WHILE
    SELECT COUNT(*) INTO v_total_lineas FROM Detalle_BOM WHERE idProductoBOM = v_bom;

    WHILE i <= v_total_lineas DO
        SELECT SKU_Componente, cantidad * v_cantidad
        INTO v_componente, v_necesario
        FROM Detalle_BOM
        WHERE idProductoBOM = v_bom AND linea = i;

        -- busco un lugar del deposito donde haya suficiente de ese componente
        SET v_id_stock = NULL;
        SELECT id_stock INTO v_id_stock
        FROM Stock_Fisico
        WHERE SKU = v_componente AND id_estado = 1 AND cantidad >= v_necesario
        ORDER BY cantidad DESC
        LIMIT 1;

        IF v_id_stock IS NULL THEN
            SET v_mensaje = CONCAT('Falta stock del componente ', v_componente);
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_mensaje;
        END IF;

        UPDATE Stock_Fisico
        SET cantidad = cantidad - v_necesario
        WHERE id_stock = v_id_stock;

        SET i = i + 1;
    END WHILE;

    -- 3. registro el control de calidad
    IF p_aprobado = 1 THEN
        INSERT INTO Control_Produccion (idProduccion, idEmpleado, detalle, id_estado, fecha)
        VALUES (p_id_produccion, p_legajo, p_detalle, 1, CURDATE());

        -- los motores aprobados entran al stock disponible
        SET v_id_stock = NULL;
        SELECT id_stock INTO v_id_stock
        FROM Stock_Fisico
        WHERE SKU = v_motor AND id_estado = 1
        LIMIT 1;

        IF v_id_stock IS NULL THEN
            -- si no habia stock de ese motor lo creo en Producto Terminado
            INSERT INTO Stock_Fisico (SKU, id_estado, id_ubicacion, cantidad)
            VALUES (v_motor, 1, 5, v_cantidad);
        ELSE
            UPDATE Stock_Fisico
            SET cantidad = cantidad + v_cantidad
            WHERE id_stock = v_id_stock;
        END IF;
    ELSE
        -- rechazado: queda registrado con la causa y los motores no entran al stock
        INSERT INTO Control_Produccion (idProduccion, idEmpleado, detalle, id_estado, fecha)
        VALUES (p_id_produccion, p_legajo, p_detalle, 4, CURDATE());
    END IF;

    -- 4. cierro la orden
    UPDATE OrdenProduccion
    SET estado = 'COMPLETADA'
    WHERE idProduccion = p_id_produccion;

    COMMIT;

    SELECT 'Orden de produccion cerrada' AS mensaje;
END //

DELIMITER ;


-- =====================================================
-- 5. PRUEBAS
-- =====================================================
-- Estan comentadas para que el script no cambie datos al correrlo.
-- Para probar, descomentar y ejecutar de a una.

-- Vistas
-- SELECT * FROM vw_catalogo_vendedor;
-- SELECT * FROM vw_produccion_supervisor;
-- SELECT * FROM vw_stock_deposito;
-- SELECT * FROM vw_kpi_facturacion_mensual;
-- SELECT * FROM vw_kpi_tasa_rechazo;
-- SELECT * FROM vw_kpi_quiebre_stock;

-- Venta que sale bien
-- CALL sp_registrar_venta('30-71000013-9', 'BOM-VOLT-001', 5, 7);

-- Venta que tiene que fallar por falta de stock (no se guarda nada)
-- CALL sp_registrar_venta('30-71000013-9', 'BOM-VOLT-001', 9999, 7);

-- Venta que tiene que fallar porque supera el limite de credito
-- CALL sp_registrar_venta('30-71000003-9', 'BOM-AMPE-003', 10, 7);

-- Cerrar la OP 91 aprobada (descuenta componentes y suma 25 motores BOM-VOLT-001)
-- CALL sp_cerrar_orden_produccion(91, 1, 'Ensayos aprobados', 24);

-- Cerrar la OP 92 rechazada (descuenta componentes pero los motores no entran al stock)
-- CALL sp_cerrar_orden_produccion(92, 0, 'Falla en prueba de vibracion', 24);

-- Cerrar la OP 89: tiene que fallar porque no alcanza la plaqueta CMP-PLAQ-005
-- y el ROLLBACK devuelve los componentes que ya habia descontado
-- CALL sp_cerrar_orden_produccion(89, 1, 'Ensayos aprobados', 24);

-- Triggers de auditoria
-- UPDATE Articulos SET precioVenta = 80000 WHERE SKU = 'BOM-VOLT-001';
-- UPDATE Detalle_BOM SET cantidad = 3 WHERE idProductoBOM = 1 AND linea = 4;
-- UPDATE Stock_Fisico SET id_estado = 4 WHERE id_stock = 3;
-- SELECT * FROM Log_Cambios;

-- Stock negativo: tiene que dar error
-- UPDATE Stock_Fisico SET cantidad = -5 WHERE id_stock = 1;
