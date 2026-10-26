from .db import conexion
from .usuarios import exigir_rol

METODOS = {'TARJETA_SIMULADA', 'EFECTIVO_SIMULADO', 'TRANSFERENCIA_SIMULADA'}


def pagar(id_compra, id_usuario, aprobado=True, metodo='TARJETA_SIMULADA'):
	if metodo not in METODOS:
		raise ValueError('Método de pago no permitido')
	with conexion() as conn:
		exigir_rol(conn, id_usuario, {'CLIENTE','TAQUILLERO','ADMINISTRADOR'})
		row = conn.execute('SELECT id_usuario FROM compra WHERE id_compra=%s', (id_compra,)).fetchone()
		if not row or row['id_usuario'] != id_usuario:
			raise PermissionError('Compra ajena o inexistente')
		resultado = conn.execute('SELECT confirmar_pago_simulado(%s,%s,%s) AS estado',
								 (id_compra, aprobado, metodo)).fetchone()['estado']
		compra = conn.execute('SELECT id_compra,total,estado,metodo_pago FROM compra WHERE id_compra=%s',
							  (id_compra,)).fetchone()
		return {'resultado': resultado, 'compra': compra}


def mis_compras(id_usuario):
	with conexion() as conn:
		return conn.execute('SELECT * FROM compra WHERE id_usuario=%s ORDER BY fecha_compra DESC',
							(id_usuario,)).fetchall()
