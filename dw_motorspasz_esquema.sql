
DROP DATABASE IF EXISTS MotorsPasz_DW;
CREATE DATABASE MotorsPasz_DW;
USE MotorsPasz_DW;


-- =====================================================
-- 1. DIMENSIONES
-- =====================================================
-- Todas usan clave subrogada (sk_...). La clave del
-- sistema operacional (CUIT, SKU, etc.) queda como
-- columna aparte con UNIQUE, para poder actualizar.

-- Tiempo: se genera desde el SP, no se copia del OLTP.
-- La clave es la fecha en formato AAAAMMDD. Se cargan
-- anios completos para que Power BI la tome como
-- tabla de fechas.
CREATE TABLE dim_tiempo (
    sk_tiempo INT PRIMARY KEY,
    fecha DATE NOT NULL UNIQUE,
    anio INT NOT NULL,
    trimestre INT NOT NULL,
    mes INT NOT NULL,
    nombre_mes VARCHAR(20) NOT NULL,
    anio_mes CHAR(7) NOT NULL,
    dia INT NOT NULL,
    dia_semana INT NOT NULL,
    nombre_dia VARCHAR(20) NOT NULL,
    es_fin_de_semana TINYINT NOT NULL
);

-- Cliente: el segmento sale de Tipo_Cliente y la
-- ubicacion de su direccion principal.
CREATE TABLE dim_cliente (
    sk_cliente INT AUTO_INCREMENT PRIMARY KEY,
    cuit VARCHAR(13) NOT NULL UNIQUE,
    razon_social VARCHAR(100) NOT NULL,
    segmento VARCHAR(50) NOT NULL,
    provincia VARCHAR(100) NOT NULL,
    localidad VARCHAR(100) NOT NULL
);

-- Articulo: motores terminados y componentes.
-- categoria separa 'Motor terminado' de 'Componente'.
CREATE TABLE dim_articulo (
    sk_articulo INT AUTO_INCREMENT PRIMARY KEY,
    sku VARCHAR(50) NOT NULL UNIQUE,
    descripcion VARCHAR(255) NOT NULL,
    tipo_articulo VARCHAR(50) NOT NULL,
    categoria VARCHAR(20) NOT NULL,
    costo_unitario DECIMAL(12,2),
    precio_venta DECIMAL(12,2),
    stock_minimo INT
);

-- Proveedor: id_proveedor = 0 es el miembro
-- 'Fabricacion propia' (motores, que no tienen proveedor).
CREATE TABLE dim_proveedor (
    sk_proveedor INT AUTO_INCREMENT PRIMARY KEY,
    id_proveedor INT NOT NULL UNIQUE,
    cuit VARCHAR(13),
    razon_social VARCHAR(100) NOT NULL,
    dias_entrega INT
);

-- Tipo de comprobante: el multiplicador hace que las
-- notas de credito resten (-1) y las facturas sumen (1).
CREATE TABLE dim_tipo_comprobante (
    sk_tipo_comprobante INT AUTO_INCREMENT PRIMARY KEY,
    id_tipo_documento INT NOT NULL UNIQUE,
    codigo VARCHAR(10) NOT NULL,
    nombre VARCHAR(50) NOT NULL,
    multiplicador INT NOT NULL
);

-- Linea de produccion: no existe como tabla en el OLTP.
-- Se deriva del turno del operario que hizo la orden.
CREATE TABLE dim_linea_produccion (
    sk_linea INT AUTO_INCREMENT PRIMARY KEY,
    id_turno INT NOT NULL UNIQUE,
    linea VARCHAR(50) NOT NULL,
    hora_entrada TIME,
    hora_salida TIME
);

-- Resultado del control de calidad y causa del rechazo.
-- La causa se clasifica en el ETL a partir del texto
-- libre de Control_Produccion.detalle.
CREATE TABLE dim_resultado_control (
    sk_resultado INT AUTO_INCREMENT PRIMARY KEY,
    resultado VARCHAR(20) NOT NULL,
    causa VARCHAR(50) NOT NULL,
    UNIQUE (resultado, causa)
);

-- Empleado: cargo y turno vienen de Rol y TurnoTrabajo
-- (estrella: quedan adentro de la dimension). No se
-- copia el salario. legajo = 0 es el miembro
-- 'Sin asignar' para hechos sin empleado.
CREATE TABLE dim_empleado (
    sk_empleado INT AUTO_INCREMENT PRIMARY KEY,
    legajo INT NOT NULL UNIQUE,
    nombre_completo VARCHAR(200) NOT NULL,
    cargo VARCHAR(50) NOT NULL,
    nivel_acceso VARCHAR(50) NOT NULL,
    turno VARCHAR(50) NOT NULL,
    area VARCHAR(50) NOT NULL
);

-- Estado de la mercaderia (Disponible, En control,
-- Danado...). id_estado = 0 es 'Sin dato'.
CREATE TABLE dim_estado_stock (
    sk_estado INT AUTO_INCREMENT PRIMARY KEY,
    id_estado INT NOT NULL UNIQUE,
    estado VARCHAR(50) NOT NULL
);


-- =====================================================
-- 2. TABLAS DE HECHOS
-- =====================================================

-- A) Facturacion
-- Grano: una linea de un comprobante de venta.
-- importe_neto = subtotal * multiplicador del comprobante.
-- cantidad_neta = cantidad * multiplicador (las notas de
-- credito restan unidades vendidas).
CREATE TABLE fact_facturacion (
    id_comprobante INT NOT NULL,
    linea INT NOT NULL,
    nro_comprobante VARCHAR(50),
    sk_tiempo INT NOT NULL,
    sk_cliente INT NOT NULL,
    sk_articulo INT NOT NULL,
    sk_tipo_comprobante INT NOT NULL,
    cantidad INT NOT NULL,
    cantidad_neta INT NOT NULL,
    precio_unitario DECIMAL(12,2) NOT NULL,
    importe_bruto DECIMAL(14,2) NOT NULL,
    importe_neto DECIMAL(14,2) NOT NULL,
    costo_total DECIMAL(14,2) NOT NULL,
    margen DECIMAL(14,2) NOT NULL,
    PRIMARY KEY (id_comprobante, linea),
    FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    FOREIGN KEY (sk_cliente) REFERENCES dim_cliente(sk_cliente),
    FOREIGN KEY (sk_articulo) REFERENCES dim_articulo(sk_articulo),
    FOREIGN KEY (sk_tipo_comprobante) REFERENCES dim_tipo_comprobante(sk_tipo_comprobante)
);

-- B) Calidad
-- Grano: un control de calidad sobre una orden de produccion.
-- Si el control rechaza, se rechaza la cantidad de la orden.
CREATE TABLE fact_calidad (
    id_control INT PRIMARY KEY,
    id_produccion INT NOT NULL,
    nro_orden VARCHAR(50),
    sk_tiempo INT NOT NULL,
    sk_articulo INT NOT NULL,
    sk_linea INT NOT NULL,
    sk_resultado INT NOT NULL,
    cantidad_ensamblada INT NOT NULL,
    cantidad_rechazada INT NOT NULL,
    es_rechazo TINYINT NOT NULL,
    dias_hasta_control INT NOT NULL,
    FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    FOREIGN KEY (sk_articulo) REFERENCES dim_articulo(sk_articulo),
    FOREIGN KEY (sk_linea) REFERENCES dim_linea_produccion(sk_linea),
    FOREIGN KEY (sk_resultado) REFERENCES dim_resultado_control(sk_resultado)
);

-- C) Stock (foto)
-- Grano: un articulo con un proveedor asignado en una
-- fecha de corte. Cada corrida del ETL agrega la foto de
-- su fecha, asi queda historia (el OLTP solo guarda el
-- estado actual). Un componente con dos proveedores
-- aparece dos veces: para contar articulos se usa
-- DISTINCTCOUNT(sk_articulo) en Power BI, y para sumar
-- stock o valor, un SUMX sobre los articulos.
-- valor_disponible = stock disponible * costo unitario.
CREATE TABLE fact_stock (
    sk_tiempo INT NOT NULL,
    sk_articulo INT NOT NULL,
    sk_proveedor INT NOT NULL,
    stock_disponible INT NOT NULL,
    stock_no_disponible INT NOT NULL,
    stock_minimo INT NOT NULL,
    valor_disponible DECIMAL(14,2) NOT NULL,
    faltante INT NOT NULL,
    bajo_punto_pedido TINYINT NOT NULL,
    pendiente_recepcion INT NOT NULL,
    PRIMARY KEY (sk_tiempo, sk_articulo, sk_proveedor),
    FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    FOREIGN KEY (sk_articulo) REFERENCES dim_articulo(sk_articulo),
    FOREIGN KEY (sk_proveedor) REFERENCES dim_proveedor(sk_proveedor)
);

-- D) Compras
-- Grano: una linea de un comprobante de compra.
-- importe_neto = subtotal * multiplicador (las notas de
-- credito de proveedores restan).
CREATE TABLE fact_compras (
    id_comprobante INT NOT NULL,
    linea INT NOT NULL,
    nro_comprobante VARCHAR(50),
    sk_tiempo INT NOT NULL,
    sk_proveedor INT NOT NULL,
    sk_articulo INT NOT NULL,
    sk_tipo_comprobante INT NOT NULL,
    cantidad INT NOT NULL,
    precio_unitario DECIMAL(12,2) NOT NULL,
    importe_bruto DECIMAL(14,2) NOT NULL,
    importe_neto DECIMAL(14,2) NOT NULL,
    PRIMARY KEY (id_comprobante, linea),
    FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    FOREIGN KEY (sk_proveedor) REFERENCES dim_proveedor(sk_proveedor),
    FOREIGN KEY (sk_articulo) REFERENCES dim_articulo(sk_articulo),
    FOREIGN KEY (sk_tipo_comprobante) REFERENCES dim_tipo_comprobante(sk_tipo_comprobante)
);

-- E) Pedidos de venta
-- Grano: una linea de una orden de venta. Entran todos
-- los estados (tambien ANULADA), el estado queda como
-- atributo del hecho para poder filtrarlo.
CREATE TABLE fact_pedidos_venta (
    id_venta INT NOT NULL,
    linea INT NOT NULL,
    sk_tiempo INT NOT NULL,
    sk_cliente INT NOT NULL,
    sk_articulo INT NOT NULL,
    estado VARCHAR(50) NOT NULL,
    cantidad INT NOT NULL,
    cantidad_entregada INT NOT NULL,
    cantidad_pendiente INT NOT NULL,
    precio_unitario DECIMAL(12,2) NOT NULL,
    importe DECIMAL(14,2) NOT NULL,
    dias_entrega_pactados INT,
    PRIMARY KEY (id_venta, linea),
    FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    FOREIGN KEY (sk_cliente) REFERENCES dim_cliente(sk_cliente),
    FOREIGN KEY (sk_articulo) REFERENCES dim_articulo(sk_articulo)
);

-- F) Despachos
-- Grano: una linea de un remito de egreso.
-- entregado_tarde = 1 si salio despues del plazo
-- pactado en la orden de venta.
CREATE TABLE fact_despachos (
    id_remito INT NOT NULL,
    linea INT NOT NULL,
    nro_remito VARCHAR(50),
    id_venta INT NOT NULL,
    sk_tiempo INT NOT NULL,
    sk_cliente INT NOT NULL,
    sk_articulo INT NOT NULL,
    cantidad_despachada INT NOT NULL,
    dias_desde_venta INT NOT NULL,
    dias_entrega_pactados INT,
    entregado_tarde TINYINT NOT NULL,
    PRIMARY KEY (id_remito, linea),
    FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    FOREIGN KEY (sk_cliente) REFERENCES dim_cliente(sk_cliente),
    FOREIGN KEY (sk_articulo) REFERENCES dim_articulo(sk_articulo)
);

-- G) Devoluciones de clientes
-- Grano: una linea de una devolucion de venta.
-- importe = cantidad * precio de la orden de venta.
CREATE TABLE fact_devoluciones_venta (
    id_devolucion INT NOT NULL,
    linea INT NOT NULL,
    id_venta INT NOT NULL,
    sk_tiempo INT NOT NULL,
    sk_cliente INT NOT NULL,
    sk_articulo INT NOT NULL,
    sk_empleado INT NOT NULL,
    sk_estado INT NOT NULL,
    motivo_devolucion VARCHAR(255),
    cantidad INT NOT NULL,
    importe DECIMAL(14,2) NOT NULL,
    PRIMARY KEY (id_devolucion, linea),
    FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    FOREIGN KEY (sk_cliente) REFERENCES dim_cliente(sk_cliente),
    FOREIGN KEY (sk_articulo) REFERENCES dim_articulo(sk_articulo),
    FOREIGN KEY (sk_empleado) REFERENCES dim_empleado(sk_empleado),
    FOREIGN KEY (sk_estado) REFERENCES dim_estado_stock(sk_estado)
);

-- H) Ordenes de compra
-- Grano: una linea de una orden de compra.
-- cantidad_pendiente ya aplica la regla 4: si la OC
-- esta vencida y el remanente es minimo, queda en 0.
CREATE TABLE fact_ordenes_compra (
    id_compra INT NOT NULL,
    linea INT NOT NULL,
    sk_tiempo INT NOT NULL,
    sk_proveedor INT NOT NULL,
    sk_articulo INT NOT NULL,
    sk_empleado INT NOT NULL,
    estado VARCHAR(50) NOT NULL,
    cantidad INT NOT NULL,
    cantidad_recibida INT NOT NULL,
    cantidad_pendiente INT NOT NULL,
    precio_unitario DECIMAL(12,2) NOT NULL,
    importe DECIMAL(14,2) NOT NULL,
    vencida TINYINT NOT NULL,
    PRIMARY KEY (id_compra, linea),
    FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    FOREIGN KEY (sk_proveedor) REFERENCES dim_proveedor(sk_proveedor),
    FOREIGN KEY (sk_articulo) REFERENCES dim_articulo(sk_articulo),
    FOREIGN KEY (sk_empleado) REFERENCES dim_empleado(sk_empleado)
);

-- I) Recepciones de proveedores
-- Grano: una linea de un remito de ingreso, con el
-- resultado de su control de recepcion.
CREATE TABLE fact_recepciones (
    id_remito INT NOT NULL,
    linea INT NOT NULL,
    nro_remito VARCHAR(50),
    id_compra INT NOT NULL,
    sk_tiempo INT NOT NULL,
    sk_proveedor INT NOT NULL,
    sk_articulo INT NOT NULL,
    sk_estado INT NOT NULL,
    sk_empleado INT NOT NULL,
    cantidad_recibida INT NOT NULL,
    cantidad_evaluada INT NOT NULL,
    dias_desde_oc INT NOT NULL,
    dias_entrega_pactados INT,
    entregado_tarde TINYINT NOT NULL,
    PRIMARY KEY (id_remito, linea),
    FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    FOREIGN KEY (sk_proveedor) REFERENCES dim_proveedor(sk_proveedor),
    FOREIGN KEY (sk_articulo) REFERENCES dim_articulo(sk_articulo),
    FOREIGN KEY (sk_estado) REFERENCES dim_estado_stock(sk_estado),
    FOREIGN KEY (sk_empleado) REFERENCES dim_empleado(sk_empleado)
);

-- J) Devoluciones a proveedores
-- Grano: una linea de una devolucion de compra.
-- importe = cantidad * precio de la orden de compra.
CREATE TABLE fact_devoluciones_compra (
    id_devolucion INT NOT NULL,
    linea INT NOT NULL,
    id_compra INT NOT NULL,
    sk_tiempo INT NOT NULL,
    sk_proveedor INT NOT NULL,
    sk_articulo INT NOT NULL,
    sk_empleado INT NOT NULL,
    motivo_devolucion VARCHAR(255),
    cantidad INT NOT NULL,
    importe DECIMAL(14,2) NOT NULL,
    PRIMARY KEY (id_devolucion, linea),
    FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    FOREIGN KEY (sk_proveedor) REFERENCES dim_proveedor(sk_proveedor),
    FOREIGN KEY (sk_articulo) REFERENCES dim_articulo(sk_articulo),
    FOREIGN KEY (sk_empleado) REFERENCES dim_empleado(sk_empleado)
);

-- K) Produccion
-- Grano: una orden de produccion (todas, tambien las
-- EN_PROCESO que todavia no tienen control).
CREATE TABLE fact_produccion (
    id_produccion INT PRIMARY KEY,
    nro_orden VARCHAR(50),
    sk_tiempo INT NOT NULL,
    sk_articulo INT NOT NULL,
    sk_linea INT NOT NULL,
    sk_empleado INT NOT NULL,
    estado VARCHAR(50) NOT NULL,
    cantidad INT NOT NULL,
    costo_total DECIMAL(14,2) NOT NULL,
    tiene_control TINYINT NOT NULL,
    FOREIGN KEY (sk_tiempo) REFERENCES dim_tiempo(sk_tiempo),
    FOREIGN KEY (sk_articulo) REFERENCES dim_articulo(sk_articulo),
    FOREIGN KEY (sk_linea) REFERENCES dim_linea_produccion(sk_linea),
    FOREIGN KEY (sk_empleado) REFERENCES dim_empleado(sk_empleado)
);



-- =====================================================
-- 3. STAGING AREA
-- =====================================================
-- Copia cruda de lo que se extrae del OLTP. Aca se aplica
-- la curaduria: cada regla que falla completa
-- motivo_descarte. Solo pasa a los hechos lo que queda
-- con motivo_descarte en NULL.

CREATE TABLE stg_facturacion (
    id_comprobante INT,
    linea INT,
    nro_comprobante VARCHAR(50),
    fecha_emision DATE,
    cuit VARCHAR(15),
    razon_social VARCHAR(100),
    id_tipo_documento INT,
    multiplicador INT,
    estado_venta VARCHAR(50),
    sku VARCHAR(50),
    cantidad INT,
    precio_unitario DECIMAL(12,2),
    subtotal DECIMAL(12,2),
    costo_unitario DECIMAL(12,2),
    motivo_descarte VARCHAR(100)
);

CREATE TABLE stg_calidad (
    id_control INT,
    id_produccion INT,
    nro_orden VARCHAR(50),
    fecha_orden DATE,
    fecha_control DATE,
    sku_motor VARCHAR(50),
    costo_motor DECIMAL(12,2),
    cantidad INT,
    id_turno INT,
    id_estado INT,
    detalle VARCHAR(255),
    resultado VARCHAR(20),
    causa VARCHAR(50),
    motivo_descarte VARCHAR(100)
);

CREATE TABLE stg_stock (
    sku VARCHAR(50),
    id_proveedor INT,
    stock_disponible INT,
    stock_no_disponible INT,
    stock_minimo INT,
    motivo_descarte VARCHAR(100)
);

CREATE TABLE stg_compras (
    id_comprobante INT,
    linea INT,
    nro_comprobante VARCHAR(50),
    fecha_emision DATE,
    id_proveedor INT,
    proveedor_existe TINYINT,
    id_tipo_documento INT,
    multiplicador INT,
    sku VARCHAR(50),
    articulo_existe TINYINT,
    cantidad INT,
    precio_unitario DECIMAL(12,2),
    subtotal DECIMAL(12,2),
    motivo_descarte VARCHAR(100)
);

-- Lineas de ordenes de compra. Alimentan
-- fact_ordenes_compra y pendiente_recepcion de
-- fact_stock. remanente_ignorado marca la regla 4.
CREATE TABLE stg_ordenes_compra (
    id_compra INT,
    linea INT,
    fecha_oc DATE,
    id_proveedor INT,
    proveedor_existe TINYINT,
    dias_entrega INT,
    id_empleado INT,
    estado VARCHAR(50),
    sku VARCHAR(50),
    articulo_existe TINYINT,
    cantidad INT,
    cantidad_pendiente INT,
    precio DECIMAL(12,2),
    subtotal DECIMAL(12,2),
    remanente_ignorado TINYINT NOT NULL DEFAULT 0,
    motivo_descarte VARCHAR(100)
);

CREATE TABLE stg_pedidos_venta (
    id_venta INT,
    linea INT,
    fecha_venta DATE,
    cuit VARCHAR(15),
    razon_social VARCHAR(100),
    estado VARCHAR(50),
    dias_entrega INT,
    sku VARCHAR(50),
    articulo_existe TINYINT,
    cantidad INT,
    cantidad_pendiente INT,
    precio DECIMAL(12,2),
    subtotal DECIMAL(12,2),
    motivo_descarte VARCHAR(100)
);

CREATE TABLE stg_despachos (
    id_remito INT,
    linea INT,
    nro_remito VARCHAR(50),
    fecha_despacho DATE,
    cuit VARCHAR(15),
    razon_social VARCHAR(100),
    id_venta INT,
    fecha_venta DATE,
    dias_entrega INT,
    sku VARCHAR(50),
    articulo_existe TINYINT,
    cantidad INT,
    motivo_descarte VARCHAR(100)
);

CREATE TABLE stg_devoluciones_venta (
    id_devolucion INT,
    linea INT,
    fecha DATE,
    id_venta INT,
    venta_existe TINYINT,
    cuit VARCHAR(15),
    razon_social VARCHAR(100),
    id_empleado INT,
    id_estado INT,
    motivo VARCHAR(255),
    sku VARCHAR(50),
    articulo_existe TINYINT,
    cantidad INT,
    precio DECIMAL(12,2),
    motivo_descarte VARCHAR(100)
);

CREATE TABLE stg_recepciones (
    id_remito INT,
    linea INT,
    nro_remito VARCHAR(50),
    fecha_recepcion DATE,
    id_proveedor INT,
    proveedor_existe TINYINT,
    id_compra INT,
    fecha_oc DATE,
    dias_entrega INT,
    sku VARCHAR(50),
    articulo_existe TINYINT,
    cantidad INT,
    id_estado INT,
    id_empleado INT,
    cantidad_evaluada INT,
    motivo_descarte VARCHAR(100)
);

CREATE TABLE stg_devoluciones_compra (
    id_devolucion INT,
    linea INT,
    fecha DATE,
    id_compra INT,
    id_proveedor INT,
    id_empleado INT,
    motivo VARCHAR(255),
    sku VARCHAR(50),
    articulo_existe TINYINT,
    cantidad INT,
    precio DECIMAL(12,2),
    motivo_descarte VARCHAR(100)
);

CREATE TABLE stg_produccion (
    id_produccion INT,
    nro_orden VARCHAR(50),
    fecha DATE,
    estado VARCHAR(50),
    id_empleado INT,
    id_turno INT,
    sku_motor VARCHAR(50),
    costo_motor DECIMAL(12,2),
    cantidad INT,
    tiene_control TINYINT,
    motivo_descarte VARCHAR(100)
);


-- =====================================================
-- 4. METADATA DEL ETL
-- =====================================================

-- Una fila por corrida del SP (metadata tecnica:
-- cuando corrio, si termino bien y cuanto cargo).
CREATE TABLE etl_ejecucion (
    id_ejecucion INT AUTO_INCREMENT PRIMARY KEY,
    fecha_corte DATE NOT NULL,
    inicio DATETIME NOT NULL,
    fin DATETIME,
    estado VARCHAR(20) NOT NULL,
    filas_facturacion INT,
    filas_calidad INT,
    filas_stock INT,
    filas_compras INT,
    filas_pedidos_venta INT,
    filas_despachos INT,
    filas_devoluciones_venta INT,
    filas_ordenes_compra INT,
    filas_recepciones INT,
    filas_devoluciones_compra INT,
    filas_produccion INT,
    filas_descartadas INT,
    mensaje VARCHAR(500)
);

-- Registro de datos sucios: nada se descarta en silencio.
-- Guarda de que tabla vino, su clave y que regla violo.
CREATE TABLE etl_descartes (
    id_descarte INT AUTO_INCREMENT PRIMARY KEY,
    id_ejecucion INT NOT NULL,
    tabla_origen VARCHAR(50) NOT NULL,
    clave_origen VARCHAR(100) NOT NULL,
    motivo VARCHAR(100) NOT NULL,
    fecha_registro DATETIME NOT NULL,
    FOREIGN KEY (id_ejecucion) REFERENCES etl_ejecucion(id_ejecucion)
);


-- =====================================================
-- 5. SEGURIDAD
-- =====================================================
-- Rol de solo lectura para Power BI. Ve unicamente
-- dimensiones y hechos del DW (ni staging ni la base
-- operacional). Mismo esquema de roles que la entrega 4.
CREATE ROLE IF NOT EXISTS 'rol_powerbi';

GRANT SELECT ON MotorsPasz_DW.dim_tiempo TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.dim_cliente TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.dim_articulo TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.dim_proveedor TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.dim_tipo_comprobante TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.dim_linea_produccion TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.dim_resultado_control TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.dim_empleado TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.dim_estado_stock TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.fact_facturacion TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.fact_calidad TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.fact_stock TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.fact_compras TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.fact_pedidos_venta TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.fact_despachos TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.fact_devoluciones_venta TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.fact_ordenes_compra TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.fact_recepciones TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.fact_devoluciones_compra TO 'rol_powerbi';
GRANT SELECT ON MotorsPasz_DW.fact_produccion TO 'rol_powerbi';

CREATE USER IF NOT EXISTS 'powerbi'@'%' IDENTIFIED BY '1234';
GRANT 'rol_powerbi' TO 'powerbi'@'%';
SET DEFAULT ROLE 'rol_powerbi' TO 'powerbi'@'%';
