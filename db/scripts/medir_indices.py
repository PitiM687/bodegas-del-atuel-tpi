#!/usr/bin/env python3
"""
medir_indices.py · Bodegas del Atuel · Etapa 4: índices y rendimiento.

Mide, sobre la base ya cargada (seed_db.py):

  1. Cada consulta de docs/etapa4/consultas_medidas.sql con
     EXPLAIN (ANALYZE, BUFFERS) SOLO con los índices de PK y UNIQUE
     (borra los de 008_indices.sql si existen).
  2. Crea los índices de db/migrations/008_indices.sql (midiendo el tiempo
     de creación y el tamaño de cada uno), ejecuta ANALYZE y repite las
     mediciones.
  3. Experimentos del informe:
       a. orden de columnas del índice compuesto: (id_sala, fecha) vs (fecha, id_sala)
       b. BRIN vs. B-tree sobre comprobante.fecha
       c. índice evaluado y descartado: cliente (tipo)
       d. casos en que el planificador NO usa un índice existente
       e. costo de escritura: carga de las tablas grandes con y sin índices
       f. costo de borrar un vino (control de la FK) con y sin índice
  4. Escribe docs/etapa4/resultados.md (tablas) y docs/etapa4/anexo_planes.md
     (planes completos). Deja la base con los índices de 008 creados.

Cada consulta se ejecuta una vez para calentar la caché y después REPETICIONES
veces; se informa la MEDIANA del Execution Time.

Conexión: variables PG* o .env de la raíz (igual que seed_db.py). Conviene
ejecutarlo como propietario (dueño de las tablas, puede crear índices).

Uso:  python db/scripts/medir_indices.py
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import statistics
import sys
import time
from pathlib import Path

import psycopg2

REPO = Path(__file__).resolve().parents[2]
CONSULTAS = REPO / "docs" / "etapa4" / "consultas_medidas.sql"
INDICES = REPO / "db" / "migrations" / "008_indices.sql"
SALIDA = REPO / "docs" / "etapa4"
REPETICIONES = 5

TABLAS = ["localidad", "sala_venta", "empleado", "departamento", "finca", "cepa", "parcela", "bodega",
          "lote_uva", "analisis_calidad", "vino", "composicion_vino", "maridaje", "vino_maridaje",
          "cliente", "socio", "distribuidor", "exportador", "permiso_exportacion", "comprobante",
          "renglon_comprobante", "transportista", "transportista_localidad", "ingreso",
          "renglon_ingreso", "transferencia", "renglon_transferencia", "stock_sala",
          "stock_deposito", "auditoria_precio"]


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
def cargar_env() -> None:
    env = REPO / ".env"
    if env.exists():
        for linea in env.read_text(encoding="utf-8").splitlines():
            if "=" in linea and not linea.lstrip().startswith("#"):
                k, v = linea.split("=", 1)
                if v.strip():
                    os.environ.setdefault(k.strip(), v.strip())


def leer_consultas() -> list[dict]:
    texto = CONSULTAS.read_text(encoding="utf-8")
    consultas = []
    for bloque in re.split(r"^-- @", texto, flags=re.M)[1:]:
        cabecera, sql = bloque.split("\n", 1)
        cid, titulo, consigna = [x.strip() for x in cabecera.split("|")]
        consultas.append(dict(id=cid, titulo=titulo, consigna=consigna, sql=sql.strip().rstrip(";")))
    return consultas


def leer_indices() -> list[tuple[str, str]]:
    """Devuelve [(nombre, sentencia CREATE INDEX)] de 008_indices.sql."""
    texto = re.sub(r"--[^\n]*", "", INDICES.read_text(encoding="utf-8"))
    sentencias = [s.strip() for s in texto.split(";") if s.strip()]
    return [(re.search(r"CREATE INDEX\s+(?:IF NOT EXISTS\s+)?(\w+)", s, re.I).group(1), s)
            for s in sentencias if re.match(r"CREATE INDEX", s, re.I)]


def analyze(cur) -> None:
    cur.execute("ANALYZE " + ", ".join(TABLAS))


def vacuum(cur) -> None:
    """Limpia tuplas muertas (p. ej. de inserciones revertidas) para que no
    distorsionen las mediciones, y actualiza estadísticas."""
    cur.execute("VACUUM (ANALYZE) " + ", ".join(TABLAS))


def nodos(plan: dict):
    yield plan
    for hijo in plan.get("Plans", []):
        yield from nodos(hijo)


def resumen_plan(plan: dict) -> dict:
    """Recorridos sobre tablas, filas leídas y buffers del plan (JSON)."""
    recorridos, leidas = [], 0
    for n in nodos(plan["Plan"]):
        tipo = n["Node Type"]
        if "Relation Name" in n or tipo in ("Bitmap Index Scan",):
            loops = n.get("Actual Loops", 1)
            filas = (n.get("Actual Rows", 0) + n.get("Rows Removed by Filter", 0)
                     + n.get("Rows Removed by Index Recheck", 0)) * loops
            if tipo == "Bitmap Index Scan":
                recorridos.append(f"Bitmap Index Scan ({n['Index Name']})")
                continue
            etiqueta = tipo + (f" ({n['Index Name']})" if "Index Name" in n else "")
            recorridos.append(f"{etiqueta} en {n['Relation Name']}")
            leidas += filas
    top = plan["Plan"]
    triggers = [(t.get("Constraint Name", t["Trigger Name"]), t.get("Relation", ""), t["Time"]) for t in plan.get("Triggers", [])]
    # PostgreSQL 18 informa Actual Rows con decimales (promedio por iteración): se redondea.
    return dict(tiempo=plan["Execution Time"], recorridos=recorridos, filas_leidas=round(leidas), triggers=triggers,
                buffers=top.get("Shared Hit Blocks", 0) + top.get("Shared Read Blocks", 0))


def medir(cur, sql: str, rollback: bool = False) -> dict:
    """EXPLAIN (ANALYZE, BUFFERS): mediana de REPETICIONES, plan JSON y texto."""
    def una(formato: str):
        if rollback:
            cur.execute("SAVEPOINT medicion")
        cur.execute(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT {formato}) {sql}")
        filas = cur.fetchall()
        if rollback:
            cur.execute("ROLLBACK TO SAVEPOINT medicion")
        return filas

    una("JSON")                                         # calentamiento
    corridas = []
    for _ in range(REPETICIONES):
        plan = una("JSON")[0][0][0]
        corridas.append((plan["Execution Time"], plan))
    corridas.sort(key=lambda x: x[0])
    mediana_plan = corridas[len(corridas) // 2][1]
    texto = "\n".join(f[0] for f in una("TEXT"))
    r = resumen_plan(mediana_plan)
    r["mediana"] = statistics.median(t for t, _ in corridas)
    r["texto"] = texto
    r["usa_indice"] = any("Index" in x for x in r["recorridos"])
    return r


def tamano(cur, rel: str) -> int:
    cur.execute("SELECT pg_relation_size(%s::regclass)", (rel,))
    return cur.fetchone()[0]


def fmt_bytes(n: int) -> str:
    for unidad in ("B", "kB", "MB", "GB"):
        if n < 1024 or unidad == "GB":
            return f"{n:,.0f} {unidad}" if unidad == "B" else f"{n:,.1f} {unidad}"
        n /= 1024
    return str(n)


def ms(x: float) -> str:
    return f"{x:,.3f}" if x < 1 else f"{x:,.2f}" if x < 100 else f"{x:,.1f}"


# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------
def main() -> int:
    cargar_env()
    conn = psycopg2.connect()
    conn.autocommit = True
    cur = conn.cursor()
    # Si otra sesión tiene bloqueada una tabla (p. ej. pgAdmin o DBeaver con una
    # transacción abierta), DROP/CREATE INDEX esperaría indefinidamente: mejor
    # fallar a los 15 s con un mensaje claro.
    cur.execute("SET lock_timeout = '15s'")
    cur.execute("SELECT version(), current_user, current_setting('server_version')")
    version, usuario, ver_corta = cur.fetchone()
    print(f"{version}\nUsuario: {usuario}\n")

    consultas = leer_consultas()
    indices = leer_indices()
    anexo = [f"# Anexo · Planes de ejecución completos\n\nPostgreSQL {ver_corta}. "
             f"Generado por `db/scripts/medir_indices.py` el {dt.datetime.now():%Y-%m-%d %H:%M}. "
             "Cada plan es `EXPLAIN (ANALYZE, BUFFERS)` de una ejecución con la caché ya caliente.\n"]

    # --- 1. Antes: solo PK y UNIQUE ------------------------------------------
    print("[1/4] Midiendo SIN los índices de 008 (solo PK y UNIQUE)")
    for nombre, _ in indices:
        cur.execute(f"DROP INDEX IF EXISTS {nombre}")
    vacuum(cur)
    antes = {}
    for q in consultas:
        antes[q["id"]] = medir(cur, q["sql"])
        print(f"   {q['id']:<4} {antes[q['id']]['mediana']:>9.3f} ms  {', '.join(antes[q['id']]['recorridos'][:3])}")

    # Borrar un vino sin movimientos: mide el control de las FK de RN-14. Se crea
    # un vino de prueba dentro de una transacción que después se revierte.
    def medir_borrado_vino():
        cur.execute("BEGIN")
        cur.execute("""INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega)
                       VALUES ('ETAPA4 vino de prueba', 'tinto', 2024, 750, 13.5, 1000,
                               (SELECT cuit FROM bodega ORDER BY cuit LIMIT 1))
                       RETURNING cod_vino""")
        cod = cur.fetchone()[0]
        cur.execute("INSERT INTO composicion_vino VALUES (%s, (SELECT min(id_cepa) FROM cepa), 100)", (cod,))
        r = medir(cur, f"DELETE FROM vino WHERE cod_vino = {cod}", rollback=True)
        cur.execute("ROLLBACK")
        return r
    sql_borrar = "DELETE FROM vino WHERE cod_vino = <vino nuevo sin movimientos>"
    borrar_antes = medir_borrado_vino()
    print(f"   RN-14 {borrar_antes['mediana']:>9.3f} ms  borrar un vino sin movimientos (control de las FK)")

    # --- 2. Crear los índices ---------------------------------------------------
    print("[2/4] Creando los índices de 008_indices.sql")
    creacion = []
    for nombre, sentencia in indices:
        t0 = time.perf_counter()
        cur.execute(sentencia)
        seg = time.perf_counter() - t0
        creacion.append((nombre, sentencia, seg, tamano(cur, nombre)))
        print(f"   {nombre:<34} {seg:6.2f} s  {fmt_bytes(creacion[-1][3])}")
    analyze(cur)

    print("[3/4] Midiendo CON los índices")
    despues = {}
    for q in consultas:
        despues[q["id"]] = medir(cur, q["sql"])
        a, d = antes[q["id"]]["mediana"], despues[q["id"]]["mediana"]
        print(f"   {q['id']:<4} {d:>9.3f} ms  (antes {a:.3f} ms, ×{a / d:,.1f})  {', '.join(despues[q['id']]['recorridos'][:3])}")
    borrar_despues = medir_borrado_vino()
    print(f"   RN-14 {borrar_despues['mediana']:>9.3f} ms  (antes {borrar_antes['mediana']:.3f} ms, "
          f"×{borrar_antes['mediana'] / borrar_despues['mediana']:,.1f})")

    # --- 3. Experimentos -----------------------------------------------------------
    print("[4/4] Experimentos")
    q = {c["id"]: c for c in consultas}
    exp = {}

    # a. Orden de columnas del compuesto (S3)
    cur.execute("DROP INDEX ix_comprobante_sala_fecha")
    cur.execute("CREATE INDEX ix_tmp_fecha_sala ON comprobante (fecha, id_sala)")
    analyze(cur)
    # Ventas mensuales de una sala en toda su historia (vw_ventas_mensuales_sala filtrada por sala):
    # solo hay condición sobre id_sala.
    sql_sala_anio = ("SELECT date_trunc('month', fecha) AS mes, SUM(total) FROM comprobante "
                     "WHERE id_sala = 5 GROUP BY 1 ORDER BY 1")
    exp["orden_inverso"] = medir(cur, q["S3"]["sql"])
    exp["orden_inverso_anio"] = medir(cur, sql_sala_anio)
    exp["orden_inverso_tam"] = tamano(cur, "ix_tmp_fecha_sala")
    cur.execute("DROP INDEX ix_tmp_fecha_sala")
    cur.execute(dict((n, s) for n, s in indices)["ix_comprobante_sala_fecha"])
    analyze(cur)
    exp["orden_bueno_anio"] = medir(cur, sql_sala_anio)
    print(f"   a. historia de la sala 5: (fecha, id_sala) {exp['orden_inverso_anio']['mediana']:.3f} ms vs "
          f"(id_sala, fecha) {exp['orden_bueno_anio']['mediana']:.3f} ms")
    print(f"   a. S3 con (fecha, id_sala): {exp['orden_inverso']['mediana']:.3f} ms "
          f"vs (id_sala, fecha): {despues['S3']['mediana']:.3f} ms")

    # b. BRIN vs B-tree en comprobante.fecha (S8)
    cur.execute("DROP INDEX ix_comprobante_fecha_brin")
    cur.execute("CREATE INDEX ix_tmp_fecha_btree ON comprobante (fecha)")
    analyze(cur)
    exp["btree_fecha"] = medir(cur, q["S8"]["sql"])
    exp["btree_fecha_tam"] = tamano(cur, "ix_tmp_fecha_btree")
    cur.execute("DROP INDEX ix_tmp_fecha_btree")
    cur.execute(dict((n, s) for n, s in indices)["ix_comprobante_fecha_brin"])
    analyze(cur)
    print(f"   b. S8 con B-tree(fecha): {exp['btree_fecha']['mediana']:.3f} ms "
          f"({fmt_bytes(exp['btree_fecha_tam'])}) vs BRIN: {despues['S8']['mediana']:.3f} ms")

    # c. Índice descartado: cliente (tipo)
    sql_tipo = ("SELECT tipo, COUNT(*) FROM cliente cl JOIN comprobante c USING (id_cliente) "
                "WHERE cl.tipo = '{}' GROUP BY tipo")
    cur.execute("SELECT tipo::text, COUNT(*), ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) "
                "FROM cliente GROUP BY tipo ORDER BY 2 DESC")
    exp["dist_tipo"] = cur.fetchall()
    exp["tipo_sin"] = {t: medir(cur, sql_tipo.format(t)) for t in ("socio", "exportador")}
    cur.execute("CREATE INDEX ix_tmp_cliente_tipo ON cliente (tipo)")
    analyze(cur)
    exp["tipo_con"] = {t: medir(cur, sql_tipo.format(t)) for t in ("socio", "exportador")}
    exp["tipo_tam"] = tamano(cur, "ix_tmp_cliente_tipo")
    cur.execute("DROP INDEX ix_tmp_cliente_tipo")
    analyze(cur)
    print("   c. cliente(tipo): " + ", ".join(
        f"{t} {exp['tipo_sin'][t]['mediana']:.2f}→{exp['tipo_con'][t]['mediana']:.2f} ms"
        f"{' (lo usa)' if any('ix_tmp_cliente_tipo' in r for r in exp['tipo_con'][t]['recorridos']) else ' (NO lo usa)'}"
        for t in ("socio", "exportador")))

    # d. El planificador no usa un índice existente (baja selectividad): S1 y S12
    #    necesitan todas las filas de renglon_comprobante aunque exista
    #    ix_renglon_comprobante_vino, y 'socio' es el 80 % de los clientes.
    exp["s1_con"] = despues["S1"]
    exp["s12_con"] = despues["S12"]
    print(f"   d. S1: {', '.join(despues['S1']['recorridos'])} · S12: {', '.join(despues['S12']['recorridos'][:2])}")

    # Estadísticas desactualizadas: 20.000 comprobantes nuevos de una sala sin ANALYZE.
    cur.execute("BEGIN")
    cur.execute("SELECT COALESCE(MAX(nro), 0) FROM comprobante")
    max_nro = cur.fetchone()[0]
    cur.execute("ALTER TABLE comprobante DISABLE TRIGGER USER")
    cur.execute(f"""INSERT INTO comprobante (nro, fecha, id_cliente, id_sala, subtotal, descuento, total)
                    OVERRIDING SYSTEM VALUE
                    SELECT {max_nro} + g, CURRENT_DATE, 1, 1, 0, 0, 0 FROM generate_series(1, 60000) g""")
    sql_stale = "SELECT COUNT(*), SUM(total) FROM comprobante WHERE id_sala = 1 AND fecha = CURRENT_DATE"
    def estimacion():
        cur.execute(f"EXPLAIN (ANALYZE, FORMAT JSON) {sql_stale}")
        plan = cur.fetchone()[0][0]
        scan = [n for n in nodos(plan["Plan"]) if n["Node Type"] in ("Bitmap Index Scan", "Index Scan",
                                                                     "Index Only Scan", "Seq Scan")][0]
        return dict(nodo=scan["Node Type"] + (f" ({scan['Index Name']})" if "Index Name" in scan else ""),
                    estimadas=round(scan["Plan Rows"]), reales=round(scan["Actual Rows"]))
    exp["stale_sin"] = medir(cur, sql_stale)
    exp["stale_sin_est"] = estimacion()
    cur.execute("ANALYZE comprobante")
    exp["stale_con"] = medir(cur, sql_stale)
    exp["stale_con_est"] = estimacion()
    cur.execute("ROLLBACK")
    vacuum(cur)            # las 60.000 filas revertidas quedan como tuplas muertas
    print(f"   d. estadísticas viejas: estimadas {exp['stale_sin_est']['estimadas']} vs reales {exp['stale_sin_est']['reales']}, "
          f"tras ANALYZE estimadas {exp['stale_con_est']['estimadas']} · "
          f"{', '.join(exp['stale_sin']['recorridos'])} "
          f"{exp['stale_sin']['mediana']:.1f} ms → tras ANALYZE: {', '.join(exp['stale_con']['recorridos'])} "
          f"{exp['stale_con']['mediana']:.1f} ms")

    # e. Costo de escritura: copiar las tablas grandes con y sin índices.
    escritura = []
    for tabla, idx in [("comprobante", ["(id_sala, fecha)", "USING brin (fecha)", "(id_cliente)"]),
                       ("renglon_comprobante", ["(cod_vino)"])]:
        cur.execute(f"SELECT COUNT(*) FROM {tabla}")
        n = cur.fetchone()[0]
        res = {}
        for con_indices in (False, True):
            cur.execute("DROP TABLE IF EXISTS etapa4_copia")
            cur.execute(f"CREATE TABLE etapa4_copia (LIKE {tabla} INCLUDING DEFAULTS INCLUDING CONSTRAINTS)")
            cur.execute("SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY array_position(i.indkey, a.attnum)) "
                        "FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey) "
                        "WHERE i.indrelid = %s::regclass AND i.indisprimary", (tabla,))
            cur.execute(f"ALTER TABLE etapa4_copia ADD PRIMARY KEY ({cur.fetchone()[0]})")
            if con_indices:
                for k, definicion in enumerate(idx):
                    cur.execute(f"CREATE INDEX etapa4_copia_ix{k} ON etapa4_copia {definicion}")
            cur.execute("CHECKPOINT") if usuario == "postgres" else None
            tiempos = []
            for _ in range(3):
                cur.execute("TRUNCATE etapa4_copia")
                t0 = time.perf_counter()
                cur.execute(f"INSERT INTO etapa4_copia SELECT * FROM {tabla}")
                tiempos.append(time.perf_counter() - t0)
            cur.execute("SELECT pg_indexes_size('etapa4_copia')")
            res[con_indices] = (statistics.median(tiempos), cur.fetchone()[0])
        cur.execute("DROP TABLE etapa4_copia")
        escritura.append((tabla, n, idx, res[False], res[True]))
        print(f"   e. {tabla} ({n:,} filas): sin {res[False][0]:.2f} s · con {res[True][0]:.2f} s "
              f"(+{100 * (res[True][0] / res[False][0] - 1):.0f} %)")

    analyze(cur)

    # --- 4. Reportes ------------------------------------------------------------------
    R = [f"# Resultados de las mediciones · Etapa 4\n",
         f"- Servidor: `{version}`",
         f"- Fecha: {dt.datetime.now():%Y-%m-%d %H:%M} · usuario `{usuario}` · "
         f"mediana de {REPETICIONES} ejecuciones con la caché caliente",
         "- Generado por `db/scripts/medir_indices.py`. Planes completos: [anexo_planes.md](anexo_planes.md)\n",
         "## 1. Tabla comparativa\n",
         "| Consulta | Antes (ms) | Recorrido antes | Filas leídas | Buffers | Después (ms) | Recorrido después | Filas leídas | Buffers | Mejora |",
         "|---|---:|---|---:|---:|---:|---|---:|---:|---:|"]
    filas_tabla = [(c["id"], c["titulo"], antes[c["id"]], despues[c["id"]]) for c in consultas]
    if borrar_antes:
        filas_tabla.append(("RN-14", f"Borrar un vino sin movimientos (`{sql_borrar}`, se revierte)",
                            borrar_antes, borrar_despues))
    for cid, titulo, a, d in filas_tabla:
        R.append(f"| **{cid}** {titulo} | {ms(a['mediana'])} | {'<br>'.join(a['recorridos'])} | {a['filas_leidas']:,} | "
                 f"{a['buffers']:,} | {ms(d['mediana'])} | {'<br>'.join(d['recorridos'])} | {d['filas_leidas']:,} | "
                 f"{d['buffers']:,} | ×{a['mediana'] / d['mediana']:,.1f} |")
    if borrar_antes:
        R += ["\n**Detalle del borrado de un vino (RN-14).** El `DELETE` en sí es instantáneo: el tiempo está en los "
              "triggers internos que controlan cada clave foránea que apunta a `vino`.\n",
              "| Clave foránea controlada | Antes (ms) | Después (ms) |", "|---|---:|---:|"]
        despues_t = {n: t for n, _, t in borrar_despues["triggers"]}
        for nombre, rel, t in sorted(borrar_antes["triggers"], key=lambda x: -x[2]):
            R.append(f"| `{nombre}` | {ms(t)} | {ms(despues_t.get(nombre, 0))} |")
    R += ["\n*Filas leídas*: filas que devolvieron los nodos de recorrido de tablas más las descartadas por el filtro. "
          "*Buffers*: páginas de 8 kB leídas (de caché o de disco).\n",
          "## 2. Índices creados\n",
          "| Índice | Definición | Tiempo de creación | Tamaño |", "|---|---|---:|---:|"]
    for nombre, sentencia, seg, tam in creacion:
        definicion = re.sub(r"\s+", " ", sentencia.split(" ON ", 1)[1])
        R.append(f"| `{nombre}` | `{definicion}` | {seg:.2f} s | {fmt_bytes(tam)} |")
    R.append(f"\nTamaño de las tablas: comprobante {fmt_bytes(tamano(cur, 'comprobante'))}, "
             f"renglon_comprobante {fmt_bytes(tamano(cur, 'renglon_comprobante'))}.\n")
    oi = exp["orden_inverso"]
    R += ["## 3. Orden de columnas del índice compuesto (S3)\n",
          "| Índice | Tiempo (ms) | Recorrido | Filas leídas | Buffers | Tamaño |", "|---|---:|---|---:|---:|---:|",
          f"| `(id_sala, fecha)` (elegido) | {ms(despues['S3']['mediana'])} | {'<br>'.join(despues['S3']['recorridos'])} | "
          f"{despues['S3']['filas_leidas']:,} | {despues['S3']['buffers']:,} | "
          f"{fmt_bytes(dict((c[0], c[3]) for c in creacion)['ix_comprobante_sala_fecha'])} |",
          f"| `(fecha, id_sala)` (descartado) | {ms(oi['mediana'])} | {'<br>'.join(oi['recorridos'])} | "
          f"{oi['filas_leidas']:,} | {oi['buffers']:,} | {fmt_bytes(exp['orden_inverso_tam'])} |\n",
          "Segunda consulta: ventas mensuales de la sala 5 en toda su historia (la condición es solo `id_sala = 5`, "
          "como en `vw_ventas_mensuales_sala` filtrada por sala).\n",
          "| Índice | Tiempo (ms) | Recorrido | Buffers |", "|---|---:|---|---:|",
          f"| `(id_sala, fecha)` | {ms(exp['orden_bueno_anio']['mediana'])} | {'<br>'.join(exp['orden_bueno_anio']['recorridos'])} | {exp['orden_bueno_anio']['buffers']:,} |",
          f"| `(fecha, id_sala)` | {ms(exp['orden_inverso_anio']['mediana'])} | {'<br>'.join(exp['orden_inverso_anio']['recorridos'])} | {exp['orden_inverso_anio']['buffers']:,} |\n"]
    bt = exp["btree_fecha"]
    R += ["## 4. BRIN vs. B-tree sobre comprobante.fecha (S8)\n",
          "| Índice | Tiempo (ms) | Recorrido | Buffers | Tamaño |", "|---|---:|---|---:|---:|",
          f"| BRIN (elegido) | {ms(despues['S8']['mediana'])} | {'<br>'.join(despues['S8']['recorridos'])} | "
          f"{despues['S8']['buffers']:,} | {fmt_bytes(dict((c[0], c[3]) for c in creacion)['ix_comprobante_fecha_brin'])} |",
          f"| B-tree | {ms(bt['mediana'])} | {'<br>'.join(bt['recorridos'])} | {bt['buffers']:,} | "
          f"{fmt_bytes(exp['btree_fecha_tam'])} |\n"]
    R += ["## 5. Índice evaluado y descartado: cliente (tipo)\n",
          "Distribución: " + ", ".join(f"{t} {n:,} ({p} %)" for t, n, p in exp["dist_tipo"]) + "\n",
          "| Consulta | Sin índice (ms) | Con índice (ms) | Recorrido con el índice creado |", "|---|---:|---:|---|"]
    for t in ("socio", "exportador"):
        R.append(f"| Ventas de clientes `{t}` | {ms(exp['tipo_sin'][t]['mediana'])} | {ms(exp['tipo_con'][t]['mediana'])} | "
                 f"{'<br>'.join(exp['tipo_con'][t]['recorridos'])} |")
    R.append(f"\nTamaño del índice: {fmt_bytes(exp['tipo_tam'])}.\n")
    R += ["## 6. El planificador no usa un índice existente\n",
          "| Caso | Selectividad | Recorrido elegido | Tiempo (ms) |", "|---|---|---|---:|",
          f"| S1: ranking de todos los vinos · existe `ix_renglon_comprobante_vino` | 100 % de los renglones | {'<br>'.join(exp['s1_con']['recorridos'])} | {ms(exp['s1_con']['mediana'])} |",
          f"| S12: clientes que nunca compraron tinto · existen `ix_comprobante_cliente` e `ix_renglon_comprobante_vino` | todas las ventas | {'<br>'.join(exp['s12_con']['recorridos'])} | {ms(exp['s12_con']['mediana'])} |",
          f"| Ventas de clientes `socio` · existe `cliente (tipo)` (sección 5) | {exp['dist_tipo'][0][2]} % de los clientes | {'<br>'.join(exp['tipo_con']['socio']['recorridos'])} | {ms(exp['tipo_con']['socio']['mediana'])} |",
          "",
          "**Estadísticas desactualizadas.** Se insertan 60.000 comprobantes de la sala 1 con fecha de hoy (dentro de "
          "una transacción que se revierte) y se consulta `id_sala = 1 AND fecha = CURRENT_DATE` antes y después de `ANALYZE`.\n",
          "| Momento | Nodo | Filas estimadas | Filas reales | Recorrido | Tiempo (ms) |", "|---|---|---:|---:|---|---:|",
          f"| Sin ANALYZE | {exp['stale_sin_est']['nodo']} | {exp['stale_sin_est']['estimadas']:,} | {exp['stale_sin_est']['reales']:,} | {'<br>'.join(exp['stale_sin']['recorridos'])} | {ms(exp['stale_sin']['mediana'])} |",
          f"| Después de ANALYZE | {exp['stale_con_est']['nodo']} | {exp['stale_con_est']['estimadas']:,} | {exp['stale_con_est']['reales']:,} | {'<br>'.join(exp['stale_con']['recorridos'])} | {ms(exp['stale_con']['mediana'])} |\n"]
    R += ["## 7. Costo de escritura\n",
          "Copia completa de cada tabla (`INSERT ... SELECT`) a una tabla nueva con la PK sola y con la PK más los "
          "índices de 008 que le corresponden. Mediana de 3 repeticiones.\n",
          "| Tabla | Filas | Índices agregados | Sin índices (s) | Con índices (s) | Sobrecosto | Tamaño de los índices sin / con |",
          "|---|---:|---|---:|---:|---:|---|"]
    for tabla, n, idx, sin, con in escritura:
        R.append(f"| {tabla} | {n:,} | {', '.join(f'`{i}`' for i in idx)} | {sin[0]:.2f} | {con[0]:.2f} | "
                 f"+{100 * (con[0] / sin[0] - 1):.0f} % | {fmt_bytes(sin[1])} / {fmt_bytes(con[1])} |")
    (SALIDA / "resultados.md").write_text("\n".join(R) + "\n", encoding="utf-8")

    for titulo, datos in [("Antes (solo PK y UNIQUE)", antes), ("Después (con 008_indices.sql)", despues)]:
        anexo.append(f"\n## {titulo}\n")
        for c in consultas:
            anexo += [f"### {c['id']} · {c['titulo']}\n", "```sql", c["sql"], "```", "```", datos[c["id"]]["texto"], "```\n"]
    if borrar_antes:
        anexo += ["\n## Borrar un vino sin movimientos (control de FK, RN-14)\n", f"`{sql_borrar}` (se revierte)\n",
                  "### Antes\n```", borrar_antes["texto"], "```", "### Después\n```", borrar_despues["texto"], "```\n"]
    anexo += ["\n## Experimentos\n",
              "### Índice compuesto en orden inverso (fecha, id_sala) · S3\n```", exp["orden_inverso"]["texto"], "```",
              "### Ventas mensuales de la sala 5 · (id_sala, fecha)\n```", exp["orden_bueno_anio"]["texto"], "```",
              "### Ventas mensuales de la sala 5 · (fecha, id_sala)\n```", exp["orden_inverso_anio"]["texto"], "```",
              "### B-tree sobre fecha · S8\n```", exp["btree_fecha"]["texto"], "```",
              "### cliente (tipo) · socio (índice creado)\n```", exp["tipo_con"]["socio"]["texto"], "```",
              "### cliente (tipo) · exportador (índice creado)\n```", exp["tipo_con"]["exportador"]["texto"], "```",
              "### Estadísticas desactualizadas · antes de ANALYZE\n```", exp["stale_sin"]["texto"], "```",
              "### Estadísticas desactualizadas · después de ANALYZE\n```", exp["stale_con"]["texto"], "```"]
    (SALIDA / "anexo_planes.md").write_text("\n".join(anexo) + "\n", encoding="utf-8")
    print(f"\nEscrito: {SALIDA / 'resultados.md'}\nEscrito: {SALIDA / 'anexo_planes.md'}")
    conn.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except psycopg2.errors.LockNotAvailable:
        print("\nERROR: otra conexión tiene bloqueada una tabla y no se pudo crear o borrar un índice.\n"
              "Cerrá pgAdmin, DBeaver o cualquier cliente con una transacción abierta sobre bodegas_atuel\n"
              "(o ejecutá COMMIT/ROLLBACK en esa sesión) y volvé a correr el script.\n"
              "Para ver quién bloquea:  SELECT pid, usename, application_name, state, query\n"
              "                         FROM pg_stat_activity WHERE datname = 'bodegas_atuel';", file=sys.stderr)
        sys.exit(2)
