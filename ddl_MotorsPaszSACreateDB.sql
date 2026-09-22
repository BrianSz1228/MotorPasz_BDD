CREATE DATABASE MotorsPasz;
USE MotorsPasz;

CREATE TABLE Tipo_Cliente (
    id_tipo_cliente INT AUTO_INCREMENT PRIMARY KEY,
    tipo_cliente VARCHAR(50) NOT NULL
);

CREATE TABLE Clientes (
    CUITCliente VARCHAR(13) PRIMARY KEY,
    id_tipo_cliente INT,
    RazonSocial VARCHAR(100) NOT NULL,
    Telefono VARCHAR(20),
    Email VARCHAR(100),
    LimiteCredito DECIMAL(12,2) DEFAULT 0,
    FOREIGN KEY (id_tipo_cliente) REFERENCES Tipo_Cliente(id_tipo_cliente)
);

CREATE TABLE Direccion (
    id_direccion INT AUTO_INCREMENT PRIMARY KEY,
    calle VARCHAR(100),
    numero INT,
    piso_depto VARCHAR(20),
    codigo_postal VARCHAR(20),
    localidad VARCHAR(100),
    provincia VARCHAR(100)
);

CREATE TABLE Direccion_Cliente (
    CUITCliente VARCHAR(13),
    id_direccion INT,
    es_principal BOOLEAN DEFAULT TRUE,
    PRIMARY KEY (CUITCliente, id_direccion),
    FOREIGN KEY (CUITCliente) REFERENCES Clientes(CUITCliente),
    FOREIGN KEY (id_direccion) REFERENCES Direccion(id_direccion)
);

CREATE TABLE Proveedores (
    idProveedor INT AUTO_INCREMENT PRIMARY KEY,
    CUIT VARCHAR(15) NOT NULL,
    razonSocial VARCHAR(100) NOT NULL,
    tiempoEstimadoEntrega INT,
    condicionesPago VARCHAR(100),
    email VARCHAR(100),
    telefono VARCHAR(20)
);

CREATE TABLE Direccion_Proveedor (
    idProveedor INT,
    id_direccion INT,
    es_principal BOOLEAN DEFAULT TRUE,
    PRIMARY KEY (idProveedor, id_direccion),
    FOREIGN KEY (idProveedor) REFERENCES Proveedores(idProveedor),
    FOREIGN KEY (id_direccion) REFERENCES Direccion(id_direccion)
);

CREATE TABLE Rol (
    idRol INT AUTO_INCREMENT PRIMARY KEY,
    cargo VARCHAR(50) NOT NULL,
    nivelAcceso VARCHAR(50),
    descripcion VARCHAR(255)
);

CREATE TABLE TurnoTrabajo (
    idTurno INT AUTO_INCREMENT PRIMARY KEY,
    horaEntrada TIME,
    horaSalida TIME,
    cantidadDias INT,
    area VARCHAR(50)
);

CREATE TABLE Empleado (
    Legajo INT AUTO_INCREMENT PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    apellido VARCHAR(100) NOT NULL,
    salario DECIMAL(12,2),
    idRol INT,
    idTurno INT,
    FOREIGN KEY (idRol) REFERENCES Rol(idRol),
    FOREIGN KEY (idTurno) REFERENCES TurnoTrabajo(idTurno)
);

CREATE TABLE Tipo_Articulo (
    id_tipo_articulo INT AUTO_INCREMENT PRIMARY KEY,
    tipo_articulo VARCHAR(50) NOT NULL
);

CREATE TABLE Articulos (
    SKU VARCHAR(50) PRIMARY KEY,
    id_tipo_articulo INT,
    descripcion VARCHAR(255) NOT NULL,
    costoUnitario DECIMAL(12,2) NOT NULL,
    precioVenta DECIMAL(12,2) NOT NULL,
    stockMinimo INT DEFAULT 0,
    FOREIGN KEY (id_tipo_articulo) REFERENCES Tipo_Articulo(id_tipo_articulo)
);

CREATE TABLE Proveedor_Articulo (
    idProveedor INT,
    SKU VARCHAR(50),
    PRIMARY KEY (idProveedor, SKU),
    FOREIGN KEY (idProveedor) REFERENCES Proveedores(idProveedor),
    FOREIGN KEY (SKU) REFERENCES Articulos(SKU)
);

CREATE TABLE Estado_Stock (
    id_estado INT AUTO_INCREMENT PRIMARY KEY,
    estado VARCHAR(50) NOT NULL
);

CREATE TABLE Ubicacion (
    id_ubicacion INT AUTO_INCREMENT PRIMARY KEY,
    sector VARCHAR(50),
    pasillo VARCHAR(50),
    estante VARCHAR(50)
);

CREATE TABLE Stock_Fisico (
    id_stock INT AUTO_INCREMENT PRIMARY KEY,
    SKU VARCHAR(50),
    id_estado INT,
    id_ubicacion INT,
    cantidad INT NOT NULL DEFAULT 0,
    FOREIGN KEY (SKU) REFERENCES Articulos(SKU),
    FOREIGN KEY (id_estado) REFERENCES Estado_Stock(id_estado),
    FOREIGN KEY (id_ubicacion) REFERENCES Ubicacion(id_ubicacion)
);

CREATE TABLE AjusteStock (
    idAjuste INT AUTO_INCREMENT PRIMARY KEY,
    idEmpleado INT,
    SKU VARCHAR(50),
    id_ubicacion INT,
    id_documento_origen INT,
    tabla_origen VARCHAR(50),
    fecha DATE,
    tipoMovimiento VARCHAR(20),
    motivo VARCHAR(255),
    cantidad INT,
    FOREIGN KEY (idEmpleado) REFERENCES Empleado(Legajo),
    FOREIGN KEY (SKU) REFERENCES Articulos(SKU),
    FOREIGN KEY (id_ubicacion) REFERENCES Ubicacion(id_ubicacion)
);

CREATE TABLE OrdenVenta (
    idVenta INT AUTO_INCREMENT PRIMARY KEY,
    CUITCliente VARCHAR(15),
    fechaVenta DATE NOT NULL,
    estado VARCHAR(50),
    precioFinal DECIMAL(12,2),
    tiempoEntrega INT,
    FOREIGN KEY (CUITCliente) REFERENCES Clientes(CUITCliente)
);

CREATE TABLE Detalle_OrdenVenta (
    idVenta INT,
    linea INT,
    SKU VARCHAR(50),
    cantidad INT NOT NULL,
    cantidad_pendiente INT NOT NULL,
    precio DECIMAL(12,2),
    subtotal DECIMAL(12,2),
    PRIMARY KEY (idVenta, linea),
    FOREIGN KEY (idVenta) REFERENCES OrdenVenta(idVenta),
    FOREIGN KEY (SKU) REFERENCES Articulos(SKU)
);

CREATE TABLE OrdenCompra (
    idCompra INT AUTO_INCREMENT PRIMARY KEY,
    idProveedor INT,
    idEmpleado INT,
    fecha DATE NOT NULL,
    costoFinal DECIMAL(12,2),
    estado VARCHAR(50),
    FOREIGN KEY (idProveedor) REFERENCES Proveedores(idProveedor),
    FOREIGN KEY (idEmpleado) REFERENCES Empleado(Legajo)
);

CREATE TABLE Detalle_OrdenCompra (
    idCompra INT,
    linea INT,
    SKU VARCHAR(50),
    cantidad INT NOT NULL,
    cantidad_pendiente INT NOT NULL,
    precio DECIMAL(12,2),
    subtotal DECIMAL(12,2),
    PRIMARY KEY (idCompra, linea),
    FOREIGN KEY (idCompra) REFERENCES OrdenCompra(idCompra),
    FOREIGN KEY (SKU) REFERENCES Articulos(SKU)
);

CREATE TABLE Remito_Ingreso (
    idRemitoIngreso INT AUTO_INCREMENT PRIMARY KEY,
    idProveedor INT,
    nroRemitoProveedor VARCHAR(50),
    fechaRecepcion DATE,
    FOREIGN KEY (idProveedor) REFERENCES Proveedores(idProveedor)
);

CREATE TABLE Detalle_Remito_Ingreso (
    idRemitoIngreso INT,
    linea INT,
    idCompra INT,
    SKU VARCHAR(50),
    cantidadRecibida INT NOT NULL,
    PRIMARY KEY (idRemitoIngreso, linea),
    FOREIGN KEY (idRemitoIngreso) REFERENCES Remito_Ingreso(idRemitoIngreso),
    FOREIGN KEY (idCompra) REFERENCES OrdenCompra(idCompra),
    FOREIGN KEY (SKU) REFERENCES Articulos(SKU)
);

CREATE TABLE Control_Recepcion (
    idControlRecepcion INT AUTO_INCREMENT PRIMARY KEY,
    idRemitoIngreso INT,
    linea_remito INT,
    idEmpleado INT,
    id_estado INT,
    fechaControl DATETIME,
    cantidad_evaluada INT,
    observaciones VARCHAR(255),
    FOREIGN KEY (idRemitoIngreso, linea_remito) REFERENCES Detalle_Remito_Ingreso(idRemitoIngreso, linea),
    FOREIGN KEY (idEmpleado) REFERENCES Empleado(Legajo),
    FOREIGN KEY (id_estado) REFERENCES Estado_Stock(id_estado)
);

CREATE TABLE Remito_Egreso (
    idRemitoEgreso INT AUTO_INCREMENT PRIMARY KEY,
    CUITCliente VARCHAR(13),
    nroRemito VARCHAR(50),
    fechaDespacho DATE,
    FOREIGN KEY (CUITCliente) REFERENCES Clientes(CUITCliente)
);

CREATE TABLE Detalle_Remito_Egreso (
    idRemitoEgreso INT,
    linea INT,
    idVenta INT,
    SKU VARCHAR(50),
    cantidadDespachada INT NOT NULL,
    PRIMARY KEY (idRemitoEgreso, linea),
    FOREIGN KEY (idRemitoEgreso) REFERENCES Remito_Egreso(idRemitoEgreso),
    FOREIGN KEY (idVenta) REFERENCES OrdenVenta(idVenta),
    FOREIGN KEY (SKU) REFERENCES Articulos(SKU)
);

CREATE TABLE Tipo_Documento (
    id_tipo_documento INT AUTO_INCREMENT PRIMARY KEY,
    codigo VARCHAR(10) NOT NULL,
    nombre VARCHAR(50) NOT NULL,
    multiplicador INT NOT NULL
);

CREATE TABLE Comprobante_Compra (
    idComprobanteCompra INT AUTO_INCREMENT PRIMARY KEY,
    idProveedor INT,
    id_tipo_documento INT,
    id_comprobante_origen INT,
    nroComprobanteProveedor VARCHAR(50),
    fechaEmision DATE,
    montoTotal DECIMAL(12,2),
    FOREIGN KEY (idProveedor) REFERENCES Proveedores(idProveedor),
    FOREIGN KEY (id_tipo_documento) REFERENCES Tipo_Documento(id_tipo_documento),
    FOREIGN KEY (id_comprobante_origen) REFERENCES Comprobante_Compra(idComprobanteCompra)
);

CREATE TABLE Detalle_Comprobante_Compra (
    idComprobanteCompra INT,
    linea INT,
    idCompra INT,
    SKU VARCHAR(50),
    cantidad INT NOT NULL,
    precioUnitario DECIMAL(12,2),
    subtotal DECIMAL(12,2),
    PRIMARY KEY (idComprobanteCompra, linea),
    FOREIGN KEY (idComprobanteCompra) REFERENCES Comprobante_Compra(idComprobanteCompra),
    FOREIGN KEY (idCompra) REFERENCES OrdenCompra(idCompra),
    FOREIGN KEY (SKU) REFERENCES Articulos(SKU)
);

CREATE TABLE Comprobante_Venta (
    idComprobanteVenta INT AUTO_INCREMENT PRIMARY KEY,
    CUITCliente VARCHAR(13),
    id_tipo_documento INT,
    id_comprobante_origen INT,
    nroComprobante VARCHAR(50),
    CAE VARCHAR(50),
    fechaEmision DATE,
    montoTotal DECIMAL(12,2),
    FOREIGN KEY (CUITCliente) REFERENCES Clientes(CUITCliente),
    FOREIGN KEY (id_tipo_documento) REFERENCES Tipo_Documento(id_tipo_documento),
    FOREIGN KEY (id_comprobante_origen) REFERENCES Comprobante_Venta(idComprobanteVenta)
);

CREATE TABLE Detalle_Comprobante_Venta (
    idComprobanteVenta INT,
    linea INT,
    idVenta INT,
    SKU VARCHAR(50),
    cantidad INT NOT NULL,
    precioUnitario DECIMAL(12,2),
    subtotal DECIMAL(12,2),
    PRIMARY KEY (idComprobanteVenta, linea),
    FOREIGN KEY (idComprobanteVenta) REFERENCES Comprobante_Venta(idComprobanteVenta),
    FOREIGN KEY (idVenta) REFERENCES OrdenVenta(idVenta),
    FOREIGN KEY (SKU) REFERENCES Articulos(SKU)
);

CREATE TABLE Devolucion_Venta (
    idDevolucionVenta INT AUTO_INCREMENT PRIMARY KEY,
    idEmpleado INT,
    idVenta INT,
    fecha DATE,
    motivo VARCHAR(255),
    FOREIGN KEY (idEmpleado) REFERENCES Empleado(Legajo),
    FOREIGN KEY (idVenta) REFERENCES OrdenVenta(idVenta)
);

CREATE TABLE Detalle_Devolucion_Venta (
    idDevolucionVenta INT,
    linea INT,
    SKU VARCHAR(50),
    cantidad INT NOT NULL,
    id_estado INT,
    PRIMARY KEY (idDevolucionVenta, linea),
    FOREIGN KEY (idDevolucionVenta) REFERENCES Devolucion_Venta(idDevolucionVenta),
    FOREIGN KEY (SKU) REFERENCES Articulos(SKU),
    FOREIGN KEY (id_estado) REFERENCES Estado_Stock(id_estado)
);

CREATE TABLE Devolucion_Compra (
    idDevolucionCompra INT AUTO_INCREMENT PRIMARY KEY,
    idEmpleado INT,
    idCompra INT,
    fecha DATE,
    motivo VARCHAR(255),
    FOREIGN KEY (idEmpleado) REFERENCES Empleado(Legajo),
    FOREIGN KEY (idCompra) REFERENCES OrdenCompra(idCompra)
);

CREATE TABLE Detalle_Devolucion_Compra (
    idDevolucionCompra INT,
    linea INT,
    SKU VARCHAR(50),
    cantidad INT NOT NULL,
    PRIMARY KEY (idDevolucionCompra, linea),
    FOREIGN KEY (idDevolucionCompra) REFERENCES Devolucion_Compra(idDevolucionCompra),
    FOREIGN KEY (SKU) REFERENCES Articulos(SKU)
);

CREATE TABLE BOM (
    idProductoBOM INT AUTO_INCREMENT PRIMARY KEY,
    SKU_Principal VARCHAR(50),
    descripcion VARCHAR(255),
    version VARCHAR(20),
    FOREIGN KEY (SKU_Principal) REFERENCES Articulos(SKU)
);

CREATE TABLE Detalle_BOM (
    idProductoBOM INT,
    linea INT,
    SKU_Componente VARCHAR(50),
    cantidad INT NOT NULL,
    PRIMARY KEY (idProductoBOM, linea),
    FOREIGN KEY (idProductoBOM) REFERENCES BOM(idProductoBOM),
    FOREIGN KEY (SKU_Componente) REFERENCES Articulos(SKU)
);

CREATE TABLE OrdenProduccion (
    idProduccion INT AUTO_INCREMENT PRIMARY KEY,
    nroOrden VARCHAR(50),
    fecha DATE,
    estado VARCHAR(50),
    idEmpleado INT,
    SKU_Motor VARCHAR(50),
    cantidad INT,
    idProductoBOM INT,
    FOREIGN KEY (idEmpleado) REFERENCES Empleado(Legajo),
    FOREIGN KEY (SKU_Motor) REFERENCES Articulos(SKU),
    FOREIGN KEY (idProductoBOM) REFERENCES BOM(idProductoBOM)
);

CREATE TABLE Control_Produccion (
    idControl INT AUTO_INCREMENT PRIMARY KEY,
    idProduccion INT,
    idEmpleado INT,
    detalle VARCHAR(255),
    id_estado INT,
    fecha DATE,
    FOREIGN KEY (idProduccion) REFERENCES OrdenProduccion(idProduccion),
    FOREIGN KEY (idEmpleado) REFERENCES Empleado(Legajo),
    FOREIGN KEY (id_estado) REFERENCES Estado_Stock(id_estado)
);

CREATE TABLE Auditoria (
    id_auditoria INT AUTO_INCREMENT PRIMARY KEY,
    id_usuario INT,
    tabla VARCHAR(100),
    id_registro VARCHAR(100),
    campo VARCHAR(100),
    valor_anterior VARCHAR(255),
    valor_nuevo VARCHAR(255),
    fecha DATETIME,
    FOREIGN KEY (id_usuario) REFERENCES Empleado(Legajo)
);

USE MotorsPasz;

-- ==========================================
-- CLIENTES Y PROVEEDORES
-- ==========================================

-- Buscar clientes por tipo
CREATE INDEX idx_clientes_tipo
ON Clientes(id_tipo_cliente);

-- El CUIT de un proveedor no puede repetirse
CREATE UNIQUE INDEX uq_proveedores_cuit
ON Proveedores(CUIT);


-- ==========================================
-- ARTÍCULOS
-- ==========================================


-- Buscar artículos por tipo
CREATE INDEX idx_articulos_tipo
ON Articulos(id_tipo_articulo);


-- ==========================================
-- STOCK
-- ==========================================

-- Un artículo no puede estar en la misma ubicación
-- con dos estados diferentes
CREATE UNIQUE INDEX uq_stock_sku_ubicacion
ON Stock_Fisico(SKU, id_ubicacion);

-- Buscar stock por artículo, estado y ubicación
CREATE INDEX idx_stock_sku_estado_ubicacion
ON Stock_Fisico(SKU, id_estado, id_ubicacion);


-- ==========================================
-- ORDENES DE VENTA
-- ==========================================


-- Ver las ventas de un cliente por fecha
CREATE INDEX idx_venta_cliente_fecha
ON OrdenVenta(CUITCliente, fechaVenta);

-- Buscar ventas por estado y fecha
CREATE INDEX idx_venta_estado_fecha
ON OrdenVenta(estado, fechaVenta);


-- ==========================================
-- DETALLE DE ORDEN DE VENTA
-- ==========================================


-- Buscar en qué ventas aparece un artículo
CREATE INDEX idx_detalle_venta_sku
ON Detalle_OrdenVenta(SKU);


-- ==========================================
-- ORDENES DE COMPRA
-- ==========================================


-- Ver las compras de un proveedor por fecha
CREATE INDEX idx_compra_proveedor_fecha
ON OrdenCompra(idProveedor, fecha);

-- Buscar compras por empleado y fecha
CREATE INDEX idx_compra_empleado_fecha
ON OrdenCompra(idEmpleado, fecha);

-- Buscar compras por estado y fecha
CREATE INDEX idx_compra_estado_fecha
ON OrdenCompra(estado, fecha);


-- ==========================================
-- DETALLE DE ORDEN DE COMPRA
-- ==========================================


-- Buscar en qué compras aparece un artículo
CREATE INDEX idx_detalle_compra_sku
ON Detalle_OrdenCompra(SKU);


-- ==========================================
-- REMITOS DE INGRESO
-- ==========================================


-- Saber qué remitos corresponden a una compra
CREATE INDEX idx_detalle_remito_ingreso_compra
ON Detalle_Remito_Ingreso(idCompra);


-- ==========================================
-- REMITOS DE EGRESO
-- ==========================================


-- Saber qué remitos corresponden a una venta
CREATE INDEX idx_detalle_remito_egreso_venta
ON Detalle_Remito_Egreso(idVenta);

-- Buscar remitos de egreso por artículo
CREATE INDEX idx_detalle_remito_egreso_sku
ON Detalle_Remito_Egreso(SKU);


-- ==========================================
-- COMPROBANTES DE COMPRA
-- ==========================================


-- Ver comprobantes de un proveedor por fecha
CREATE INDEX idx_comprobante_compra_proveedor_fecha
ON Comprobante_Compra(idProveedor, fechaEmision);

-- Buscar comprobantes por número del proveedor
CREATE INDEX idx_comprobante_compra_nro
ON Comprobante_Compra(nroComprobanteProveedor);


-- ==========================================
-- COMPROBANTES DE VENTA
-- ==========================================


-- Ver comprobantes de un cliente por fecha
CREATE INDEX idx_comprobante_venta_cliente_fecha
ON Comprobante_Venta(CUITCliente, fechaEmision);

-- Buscar comprobantes por CAE
CREATE INDEX idx_comprobante_venta_cae
ON Comprobante_Venta(CAE);


-- ==========================================
-- DEVOLUCIONES
-- ==========================================


-- Buscar devoluciones de una venta
CREATE INDEX idx_devolucion_venta_venta
ON Devolucion_Venta(idVenta);

-- Buscar devoluciones de una compra
CREATE INDEX idx_devolucion_compra_compra
ON Devolucion_Compra(idCompra);


-- ==========================================
-- BOM
-- ==========================================


-- Un producto puede tener varias versiones,
-- pero no dos veces la misma versión
CREATE UNIQUE INDEX uq_bom_producto_version
ON BOM(SKU_Principal, version);

-- Buscar en qué BOM aparece un componente
CREATE INDEX idx_detalle_bom_componente
ON Detalle_BOM(SKU_Componente);


-- ==========================================
-- PRODUCCIÓN
-- ==========================================


-- Buscar órdenes de producción por motor
CREATE INDEX idx_produccion_motor
ON OrdenProduccion(SKU_Motor);

-- Buscar órdenes de producción por BOM
CREATE INDEX idx_produccion_bom
ON OrdenProduccion(idProductoBOM);

-- Buscar producción por estado y fecha
CREATE INDEX idx_produccion_estado_fecha
ON OrdenProduccion(estado, fecha);


-- ==========================================
-- AUDITORÍA
-- ==========================================


-- Buscar acciones realizadas por un usuario
CREATE INDEX idx_auditoria_usuario
ON Auditoria(id_usuario);

-- Buscar todos los cambios de un registro
CREATE INDEX idx_auditoria_tabla_registro
ON Auditoria(tabla, id_registro);

-- Buscar auditoría por fecha
CREATE INDEX idx_auditoria_fecha
ON Auditoria(fecha);
