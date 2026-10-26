from pathlib import Path
from .db import conexion
from .usuarios import exigir_rol


def mis_boletos(id_usuario):
	with conexion() as conn:
		return conn.execute("""SELECT b.id_boleto,b.id_funcion,b.id_asiento,b.estado,b.fecha_emision,
			q.id_qr,p.titulo,f.fecha,f.hora_inicio,a.fila,a.numero,c.nombre AS cine
			FROM boleto b JOIN compra co ON co.id_compra=b.id_compra
			JOIN qr q ON q.id_boleto=b.id_boleto
			JOIN funciones f ON f.id_funcion=b.id_funcion
			JOIN peliculas p ON p.id_pelicula=f.id_pelicula
			JOIN asiento a ON a.id_asiento=b.id_asiento
			JOIN cine c ON c.id_cine=f.id_cine
			WHERE co.id_usuario=%s ORDER BY b.id_boleto DESC""", (id_usuario,)).fetchall()


def generar_imagen_qr(id_usuario, id_boleto, ruta):
	import qrcode
	with conexion() as conn:
		row = conn.execute("""SELECT q.id_qr FROM qr q JOIN boleto b ON b.id_boleto=q.id_boleto
			JOIN compra c ON c.id_compra=b.id_compra
			WHERE b.id_boleto=%s AND c.id_usuario=%s AND c.estado='PAGADA'""",
			(id_boleto, id_usuario)).fetchone()
		if not row:
			raise PermissionError('Boleto inexistente o no pertenece al usuario')
	salida = Path(ruta)
	salida.parent.mkdir(parents=True, exist_ok=True)
	qrcode.make(str(row['id_qr'])).save(salida)
	return str(salida)


def validar_codigo(codigo, id_funcion, id_operador, puerta='PUERTA 1'):
	with conexion() as conn:
		exigir_rol(conn, id_operador, {'OPERADOR','ADMINISTRADOR'})
		return conn.execute('SELECT validar_qr(%s::uuid,%s,%s,%s) AS resultado',
							(str(codigo),id_funcion,id_operador,puerta)).fetchone()['resultado']


def reembolsar_boleto(admin_id, id_boleto, motivo='Reembolso administrativo'):
	# RN-19/RN-20: reembolso forzado hasta 2 h antes; libera el asiento y queda en bitácora.
	with conexion() as conn:
		exigir_rol(conn, admin_id, {'ADMINISTRADOR'})
		boleto = conn.execute("""SELECT b.id_boleto,b.estado,b.id_reserva,b.id_funcion,b.id_asiento,b.id_compra,
			f.fecha,f.hora_inicio FROM boleto b JOIN funciones f ON f.id_funcion=b.id_funcion
			WHERE b.id_boleto=%s FOR UPDATE OF b""", (id_boleto,)).fetchone()
		if not boleto:
			raise ValueError('Boleto inexistente')
		if boleto['estado'] != 'VIGENTE':
			raise ValueError('Solo se reembolsan boletos vigentes (no usados ni anulados)')
		permitido = conn.execute("SELECT (%s::date + %s::time) - interval '2 hours' > now() AS ok",
								 (boleto['fecha'], boleto['hora_inicio'])).fetchone()['ok']
		if not permitido:
			raise ValueError('Fuera de política: solo hasta 2 horas antes de la función')
		conn.execute("UPDATE boleto SET estado='ANULADO' WHERE id_boleto=%s", (id_boleto,))
		conn.execute("UPDATE reserva_compra SET estado='LIBERADA' WHERE id_reserva=%s", (boleto['id_reserva'],))
		conn.execute("""INSERT INTO asiento_auditoria_log(id_reserva,id_funcion,id_asiento,evento)
			VALUES(%s,%s,%s,'REEMBOLSO')""", (boleto['id_reserva'], boleto['id_funcion'], boleto['id_asiento']))
		conn.execute("INSERT INTO transaccion_log(id_compra,evento,detalle) VALUES(%s,'REEMBOLSO',%s)",
					(boleto['id_compra'], motivo))
		conn.execute("""INSERT INTO admin_operacion_audit(id_usuario,id_rol,accion,detalle)
			SELECT id_usuario,id_rol,'REEMBOLSO_BOLETO',%s FROM usuario WHERE id_usuario=%s""",
			(f'Boleto {id_boleto}: {motivo}', admin_id))
		return True
