import hashlib
import hmac
import os
from .db import conexion


def _hash(password, iteraciones=260000, salt=None):
	salt = salt or os.urandom(16).hex()
	digest = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt.encode('utf-8'), iteraciones).hex()
	return f'pbkdf2_sha256${iteraciones}${salt}${digest}'


def _verificar(password, guardado):
	try:
		algoritmo, rondas, salt, digest = guardado.split('$', 3)
		if algoritmo != 'pbkdf2_sha256':
			return False
		candidato = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt.encode('utf-8'), int(rondas)).hex()
		return hmac.compare_digest(candidato, digest)
	except (ValueError, AttributeError):
		return False


def iniciar_sesion(correo, contrasena):
	with conexion() as conn:
		usuario = conn.execute("""SELECT u.id_usuario,u.nombre,u.apellido1,u.correo,u.contrasena,
			   r.nombre AS rol FROM usuario u JOIN rol r ON r.id_rol=u.id_rol
			   WHERE lower(u.correo)=lower(%s)""", (correo.strip(),)).fetchone()
		if not usuario or not _verificar(contrasena, usuario['contrasena']):
			raise ValueError('Credenciales incorrectas')
		usuario.pop('contrasena')
		return usuario


def registrar_cliente(nombre, apellido1, correo, contrasena, apellido2=None):
	if len(contrasena) < 8:
		raise ValueError('La contraseña debe tener al menos 8 caracteres')
	with conexion() as conn:
		rol = conn.execute("SELECT id_rol FROM rol WHERE nombre='CLIENTE'").fetchone()
		if not rol:
			raise ValueError('Falta el rol CLIENTE en la base de datos')
		row = conn.execute("""INSERT INTO usuario(nombre,apellido1,apellido2,correo,contrasena,id_rol)
			VALUES (%s,%s,%s,%s,%s,%s) RETURNING id_usuario""",
			(nombre.strip(), apellido1.strip(), apellido2, correo.strip().lower(), _hash(contrasena), rol['id_rol'])).fetchone()
		return row['id_usuario']


def exigir_rol(conn, usuario_id, roles):
	row = conn.execute("""SELECT r.nombre AS rol FROM usuario u JOIN rol r ON r.id_rol=u.id_rol
		WHERE u.id_usuario=%s""", (usuario_id,)).fetchone()
	if not row or row['rol'] not in roles:
		raise PermissionError('No tiene permisos para esta operación')
	return row['rol']
