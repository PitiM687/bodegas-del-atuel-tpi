import csv
import os
import random
import time
import psycopg2
from psycopg2.extras import execute_values
from faker import Faker

# Semilla fija para reproducibilidad total
SEED = 42
fake = Faker('es_AR')
Faker.seed(SEED)
random.seed(SEED)

DB_CONFIG = {
    "dbname": "bodegas_atuel",
    "user": "postgres",
    "password": "admin",  # Cambiar por tu contraseña local si es distinta
    "host": "localhost",
    "port": "5432"
}

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

def get_csv_path(filename):
    return os.path.join(SCRIPT_DIR, filename)

def conectar_db():
    return psycopg2.connect(**DB_CONFIG)

def cargar_csv_catalogos(cursor):
    print(" [1/5] Cargando catálogos reales desde CSV...")
    
    with open(get_csv_path('departamentos.csv'), mode='r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        deps = [(r['nombre'], r['provincia']) for r in reader]
        execute_values(cursor, "INSERT INTO departamento (nombre, provincia) VALUES %s ON CONFLICT DO NOTHING;", deps)
        
    with open(get_csv_path('cepas.csv'), mode='r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        cepas = [(r['nombre'], r['tipo']) for r in reader]
        execute_values(cursor, "INSERT INTO cepa (nombre, tipo) VALUES %s ON CONFLICT DO NOTHING;", cepas)
        
    with open(get_csv_path('maridajes.csv'), mode='r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        maridajes = [(r['nombre'], float(r['temperatura_c'])) for r in reader]
        execute_values(cursor, "INSERT INTO maridaje (nombre, temperatura_c) VALUES %s ON CONFLICT DO NOTHING;", maridajes)

    with open(get_csv_path('localidades.csv'), mode='r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        locs = [(r['codigo_postal'], r['nombre'], r['provincia'], r['encargado_regional']) for r in reader]
        execute_values(cursor, "INSERT INTO localidad (codigo_postal, nombre, provincia, encargado_regional) VALUES %s ON CONFLICT DO NOTHING;", locs)

def deshabilitar_triggers(cursor):
    print(" [2/5] Deshabilitando triggers temporalmente para carga masiva...")
    tablas = ['comprobante', 'renglon_comprobante', 'stock_sala', 'stock_deposito', 'vino']
    for t in tablas:
        cursor.execute(f"ALTER TABLE {t} DISABLE TRIGGER ALL;")

def habilitar_triggers(cursor):
    print(" [4/5] Re-habilitando triggers en PostgreSQL...")
    tablas = ['comprobante', 'renglon_comprobante', 'stock_sala', 'stock_deposito', 'vino']
    for t in tablas:
        cursor.execute(f"ALTER TABLE {t} ENABLE TRIGGER ALL;")

def generar_datos_masivos(cursor):
    print(" [3/5] Generando entidades operativas y 500.000 renglones...")
    
    # Bodegas (20)
    bodegas = [(f"30{i:08d}9", f"Bodega {fake.company()}", fake.address()) for i in range(1, 21)]
    execute_values(cursor, "INSERT INTO bodega (cuit, razon_social, domicilio) VALUES %s ON CONFLICT DO NOTHING;", bodegas)
    cuits_bodegas = [b[0] for b in bodegas]

    # Transportistas (15)
    transportistas = [(f"Trans {fake.company()} S.R.L.", f"30{i:08d}3", fake.email(), fake.phone_number(), fake.address()) for i in range(100, 115)]
    execute_values(cursor, "INSERT INTO transportista (razon_social, cuit, email, telefono, domicilio) VALUES %s ON CONFLICT DO NOTHING;", transportistas)

    cursor.execute("SELECT id_localidad FROM localidad;")
    ids_locs = [r[0] for r in cursor.fetchall()]

    # Salas de Venta (20)
    dias = ['lunes', 'martes', 'miercoles', 'jueves', 'viernes', 'sabado', 'domingo']
    salas = [(fake.street_name(), str(random.randint(10, 2000)), random.choice(dias), random.choice(ids_locs)) for _ in range(20)]
    execute_values(cursor, "INSERT INTO sala_venta (calle, numero, dia_cierre, id_localidad) VALUES %s;", salas)
    cursor.execute("SELECT id_sala FROM sala_venta;")
    ids_salas = [r[0] for r in cursor.fetchall()]

    # Vinos (500)
    tipos_vino = ['tinto', 'blanco', 'rosado', 'espumante']
    vinos = []
    for i in range(1, 501):
        nombre_vino = f"Vino {fake.word().capitalize()} Nro {i} Reserva"
        vinos.append((
            nombre_vino,
            random.choice(tipos_vino),
            random.randint(2019, 2024),
            750,
            round(random.uniform(11.5, 15.0), 2),
            round(random.uniform(4000, 35000), 2),
            random.choice(cuits_bodegas)
        ))
    execute_values(cursor, "INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega) VALUES %s;", vinos)
    
    cursor.execute("SELECT cod_vino, precio FROM vino;")
    dict_vinos = {r[0]: float(r[1]) for r in cursor.fetchall()}
    ids_vinos = list(dict_vinos.keys())

    # Clientes (20.000)
    print("   -> Cargando 20.000 clientes...")
    tipos_cli = ['socio', 'distribuidor', 'exportador']
    tipos_doc = ['DNI', 'CUIT', 'CUIL']
    clientes = []
    for i in range(1, 20001):
        t_cli = random.choice(tipos_cli)
        desc = 10.0 if t_cli == 'socio' else (20.0 if t_cli == 'distribuidor' else 35.0)
        clientes.append((fake.name(), t_cli, random.choice(tipos_doc), str(10000000 + i), fake.address(), random.choice(ids_locs), fake.date_between(start_date='-3y', end_date='today'), desc))
    execute_values(cursor, "INSERT INTO cliente (nombre_razon, tipo, tipo_documento, nro_documento, direccion, id_localidad, fecha_alta, descuento) VALUES %s;", clientes, page_size=5000)

    cursor.execute("SELECT id_cliente, descuento FROM cliente;")
    dict_clientes = {r[0]: float(r[1]) for r in cursor.fetchall()}
    ids_clientes = list(dict_clientes.keys())

    # Stock Inicial
    stock_salas = [(s, v, 500000) for s in ids_salas for v in ids_vinos]
    execute_values(cursor, "INSERT INTO stock_sala (id_sala, cod_vino, cantidad) VALUES %s ON CONFLICT DO NOTHING;", stock_salas, page_size=5000)

    # 150.000 Comprobantes y 500.000 Renglones
    print("   -> Generando 150.000 comprobantes y 500.000 renglones...")
    t_inicio = time.time()

    comprobantes = [(fake.date_between(start_date='-2y', end_date='today'), random.choice(ids_clientes), random.choice(ids_salas), 0.0, 0.0, 0.0) for _ in range(150000)]
    execute_values(cursor, "INSERT INTO comprobante (fecha, id_cliente, id_sala, subtotal, descuento, total) VALUES %s;", comprobantes, page_size=10000)

    renglones = []
    totales_comp = {i: {'subtotal': 0.0, 'descuento': 0.0} for i in range(1, 150001)}

    for comp_nro in range(1, 150001):
        cant_r = 3 if comp_nro <= 100000 else 4
        vinos_u = random.sample(ids_vinos, cant_r)
        c_id = comprobantes[comp_nro - 1][1]
        pct_desc = dict_clientes[c_id]

        for v_cod in vinos_u:
            cant = random.randint(1, 12)
            p_unit = dict_vinos[v_cod]
            subt = cant * p_unit
            desc_imp = subt * (pct_desc / 100.0)
            
            renglones.append((comp_nro, v_cod, cant, p_unit, pct_desc, subt))
            totales_comp[comp_nro]['subtotal'] += subt
            totales_comp[comp_nro]['descuento'] += desc_imp

    print("   -> Insertando 500.000 renglones por lotes...")
    execute_values(cursor, "INSERT INTO renglon_comprobante (nro, cod_vino, cantidad, precio_unitario, descuento_pct, subtotal) VALUES %s;", renglones, page_size=10000)

    print("   -> Actualizando cabeceras de comprobante...")
    updates_comp = [(t['subtotal'], t['descuento'], t['subtotal'] - t['descuento'], nro) for nro, t in totales_comp.items()]
    execute_values(cursor, "UPDATE comprobante SET subtotal = data.subt, descuento = data.descto, total = data.tot FROM (VALUES %s) AS data(subt, descto, tot, nro) WHERE comprobante.nro = data.nro;", updates_comp, page_size=10000)

    t_fin = time.time()
    print(f"   ✓ Carga masiva completada en {t_fin - t_inicio:.2f} segundos.")

def main():
    conn = conectar_db()
    conn.autocommit = False
    cursor = conn.cursor()

    try:
        cargar_csv_catalogos(cursor)
        deshabilitar_triggers(cursor)
        generar_datos_masivos(cursor)
        habilitar_triggers(cursor)
        
        conn.commit()
        print(" [5/5] ¡CARGA MASIVA FINALIZADA Y GUARDADA CON ÉXITO!")
    except Exception as e:
        conn.rollback()
        print(f" ERROR DURANTE LA CARGA: {e}")
    finally:
        cursor.close()
        conn.close()

if __name__ == "__main__":
    main()