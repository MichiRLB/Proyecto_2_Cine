from .db import conexion
from .usuarios import exigir_rol


def cartelera(id_cine=None, fecha_desde=None):
	with conexion() as conn:
		return conn.execute("""SELECT f.id_funcion, f.fecha, f.hora_inicio, f.hora_fin,
			f.precio_base, p.id_pelicula, p.titulo, p.sinopsis,p.clasificacion,p.cartel,
			c.id_cine,c.nombre AS cine,c.ciudad, s.id_sala,s.capacidad
			FROM funciones f JOIN peliculas p ON p.id_pelicula=f.id_pelicula
			JOIN cine c ON c.id_cine=f.id_cine JOIN sala s ON s.id_sala=f.id_sala
			WHERE f.estado='ACTIVA' AND p.estado='ACTIVA' AND s.estado='ACTIVA'
				AND (f.fecha + f.hora_inicio) > LOCALTIMESTAMP
				AND (%s::integer IS NULL OR f.id_cine=%s)
				AND (%s::date IS NULL OR f.fecha >= %s)
			ORDER BY f.fecha,f.hora_inicio,p.titulo""",
			(id_cine, id_cine, fecha_desde, fecha_desde)).fetchall()


def asientos_disponibilidad(id_funcion):
	with conexion() as conn:
		conn.execute('SELECT liberar_reservas_expiradas()')
		return conn.execute("""SELECT a.id_asiento,a.fila,a.numero,a.zona,
			CASE WHEN r.estado='COMPRADA' THEN 'OCUPADO'
				 WHEN r.estado='BLOQUEADA' THEN 'BLOQUEADO'
				 ELSE 'DISPONIBLE' END AS disponibilidad
			FROM funciones f JOIN asiento a ON a.id_sala=f.id_sala
			LEFT JOIN reserva_compra r ON r.id_funcion=f.id_funcion AND r.id_asiento=a.id_asiento
				 AND r.estado IN ('BLOQUEADA','COMPRADA')
			WHERE f.id_funcion=%s ORDER BY a.fila,a.numero""", (id_funcion,)).fetchall()


def crear_funcion(admin_id, id_pelicula, id_cine, id_sala, fecha, hora_inicio, hora_fin, precio_base):
	with conexion() as conn:
		exigir_rol(conn, admin_id, {'ADMINISTRADOR'})
		# No programar otra función traslapada en la misma sala.
		solape = conn.execute("""SELECT 1 FROM funciones WHERE id_sala=%s AND fecha=%s
			AND estado='ACTIVA' AND hora_inicio < %s AND hora_fin > %s LIMIT 1""",
			(id_sala, fecha, hora_fin, hora_inicio)).fetchone()
		if solape:
			raise ValueError('Ya existe una función superpuesta en esta sala')
		row = conn.execute("""INSERT INTO funciones(id_pelicula,id_cine,id_sala,fecha,hora_inicio,hora_fin,precio_base)
			VALUES(%s,%s,%s,%s,%s,%s,%s) RETURNING id_funcion""",
			(id_pelicula,id_cine,id_sala,fecha,hora_inicio,hora_fin,precio_base)).fetchone()
		conn.execute("""INSERT INTO admin_operacion_audit(id_usuario,id_rol,accion,detalle)
			SELECT id_usuario,id_rol,'CREAR_FUNCION',%s FROM usuario WHERE id_usuario=%s""",
			(f'Función {row["id_funcion"]}', admin_id))
		return row['id_funcion']
