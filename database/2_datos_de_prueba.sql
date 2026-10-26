BEGIN;
SET search_path TO imax, public;

INSERT INTO rol(id_rol,nombre,descripcion,tipos_roles) VALUES
	(1,'CLIENTE','Compra entradas','PUBLICO'),
	(2,'TAQUILLERO','Venta presencial','OPERATIVO'),
	(3,'OPERADOR','Escaneo en puerta','OPERATIVO'),
	(4,'CONTADOR','Consulta reportes','FINANCIERO'),
	(5,'ADMINISTRADOR','Configura cartelera y salas','ADMINISTRATIVO');

-- contraseña de demostración: Demo12345!
INSERT INTO usuario(id_usuario,nombre,apellido1,apellido2,correo,contrasena,id_rol) VALUES
	(1,'Ana','Vargas','Mora','ana@example.test','pbkdf2_sha256$200000$imax-demo-2026$5992b3fb05f65386b0e5ae79baa6a94636471ea1c81862a684a0a4a00ad0736b',1),
	(2,'Luis','Soto','Rojas','luis@example.test','pbkdf2_sha256$200000$imax-demo-2026$5992b3fb05f65386b0e5ae79baa6a94636471ea1c81862a684a0a4a00ad0736b',1),
	(3,'Maria','Lopez','Diaz','admin@example.test','pbkdf2_sha256$200000$imax-demo-2026$5992b3fb05f65386b0e5ae79baa6a94636471ea1c81862a684a0a4a00ad0736b',5),
	(4,'Carlos','Alfaro',NULL,'puerta@example.test','pbkdf2_sha256$200000$imax-demo-2026$5992b3fb05f65386b0e5ae79baa6a94636471ea1c81862a684a0a4a00ad0736b',3),
	(5,'Elena','Rojas',NULL,'caja@example.test','pbkdf2_sha256$200000$imax-demo-2026$5992b3fb05f65386b0e5ae79baa6a94636471ea1c81862a684a0a4a00ad0736b',2),
	(6,'Pedro','Jimenez',NULL,'conta@example.test','pbkdf2_sha256$200000$imax-demo-2026$5992b3fb05f65386b0e5ae79baa6a94636471ea1c81862a684a0a4a00ad0736b',4);

INSERT INTO peliculas(id_pelicula,titulo,sinopsis,duracion,clasificacion,genero,estado,cartel) VALUES
	(1,'Aventura en Marte','Un equipo explora el planeta rojo.',125,'TP','Ciencia ficcion','ACTIVA','posters/marte.jpg'),
	(2,'El Ultimo Bosque','Una aventura ecologica.',102,'TP','Aventura','ACTIVA','posters/bosque.jpg'),
	(3,'Misterio Nocturno','Una investigacion inesperada.',115,'M12','Suspenso','ACTIVA','posters/misterio.jpg');

INSERT INTO cine(id_cine,nombre,pais,ciudad,direccion) VALUES
	(1,'IMAX San Jose','Costa Rica','San Jose','Centro comercial Demo, San Jose'),
	(2,'IMAX Cartago','Costa Rica','Cartago','Avenida Central, Cartago');

INSERT INTO sala(id_sala,id_cine,capacidad,estado) VALUES
	(1,1,12,'ACTIVA'),(2,1,8,'ACTIVA'),(3,2,12,'ACTIVA');

INSERT INTO asiento (id_asiento, id_sala, zona, fila, numero) VALUES
	-- Sala 1: 12 asientos
	(1, 1, 'VIP', 'A', 1),
	(2, 1, 'VIP', 'A', 2),
	(3, 1, 'VIP', 'A', 3),
	(4, 1, 'VIP', 'A', 4),
	(5, 1, 'GENERAL', 'B', 1),
	(6, 1, 'GENERAL', 'B', 2),
	(7, 1, 'GENERAL', 'B', 3),
	(8, 1, 'GENERAL', 'B', 4),
	(9, 1, 'GENERAL', 'C', 1),
	(10, 1, 'GENERAL', 'C', 2),
	(11, 1, 'GENERAL', 'C', 3),
	(12, 1, 'GENERAL', 'C', 4),

	-- Sala 2: 8 asientos
	(13, 2, 'VIP', 'A', 1),
	(14, 2, 'VIP', 'A', 2),
	(15, 2, 'VIP', 'A', 3),
	(16, 2, 'VIP', 'A', 4),
	(17, 2, 'GENERAL', 'B', 1),
	(18, 2, 'GENERAL', 'B', 2),
	(19, 2, 'GENERAL', 'B', 3),
	(20, 2, 'GENERAL', 'B', 4),

	-- Sala 3: 12 asientos
	(25, 3, 'VIP', 'A', 1),
	(26, 3, 'VIP', 'A', 2),
	(27, 3, 'VIP', 'A', 3),
	(28, 3, 'VIP', 'A', 4),
	(29, 3, 'GENERAL', 'B', 1),
	(30, 3, 'GENERAL', 'B', 2),
	(31, 3, 'GENERAL', 'B', 3),
	(32, 3, 'GENERAL', 'B', 4),
	(33, 3, 'GENERAL', 'C', 1),
	(34, 3, 'GENERAL', 'C', 2),
	(35, 3, 'GENERAL', 'C', 3),
	(36, 3, 'GENERAL', 'C', 4);

INSERT INTO funciones(id_funcion,id_pelicula,id_cine,id_sala,fecha,hora_inicio,hora_fin,precio_base) VALUES
	(1,1,1,1,CURRENT_DATE + 1,'18:00','20:05',4500),
	(2,2,1,2,CURRENT_DATE + 1,'15:00','16:42',3500),
	(3,1,2,3,CURRENT_DATE + 2,'17:00','19:05',4000),
	(4,3,1,1,CURRENT_DATE + 1,'21:00','22:55',3900);

INSERT INTO compra(id_compra,id_usuario) VALUES(1,1),(2,2),(3,1),(4,2);

SELECT reservar_asiento(1,1,1);
SELECT reservar_asiento(1,1,2);
SELECT confirmar_pago_simulado(1,TRUE);
SELECT reservar_asiento(2,2,13);
SELECT confirmar_pago_simulado(2,TRUE,'EFECTIVO_SIMULADO');
SELECT reservar_asiento(3,1,3);
SELECT confirmar_pago_simulado(3,FALSE);
SELECT reservar_asiento(4,1,4);

INSERT INTO admin_operacion_audit(id_usuario,id_rol,ip,accion,detalle)
VALUES(3,5,'127.0.0.1','CREAR_FUNCION','Creacion de cartelera de prueba');

-- Ajustar secuencias despues de insertar los IDs manualmente.
SELECT setval(pg_get_serial_sequence('rol','id_rol'),(SELECT max(id_rol) FROM rol));
SELECT setval(pg_get_serial_sequence('usuario','id_usuario'),(SELECT max(id_usuario) FROM usuario));
SELECT setval(pg_get_serial_sequence('peliculas','id_pelicula'),(SELECT max(id_pelicula) FROM peliculas));
SELECT setval(pg_get_serial_sequence('cine','id_cine'),(SELECT max(id_cine) FROM cine));
SELECT setval(pg_get_serial_sequence('sala','id_sala'),(SELECT max(id_sala) FROM sala));
SELECT setval(pg_get_serial_sequence('asiento','id_asiento'),(SELECT max(id_asiento) FROM asiento));
SELECT setval(pg_get_serial_sequence('funciones','id_funcion'),(SELECT max(id_funcion) FROM funciones));
SELECT setval(pg_get_serial_sequence('compra','id_compra'),(SELECT max(id_compra) FROM compra));

COMMIT;
