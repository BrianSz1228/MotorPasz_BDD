# Punto 5: guía para armar el `.pbix`

El `.pbix` se arma a mano en Power BI Desktop. Esta guía usa las tablas que deja `sp_etl_motorspasz`.

## 1. Conexión (solo al DW)
1. Obtener datos → **Base de datos MySQL**. Servidor `localhost`, base `MotorsPasz_DW`.
2. Usuario `powerbi` / `1234`. Tiene el rol `rol_powerbi`, que solo da `SELECT` sobre `dim_*` y `fact_*`, así que Power BI no puede leer la base operacional ni el staging.
3. Importar las 9 dimensiones y las 11 tablas de hechos (todas las `dim_*` y `fact_*`).

Si ya tenías el `.pbix` armado con la versión anterior: correr de nuevo `dw_motorspasz_esquema.sql`, `dw_motorspasz_etl.sql` y `CALL MotorsPasz_DW.sp_etl_motorspasz(NULL);`. Después, en Power BI, **Actualizar** y, en **Transformar datos → Nuevo origen → MySQL**, sumar las tablas nuevas. Las que ya tenías no se tocan.

## 2. Relaciones (modelo → todas 1:N, filtro simple)
| Dimensión | Hechos |
|---|---|
| `dim_tiempo[sk_tiempo]` | todas las `fact_*` |
| `dim_articulo[sk_articulo]` | todas las `fact_*` |
| `dim_cliente[sk_cliente]` | `fact_facturacion`, `fact_pedidos_venta`, `fact_despachos`, `fact_devoluciones_venta` |
| `dim_proveedor[sk_proveedor]` | `fact_stock`, `fact_compras`, `fact_ordenes_compra`, `fact_recepciones`, `fact_devoluciones_compra` |
| `dim_tipo_comprobante[sk_tipo_comprobante]` | `fact_facturacion`, `fact_compras` |
| `dim_linea_produccion[sk_linea]` | `fact_calidad`, `fact_produccion` |
| `dim_resultado_control[sk_resultado]` | `fact_calidad` |
| `dim_empleado[sk_empleado]` | `fact_devoluciones_venta`, `fact_ordenes_compra`, `fact_recepciones`, `fact_devoluciones_compra`, `fact_produccion` |
| `dim_estado_stock[sk_estado]` | `fact_devoluciones_venta`, `fact_recepciones` |

Power BI suele crear solas las relaciones por nombre de columna. Revisar en **Administrar relaciones** que todas queden de `fact_*` (varios) a `dim_*` (uno), y crear a mano las que falten.

Marcar `dim_tiempo` como **tabla de fechas** (columna `fecha`). El SP la carga por años completos, que es lo que pide Power BI.

## 3. Medidas DAX

```DAX
-- KPI 1: Facturación Neta
Facturacion Neta = SUM ( fact_facturacion[importe_neto] )

Facturacion Mes Anterior =
CALCULATE ( [Facturacion Neta], DATEADD ( dim_tiempo[fecha], -1, MONTH ) )

Variacion vs Mes Anterior % =
DIVIDE ( [Facturacion Neta] - [Facturacion Mes Anterior], [Facturacion Mes Anterior] )

-- KPI 2: Tasa de Rechazo
Motores Ensamblados = SUM ( fact_calidad[cantidad_ensamblada] )
Motores Rechazados = SUM ( fact_calidad[cantidad_rechazada] )
Tasa de Rechazo % = DIVIDE ( [Motores Rechazados], [Motores Ensamblados] )

-- KPI 3: Quiebre de Stock (última foto, solo componentes)
Ultima Foto = MAX ( fact_stock[sk_tiempo] )

Componentes en Quiebre =
VAR ultima = [Ultima Foto]
RETURN CALCULATE (
    DISTINCTCOUNT ( fact_stock[sk_articulo] ),
    fact_stock[sk_tiempo] = ultima,
    fact_stock[bajo_punto_pedido] = 1,
    dim_articulo[categoria] = "Componente"
)

Total Componentes =
VAR ultima = [Ultima Foto]
RETURN CALCULATE (
    DISTINCTCOUNT ( fact_stock[sk_articulo] ),
    fact_stock[sk_tiempo] = ultima,
    dim_articulo[categoria] = "Componente"
)

% Quiebre de Stock = DIVIDE ( [Componentes en Quiebre], [Total Componentes] )
```

Se usa `DISTINCTCOUNT` porque un componente con dos proveedores aparece en dos filas de `fact_stock`.

```DAX
-- Para los graficos
Motores Vendidos =
CALCULATE ( SUM ( fact_facturacion[cantidad_neta] ), dim_articulo[categoria] = "Motor terminado" )

Stock Valorizado =
VAR ultima = MAX ( fact_stock[sk_tiempo] )
RETURN SUMX (
    VALUES ( fact_stock[sk_articulo] ),
    CALCULATE ( MAX ( fact_stock[valor_disponible] ), fact_stock[sk_tiempo] = ultima )
)

% Rechazo por Causa =
DIVIDE (
    SUM ( fact_calidad[cantidad_rechazada] ),
    CALCULATE ( SUM ( fact_calidad[cantidad_ensamblada] ), REMOVEFILTERS ( dim_resultado_control ) )
)

Compras Netas = SUM ( fact_compras[importe_neto] )
```

`Stock Valorizado` usa `SUMX` sobre los artículos por lo mismo: si sumara directo, un componente con dos proveedores contaría dos veces. `% Rechazo por Causa` divide por el total ensamblado, sin el filtro de la causa, así las barras suman la tasa de rechazo total.

## 4. Gráficos
| Gráfico | Visual | Eje X / categoría | Valor | Detalle |
|---|---|---|---|---|
| Motores vendidos por mes | Gráfico de líneas | `dim_tiempo[anio_mes]` | `[Motores Vendidos]` | Ordenar el eje por `anio_mes` ascendente |
| Facturación por mes | Gráfico de columnas | `dim_tiempo[anio_mes]` | `[Facturacion Neta]` | |
| Stock valorizado por categoría | Gráfico de barras | `dim_articulo[tipo_articulo]` | `[Stock Valorizado]` | Para ver solo motores vs. componentes, usar `dim_articulo[categoria]` |
| % de rechazo por causa | Gráfico de barras | `dim_resultado_control[causa]` | `[% Rechazo por Causa]` | Filtro del visual: `causa` distinto de "Sin falla". Formato de la medida: porcentaje |
| Compras por mes | Gráfico de columnas | `dim_tiempo[anio_mes]` | `[Compras Netas]` | |

Para armar cada uno: clic en el lienzo vacío, elegir el visual en el panel **Visualizaciones**, y arrastrar los campos del panel **Datos** a los casilleros de la tabla.

## 5. Hojas del tablero

Dos medidas más, además de las de la sección 3:

```DAX
-- Facturacion del ultimo mes que tiene datos (no depende
-- de la fecha de hoy ni de los filtros de fecha)
Facturacion Ultimo Mes =
VAR ultimoSk = CALCULATE ( MAX ( fact_facturacion[sk_tiempo] ), REMOVEFILTERS ( dim_tiempo ) )
VAR ultimoMes = INT ( ultimoSk / 100 )
RETURN CALCULATE (
    [Facturacion Neta],
    REMOVEFILTERS ( dim_tiempo ),
    INT ( dim_tiempo[sk_tiempo] / 100 ) = ultimoMes
)

-- Recepciones que llegaron despues de la fecha de la OC
-- mas los dias de entrega del proveedor
% Entregas Atrasadas Compras =
DIVIDE ( SUM ( fact_recepciones[entregado_tarde] ), COUNTROWS ( fact_recepciones ) )
```

Formato: las medidas que empiezan con `%` y `Tasa de Rechazo %` van como **Porcentaje** (Herramientas de medición → Formato), y las de importes como **Moneda**.

**Hoja Facturación**
| Visual | Configuración | Valor esperado* |
|---|---|---|
| Barras | Eje Y `dim_cliente[segmento]`, valor `[Facturacion Ultimo Mes]` | Junio 2026: Exportación 6.860.000, Corporativo 6.460.000, Minorista 4.100.000, Distribuidor 570.000, Mayorista −230.000 |
| Líneas | Eje X `dim_tiempo[anio_mes]`, valor `[Facturacion Neta]` | Total 632.426.000 |
| Líneas | Eje X `dim_tiempo[anio_mes]`, valor `[Motores Vendidos]` | Junio 2026: 90 bombas |

**Hoja Rechazo**
| Visual | Configuración | Valor esperado* |
|---|---|---|
| Tarjeta | `[Tasa de Rechazo %]` | 7,34 % |
| Barras | Eje Y `dim_resultado_control[causa]`, valor `[% Rechazo por Causa]`, filtro del visual sin "Sin falla" | Vibración / Ruido 6,63 %, Eléctrica 0,40 %, Bobinado 0,30 % |

**Hoja Stock**
| Visual | Configuración | Valor esperado* |
|---|---|---|
| Tarjeta | `[Stock Valorizado]` | 219.450.000 |
| Barras | Eje Y `dim_articulo[categoria]`, valor `[Stock Valorizado]` | Componente 113.450.000, Motor terminado 106.000.000 |
| Tarjeta | `[% Quiebre de Stock]` | 5 % (2 de 40) |
| Tarjeta | `[% Entregas Atrasadas Compras]` | 25,47 % (27 de 106) |

\* Con los datos de prueba de `pruebas_punto5.sql` cargados. El −230.000 de Mayorista es la nota de crédito de prueba.

## 6. Para la demo en vivo
1. Correr `CALL MotorsPasz_DW.sp_etl_motorspasz(NULL);` en Workbench.
2. En Power BI, hacer clic en **Actualizar**. Los números cambian sin tocar el modelo.
3. Mostrar `etl_ejecucion` y `etl_descartes` para explicar el criterio de curaduría.
