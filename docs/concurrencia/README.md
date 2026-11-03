# Demostración de concurrencia: la última botella

**Etapa 2 · paso 8 · RN-09** — Dos sesiones intentan vender al mismo tiempo la última botella de un vino en una sala. Se muestra qué pasa **sin** bloqueo, **con** `SELECT ... FOR UPDATE` y con **el sistema real** (venta por `INSERT` en `renglon_comprobante`), y se explica el nivel de aislamiento utilizado.

## Cómo se ejecuta

```powershell
powershell -ExecutionPolicy Bypass -File docs\concurrencia\ejecutar_demo.ps1
```

El script toma una fila real de `stock_sala`, la pone en **1 botella** antes de cada escenario y lanza dos `psql` en paralelo: la sesión **A** arranca primero y la **B**, medio segundo después. Cada paso imprime la hora con milisegundos (`clock_timestamp()`), y la salida de ambas sesiones se ordena por hora. Al terminar, borra los comprobantes de la demo y repone el stock original: **la base queda como estaba**. El resultado se guarda en `resultado_demo.txt`.

| Archivo | Sesión | Qué hace |
|---|---|---|
| `1a_sin_bloqueo_sesion_A.sql` / `1b_...B.sql` | A / B | Lee el stock con `SELECT`, espera 2 s ("el usuario confirma") y escribe `stock := leído − 1` |
| `2a_for_update_sesion_A.sql` / `2b_...B.sql` | A / B | Igual, pero lee con `SELECT ... FOR UPDATE` |
| `3a_trigger_sesion_A.sql` / `3b_...B.sql` | A / B | Vende como lo hace la API: `INSERT` del comprobante y del renglón; el trigger valida y descuenta |

Para hacerlo a mano en dos terminales `psql`, se pueden ejecutar los mismos archivos pasando las variables `-v sala=1 -v vino=16 -v cliente=1`.

## Nivel de aislamiento

Todas las sesiones usan **READ COMMITTED**, el nivel por defecto de PostgreSQL (cada script lo imprime con `current_setting('transaction_isolation')`). En READ COMMITTED:

- Cada **sentencia** ve los datos confirmados hasta el momento en que **esa sentencia** empieza. Dos `SELECT` comunes no se bloquean entre sí, aunque estén dentro de transacciones abiertas.
- Un `UPDATE`, un `DELETE` o un `SELECT ... FOR UPDATE` sobre una fila que otra transacción tiene bloqueada **espera** a que esa transacción termine. Cuando la otra confirma, PostgreSQL **vuelve a leer la versión nueva de la fila** y reevalúa la condición antes de seguir.

Esa segunda regla explica la diferencia entre los tres escenarios.

## Resultado

Corrida en PostgreSQL con la base cargada (fila: sala 1, vino 16).

### Escenario 1 · Sin bloqueo → la misma botella se vende dos veces

```
12:34:30.533  A  aislamiento: read committed
12:34:30.535  A  SELECT cantidad  -> 1 botella(s). Hay stock: vendo.
12:34:31.035  B  aislamiento: read committed
12:34:31.036  B  SELECT cantidad  -> 1 botella(s). Hay stock: vendo.
12:34:32.543  A  UPDATE stock := 1 - 1
12:34:32.546  A  COMMIT
12:34:33.041  B  UPDATE stock := 1 - 1
12:34:33.042  B  COMMIT
Stock final: 0 botella(s)
```

**Qué pasó.** B lee mientras A todavía no confirmó, así que en READ COMMITTED ve el valor confirmado: 1. **Las dos sesiones deciden vender.** Cada una escribe el valor que calculó con su lectura (1 − 1 = 0). Hubo **dos ventas y el stock bajó una sola vez**: es una **actualización perdida** (*lost update*). Ninguna restricción lo detecta, porque 0 es un valor válido.

> **Variante.** Si la aplicación escribiera `SET cantidad = cantidad - 1` en lugar del valor calculado, el `UPDATE` de B esperaría a que A confirme, volvería a leer la fila (0) y calcularía −1. Ahí el `CHECK (cantidad >= 0)` de `stock_sala` rechazaría la sentencia. Es la última barrera de la base: evita el stock negativo, pero recién **después** de que la aplicación le confirmó la venta al usuario.

### Escenario 2 · Con `SELECT ... FOR UPDATE` → B espera y rechaza

```
12:34:33.179  A  aislamiento: read committed
12:34:33.180  A  SELECT ... FOR UPDATE -> 1 botella(s). Fila bloqueada. Vendo.
12:34:33.692  B  SELECT ... FOR UPDATE (si A tiene la fila, espera)
12:34:35.186  A  UPDATE stock := stock - 1
12:34:35.194  A  COMMIT (libera el bloqueo)
12:34:35.201  B  obtuvo la fila -> 0 botella(s). Sin stock: la venta se rechaza.
12:34:35.202  B  ROLLBACK
Stock final: 0 botella(s)
```

**Qué pasó.** `FOR UPDATE` toma un **bloqueo de fila** que dura hasta el fin de la transacción. B pide la misma fila a las 33.692 y **queda esperando 1,5 s**, hasta que A confirma a las 35.194. Recién ahí obtiene la fila, **ya con el valor nuevo (0)**, y la venta se rechaza. Las operaciones de lectura y decisión quedan **serializadas** para esa fila, sin bloquear el resto de la tabla.

### Escenario 3 · El sistema real → el trigger hace el bloqueo

```
12:34:35.337  A  INSERT comprobante 150001
12:34:35.340  A  INSERT renglón (1 botella): el trigger bloqueó la fila de stock y la descontó
12:34:35.851  B  INSERT comprobante 150002
12:34:35.851  B  INSERT renglón (1 botella): espera a que A libere la fila de stock...
12:34:37.344  A  COMMIT
12:34:37.346  B  RECHAZADA: Stock insuficiente del vino 16 en la sala 1 (disponible: 0, solicitado: 1). (RN-09) -> ROLLBACK (no queda nada a medias)
Stock final: 0 botella(s)
```

**Qué pasó.** La aplicación no escribe ningún `FOR UPDATE`: lo hace la base. El trigger `trg_validar_stock_venta` (BEFORE INSERT en `renglon_comprobante`, ver `db/migrations/005_triggers.sql`) lee la fila de `stock_sala` **con `FOR UPDATE`**. El `INSERT` de B espera hasta el `COMMIT` de A, lee el stock actualizado (0) y el trigger lanza la excepción de **RN-09**. B hace `ROLLBACK` y su comprobante tampoco queda grabado: **no hay datos a medias**.

Esta es la razón por la que la regla vive en la base y no en la API: **cualquier** cliente (la API, el front, `psql` o un script) queda protegido, aunque no sepa nada de bloqueos.

## Resumen

| Escenario | ¿B espera? | Ventas | Stock final | Correcto |
|---|---|---:|---:|---|
| 1 · Sin bloqueo | No | 2 | 0 | ❌ actualización perdida |
| 2 · `SELECT ... FOR UPDATE` | Sí (≈1,5 s) | 1 | 0 | ✅ |
| 3 · Sistema real (trigger RN-09) | Sí (≈1,5 s) | 1 | 0 | ✅ y rechazo con mensaje claro |

**¿Por qué no usar SERIALIZABLE?** Con `SERIALIZABLE`, el escenario 1 también se resolvería: una de las dos transacciones fallaría con error `40001` (*serialization failure*) y habría que reintentarla. Se eligió **READ COMMITTED + bloqueo de fila en el trigger** porque:

- no obliga a la API a implementar reintentos en todas las operaciones;
- bloquea solo la fila involucrada (sala + vino), no el resto de las ventas;
- falla con el mensaje de la regla de negocio (RN-09), que la API traduce a HTTP 409.

En la Etapa 6, la API igual traduce `40001` y `40P01` (deadlock) a HTTP 503 con reintento sugerido. Para evitar deadlocks, `sp_procesar_transferencia` bloquea las filas de stock siempre en el mismo orden (por `cod_vino`).
