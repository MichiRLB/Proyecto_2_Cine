from .db import conexion
from .usuarios import exigir_rol
from psycopg.errors import UniqueViolation


def crear_compra(id_usuario):
	with conexion() as conn:
		exigir_rol(conn, id_usuario, {'CLIENTE', 'TAQUILLERO', 'ADMINISTRADOR'})
		return conn.execute('INSERT INTO compra(id_usuario) VALUES (%s) RETURNING id_compra',
							(id_usuario,)).fetchone()['id_compra']


def reservar_asiento(id_compra, id_funcion, id_asiento, id_usuario):
	try:
		with conexion() as conn:
			compra = conn.execute('SELECT id_usuario FROM compra WHERE id_compra=%s', (id_compra,)).fetchone()
			if not compra or compra['id_usuario'] != id_usuario:
				raise PermissionError('Compra ajena o inexistente')
			exigir_rol(conn, id_usuario, {'CLIENTE', 'TAQUILLERO', 'ADMINISTRADOR'})
			row = conn.execute('SELECT reservar_asiento(%s,%s,%s) AS id_reserva',
							   (id_compra, id_funcion, id_asiento)).fetchone()
			return row['id_reserva']
	except UniqueViolation as error:
		raise ValueError('Asiento ocupado o bloqueado por otra compra') from error


def liberar_vencidas():
	with conexion() as conn:
		return conn.execute('SELECT liberar_reservas_expiradas() AS cantidad').fetchone()['cantidad']


def cancelar_compra(id_compra, id_usuario):
	with conexion() as conn:
		row = conn.execute('SELECT id_usuario,estado FROM compra WHERE id_compra=%s FOR UPDATE',
						   (id_compra,)).fetchone()
		if not row or row['id_usuario'] != id_usuario:
			raise PermissionError('Compra ajena o inexistente')
		if row['estado'] != 'PENDIENTE':
			raise ValueError('Solo se cancelan compras pendientes desde esta operación')
		reservas = conn.execute("""UPDATE reserva_compra SET estado='LIBERADA'
			WHERE id_compra=%s AND estado='BLOQUEADA'
			RETURNING id_reserva,id_funcion,id_asiento""", (id_compra,)).fetchall()
		for r in reservas:
			conn.execute("""INSERT INTO asiento_auditoria_log(id_reserva,id_funcion,id_asiento,evento)
				VALUES (%s,%s,%s,'CANCELACION')""", (r['id_reserva'],r['id_funcion'],r['id_asiento']))
		conn.execute("UPDATE compra SET estado='CANCELADA' WHERE id_compra=%s", (id_compra,))
		conn.execute("INSERT INTO transaccion_log(id_compra,evento) VALUES(%s,'COMPRA_CANCELADA')", (id_compra,))
		return True
