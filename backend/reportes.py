from .db import conexion
from .usuarios import exigir_rol


def reporte_funciones(usuario_id):
	with conexion() as conn:
		exigir_rol(conn, usuario_id, {'ADMINISTRADOR','CONTADOR'})
		return conn.execute("""SELECT f.id_funcion,p.titulo, f.fecha,f.hora_inicio,
		  c.nombre AS cine,s.capacidad,
		  count(b.id_boleto) FILTER (WHERE b.estado <> 'ANULADO') AS boletos_vendidos,
		  round(100.0*count(b.id_boleto) FILTER (WHERE b.estado <> 'ANULADO')/s.capacidad,2) AS ocupacion_pct,
		  coalesce(sum(f.precio_base) FILTER (WHERE b.estado <> 'ANULADO'),0) AS ingresos_estimados
		  FROM funciones f JOIN peliculas p ON p.id_pelicula=f.id_pelicula
		  JOIN sala s ON s.id_sala=f.id_sala JOIN cine c ON c.id_cine=f.id_cine
		  LEFT JOIN boleto b ON b.id_funcion=f.id_funcion
		  GROUP BY f.id_funcion,p.titulo,c.nombre,s.capacidad ORDER BY f.fecha,f.hora_inicio""").fetchall()


def pagos_por_metodo(usuario_id):
	with conexion() as conn:
		exigir_rol(conn, usuario_id, {'ADMINISTRADOR','CONTADOR'})
		return conn.execute("""SELECT metodo_pago, count(*) AS compras, sum(total) AS total,
			round(100.0*count(*)/sum(count(*)) OVER (),2) AS porcentaje
			FROM compra WHERE estado='PAGADA' GROUP BY metodo_pago ORDER BY total DESC""").fetchall()


def top_funciones(usuario_id, limite=5):
	with conexion() as conn:
		exigir_rol(conn, usuario_id, {'ADMINISTRADOR','CONTADOR'})
		return conn.execute("""SELECT p.titulo, c.nombre AS cine,
			count(b.id_boleto) AS boletos_vendidos
			FROM boleto b JOIN funciones f ON f.id_funcion=b.id_funcion
			JOIN peliculas p ON p.id_pelicula=f.id_pelicula
			JOIN cine c ON c.id_cine=f.id_cine
			WHERE b.estado <> 'ANULADO' AND b.fecha_emision >= now() - interval '7 days'
			GROUP BY p.id_pelicula, p.titulo, c.nombre
			ORDER BY boletos_vendidos DESC LIMIT %s""", (limite,)).fetchall()


def operaciones_criticas(usuario_id):
	with conexion() as conn:
		exigir_rol(conn, usuario_id, {'ADMINISTRADOR'})
		return conn.execute("""SELECT u.id_usuario, u.correo,
			count(*) AS operaciones, string_agg(DISTINCT a.accion, ', ') AS acciones
			FROM admin_operacion_audit a JOIN usuario u ON u.id_usuario=a.id_usuario
			WHERE a.fecha >= now() - interval '1 month'
			GROUP BY u.id_usuario, u.correo ORDER BY operaciones DESC""").fetchall()


def auditoria(usuario_id, tabla='transaccion_log', limite=100):
	tablas = {'transaccion_log','asiento_auditoria_log','acceso_puerta_log','admin_operacion_audit'}
	if tabla not in tablas:
		raise ValueError('Bitácora no permitida')
	with conexion() as conn:
		exigir_rol(conn, usuario_id, {'ADMINISTRADOR'})
		return conn.execute(f'SELECT * FROM {tabla} ORDER BY fecha DESC LIMIT %s',
							(min(max(int(limite),1),500),)).fetchall()
