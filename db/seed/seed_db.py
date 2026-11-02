#!/usr/bin/env python3
"""
seed_db.py · Bodegas del Atuel · Etapa 3: carga masiva reproducible.

Genera un dataset COHERENTE simulando la operación de la empresa día por día
durante ANIOS_HISTORIA años hasta la fecha de referencia:

  * Las bodegas envían INGRESOS al depósito central cuando el stock baja.
  * Cada sala pide TRANSFERENCIAS al depósito cada 14 días.
  * Las VENTAS solo pueden vender lo que la sala tiene en stock.
  * Los precios suben cada semestre y cada aumento queda en auditoria_precio.
  * Un vino solo se mueve después de su fecha de lanzamiento (añada + crianza).

El stock final de cada sala y del depósito es el resultado de esos movimientos,
así que la consulta de control "ingresos - transferencias - ventas = stock"
cierra exactamente.

Reproducibilidad: misma SEMILLA + misma --fecha-ref => mismos datos. El script
vacía todas las tablas (TRUNCATE ... RESTART IDENTITY) antes de cargar.

Conexión: variables de entorno de libpq (PGHOST, PGPORT, PGDATABASE, PGUSER,
PGPASSWORD). Si existe un archivo .env en la raíz del repo, se lee. Conviene
ejecutarlo con el rol propietario (dueño de las tablas).

Uso:
    python db/seed/seed_db.py                       # fecha de referencia por defecto
    python db/seed/seed_db.py --fecha-ref 2026-12-01
    python db/seed/seed_db.py --reporte docs/reporte_carga.md
"""
from __future__ import annotations

import argparse
import bisect
import csv
import datetime as dt
import io
import os
import random
import sys
import time
import traceback
from collections import defaultdict
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

import psycopg2
from psycopg2.extras import execute_values
from faker import Faker

# ---------------------------------------------------------------------------
# Parámetros
# ---------------------------------------------------------------------------
SEED = 42
FECHA_REF_DEFAULT = dt.date(2026, 11, 1)
ANIOS_HISTORIA = 6

N_BODEGAS = 20
N_TRANSPORTISTAS = 15
N_SALAS = 25
N_FINCAS = 60
N_CLIENTES = 20_000
N_COMPROBANTES = 150_000
PCT_TIPO_CLIENTE = {"socio": 0.80, "distribuidor": 0.15, "exportador": 0.05}
PCT_SOCIOS_SIN_COMPRAS = 0.04

DESCUENTO = {"socio": Decimal("10.00"), "distribuidor": Decimal("20.00"), "exportador": Decimal("30.00")}

SEED_DIR = Path(__file__).resolve().parent
REPO_DIR = SEED_DIR.parent.parent
CENT = Decimal("0.01")

# Tablas de movimientos: durante la carga histórica se deshabilitan sus
# triggers de USUARIO (los de FK siguen activos). Ver informe de la Etapa 3.
TABLAS_SIN_TRIGGERS = [
    "comprobante", "renglon_comprobante",
    "ingreso", "renglon_ingreso",
    "transferencia", "renglon_transferencia",
]

TODAS_LAS_TABLAS = [
    "localidad", "sala_venta", "empleado", "departamento", "finca", "cepa", "parcela",
    "bodega", "lote_uva", "analisis_calidad", "vino", "composicion_vino", "maridaje",
    "vino_maridaje", "cliente", "socio", "distribuidor", "exportador", "permiso_exportacion",
    "comprobante", "renglon_comprobante", "transportista", "transportista_localidad",
    "ingreso", "renglon_ingreso", "transferencia", "renglon_transferencia",
    "stock_sala", "stock_deposito", "auditoria_precio",
]

rng = random.Random(SEED)
fake = Faker("es_AR")
fake.seed_instance(SEED)


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
def cargar_env() -> None:
    """Lee un .env simple (CLAVE=valor) de la raíz del repo, sin pisar el entorno."""
    env = REPO_DIR / ".env"
    if not env.exists():
        return
    for linea in env.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if linea and not linea.startswith("#") and "=" in linea:
            k, v = linea.split("=", 1)
            if v.strip():
                os.environ.setdefault(k.strip(), v.strip())


def cuit(prefijo: int, numero: int) -> str:
    """CUIT/CUIL de 11 dígitos con dígito verificador (módulo 11)."""
    base = f"{prefijo:02d}{numero:08d}"
    pesos = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]
    resto = sum(int(d) * p for d, p in zip(base, pesos)) % 11
    dv = 0 if resto == 0 else 11 - resto
    if dv == 10:
        dv = 9
    return base + str(dv)


def fecha_aleatoria(desde: dt.date, hasta: dt.date) -> dt.date:
    return desde + dt.timedelta(days=rng.randint(0, (hasta - desde).days))


def dinero(x) -> Decimal:
    return Decimal(x).quantize(CENT, rounding=ROUND_HALF_UP)


def subtotal_renglon(cantidad: int, precio: Decimal, desc_pct: Decimal) -> Decimal:
    """Misma fórmula que fn_subtotal_renglon (ROUND a 2 decimales)."""
    return (cantidad * precio * (1 - desc_pct / 100)).quantize(CENT, rounding=ROUND_HALF_UP)


def leer_csv(nombre: str) -> list[dict]:
    with open(SEED_DIR / nombre, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


DIAS = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]


class Cronometro:
    def __init__(self):
        self.tiempos: list[tuple[str, float, int]] = []

    def medir(self, etiqueta, funcion, *args, **kw):
        t0 = time.perf_counter()
        filas = funcion(*args, **kw)
        dur = time.perf_counter() - t0
        self.tiempos.append((etiqueta, dur, filas or 0))
        print(f"   {etiqueta:<42} {filas or 0:>9,} filas  {dur:7.2f} s")
        return filas


def insertar(cur, sql: str, filas: list, page_size: int = 5000) -> int:
    if filas:
        execute_values(cur, sql, filas, page_size=page_size)
    return len(filas)


# ---------------------------------------------------------------------------
# 1. Catálogos reales (CSV)
# ---------------------------------------------------------------------------
def cargar_catalogos(cur) -> dict:
    insertar(cur, "INSERT INTO departamento (nombre, provincia) VALUES %s",
             [(r["nombre"], r["provincia"]) for r in leer_csv("departamentos.csv")])
    insertar(cur, "INSERT INTO cepa (nombre, tipo) VALUES %s",
             [(r["nombre"], r["tipo"]) for r in leer_csv("cepas.csv")])
    insertar(cur, "INSERT INTO maridaje (nombre, temperatura_c) VALUES %s",
             [(r["nombre"], Decimal(r["temperatura_c"])) for r in leer_csv("maridajes.csv")])
    insertar(cur, "INSERT INTO localidad (codigo_postal, nombre, provincia, encargado_regional) VALUES %s",
             [(r["codigo_postal"], r["nombre"], r["provincia"], r["encargado_regional"])
              for r in leer_csv("localidades.csv")])

    cat = {}
    for tabla, clave, nombre in [("departamento", "id_departamento", "nombre"), ("cepa", "id_cepa", "nombre"),
                                 ("maridaje", "id_maridaje", "nombre"), ("localidad", "id_localidad", "nombre")]:
        cur.execute(f"SELECT {nombre}, {clave} FROM {tabla} ORDER BY {clave}")
        cat[tabla] = dict(cur.fetchall())
    cur.execute("SELECT nombre, tipo::text FROM cepa")
    cat["tipo_cepa"] = dict(cur.fetchall())
    return cat


# ---------------------------------------------------------------------------
# 2. Datos maestros generados
# ---------------------------------------------------------------------------
PESO_LOCALIDAD = {  # tamaño relativo de cada localidad (salas y clientes)
    "Mendoza Capital": 5, "Guaymallén": 3, "Godoy Cruz": 3, "Luján de Cuyo": 2, "Maipú": 2,
    "Tunuyán": 1, "Tupungato": 1, "San Carlos": 1, "San Rafael": 4, "General Alvear": 2, "Malargüe": 1,
}
PESO_DEPTO_FINCA = {
    "San Rafael": 6, "General Alvear": 4, "Luján de Cuyo": 5, "Maipú": 4, "Tupungato": 4,
    "Tunuyán": 4, "San Carlos": 3, "Rivadavia": 2, "Junín": 2, "San Martín": 2, "Santa Rosa": 1,
    "Lavalle": 1, "La Paz": 1,
}
# Semillón queda en el catálogo pero sin uso (permite demostrar la consigna D2).
PESO_CEPA_PARCELA = {
    "Malbec": 34, "Cabernet Sauvignon": 12, "Bonarda": 8, "Syrah": 6, "Merlot": 6, "Tempranillo": 4,
    "Pinot Noir": 4, "Chardonnay": 11, "Sauvignon Blanc": 6, "Torrontés": 6, "Chenin Blanc": 3,
}
MARCAS = ["Atuel", "Cerro Nevado", "Los Reyunos", "Valle Grande", "Piedra Negra", "Cuesta de los Terneros",
          "El Nihuil", "Sierra Pintada", "Las Paredes", "Rama Caída", "Cañada Seca", "Villa Atuel",
          "Salto de las Rosas", "Real del Padre", "Jaime Prats", "Punta del Agua", "Bowen", "Carmensa",
          "Diamante", "Los Molles", "Valle de Uco", "Altos del Plata", "Tierra Andina", "Vista Flores",
          "La Consulta", "Agrelo", "Perdriel", "Gualtallary", "El Cepillo", "Paraje Altamira"]


def generar_maestros(cur, cat: dict, fecha_ref: dt.date) -> dict:
    m: dict = {}
    loc_ids = cat["localidad"]
    loc_nombres = list(loc_ids)

    # --- Bodegas -----------------------------------------------------------
    bodegas, usados = [], set()
    while len(bodegas) < N_BODEGAS:
        nombre = rng.choice(["Bodega {}", "Bodegas {}", "Bodega y Viñedos {}", "Familia {}", "{} Wines"]).format(fake.last_name())
        if nombre in usados:
            continue
        usados.add(nombre)
        n = len(bodegas) + 1
        loc = rng.choices(loc_nombres, weights=[PESO_LOCALIDAD[x] for x in loc_nombres])[0]
        bodegas.append((cuit(30, 71000000 + n * 137), nombre + (" S.A." if n % 2 else " S.R.L."),
                        f"{fake.street_name()} {rng.randint(100, 9999)}, {loc}, Mendoza"))
    insertar(cur, "INSERT INTO bodega (cuit, razon_social, domicilio) VALUES %s", bodegas)
    m["bodegas"] = [b[0] for b in bodegas]

    # --- Transportistas y cobertura -----------------------------------------
    transp = []
    for i in range(1, N_TRANSPORTISTAS + 1):
        ap = fake.last_name()
        transp.append((i, f"Transportes {ap} {rng.choice(['S.R.L.', 'S.A.', 'e Hijos S.R.L.'])}",
                       cuit(30, 72000000 + i * 211),
                       f"logistica@transportes{ap.lower().replace(' ', '')}{i}.com.ar",
                       f"0260-4{rng.randint(100000, 999999)}",
                       f"{fake.street_name()} {rng.randint(100, 9999)}, {rng.choice(loc_nombres)}"))
    insertar(cur, "INSERT INTO transportista (id_transportista, razon_social, cuit, email, telefono, domicilio) "
                  "OVERRIDING SYSTEM VALUE VALUES %s", transp)
    # Actividad desigual: los tres últimos casi no trabajan (consignas S7 e I1).
    m["peso_transportista"] = {i: (0.15 if i > N_TRANSPORTISTAS - 3 else rng.uniform(0.6, 3.0))
                               for i in range(1, N_TRANSPORTISTAS + 1)}
    cobertura = []
    for i in range(1, N_TRANSPORTISTAS + 1):
        candidatas = [x for x in loc_nombres if not (i > N_TRANSPORTISTAS - 3 and x == "General Alvear")]
        for loc in rng.sample(candidatas, k=rng.randint(3, 7)):
            cobertura.append((i, loc_ids[loc]))
    insertar(cur, "INSERT INTO transportista_localidad VALUES %s", cobertura)

    # --- Salas ------------------------------------------------------------------
    # La sala 1 está en San Rafael (casa central, usada en la consigna I3).
    salas, sala_loc = [], {}
    locs_sala = ["San Rafael", "General Alvear"] + rng.choices(
        loc_nombres, weights=[PESO_LOCALIDAD[x] for x in loc_nombres], k=N_SALAS - 2)
    for i, loc in enumerate(locs_sala, start=1):
        cierre = rng.choices(DIAS, weights=[5, 2, 3, 1, 1, 1, 4])[0]
        salas.append((i, fake.street_name(), str(rng.randint(10, 3500)), cierre, loc_ids[loc]))
        sala_loc[i] = loc_ids[loc]
    insertar(cur, "INSERT INTO sala_venta (id_sala, calle, numero, dia_cierre, id_localidad) "
                  "OVERRIDING SYSTEM VALUE VALUES %s", salas)
    m["salas"] = [s[0] for s in salas]
    m["sala_cierre"] = {s[0]: DIAS.index(s[3]) for s in salas}
    m["sala_loc"] = sala_loc
    m["sala_peso"] = {s[0]: PESO_LOCALIDAD[locs_sala[s[0] - 1]] * rng.uniform(0.6, 1.4) for s in salas}

    # --- Empleados ---------------------------------------------------------------
    empleados, dnis = [], rng.sample(range(20_000_000, 45_000_000), 400)
    for s in m["salas"]:
        for _ in range(rng.randint(3, 7)):
            dni = dnis.pop()
            ingreso = fecha_aleatoria(fecha_ref - dt.timedelta(days=365 * 18), fecha_ref - dt.timedelta(days=15))
            antig = (fecha_ref - ingreso).days / 365
            salario = dinero(rng.uniform(950_000, 1_250_000) * (1 + 0.025 * antig))
            empleados.append((cuit(rng.choice([20, 27]), dni), fake.name(), ingreso, salario, s))
    insertar(cur, "INSERT INTO empleado (cuit, nombre, fecha_ingreso, salario, id_sala) VALUES %s", empleados)
    m["n_empleados"] = len(empleados)
    return m


# ---------------------------------------------------------------------------
# 3. Vinos (líneas de producto × presentaciones × añadas)
# ---------------------------------------------------------------------------
NIVELES = {  # nivel: (precio base a la fecha de referencia, meses hasta el lanzamiento, popularidad)
    "Joven": (6500, 5, 10.0), "Roble": (9500, 12, 6.0), "Reserva": (15000, 18, 4.0),
    "Gran Reserva": (28000, 30, 1.6), "Ícono": (60000, 40, 0.5),
    "Extra Brut": (11000, 14, 2.5), "Brut Nature": (16000, 20, 1.2),
}
MARIDAJES_POR_TIPO = {
    "tinto": ["Carnes rojas", "Quesos duros", "Pastas con salsa roja", "Entradas y fiambres"],
    "blanco": ["Pescados y mariscos", "Carnes blancas", "Quesos blandos", "Entradas y fiambres"],
    "rosado": ["Entradas y fiambres", "Carnes blancas", "Pastas con salsa roja", "Quesos blandos"],
    "espumante": ["Postres", "Entradas y fiambres", "Pescados y mariscos"],
}
TINTAS = ["Malbec", "Cabernet Sauvignon", "Merlot", "Syrah", "Bonarda", "Tempranillo", "Pinot Noir"]
BLANCAS = ["Chardonnay", "Sauvignon Blanc", "Torrontés", "Chenin Blanc"]
# Aumentos semestrales de precio por año (rango de % por semestre).
INFLACION = {2015: (0.10, 0.15), 2016: (0.15, 0.20), 2017: (0.10, 0.12), 2018: (0.15, 0.25),
             2019: (0.20, 0.25), 2020: (0.12, 0.20), 2021: (0.15, 0.25), 2022: (0.25, 0.40), 2023: (0.35, 0.60),
             2024: (0.18, 0.35), 2025: (0.08, 0.15), 2026: (0.05, 0.10)}


def corte(tipo: str) -> tuple[str, list[tuple[str, int]]]:
    """Devuelve (nombre del varietal, composición que suma 100)."""
    if tipo == "tinto":
        if rng.random() < 0.75:
            principal = rng.choices(TINTAS, weights=[45, 18, 6, 7, 10, 5, 4])[0]
            if rng.random() < 0.5:
                return principal, [(principal, 100)]
            pct = rng.choice([85, 90, 95])
            otra = rng.choice([c for c in TINTAS if c != principal])
            return principal, [(principal, pct), (otra, 100 - pct)]
        cepas = rng.sample(TINTAS[:6], k=rng.randint(2, 4))
        pcts = sorted(rng.sample(range(5, 100, 5), k=len(cepas) - 1))
        partes = [b - a for a, b in zip([0] + pcts, pcts + [100])]
        return rng.choice(["Blend", "Corte de Autor", "Ensamblaje"]), list(zip(cepas, partes))
    if tipo == "blanco":
        principal = rng.choices(BLANCAS, weights=[40, 25, 25, 10])[0]
        if rng.random() < 0.7:
            return principal, [(principal, 100)]
        otra = rng.choice([c for c in BLANCAS if c != principal])
        return principal, [(principal, 85), (otra, 15)]
    if tipo == "rosado":
        if rng.random() < 0.6:
            return "Rosé de Malbec", [("Malbec", 100)]
        return "Rosé", [("Malbec", 70), (rng.choice(["Pinot Noir", "Syrah"]), 30)]
    # espumante
    return rng.choice([("Espumante", [("Chardonnay", 70), ("Pinot Noir", 30)]),
                       ("Espumante", [("Chardonnay", 100)]),
                       ("Espumante", [("Chenin Blanc", 60), ("Chardonnay", 40)])])


def fecha_lanzamiento(anada: int, nivel: str) -> dt.date:
    """Cosecha en marzo de la añada + meses de crianza."""
    meses = NIVELES[nivel][1] + 3
    anio, mes = anada + (meses - 1) // 12, (meses - 1) % 12 + 1
    return dt.date(anio, mes, 1)


def generar_vinos(cur, cat: dict, m: dict, fecha_ref: dt.date) -> dict:
    h0 = fecha_ref.replace(year=fecha_ref.year - ANIOS_HISTORIA)
    lineas, nombres = [], set()

    # Línea del ejemplo del enunciado (consignas I6 y S9): "Malbec Reserva", 85/15.
    lineas.append(dict(nombre="Malbec Reserva", tipo="tinto", nivel="Reserva", bodega=m["bodegas"][0],
                       comp=[("Malbec", 85), ("Cabernet Sauvignon", 15)], vols=[750, 375, 1500],
                       primera=2017, precio=Decimal("12500"), maridajes=["Carnes rojas", "Quesos duros"]))
    nombres.add("Malbec Reserva")

    for b_idx, bodega in enumerate(m["bodegas"]):
        # La última bodega es boutique: una sola línea (consigna S12, división relacional).
        n_lineas = 1 if b_idx == N_BODEGAS - 1 else rng.randint(4, 6)
        marca = MARCAS[b_idx]
        for _ in range(n_lineas):
            tipo = rng.choices(["tinto", "blanco", "rosado", "espumante"], weights=[62, 20, 9, 9])[0]
            if b_idx == N_BODEGAS - 1:
                tipo = "tinto"
            varietal, comp = corte(tipo)
            nivel = {"tinto": rng.choices(["Joven", "Roble", "Reserva", "Gran Reserva", "Ícono"],
                                          weights=[30, 25, 25, 14, 6])[0],
                     "blanco": rng.choices(["Joven", "Reserva"], weights=[75, 25])[0],
                     "rosado": "Joven",
                     "espumante": rng.choice(["Extra Brut", "Brut Nature"])}[tipo]
            sufijo = "" if nivel == "Joven" else f" {nivel}"
            nombre = f"{marca} {varietal}{sufijo}"
            if nombre in nombres:
                continue
            nombres.add(nombre)
            vols = [750]
            if tipo != "espumante" and rng.random() < 0.2:
                vols.append(375)
            if tipo == "tinto" and nivel in ("Reserva", "Gran Reserva", "Ícono") and rng.random() < 0.35:
                vols.append(1500)
            maridajes = rng.sample(MARIDAJES_POR_TIPO[tipo], k=rng.randint(1, 3))
            primera = 2024 if b_idx == N_BODEGAS - 1 else rng.randint(2015, 2023)
            lineas.append(dict(nombre=nombre, tipo=tipo, nivel=nivel, bodega=bodega, comp=comp, vols=vols,
                               primera=primera, precio=None, maridajes=maridajes))

    vinos, composicion, vino_mar, auditoria = [], [], [], []
    info: dict[int, dict] = {}
    productos: list[dict] = []
    cod = 0
    for li in lineas:
        nivel_base, _, popularidad = NIVELES[li["nivel"]]
        pop_linea = popularidad * rng.lognormvariate(0, 0.6) * (1.6 if "Malbec" in li["nombre"] else 1.0)
        for vol in li["vols"]:
            factor_vol = {375: Decimal("0.58"), 750: Decimal("1"), 1500: Decimal("2.2")}[vol]
            prod = dict(nombre=li["nombre"], vol=vol, bodega=li["bodega"], vinos=[],
                        pop=pop_linea * (1.0 if vol == 750 else 0.25))
            for anada in range(li["primera"], fecha_ref.year):
                lanz = fecha_lanzamiento(anada, li["nivel"])
                if lanz > fecha_ref:
                    break
                if lanz < h0 - dt.timedelta(days=365 * 2):   # añadas muy viejas: fuera de catálogo
                    continue
                cod += 1
                grad = {"tinto": (13.0, 15.5), "blanco": (12.0, 14.0), "rosado": (12.0, 13.5),
                        "espumante": (11.5, 12.8)}[li["tipo"]]
                graduacion = Decimal(str(round(rng.uniform(*grad) * 2) / 2)).quantize(CENT)
                edad = max(0, fecha_ref.year - anada - 2)
                base = li["precio"] or Decimal(nivel_base) * Decimal(str(rng.uniform(0.8, 1.25)))
                precio_final = (base * factor_vol * Decimal(str(1 + 0.04 * edad))).quantize(Decimal("10"))
                if li["precio"] is not None and anada == 2021 and vol == 750:
                    precio_final, graduacion = li["precio"], Decimal("14.00")   # ejemplo del enunciado
                # Historia de precios: aumentos semestrales (1/1 y 1/7) desde el lanzamiento.
                fechas = [dt.date(a, mes, 1) for a in range(lanz.year, fecha_ref.year + 1) for mes in (1, 7)]
                fechas = [f for f in fechas if lanz < f <= fecha_ref]
                precios = [precio_final]
                for f in reversed(fechas):
                    inc = Decimal(str(rng.uniform(*INFLACION[f.year])))
                    precios.append(max(Decimal("10"), (precios[-1] / (1 + inc)).quantize(Decimal("10"))))
                precios.reverse()            # precios[0] = precio de lanzamiento
                historia = [(lanz, precios[0])] + list(zip(fechas, precios[1:]))
                for (f_ant, p_ant), (f_nuevo, p_nuevo) in zip(historia, historia[1:]):
                    auditoria.append((cod, p_ant, p_nuevo,
                                      dt.datetime(f_nuevo.year, f_nuevo.month, 1, 9, 0,
                                                  tzinfo=dt.timezone(dt.timedelta(hours=-3))),
                                      "carga_historica"))
                vinos.append((cod, li["nombre"], li["tipo"], anada, vol, graduacion, precio_final, li["bodega"]))
                for cepa_nombre, pct in li["comp"]:
                    composicion.append((cod, cat["cepa"][cepa_nombre], Decimal(pct)))
                for mar in li["maridajes"]:
                    vino_mar.append((cod, cat["maridaje"][mar]))
                info[cod] = dict(lanz=lanz, fechas_precio=[h[0] for h in historia],
                                 precios=[h[1] for h in historia], prod=len(productos), bodega=li["bodega"])
                prod["vinos"].append(cod)
            if prod["vinos"]:
                productos.append(prod)

    insertar(cur, "INSERT INTO vino (cod_vino, nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega) "
                  "OVERRIDING SYSTEM VALUE VALUES %s", vinos)
    insertar(cur, "INSERT INTO composicion_vino (cod_vino, id_cepa, porcentaje) VALUES %s", composicion)
    insertar(cur, "INSERT INTO vino_maridaje (cod_vino, id_maridaje) VALUES %s", vino_mar)
    return dict(info=info, productos=productos, auditoria=auditoria, lineas=lineas,
                n_vinos=len(vinos), n_comp=len(composicion), n_mar=len(vino_mar))


def precio_vigente(v: dict, fecha: dt.date) -> Decimal:
    return v["precios"][bisect.bisect_right(v["fechas_precio"], fecha) - 1]


# ---------------------------------------------------------------------------
# 4. Producción de uva: fincas, parcelas, lotes y análisis
# ---------------------------------------------------------------------------
def generar_produccion(cur, cat: dict, vinos: dict, fecha_ref: dt.date) -> dict:
    deptos = [d for d in PESO_DEPTO_FINCA if d in cat["departamento"]]
    cepas = list(PESO_CEPA_PARCELA)
    # Bodegas que elaboran vinos con cada cepa (destino coherente de la uva).
    bodegas_por_cepa = defaultdict(set)
    for li in vinos["lineas"]:
        for c, _ in li["comp"]:
            bodegas_por_cepa[c].add(li["bodega"])
    todas = sorted({li["bodega"] for li in vinos["lineas"]})

    fincas, parcelas, lotes, analisis = [], [], [], []
    nombres = set()
    nro_lote = 0
    campanias = [a for a in range(fecha_ref.year - 4, fecha_ref.year + 1) if dt.date(a, 4, 30) <= fecha_ref]
    for f in range(1, N_FINCAS + 1):
        while True:
            nombre = rng.choice(["Finca {}", "Finca La {}", "Viñedo {}", "Finca Los {}", "Estancia {}"]).format(fake.last_name())
            if nombre not in nombres:
                nombres.add(nombre)
                break
        depto = rng.choices(deptos, weights=[PESO_DEPTO_FINCA[d] for d in deptos])[0]
        sup_parcelas = Decimal(0)
        for nro in range(1, rng.randint(8, 16) + 1):
            sup = dinero(rng.uniform(1.5, 12))
            sup_parcelas += sup
            cepa = rng.choices(cepas, weights=[PESO_CEPA_PARCELA[c] for c in cepas])[0]
            plantacion = rng.randint(1965, 2020)
            parcelas.append((f, nro, sup, plantacion, cat["cepa"][cepa]))
            # Rendimiento base de la parcela (las muy viejas o muy jóvenes rinden menos).
            edad = fecha_ref.year - plantacion
            base = rng.uniform(8000, 14000) * (0.75 if edad > 45 or edad < 6 else 1.0)
            destinos = sorted(bodegas_por_cepa.get(cepa) or todas)
            bodega_destino = rng.choice(destinos)
            for camp in campanias:
                if rng.random() > 0.92:            # algunas campañas la parcela no se cosecha
                    continue
                nro_lote += 1
                tipo = cat["tipo_cepa"][cepa]
                cosecha = dt.date(camp, 2, 10) + dt.timedelta(days=rng.randint(0, 25) if tipo == "blanca"
                                                                else rng.randint(25, 70))
                factor_camp = {0: 1.0, 1: 0.85, 2: 1.1, 3: 0.95, 4: 1.05}[camp % 5]   # clima del año
                kg = dinero(Decimal(str(base * factor_camp * rng.uniform(0.85, 1.15))) * sup)
                lotes.append((nro_lote, f, nro, camp, cosecha, kg, bodega_destino))
                for _ in range(rng.choices([1, 2, 3], weights=[45, 40, 15])[0]):
                    analisis.append((nro_lote, cosecha + dt.timedelta(days=rng.randint(0, 12)),
                                     Decimal(str(round(rng.uniform(20.5, 26.5), 1))),
                                     Decimal(str(round(rng.uniform(3.25, 3.95), 2))),
                                     Decimal(str(round(rng.uniform(4.5, 7.5), 2)))))
        fincas.append((f, nombre, dinero(sup_parcelas * Decimal(str(rng.uniform(1.0, 1.3)))),
                       cat["departamento"][depto]))

    insertar(cur, "INSERT INTO finca (id_finca, nombre, superficie_ha, id_departamento) "
                  "OVERRIDING SYSTEM VALUE VALUES %s", fincas)
    insertar(cur, "INSERT INTO parcela (id_finca, nro_parcela, superficie_ha, anio_plantacion, id_cepa) VALUES %s",
             parcelas)
    insertar(cur, "INSERT INTO lote_uva (nro_lote, id_finca, nro_parcela, campania, fecha_cosecha, kg_cosechados, "
                  "cuit_bodega) OVERRIDING SYSTEM VALUE VALUES %s", lotes)
    insertar(cur, "INSERT INTO analisis_calidad (nro_lote, fecha, grado_brix, ph, acidez_total) VALUES %s",
             analisis, page_size=10000)
    return dict(fincas=len(fincas), parcelas=len(parcelas), lotes=len(lotes), analisis=len(analisis))


# ---------------------------------------------------------------------------
# 5. Clientes (jerarquía) y permisos de exportación
# ---------------------------------------------------------------------------
ZONAS = ["Gran Mendoza", "Sur mendocino", "Valle de Uco", "Este mendocino", "Cuyo", "Córdoba",
         "Buenos Aires", "NOA", "Patagonia", "Litoral"]
PAISES = {"Estados Unidos": 30, "Brasil": 20, "Reino Unido": 10, "Canadá": 8, "China": 6, "Países Bajos": 5,
          "México": 5, "Paraguay": 4, "Uruguay": 4, "Alemania": 4, "Japón": 4}


def generar_clientes(cur, cat: dict, m: dict, fecha_ref: dt.date) -> dict:
    loc_ids = cat["localidad"]
    loc_nombres = list(loc_ids)
    desde = fecha_ref.replace(year=fecha_ref.year - ANIOS_HISTORIA - 2)
    dnis = iter(rng.sample(range(10_000_000, 46_000_000), N_CLIENTES))
    cuits = iter(rng.sample(range(50_000_000, 99_999_999), N_CLIENTES))
    tipos = rng.choices(list(PCT_TIPO_CLIENTE), weights=list(PCT_TIPO_CLIENTE.values()), k=N_CLIENTES)

    clientes, socios, distrib, export, permisos = [], [], [], [], []
    comp_info = {}
    for i, tipo in enumerate(tipos, start=1):
        loc = rng.choices(loc_nombres, weights=[PESO_LOCALIDAD[x] for x in loc_nombres])[0]
        # Altas crecientes en el tiempo (más clientes nuevos en los últimos años).
        alta = desde + dt.timedelta(days=int((fecha_ref - desde).days * (rng.random() ** 0.8)))
        if tipo == "socio":
            nombre = f"{fake.last_name()}, {fake.first_name()}"
            tdoc, ndoc = ("PASAPORTE", f"AAB{next(dnis)}") if rng.random() < 0.02 else ("DNI", str(next(dnis)))
            socios.append((i,))
        else:
            ap = fake.last_name()
            if tipo == "distribuidor":
                nombre = f"Distribuidora {ap} {rng.choice(['S.R.L.', 'S.A.'])}"
                distrib.append((i, rng.choice(ZONAS), f"INV-{rng.randint(10000, 99999)}-{i}"))
            else:
                nombre = f"{ap} {rng.choice(['Wine Export', 'Export', 'Trading'])} S.A."
                export.append((i, rng.choices(list(PAISES), weights=list(PAISES.values()))[0]))
                for k in range(rng.choices([1, 2, 3, 4, 5], weights=[30, 30, 22, 10, 8])[0]):
                    emision = fecha_aleatoria(alta, fecha_ref)
                    permisos.append((f"PE-{emision.year}-{i:05d}-{k + 1}", i, emision,
                                     emision + dt.timedelta(days=365 * rng.randint(1, 3))))
            tdoc, ndoc = "CUIT", cuit(30, next(cuits))
        clientes.append((i, nombre, tipo, tdoc, ndoc,
                         f"{fake.street_name()} {rng.randint(1, 5000)}", loc_ids[loc], alta))
        sin_compras = tipo == "socio" and rng.random() < PCT_SOCIOS_SIN_COMPRAS
        comp_info[i] = dict(tipo=tipo, loc=loc_ids[loc], alta=alta, compra=not sin_compras)

    # El descuento NO se envía: lo completa el trigger trg_descuento_cliente (RN-06).
    insertar(cur, "INSERT INTO cliente (id_cliente, nombre_razon, tipo, tipo_documento, nro_documento, direccion, "
                  "id_localidad, fecha_alta) OVERRIDING SYSTEM VALUE VALUES %s", clientes)
    insertar(cur, "INSERT INTO socio (id_cliente) VALUES %s", socios)
    insertar(cur, "INSERT INTO distribuidor (id_cliente, zona_cobertura, nro_habilitacion) VALUES %s", distrib)
    insertar(cur, "INSERT INTO exportador (id_cliente, pais_destino) VALUES %s", export)
    insertar(cur, "INSERT INTO permiso_exportacion (codigo, id_cliente, fecha_emision, fecha_vencimiento) VALUES %s",
             permisos)
    return dict(info=comp_info, n=len(clientes), socios=len(socios), distrib=len(distrib),
                export=len(export), permisos=len(permisos))


# ---------------------------------------------------------------------------
# 6. Simulación de la operación: ingresos, transferencias y ventas
# ---------------------------------------------------------------------------
def simular_operacion(m: dict, vinos: dict, clientes: dict, fecha_ref: dt.date) -> dict:
    h0 = fecha_ref.replace(year=fecha_ref.year - ANIOS_HISTORIA)
    dias = [h0 + dt.timedelta(days=k) for k in range((fecha_ref - h0).days + 1)]
    info, productos = vinos["info"], vinos["productos"]
    salas = m["salas"]

    # --- Surtido de cada sala: los 12 productos más populares van a todas. ----
    orden_pop = sorted(range(len(productos)), key=lambda p: -productos[p]["pop"])
    imprescindibles = set(orden_pop[:12])
    surtido = {}
    for s in salas:
        tam = int(len(productos) * min(0.75, 0.25 + 0.06 * m["sala_peso"][s]))
        resto = [p for p in range(len(productos)) if p not in imprescindibles]
        pesos = [productos[p]["pop"] for p in resto]
        elegidos = set(imprescindibles)
        while len(elegidos) < tam:
            elegidos.add(rng.choices(resto, weights=pesos)[0])
        surtido[s] = sorted(elegidos)

    # --- Cantidad de comprobantes por día (crecimiento, estacionalidad, día) ---
    estacion = {1: 0.9, 2: 0.85, 3: 0.95, 4: 0.95, 5: 1.0, 6: 1.1, 7: 1.1, 8: 0.95, 9: 1.0, 10: 1.05,
                11: 1.15, 12: 1.55}
    finde = {0: 0.8, 1: 0.9, 2: 0.95, 3: 1.0, 4: 1.35, 5: 1.45, 6: 1.1}
    pesos_dia = [(1 + 0.7 * k / len(dias)) * estacion[d.month] * finde[d.weekday()] for k, d in enumerate(dias)]
    total = sum(pesos_dia)
    cuotas = [N_COMPROBANTES * w / total for w in pesos_dia]
    comps_dia = [int(c) for c in cuotas]
    for k in sorted(range(len(dias)), key=lambda k: -(cuotas[k] - comps_dia[k]))[:N_COMPROBANTES - sum(comps_dia)]:
        comps_dia[k] += 1

    # --- Demanda esperada (botellas/semana) para dimensionar reposiciones ------
    botellas_por_comp = 3.4 * 2.9
    semanas = len(dias) / 7
    peso_sala_total = sum(m["sala_peso"].values())
    demanda_sp = {}
    for s in salas:
        tot_pop = sum(productos[p]["pop"] for p in surtido[s])
        sem_sala = N_COMPROBANTES * botellas_por_comp / semanas * m["sala_peso"][s] / peso_sala_total
        for p in surtido[s]:
            demanda_sp[(s, p)] = sem_sala * productos[p]["pop"] / tot_pop
    demanda_red = defaultdict(float)
    for (s, p), d in demanda_sp.items():
        demanda_red[p] += d

    def vino_actual(p: int, fecha: dt.date):
        actual = None
        for v in productos[p]["vinos"]:
            if info[v]["lanz"] <= fecha:
                actual = v
        return actual

    # --- Clientes compradores ordenados por fecha de alta (por localidad) ----
    por_loc, global_ = defaultdict(list), []
    for cid, c in clientes["info"].items():
        if c["compra"]:
            por_loc[c["loc"]].append((c["alta"], cid))
            global_.append((c["alta"], cid))
    for lst in list(por_loc.values()) + [global_]:
        lst.sort()
    altas_loc = {k: [a for a, _ in v] for k, v in por_loc.items()}
    altas_glob = [a for a, _ in global_]

    # --- Estado ----------------------------------------------------------------
    deposito = defaultdict(int)
    stock = {s: defaultdict(int) for s in salas}
    disp = {s: [] for s in salas}          # vinos con stock > 0 en la sala
    pos = {s: {} for s in salas}

    def sumar_sala(s, v, q):
        if stock[s][v] == 0 and q > 0:
            pos[s][v] = len(disp[s])
            disp[s].append(v)
        stock[s][v] += q

    def restar_sala(s, v, q):
        stock[s][v] -= q
        if stock[s][v] == 0:
            i = pos[s].pop(v)
            ultimo = disp[s].pop()
            if ultimo != v:
                disp[s][i] = ultimo
                pos[s][ultimo] = i

    ingresos, r_ingresos, transferencias, r_transf, comprobantes, renglones = [], [], [], [], [], []
    transportistas = list(m["peso_transportista"])
    pesos_tr = [m["peso_transportista"][t] for t in transportistas]
    pendiente_desde = fecha_ref - dt.timedelta(days=12)

    def estado_documento(fecha):
        """Los documentos de los últimos 12 días pueden quedar sin procesar."""
        if fecha >= pendiente_desde and rng.random() < 0.6:
            return "en_confeccion" if fecha >= fecha_ref - dt.timedelta(days=2) else "terminado"
        return "procesado"

    def ordenar_deposito(fecha, inicial=False):
        por_bodega = defaultdict(list)
        for p in range(len(productos)):
            v = vino_actual(p, fecha)
            if v is None:
                continue
            sem = max(demanda_red[p], 3)
            if deposito[v] < sem * (8 if inicial else 3):
                q = int(-(-sem * (22 if inicial else 7) // 6) * 6)
                por_bodega[info[v]["bodega"]].append((v, max(q, 60)))
        for bodega in sorted(por_bodega):
            items = por_bodega[bodega]
            for i in range(0, len(items), 6):
                cod = len(ingresos) + 1
                estado = "procesado" if inicial else estado_documento(fecha)
                ingresos.append((cod, fecha, estado, rng.choices(transportistas, weights=pesos_tr)[0], bodega))
                for v, q in items[i:i + 6]:
                    r_ingresos.append((cod, v, q))
                    if estado == "procesado":
                        deposito[v] += q

    def reponer_sala(s, fecha, inicial=False):
        lineas = []
        for p in surtido[s]:
            v = vino_actual(p, fecha)
            if v is None:
                continue
            sem = max(demanda_sp[(s, p)], 0.5)
            if stock[s][v] < sem * 6 or (inicial and stock[s][v] == 0):
                q = min(int(-(-sem * 30 // 6) * 6), deposito[v])
                q = max(q, 0)
                if q >= 6:
                    lineas.append((v, q))
        for i in range(0, len(lineas), 8 if inicial else 6):
            nro = len(transferencias) + 1
            estado = "procesado" if inicial else estado_documento(fecha)
            transferencias.append((nro, s, fecha, estado))
            for v, q in lineas[i:i + (8 if inicial else 6)]:
                r_transf.append((nro, v, q))
                if estado == "procesado":
                    deposito[v] -= q
                    sumar_sala(s, v, q)

    # Revisión de cada sala cada 14 días, en un día en que no cierra.
    offset = {}
    for s in salas:
        opciones = [k for k in range(14) if (h0 + dt.timedelta(days=k)).weekday() != m["sala_cierre"][s]]
        offset[s] = rng.choice(opciones)

    sala_ids = list(salas)
    q_por_tipo = {"socio": ([1, 2, 3], [70, 25, 5]), "distribuidor": ([3, 6, 12], [30, 45, 25]),
                  "exportador": ([6, 12, 24], [30, 45, 25])}
    renglones_por_comp = ([1, 2, 3, 4, 5, 6], [9, 19, 24, 25, 13, 10])

    for k, d in enumerate(dias):
        if k == 0:
            ordenar_deposito(d, inicial=True)
            for s in salas:
                reponer_sala(s, d, inicial=True)
        else:
            if d.weekday() == 0:
                ordenar_deposito(d)
            for s in salas:
                if k % 14 == offset[s]:
                    reponer_sala(s, d)

        abiertas = [s for s in sala_ids if m["sala_cierre"][s] != d.weekday()]
        pesos_ab = [m["sala_peso"][s] for s in abiertas]
        pendientes, intentos = comps_dia[k], 0
        while pendientes > 0 and intentos < comps_dia[k] * 5:
            intentos += 1
            s = rng.choices(abiertas, weights=pesos_ab)[0]
            if not disp[s]:
                continue
            loc = m["sala_loc"][s]
            if rng.random() < 0.7 and loc in altas_loc:
                n = bisect.bisect_right(altas_loc[loc], d)
                lista = por_loc[loc]
            else:
                n, lista = 0, None
            if not n:
                n, lista = bisect.bisect_right(altas_glob, d), global_
            if not n:
                continue
            cid = lista[rng.randrange(n)][1]
            tipo = clientes["info"][cid]["tipo"]
            desc = DESCUENTO[tipo]
            nro = len(comprobantes) + 1
            elegidos, bruto, neto = set(), Decimal(0), Decimal(0)
            for _ in range(rng.choices(*renglones_por_comp)[0]):
                if len(elegidos) >= len(disp[s]):
                    break
                for _intento in range(8):
                    cand = [disp[s][rng.randrange(len(disp[s]))] for _ in range(4)]
                    v = rng.choices(cand, weights=[productos[info[c]["prod"]]["pop"] for c in cand])[0]
                    if v not in elegidos:
                        break
                else:
                    continue
                elegidos.add(v)
                cant = min(rng.choices(*q_por_tipo[tipo])[0], stock[s][v])
                precio = precio_vigente(info[v], d)
                sub = subtotal_renglon(cant, precio, desc)
                renglones.append((nro, v, cant, precio, desc, sub))
                bruto += cant * precio
                neto += sub
                restar_sala(s, v, cant)
            if elegidos:
                comprobantes.append((nro, d, cid, s, dinero(bruto), dinero(bruto) - neto, neto))
                pendientes -= 1

    # Filas en 0 solo para el vino vigente de cada producto del surtido ("agotado");
    # las añadas discontinuadas que se vendieron por completo no conservan fila.
    vigentes = {s: {vino_actual(p, fecha_ref) for p in surtido[s]} for s in salas}
    stock_sala = [(s, v, q) for s in salas for v, q in sorted(stock[s].items()) if q > 0 or v in vigentes[s]]
    stock_dep = sorted(deposito.items())
    return dict(ingresos=ingresos, r_ingresos=r_ingresos, transferencias=transferencias, r_transf=r_transf,
                comprobantes=comprobantes, renglones=renglones, stock_sala=stock_sala, stock_dep=stock_dep)


def cargar_movimientos(cur, crono: Cronometro, sim: dict, auditoria: list) -> None:
    crono.medir("ingreso", insertar, cur,
                "INSERT INTO ingreso (cod_ingreso, fecha, estado, id_transportista, cuit_bodega) "
                "OVERRIDING SYSTEM VALUE VALUES %s", sim["ingresos"])
    crono.medir("renglon_ingreso", insertar, cur,
                "INSERT INTO renglon_ingreso (cod_ingreso, cod_vino, cantidad) VALUES %s", sim["r_ingresos"])
    crono.medir("transferencia", insertar, cur,
                "INSERT INTO transferencia (nro_solicitud, id_sala, fecha_confeccion, estado) "
                "OVERRIDING SYSTEM VALUE VALUES %s", sim["transferencias"])
    crono.medir("renglon_transferencia", insertar, cur,
                "INSERT INTO renglon_transferencia (nro_solicitud, cod_vino, cantidad) VALUES %s", sim["r_transf"])
    crono.medir("comprobante", insertar, cur,
                "INSERT INTO comprobante (nro, fecha, id_cliente, id_sala, subtotal, descuento, total) "
                "OVERRIDING SYSTEM VALUE VALUES %s", sim["comprobantes"], 10000)
    crono.medir("renglon_comprobante", insertar, cur,
                "INSERT INTO renglon_comprobante (nro, cod_vino, cantidad, precio_unitario, descuento_pct, subtotal) "
                "VALUES %s", sim["renglones"], 10000)
    crono.medir("stock_deposito", insertar, cur,
                "INSERT INTO stock_deposito (cod_vino, cantidad) VALUES %s", sim["stock_dep"])
    crono.medir("stock_sala", insertar, cur,
                "INSERT INTO stock_sala (id_sala, cod_vino, cantidad) VALUES %s", sim["stock_sala"])
    crono.medir("auditoria_precio", insertar, cur,
                "INSERT INTO auditoria_precio (cod_vino, precio_anterior, precio_nuevo, fecha_hora, usuario) VALUES %s",
                auditoria)


# ---------------------------------------------------------------------------
# 7. Medición: fila por fila vs. por lotes vs. COPY
# ---------------------------------------------------------------------------
def medir_fila_vs_lote(cur, renglones: list, n: int = 10_000) -> list[tuple[str, int, float]]:
    """Inserta las mismas n filas de renglón en una tabla temporal con tres métodos."""
    filas = renglones[:n]
    cur.execute("CREATE TEMP TABLE bench_renglon (LIKE renglon_comprobante INCLUDING DEFAULTS INCLUDING CONSTRAINTS)")
    resultados = []

    t0 = time.perf_counter()
    for f in filas:
        cur.execute("INSERT INTO bench_renglon VALUES (%s, %s, %s, %s, %s, %s)", f)
    resultados.append(("Fila por fila (cursor.execute en un bucle)", n, time.perf_counter() - t0))

    cur.execute("TRUNCATE bench_renglon")
    t0 = time.perf_counter()
    execute_values(cur, "INSERT INTO bench_renglon VALUES %s", filas, page_size=5000)
    resultados.append(("Por lotes (execute_values, 5000 por sentencia)", n, time.perf_counter() - t0))

    cur.execute("TRUNCATE bench_renglon")
    buf = io.StringIO("".join("\t".join(map(str, f)) + "\n" for f in filas))
    t0 = time.perf_counter()
    cur.copy_expert("COPY bench_renglon FROM STDIN", buf)
    resultados.append(("COPY FROM STDIN", n, time.perf_counter() - t0))

    cur.execute("DROP TABLE bench_renglon")
    return resultados


# ---------------------------------------------------------------------------
# 8. Consultas de control
# ---------------------------------------------------------------------------
CONTROLES = [
    ("Tablas sin filas",
     " UNION ALL ".join(f"SELECT '{t}' FROM {t} HAVING count(*) = 0" for t in TODAS_LAS_TABLAS)),
    ("Renglones de venta huérfanos (sin comprobante)",
     "SELECT 1 FROM renglon_comprobante r WHERE NOT EXISTS (SELECT 1 FROM comprobante c WHERE c.nro = r.nro)"),
    ("Comprobantes sin renglones",
     "SELECT 1 FROM comprobante c WHERE NOT EXISTS (SELECT 1 FROM renglon_comprobante r WHERE r.nro = c.nro)"),
    ("Subtotal de renglón distinto de fn_subtotal_renglon",
     "SELECT 1 FROM renglon_comprobante WHERE subtotal <> fn_subtotal_renglon(cantidad, precio_unitario, descuento_pct)"),
    ("Total del comprobante distinto de la suma de sus renglones",
     """SELECT 1 FROM comprobante c
          JOIN (SELECT nro, SUM(cantidad * precio_unitario)::NUMERIC(14,2) AS bruto, SUM(subtotal) AS neto
                  FROM renglon_comprobante GROUP BY nro) r USING (nro)
         WHERE c.subtotal <> r.bruto OR c.total <> r.neto OR c.descuento <> r.bruto - r.neto"""),
    ("Descuento del renglón distinto del descuento del cliente",
     """SELECT 1 FROM renglon_comprobante r JOIN comprobante c USING (nro)
          JOIN cliente cl USING (id_cliente) WHERE r.descuento_pct <> cl.descuento"""),
    ("Descuento del cliente distinto de fn_descuento_cliente(tipo)",
     "SELECT 1 FROM cliente WHERE descuento <> fn_descuento_cliente(tipo)"),
    ("Venta anterior al alta del cliente",
     "SELECT 1 FROM comprobante c JOIN cliente cl USING (id_cliente) WHERE c.fecha < cl.fecha_alta"),
    ("Venta en el día de cierre de la sala",
     """SELECT 1 FROM comprobante c JOIN sala_venta s USING (id_sala)
         WHERE (ARRAY['lunes','martes','miercoles','jueves','viernes','sabado','domingo'])
               [EXTRACT(ISODOW FROM c.fecha)::int] = s.dia_cierre::text"""),
    ("Precio de venta distinto del precio vigente según la auditoría",
     # Intervalos [desde, hasta) de precio de cada vino reconstruidos desde la auditoría.
     """WITH historia AS (
            SELECT cod_vino, fecha_hora::date AS desde, precio_nuevo AS precio,
                   LEAD(fecha_hora::date) OVER (PARTITION BY cod_vino ORDER BY fecha_hora) AS hasta
              FROM auditoria_precio
            UNION ALL
            (SELECT DISTINCT ON (cod_vino) cod_vino, '-infinity'::date, precio_anterior, fecha_hora::date
               FROM auditoria_precio ORDER BY cod_vino, fecha_hora)
            UNION ALL
            SELECT cod_vino, '-infinity'::date, precio, NULL FROM vino v
             WHERE NOT EXISTS (SELECT 1 FROM auditoria_precio a WHERE a.cod_vino = v.cod_vino))
        SELECT 1 FROM renglon_comprobante r JOIN comprobante c USING (nro)
          JOIN historia h ON h.cod_vino = r.cod_vino AND c.fecha >= h.desde
                         AND (h.hasta IS NULL OR c.fecha < h.hasta)
         WHERE r.precio_unitario <> h.precio"""),
    ("Último precio auditado distinto del precio actual del vino",
     """SELECT 1 FROM vino v JOIN LATERAL (SELECT precio_nuevo FROM auditoria_precio a
                 WHERE a.cod_vino = v.cod_vino ORDER BY fecha_hora DESC LIMIT 1) a ON TRUE
         WHERE a.precio_nuevo <> v.precio"""),
    ("Vino vendido o ingresado antes de su añada",
     """SELECT 1 FROM renglon_ingreso r JOIN ingreso i USING (cod_ingreso) JOIN vino v USING (cod_vino)
         WHERE EXTRACT(YEAR FROM i.fecha) < v.anada"""),
    ("Composición que no suma 100",
     "SELECT 1 FROM vino v LEFT JOIN composicion_vino c USING (cod_vino) GROUP BY v.cod_vino "
     "HAVING COALESCE(SUM(c.porcentaje), 0) <> 100"),
    ("Cliente sin su fila de subtipo (o en otra subtabla)",
     """SELECT 1 FROM cliente c WHERE NOT (
          (c.tipo = 'socio'        AND EXISTS (SELECT 1 FROM socio        s WHERE s.id_cliente = c.id_cliente)) OR
          (c.tipo = 'distribuidor' AND EXISTS (SELECT 1 FROM distribuidor d WHERE d.id_cliente = c.id_cliente)) OR
          (c.tipo = 'exportador'   AND EXISTS (SELECT 1 FROM exportador   e WHERE e.id_cliente = c.id_cliente)))"""),
    ("Stock negativo (sala o depósito)",
     "SELECT 1 FROM stock_sala WHERE cantidad < 0 UNION ALL SELECT 1 FROM stock_deposito WHERE cantidad < 0"),
    ("Depósito: ingresos procesados - transferencias procesadas <> stock",
     """SELECT 1 FROM (
          SELECT cod_vino, SUM(q) AS q FROM (
              SELECT r.cod_vino, r.cantidad AS q FROM renglon_ingreso r JOIN ingreso i USING (cod_ingreso)
               WHERE i.estado = 'procesado'
              UNION ALL
              SELECT r.cod_vino, -r.cantidad FROM renglon_transferencia r JOIN transferencia t USING (nro_solicitud)
               WHERE t.estado = 'procesado') mov
          GROUP BY cod_vino) m
        FULL JOIN stock_deposito d USING (cod_vino)
       WHERE COALESCE(m.q, 0) <> COALESCE(d.cantidad, 0)"""),
    ("Sala: transferencias procesadas - ventas <> stock",
     """SELECT 1 FROM (
          SELECT id_sala, cod_vino, SUM(q) AS q FROM (
              SELECT t.id_sala, r.cod_vino, r.cantidad AS q FROM renglon_transferencia r
                JOIN transferencia t USING (nro_solicitud) WHERE t.estado = 'procesado'
              UNION ALL
              SELECT c.id_sala, r.cod_vino, -r.cantidad FROM renglon_comprobante r JOIN comprobante c USING (nro)) mov
          GROUP BY id_sala, cod_vino) m
        FULL JOIN stock_sala s USING (id_sala, cod_vino)
       WHERE COALESCE(m.q, 0) <> COALESCE(s.cantidad, 0)"""),
    ("Lote de uva cosechado después de la fecha de referencia o análisis antes de la cosecha",
     """SELECT 1 FROM analisis_calidad a JOIN lote_uva l USING (nro_lote)
         WHERE a.fecha < l.fecha_cosecha OR l.fecha_cosecha > CURRENT_DATE"""),
    ("Superficie de las parcelas mayor que la de su finca",
     """SELECT 1 FROM finca f JOIN parcela p USING (id_finca) GROUP BY f.id_finca, f.superficie_ha
        HAVING SUM(p.superficie_ha) > f.superficie_ha"""),
]


def ejecutar_controles(cur) -> list[tuple[str, int]]:
    resultados = []
    for nombre, sql in CONTROLES:
        cur.execute(f"SELECT count(*) FROM ({sql}) AS x")
        resultados.append((nombre, cur.fetchone()[0]))
    return resultados


# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description="Carga masiva reproducible de Bodegas del Atuel")
    ap.add_argument("--fecha-ref", type=dt.date.fromisoformat, default=FECHA_REF_DEFAULT,
                    help=f"último día simulado (por defecto {FECHA_REF_DEFAULT}). Las consultas con "
                         "CURRENT_DATE encuentran datos recientes si es cercana a hoy.")
    ap.add_argument("--sin-benchmark", action="store_true", help="omite la medición fila por fila vs. lotes")
    ap.add_argument("--reporte", type=Path, help="escribe un reporte en Markdown en esta ruta")
    args = ap.parse_args()
    fecha_ref: dt.date = args.fecha_ref

    cargar_env()
    conn = psycopg2.connect()       # usa PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
    conn.autocommit = False
    cur = conn.cursor()
    crono = Cronometro()
    t_total = time.perf_counter()
    print(f"Bodegas del Atuel · carga masiva · semilla {SEED} · fecha de referencia {fecha_ref}")
    p = conn.get_dsn_parameters()
    print(f"Conectado a {p.get('dbname')} en {p.get('host')}:{p.get('port')} como {p.get('user')}\n")

    try:
        print("[1/7] Vaciando tablas (TRUNCATE ... RESTART IDENTITY)")
        cur.execute(f"TRUNCATE {', '.join(TODAS_LAS_TABLAS)} RESTART IDENTITY CASCADE")

        print("[2/7] Catálogos reales desde CSV")
        cat = cargar_catalogos(cur)

        print("[3/7] Datos maestros")
        m = generar_maestros(cur, cat, fecha_ref)
        vinos = generar_vinos(cur, cat, m, fecha_ref)
        prod = generar_produccion(cur, cat, vinos, fecha_ref)
        t0 = time.perf_counter()
        cli = generar_clientes(cur, cat, m, fecha_ref)
        crono.tiempos.append(("cliente + subtipos + permisos", time.perf_counter() - t0, cli["n"]))
        print(f"   bodegas {N_BODEGAS} · salas {N_SALAS} · empleados {m['n_empleados']} · vinos {vinos['n_vinos']} · "
              f"fincas {prod['fincas']} · parcelas {prod['parcelas']} · lotes {prod['lotes']} · "
              f"análisis {prod['analisis']} · clientes {cli['n']:,}")

        print("[4/7] Simulando la operación día por día")
        t0 = time.perf_counter()
        sim = simular_operacion(m, vinos, cli, fecha_ref)
        t_sim = time.perf_counter() - t0
        print(f"   {len(sim['ingresos']):,} ingresos · {len(sim['transferencias']):,} transferencias · "
              f"{len(sim['comprobantes']):,} comprobantes · {len(sim['renglones']):,} renglones  ({t_sim:.1f} s)")

        bench = []
        if not args.sin_benchmark:
            print("[5/7] Midiendo inserción fila por fila vs. por lotes (tabla temporal, 10.000 filas)")
            bench = medir_fila_vs_lote(cur, sim["renglones"])
            for nombre, n, seg in bench:
                print(f"   {nombre:<50} {seg:7.2f} s  ({n / seg:,.0f} filas/s)")
        else:
            print("[5/7] Medición omitida")

        print("[6/7] Cargando movimientos históricos (triggers de usuario deshabilitados)")
        for t in TABLAS_SIN_TRIGGERS:
            cur.execute(f"ALTER TABLE {t} DISABLE TRIGGER USER")
        cargar_movimientos(cur, crono, sim, vinos["auditoria"])
        for t in TABLAS_SIN_TRIGGERS:
            cur.execute(f"ALTER TABLE {t} ENABLE TRIGGER USER")

        # Las identidades siguen después del último ID cargado.
        cur.execute("""SELECT format('SELECT setval(%L, COALESCE((SELECT max(%I) FROM %I), 0) + 1, false)',
                                     pg_get_serial_sequence(table_name, column_name), column_name, table_name)
                         FROM information_schema.columns
                        WHERE table_schema = 'public' AND is_identity = 'YES'""")
        for (sql,) in cur.fetchall():
            cur.execute(sql)

        print("[7/7] Consultas de control")
        cur.execute("SET CONSTRAINTS ALL IMMEDIATE")      # valida ya los constraint triggers diferidos
        controles = ejecutar_controles(cur)
        for nombre, n in controles:
            print(f"   {'OK ' if n == 0 else 'ERROR'} {nombre:<75} {n}")
        if any(n for _, n in controles):
            raise RuntimeError("Las consultas de control encontraron inconsistencias")

        cur.execute("ANALYZE")
        conteos = []
        for t in TODAS_LAS_TABLAS:
            cur.execute(f"SELECT count(*) FROM {t}")
            conteos.append((t, cur.fetchone()[0]))
        conn.commit()
    except Exception as e:
        conn.rollback()
        traceback.print_exc()
        print(f"\nERROR: {e}\nSe revirtió toda la carga.", file=sys.stderr)
        return 1
    finally:
        cur.close()
        conn.close()

    total = time.perf_counter() - t_total
    print("\nFilas por tabla:")
    for t, n in sorted(conteos, key=lambda x: -x[1]):
        print(f"   {t:<26} {n:>9,}")
    print(f"\nCarga completa en {total:.1f} s. Semilla {SEED}, fecha de referencia {fecha_ref}.")

    if args.reporte:
        escribir_reporte(args.reporte, fecha_ref, conteos, crono, t_sim, bench, controles, total)
        print(f"Reporte escrito en {args.reporte}")
    return 0


def escribir_reporte(ruta: Path, fecha_ref, conteos, crono, t_sim, bench, controles, total) -> None:
    L = [f"# Reporte de carga masiva", "",
         f"- Semilla: `{SEED}` · fecha de referencia: `{fecha_ref}` · historia simulada: {ANIOS_HISTORIA} años",
         f"- Tiempo total: {total:.1f} s (simulación en Python: {t_sim:.1f} s)", "",
         "## Filas por tabla", "", "| Tabla | Filas |", "|---|---:|"]
    L += [f"| {t} | {n:,} |" for t, n in sorted(conteos, key=lambda x: -x[1])]
    L += ["", "## Tiempos de inserción (por lotes, execute_values)", "", "| Tabla | Filas | Segundos | Filas/s |",
          "|---|---:|---:|---:|"]
    L += [f"| {e} | {n:,} | {s:.2f} | {n / s:,.0f} |" for e, s, n in crono.tiempos if s > 0]
    if bench:
        L += ["", "## Fila por fila vs. por lotes (10.000 renglones, tabla temporal)", "",
              "| Método | Segundos | Filas/s | Relación |", "|---|---:|---:|---:|"]
        base = bench[0][2]
        L += [f"| {nm} | {s:.2f} | {n / s:,.0f} | ×{base / s:,.1f} |" for nm, n, s in bench]
    L += ["", "## Consultas de control", "", "| Control | Filas con problema |", "|---|---:|"]
    L += [f"| {nm} | {n} |" for nm, n in controles]
    ruta.parent.mkdir(parents=True, exist_ok=True)
    ruta.write_text("\n".join(L) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
