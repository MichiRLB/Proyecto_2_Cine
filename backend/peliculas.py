from .db import conexion
from .usuarios import exigir_rol


def listar_peliculas(solo_activas=True):
	with conexion() as conn:
		return conn.execute("SELECT * FROM peliculas WHERE (%s = FALSE OR estado='ACTIVA') ORDER BY titulo", (solo_activas,)).fetchall()


def obtener_pelicula(id_pelicula):
	with conexion() as conn:
		return conn.execute('SELECT * FROM peliculas WHERE id_pelicula=%s', (id_pelicula,)).fetchone()


def crear_pelicula(admin_id, titulo, sinopsis, duracion, clasificacion, genero, cartel=None):
	with conexion() as conn:
		exigir_rol(conn, admin_id, {'ADMINISTRADOR'})
		row = conn.execute("""INSERT INTO peliculas(titulo,sinopsis,duracion,clasificacion,genero,cartel)
			VALUES(%s,%s,%s,%s,%s,%s) RETURNING id_pelicula""",
			(titulo, sinopsis, duracion, clasificacion, genero, cartel)).fetchone()
		conn.execute("""INSERT INTO admin_operacion_audit(id_usuario,id_rol,accion,detalle)
			SELECT id_usuario,id_rol,'CREAR_PELICULA',%s FROM usuario WHERE id_usuario=%s""",
			(f'Película: {titulo}', admin_id))
		return row['id_pelicula']


def actualizar_pelicula(admin_id, id_pelicula, **cambios):
	permitidos = {'titulo', 'sinopsis', 'duracion', 'clasificacion', 'genero', 'estado', 'cartel'}
	if not cambios or set(cambios) - permitidos:
		raise ValueError('Campos incorrectos')
	with conexion() as conn:
		exigir_rol(conn, admin_id, {'ADMINISTRADOR'})
		columnas = ', '.join(f'{campo}=%s' for campo in cambios)
		row = conn.execute(f'UPDATE peliculas SET {columnas} WHERE id_pelicula=%s RETURNING id_pelicula',
						   (*cambios.values(), id_pelicula)).fetchone()
		if row:
			conn.execute("""INSERT INTO admin_operacion_audit(id_usuario,id_rol,accion,detalle)
				SELECT id_usuario,id_rol,'EDITAR_PELICULA',%s FROM usuario WHERE id_usuario=%s""",
				(f'Película {id_pelicula}: {list(cambios)}', admin_id))
		return bool(row)
