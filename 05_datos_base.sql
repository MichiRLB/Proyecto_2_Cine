-- 05_datos_base.sql
-- Proyecto 2 - Cine IMAX (TI-3600 Bases de Datos)
-- Datos minimos para poder usar el sistema y la interfaz: roles, catalogos, tarifas,
-- usuarios de prueba, 3 salas con sus asientos, 5 peliculas y funciones para los proximos dias.
-- (La carga masiva para las pruebas de rendimiento es otro script, este es solo el basico.)
--
-- Los valores de los parametros y de las tarifas son de ejemplo y se pueden cambiar
-- desde la tabla parametro_sistema / tarifa sin tocar el codigo.

SET search_path = imax, public;

-- la carga inicial no se manda a la bitacora administrativa (solo la apaga un superusuario)
SET app.modo_carga = 'on';

-- ---------- roles ----------
INSERT INTO rol (codigo, nombre, descripcion) VALUES
 ('CLIENTE',       'Cliente / Espectador',    'Compra entradas y ve sus propios boletos'),
 ('TAQUILLERO',    'Taquillero',              'Vende entradas de forma presencial y hace su corte de caja'),
 ('OPERADOR_SALA', 'Operador de sala',        'Valida los codigos QR en la puerta'),
 ('CONTADOR',      'Contador',                'Consulta ingresos y concilia pagos'),
 ('ADMIN',         'Administrador / Gerente', 'Configura cartelera, salas, precios y consulta la auditoria');

-- ---------- usuarios de prueba ----------
INSERT INTO usuario (id_rol, nombre, apellidos, correo, telefono)
SELECT r.id_rol, u.nombre, u.apellidos, u.correo, u.telefono
  FROM (VALUES
     ('ADMIN',         'Sistema',  'Automatico',  'sistema@imax.test',    NULL),
     ('ADMIN',         'Marcela',  'Vargas Mora', 'admin1@imax.test',     '8800-0001'),
     ('TAQUILLERO',    'Diego',    'Solis Cruz',  'taquilla1@imax.test',  '8800-0002'),
     ('OPERADOR_SALA', 'Karla',    'Jimenez Paz', 'puerta1@imax.test',    '8800-0003'),
     ('CONTADOR',      'Esteban',  'Rojas Leon',  'contador1@imax.test',  '8800-0004'),
     ('CLIENTE',       'Ana',      'Mora Soto',   'cliente1@imax.test',   '8800-0011'),
     ('CLIENTE',       'Luis',     'Perez Vega',  'cliente2@imax.test',   '8800-0012'),
     ('CLIENTE',       'Sofia',    'Castro Ruiz', 'cliente3@imax.test',   '8800-0013'),
     ('CLIENTE',       'Mateo',    'Araya Gil',   'cliente4@imax.test',   '8800-0014'),
     ('CLIENTE',       'Valeria',  'Brenes Mena', 'cliente5@imax.test',   '8800-0015')
  ) AS u(rol, nombre, apellidos, correo, telefono)
  JOIN rol r ON r.codigo = u.rol;

-- ---------- catalogos ----------
INSERT INTO clasificacion (codigo, descripcion, edad_minima) VALUES
 ('TP',  'Todo publico',       0),
 ('+7',  'Mayores de 7 anios', 7),
 ('+12', 'Mayores de 12 anios', 12),
 ('+15', 'Mayores de 15 anios', 15),
 ('+18', 'Mayores de 18 anios', 18);

INSERT INTO genero (nombre) VALUES
 ('Accion'), ('Aventura'), ('Ciencia ficcion'), ('Animacion'), ('Drama'), ('Suspenso'), ('Comedia');

INSERT INTO formato_proyeccion (nombre) VALUES ('IMAX 2D'), ('IMAX 3D'), ('IMAX Laser');

INSERT INTO tipo_asiento (codigo, nombre) VALUES
 ('GENERAL', 'General'), ('PLATEA', 'Platea'), ('PALCO', 'Palco'), ('VIP', 'VIP');

INSERT INTO tipo_entrada (codigo, nombre, descuento_pct, requiere_validacion_doc) VALUES
 ('ADULTO',       'Adulto',        0,   FALSE),
 ('NINO',         'Nino',          50,  TRUE),
 ('TERCERA_EDAD', 'Tercera edad',  30,  TRUE),
 ('ESTUDIANTE',   'Estudiante',    20,  TRUE),
 ('CORTESIA',     'Cortesia',      100, FALSE);

INSERT INTO metodo_pago (codigo, nombre, requiere_tarjeta) VALUES
 ('TARJETA_CREDITO',   'Tarjeta de credito',  TRUE),
 ('TARJETA_DEBITO',    'Tarjeta de debito',   TRUE),
 ('PAYPAL',            'PayPal',              FALSE),
 ('BILLETERA_DIGITAL', 'Billetera digital',   FALSE),
 ('TRANSFERENCIA',     'Transferencia',       FALSE);

INSERT INTO parametro_sistema (clave, valor, descripcion) VALUES
 ('max_asientos_por_compra', '6',                   'RN-04: maximo de asientos por compra'),
 ('bloqueo_segundos',        '120',                 'RN-05: duracion del bloqueo temporal de un asiento'),
 ('checkin_min_antes',       '30',                  'RN-16: minutos antes del inicio en que se abre el ingreso'),
 ('checkin_min_despues',     '15',                  'RN-16: minutos despues del inicio en que se cierra el ingreso'),
 ('reembolso_horas_antes',   '2',                   'RN-19: horas antes de la funcion hasta las que se permite reembolsar'),
 ('cargo_servicio_pct',      '5',                   'RN-08: cargo por servicio en porcentaje sobre el total con descuentos'),
 ('iva_pct',                 '13',                  'Impuesto incluido en el total (solo informativo para los reportes)'),
 ('limpieza_min',            '20',                  'Minutos de limpieza entre una funcion y la siguiente en la misma sala'),
 ('zona_horaria',            'America/Costa_Rica',  'Zona horaria para calcular dia de la semana y fecha de las funciones');

-- ---------- tarifas: zona x dia (1 = lunes ... 7 = domingo) ----------
-- base: general 8, platea 10, palco 12, vip 15. Viernes a domingo +2, miercoles (dia del cine) -2.
INSERT INTO tarifa (id_tipo_asiento, dia_semana, precio)
SELECT ta.id_tipo_asiento, d.dia,
       CASE ta.codigo WHEN 'GENERAL' THEN 8 WHEN 'PLATEA' THEN 10 WHEN 'PALCO' THEN 12 ELSE 15 END
       + CASE WHEN d.dia IN (5, 6, 7) THEN 2 WHEN d.dia = 3 THEN -2 ELSE 0 END
  FROM tipo_asiento ta CROSS JOIN generate_series(1, 7) AS d(dia);

INSERT INTO promocion (nombre, tipo, descuento_pct, dia_semana, prioridad) VALUES
 ('2x1 los miercoles',   '2X1',        NULL, 3, 1),
 ('10% los martes',      'PORCENTAJE', 10,   2, 2);

-- ---------- cines, salas, asientos y puertas ----------
INSERT INTO cine (nombre, region, ciudad, direccion) VALUES
 ('IMAX Escazu',  'San Jose', 'Escazu',  'Avenida Escazu, torre 2, nivel 3'),
 ('IMAX Heredia', 'Heredia',  'Heredia', 'Centro comercial Paseo de las Flores, nivel 2');

INSERT INTO sala (id_cine, id_formato, nombre)
SELECT c.id_cine, f.id_formato, s.nombre
  FROM (VALUES ('IMAX Escazu',  'IMAX Laser', 'Sala IMAX 1'),
               ('IMAX Escazu',  'IMAX 3D',    'Sala IMAX 2'),
               ('IMAX Heredia', 'IMAX 2D',    'Sala IMAX 1')) AS s(cine, formato, nombre)
  JOIN cine c ON c.nombre = s.cine
  JOIN formato_proyeccion f ON f.nombre = s.formato;

-- Sala IMAX 1 de Escazu y la de Heredia: 5 filas (A-E) x 8 asientos, igual que el mapa de la interfaz.
-- A-B general, C-D platea, E vip.
INSERT INTO asiento (id_sala, id_tipo_asiento, fila, numero)
SELECT s.id_sala, ta.id_tipo_asiento, chr(64 + f.n), n.numero
  FROM sala s
  JOIN cine c ON c.id_cine = s.id_cine
  CROSS JOIN generate_series(1, 5) AS f(n)
  CROSS JOIN generate_series(1, 8) AS n(numero)
  JOIN tipo_asiento ta ON ta.codigo = CASE WHEN f.n <= 2 THEN 'GENERAL' WHEN f.n <= 4 THEN 'PLATEA' ELSE 'VIP' END
 WHERE (c.nombre = 'IMAX Escazu' AND s.nombre = 'Sala IMAX 1') OR c.nombre = 'IMAX Heredia';

-- Sala IMAX 2 de Escazu: 6 filas (A-F) x 10 asientos. A-B general, C-E platea, F palco.
INSERT INTO asiento (id_sala, id_tipo_asiento, fila, numero)
SELECT s.id_sala, ta.id_tipo_asiento, chr(64 + f.n), n.numero
  FROM sala s
  JOIN cine c ON c.id_cine = s.id_cine
  CROSS JOIN generate_series(1, 6) AS f(n)
  CROSS JOIN generate_series(1, 10) AS n(numero)
  JOIN tipo_asiento ta ON ta.codigo = CASE WHEN f.n <= 2 THEN 'GENERAL' WHEN f.n <= 5 THEN 'PLATEA' ELSE 'PALCO' END
 WHERE c.nombre = 'IMAX Escazu' AND s.nombre = 'Sala IMAX 2';

INSERT INTO puerta (id_sala, nombre, tipo)
SELECT id_sala, 'Puerta 1', 'TOTEM' FROM sala
UNION ALL
SELECT id_sala, 'Puerta 2', 'PERSONAL' FROM sala;

-- ---------- peliculas (de mentiras, para no usar titulos con derechos) ----------
INSERT INTO pelicula (id_clasificacion, titulo, sinopsis, duracion_min, poster_url, fecha_estreno)
SELECT c.id_clasificacion, p.titulo, p.sinopsis, p.duracion, p.poster, current_date - 7
  FROM (VALUES
    ('+12', 'Horizonte Perdido',
     'Una tripulacion de rescate viaja al borde del sistema solar para recuperar una nave que dejo de transmitir hace diez anios.',
     128, 'posters/horizonte_perdido.jpg'),
    ('+15', 'La Ultima Frontera',
     'Un guardabosques y una geologa deben cruzar una cordillera nevada antes de que una tormenta cierre el unico paso.',
     141, 'posters/ultima_frontera.jpg'),
    ('+12', 'Ecos del Abismo',
     'Un buzo de profundidad escucha una senal que viene del fondo del oceano y descubre que alguien mas la esta buscando.',
     117, 'posters/ecos_del_abismo.jpg'),
    ('TP',  'Aventuras en el Bosque Magico',
     'Tres hermanos encuentran una puerta en el tronco de un arbol y viajan a un bosque donde los animales hablan.',
     96, 'posters/bosque_magico.jpg'),
    ('+7',  'Operacion Relampago',
     'Un equipo de pilotos jovenes compite contra reloj para entregar una medicina urgente en medio de una tormenta electrica.',
     109, 'posters/operacion_relampago.jpg')
  ) AS p(clasif, titulo, sinopsis, duracion, poster)
  JOIN clasificacion c ON c.codigo = p.clasif;

INSERT INTO pelicula_genero (id_pelicula, id_genero)
SELECT p.id_pelicula, g.id_genero
  FROM (VALUES
    ('Horizonte Perdido', 'Ciencia ficcion'), ('Horizonte Perdido', 'Aventura'),
    ('La Ultima Frontera', 'Accion'), ('La Ultima Frontera', 'Drama'),
    ('Ecos del Abismo', 'Suspenso'), ('Ecos del Abismo', 'Ciencia ficcion'),
    ('Aventuras en el Bosque Magico', 'Animacion'), ('Aventuras en el Bosque Magico', 'Aventura'),
    ('Operacion Relampago', 'Accion'), ('Operacion Relampago', 'Comedia')
  ) AS x(titulo, genero)
  JOIN pelicula p ON p.titulo = x.titulo
  JOIN genero g ON g.nombre = x.genero;

-- ---------- funciones: proximos 3 dias en las 3 salas ----------
-- 14:00, 17:30 y 21:00 (hora del cine). Hay 3.5 horas entre una y otra, mas que suficiente para la pelicula mas larga + limpieza.
INSERT INTO funcion (id_pelicula, id_sala, inicio)
SELECT p.id_pelicula, s.id_sala,
       ((current_date + d.dia) + t.hora) AT TIME ZONE fn_param('zona_horaria')
  FROM (SELECT id_sala, row_number() OVER (ORDER BY id_sala) AS rs FROM sala) s
  CROSS JOIN generate_series(1, 3) AS d(dia)
  CROSS JOIN (VALUES (time '14:00', 1), (time '17:30', 2), (time '21:00', 3)) AS t(hora, k)
  JOIN (SELECT id_pelicula, row_number() OVER (ORDER BY id_pelicula) AS rp FROM pelicula) p
    ON p.rp = ((s.rs + d.dia + t.k) % 5) + 1;

-- una funcion que empieza en 25 minutos (en la sala IMAX 2) para poder probar el check-in sin esperar
INSERT INTO funcion (id_pelicula, id_sala, inicio)
SELECT (SELECT min(id_pelicula) FROM pelicula),
       (SELECT s.id_sala FROM sala s JOIN cine c ON c.id_cine = s.id_cine WHERE c.nombre = 'IMAX Escazu' AND s.nombre = 'Sala IMAX 2'),
       now() + INTERVAL '25 minutes';

RESET app.modo_carga;

-- resumen rapido
SELECT 'roles' AS tabla, count(*) FROM rol UNION ALL
SELECT 'usuarios', count(*) FROM usuario UNION ALL
SELECT 'cines', count(*) FROM cine UNION ALL
SELECT 'salas', count(*) FROM sala UNION ALL
SELECT 'asientos', count(*) FROM asiento UNION ALL
SELECT 'peliculas', count(*) FROM pelicula UNION ALL
SELECT 'tarifas', count(*) FROM tarifa UNION ALL
SELECT 'funciones', count(*) FROM funcion;
