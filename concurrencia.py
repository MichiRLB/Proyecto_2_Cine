"""
concurrencia.py
Proyecto 2 - Cine IMAX (TI-3600 Bases de Datos)

Prueba de concurrencia contra la BD real: muchos hilos, cada uno con su propia conexion,
pelean por lo mismo al mismo tiempo (se usa un Barrier para que todos arranquen juntos).

Escenarios:
  1. N clientes bloquean EL MISMO asiento           -> tiene que ganar exactamente 1
  2. N clientes bloquean asientos DISTINTOS          -> tienen que ganar todos
  3. N clientes bloquean el mismo asiento cuyo bloqueo YA VENCIO -> gana exactamente 1
  4. N intentos de pagar LA MISMA compra              -> exactamente 1 pago aprobado
  5. N escaneos del MISMO QR en la puerta             -> exactamente 1 entrada exitosa
  6. Cruce: clientes con asientos en distinto orden (A-B y B-A) -> sin deadlock, todo o nada

Uso:
    pip install psycopg2-binary
    python tests/concurrencia.py --dsn "host=localhost dbname=imax user=postgres password=xxxx" --hilos 50

El usuario de conexion tiene que ser superusuario (crea una funcion de prueba y ajusta tiempos).
Los datos de prueba quedan en la BD; hay que usar una BD de pruebas.
"""
import argparse
import sys
import threading
import time
from collections import Counter

import psycopg2

p = argparse.ArgumentParser()
p.add_argument("--dsn", default="dbname=imax user=postgres", help="cadena de conexion de psycopg2")
p.add_argument("--hilos", type=int, default=50, help="cantidad de hilos por escenario (20 a 50)")
args = p.parse_args()
N = args.hilos

resultados = []   # (escenario, ok, detalle)


def conectar():
    c = psycopg2.connect(args.dsn)
    c.autocommit = True
    with c.cursor() as cur:
        cur.execute("SET search_path = imax, public")
    return c


admin = conectar()


def q(sql, params=None):
    with admin.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall() if cur.description else None


def reportar(nombre, ok, detalle):
    resultados.append((nombre, ok, detalle))
    print(("[OK]    " if ok else "[FALLA] ") + nombre + " -> " + detalle, flush=True)


def correr_hilos(n, tarea):
    """Lanza n hilos con su propia conexion. tarea(conn, i) devuelve lo que quiera. Todos arrancan juntos."""
    barrera = threading.Barrier(n)
    salidas = [None] * n
    errores = []

    def worker(i):
        try:
            c = conectar()
            barrera.wait(timeout=60)
            salidas[i] = tarea(c, i)
            c.close()
        except Exception as e:  # noqa
            errores.append(repr(e))

    t0 = time.perf_counter()
    hs = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
    for h in hs:
        h.start()
    for h in hs:
        h.join()
    return salidas, errores, (time.perf_counter() - t0) * 1000


# ---------------------------------------------------------------
# preparacion
# ---------------------------------------------------------------
clientes = [r[0] for r in q("SELECT id_usuario FROM usuario u JOIN rol r USING (id_rol) WHERE r.codigo = 'CLIENTE' ORDER BY 1")]
operador = q("SELECT u.id_usuario FROM usuario u JOIN rol r USING (id_rol) WHERE r.codigo = 'OPERADOR_SALA' LIMIT 1")[0][0]
# hay pocos clientes sembrados: se crean los que falten para que cada hilo sea un usuario distinto
while len(clientes) < N:
    k = len(clientes) + 1
    nuevo = q("""INSERT INTO usuario (id_rol, nombre, apellidos, correo)
                 VALUES ((SELECT id_rol FROM rol WHERE codigo = 'CLIENTE'), 'Concurrente', %s, %s)
                 ON CONFLICT (correo) DO UPDATE SET nombre = EXCLUDED.nombre RETURNING id_usuario""",
              (f"Hilo {k}", f"hilo{k}@imax.test"))[0][0]
    clientes.append(nuevo)

# sala mas grande para tener asientos de sobra
sala = q("SELECT s.id_sala FROM sala s JOIN asiento a USING (id_sala) GROUP BY s.id_sala ORDER BY count(*) DESC LIMIT 1")[0][0]
puerta = q("SELECT min(id_puerta) FROM puerta WHERE id_sala = %s", (sala,))[0][0]
pelicula = q("SELECT min(id_pelicula) FROM pelicula")[0][0]


def crear_funcion(offset_horas):
    """crea una funcion en la sala grande; si choca con otra se corre una hora"""
    for extra in range(0, 48):
        try:
            return q("""INSERT INTO funcion (id_pelicula, id_sala, inicio)
                        VALUES (%s, %s, date_trunc('hour', now()) + make_interval(hours => %s)) RETURNING id_funcion""",
                     (pelicula, sala, offset_horas + extra * 4))[0][0]
        except psycopg2.errors.ExclusionViolation:
            continue
    raise RuntimeError("no encontre horario libre para la funcion de prueba")


def asientos_de(f, cantidad):
    return [r[0] for r in q("""SELECT a.id_asiento FROM funcion f JOIN asiento a USING (id_sala)
                               WHERE f.id_funcion = %s ORDER BY a.fila, a.numero LIMIT %s""", (f, cantidad))]


print(f"Hilos por escenario: {N}  | sala {sala} | clientes disponibles: {len(clientes)}\n")

# ---------------------------------------------------------------
# 1. mismo asiento
# ---------------------------------------------------------------
f1 = crear_funcion(24 * 20)
a1 = asientos_de(f1, 1)[0]


def t_mismo(c, i):
    with c.cursor() as cur:
        cur.execute("SELECT exito, cod_resultado FROM sp_bloquear_asiento(%s, %s, %s)", (f1, a1, clientes[i]))
        return cur.fetchone()


sal, err, ms = correr_hilos(N, t_mismo)
cont = Counter((s[0], s[1]) for s in sal if s)
ganadores = cont.get((True, "OK"), 0)
ocupados = cont.get((False, "ASIENTO_OCUPADO"), 0)
reportar(f"1. {N} clientes, MISMO asiento", ganadores == 1 and ocupados == N - 1 and not err,
         f"ganadores={ganadores} ocupados={ocupados} errores={len(err)} ({ms:.0f} ms)")
activas = q("SELECT count(*) FROM reserva_asiento WHERE id_funcion = %s AND id_asiento = %s AND estado IN ('BLOQUEADO','VENDIDO')", (f1, a1))[0][0]
reportar("1b. en la tabla queda UNA sola reserva activa para ese asiento", activas == 1, f"reservas activas={activas}")
colisiones = q("SELECT count(*) FROM asiento_auditoria_log WHERE id_funcion = %s AND id_asiento = %s AND evento = 'COLISION'", (f1, a1))[0][0]
reportar("1c. las colisiones quedaron en asiento_auditoria_log", colisiones >= 1, f"colisiones registradas={colisiones}")

# ---------------------------------------------------------------
# 2. asientos distintos
# ---------------------------------------------------------------
f2 = crear_funcion(24 * 21)
seats = asientos_de(f2, N)
if len(seats) < N:
    print(f"(la sala solo tiene {len(seats)} asientos, se baja el escenario 2 a ese numero)")
n2 = min(N, len(seats))


def t_distintos(c, i):
    with c.cursor() as cur:
        cur.execute("SELECT exito, cod_resultado FROM sp_bloquear_asiento(%s, %s, %s)", (f2, seats[i], clientes[i]))
        return cur.fetchone()


sal, err, ms = correr_hilos(n2, t_distintos)
oks = sum(1 for s in sal if s and s[0])
reportar(f"2. {n2} clientes, asientos DISTINTOS", oks == n2 and not err, f"exitosos={oks}/{n2} errores={len(err)} ({ms:.0f} ms)")

# ---------------------------------------------------------------
# 3. bloqueo vencido + competencia
# ---------------------------------------------------------------
f3 = crear_funcion(24 * 22)
a3 = asientos_de(f3, 1)[0]
q("SELECT exito FROM sp_bloquear_asiento(%s, %s, %s)", (f3, a3, clientes[0]))
q("""UPDATE reserva_asiento SET bloqueado_en = now() - interval '3 minutes', bloqueado_hasta = now() - interval '1 minute'
     WHERE id_funcion = %s AND id_asiento = %s AND estado = 'BLOQUEADO'""", (f3, a3))


def t_vencido(c, i):
    with c.cursor() as cur:
        cur.execute("SELECT exito, cod_resultado FROM sp_bloquear_asiento(%s, %s, %s)", (f3, a3, clientes[(i + 1) % len(clientes)]))
        return cur.fetchone()


sal, err, ms = correr_hilos(N, t_vencido)
ganadores = sum(1 for s in sal if s and s[0])
reportar(f"3. {N} clientes, mismo asiento con bloqueo VENCIDO", ganadores == 1 and not err,
         f"ganadores={ganadores} errores={len(err)} ({ms:.0f} ms)")
exp = q("SELECT count(*) FROM reserva_asiento WHERE id_funcion = %s AND id_asiento = %s AND estado = 'EXPIRADO'", (f3, a3))[0][0]
reportar("3b. la reserva vencida quedo EXPIRADO (solo una vez)", exp == 1, f"expiradas={exp}")

# ---------------------------------------------------------------
# 4. pagar la misma compra muchas veces
# ---------------------------------------------------------------
f4 = crear_funcion(24 * 23)
a4 = asientos_de(f4, 2)
b = q("SELECT ids_reserva FROM sp_bloquear_asientos(%s, %s, %s)", (f4, a4, clientes[0]))[0][0]
tipo = q("SELECT id_tipo_entrada FROM tipo_entrada WHERE codigo = 'ADULTO'")[0][0]
comp = q("SELECT id_compra FROM sp_iniciar_compra(%s, %s::bigint[], %s::smallint[])", (clientes[0], b, [tipo, tipo]))[0][0]


def t_pago(c, i):
    with c.cursor() as cur:
        cur.execute("SELECT exito, cod_resultado FROM sp_procesar_pago(%s, 1::smallint, '4242', 'VISA', 'APROBADO')", (comp,))
        return cur.fetchone()


sal, err, ms = correr_hilos(N, t_pago)
cont = Counter((s[0], s[1]) for s in sal if s)
aprob = cont.get((True, "APROBADO"), 0)
pagos = q("SELECT count(*) FROM pago WHERE id_compra = %s AND estado = 'APROBADO'", (comp,))[0][0]
bolet = q("SELECT count(*) FROM boleto WHERE id_compra = %s AND estado = 'EMITIDO'", (comp,))[0][0]
reportar(f"4. {N} intentos de pagar la MISMA compra", aprob == 1 and pagos == 1 and bolet == 2 and not err,
         f"respuestas aprobadas={aprob} pagos en tabla={pagos} boletos emitidos={bolet} errores={len(err)} resp={dict(cont)} ({ms:.0f} ms)")

# ---------------------------------------------------------------
# 5. el mismo QR escaneado muchas veces
# ---------------------------------------------------------------
# funcion que empieza en unos minutos (en la primera sala libre) para que el QR este dentro de la ventana de ingreso (-30/+15 min)
f5 = None
puerta5 = None
for sala5 in [r[0] for r in q("SELECT id_sala FROM sala ORDER BY id_sala")]:
    for off in (5, 10, 15, 20):
        try:
            f5 = q("""INSERT INTO funcion (id_pelicula, id_sala, inicio) VALUES (%s, %s, now() + make_interval(mins => %s)) RETURNING id_funcion""",
                   (pelicula, sala5, off))[0][0]
            puerta5 = q("SELECT min(id_puerta) FROM puerta WHERE id_sala = %s", (sala5,))[0][0]
            break
        except psycopg2.errors.ExclusionViolation:
            continue
    if f5 is not None:
        break
if f5 is None:
    reportar("5. escaneos del mismo QR", False, "no se pudo crear la funcion de prueba")
else:
    a5 = asientos_de(f5, 1)
    b5 = q("SELECT ids_reserva FROM sp_bloquear_asientos(%s, %s, %s)", (f5, a5, clientes[1]))[0][0]
    c5 = q("SELECT id_compra FROM sp_iniciar_compra(%s, %s::bigint[], %s::smallint[])", (clientes[1], b5, [tipo]))[0][0]
    q("SELECT * FROM sp_procesar_pago(%s, 1::smallint, '4242', 'VISA', 'APROBADO')", (c5,))
    qr = q("SELECT codigo_qr FROM boleto WHERE id_compra = %s", (c5,))[0][0]

    def t_scan(c, i):
        with c.cursor() as cur:
            cur.execute("SELECT exito, cod_resultado FROM sp_validar_entrada(%s, %s, %s)", (qr, puerta5, operador))
            return cur.fetchone()

    sal, err, ms = correr_hilos(N, t_scan)
    cont = Counter((s[0], s[1]) for s in sal if s)
    exitosos = cont.get((True, "EXITOSO"), 0)
    dup = cont.get((False, "RECHAZADO_DUPLICADO"), 0)
    usado = q("SELECT estado FROM boleto WHERE id_compra = %s", (c5,))[0][0]
    reportar(f"5. {N} escaneos del MISMO QR", exitosos == 1 and dup == N - 1 and usado == "USADO" and not err,
             f"exitosos={exitosos} duplicados={dup} estado={usado} errores={len(err)} resp={dict(cont)} ({ms:.0f} ms)")

# ---------------------------------------------------------------
# 6. orden cruzado de asientos (riesgo de deadlock)
# ---------------------------------------------------------------
f6 = crear_funcion(24 * 24)
a6 = asientos_de(f6, 4)


def t_cruce(c, i):
    orden = a6 if i % 2 == 0 else list(reversed(a6))
    with c.cursor() as cur:
        cur.execute("SELECT exito, cod_resultado FROM sp_bloquear_asientos(%s, %s, %s)", (f6, orden, clientes[i]))
        return cur.fetchone()


sal, err, ms = correr_hilos(N, t_cruce)
ganadores = sum(1 for s in sal if s and s[0])
activas = q("SELECT count(*) FROM reserva_asiento WHERE id_funcion = %s AND estado = 'BLOQUEADO'", (f6,))[0][0]
reportar(f"6. {N} clientes piden los mismos 4 asientos en orden cruzado", ganadores == 1 and activas == 4 and not err,
         f"ganadores={ganadores} asientos bloqueados={activas} errores/deadlocks={len(err)} ({ms:.0f} ms)")

# ---------------------------------------------------------------
print()
fallas = [r for r in resultados if not r[1]]
print(f"RESUMEN: {len(resultados) - len(fallas)} de {len(resultados)} verificaciones correctas")
sys.exit(1 if fallas else 0)
