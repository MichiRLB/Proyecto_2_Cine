-- pruebas_reglas.sql
-- Proyecto 2 - Cine IMAX (TI-3600 Bases de Datos)
-- Pruebas de las reglas de negocio que se resuelven dentro de la base de datos.
--
-- Como correrlo (sobre una BD recien cargada con 00 al 05, con un usuario superusuario):
--     psql -d imax -f tests/pruebas_reglas.sql
-- En DBeaver tambien sirve: abrir el archivo y ejecutarlo como script (Alt+X).
-- Todo se anota en la tabla temporal "res" y al final sale el resumen. Si una prueba falla, la
-- columna "detalle" dice que fue lo que devolvio la base.
-- Las pruebas dejan datos de prueba en la BD (compras, bitacoras), asi que hay que correrlo una vez
-- por cada carga limpia.

\pset pager off
\pset null '-'
SET search_path = imax, public;

CREATE TEMP TABLE res (n SERIAL, grupo TEXT, prueba TEXT, ok BOOLEAN, detalle TEXT);
CREATE TEMP TABLE cfg (clave TEXT PRIMARY KEY, valor BIGINT);

-- ---------------------------------------------------------------
-- funciones de ayuda (viven solo durante esta sesion)
-- ---------------------------------------------------------------
CREATE FUNCTION pg_temp.chk(g TEXT, p TEXT, p_ok BOOLEAN, d TEXT DEFAULT NULL) RETURNS VOID LANGUAGE sql AS
$$ INSERT INTO res (grupo, prueba, ok, detalle) VALUES (g, p, coalesce(p_ok, FALSE), d) $$;

CREATE FUNCTION pg_temp.k(p_clave TEXT) RETURNS BIGINT LANGUAGE sql AS $$ SELECT valor FROM cfg WHERE clave = p_clave $$;

CREATE FUNCTION pg_temp.cli(n INTEGER) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT id_usuario FROM usuario WHERE correo = 'cliente' || n || '@imax.test' $$;

CREATE FUNCTION pg_temp.staff(p_rol TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT u.id_usuario FROM usuario u JOIN rol r USING (id_rol)
    WHERE r.codigo = p_rol AND u.correo <> 'sistema@imax.test' ORDER BY u.id_usuario LIMIT 1 $$;

CREATE FUNCTION pg_temp.te(p_codigo TEXT) RETURNS SMALLINT LANGUAGE sql AS
$$ SELECT id_tipo_entrada FROM tipo_entrada WHERE codigo = p_codigo $$;

-- id del asiento a partir de la funcion + fila + numero
CREATE FUNCTION pg_temp.asi(p_funcion BIGINT, p_fila TEXT, p_num INTEGER) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT a.id_asiento FROM funcion f JOIN asiento a ON a.id_sala = f.id_sala
    WHERE f.id_funcion = p_funcion AND a.fila = p_fila AND a.numero = p_num $$;

-- primera fecha con ese dia de la semana (1 = lunes ... 7 = domingo) que cae al menos 4 dias despues de hoy
CREATE FUNCTION pg_temp.prox_dia(p_dow INTEGER) RETURNS DATE LANGUAGE sql AS
$$ SELECT (current_date + 4 + ((p_dow - extract(isodow FROM current_date + 4)::int + 7) % 7))::date $$;

CREATE FUNCTION pg_temp.mk_func(p_sala INTEGER, p_fecha DATE, p_hora TIME, p_peli_idx INTEGER DEFAULT 0) RETURNS BIGINT LANGUAGE sql AS
$$ INSERT INTO funcion (id_pelicula, id_sala, inicio)
   VALUES ((SELECT id_pelicula FROM pelicula ORDER BY id_pelicula OFFSET p_peli_idx LIMIT 1), p_sala,
           (p_fecha + p_hora) AT TIME ZONE fn_param('zona_horaria'))
   RETURNING id_funcion $$;

-- ejecuta una instruccion y dice 'OK' o 'SQLSTATE: mensaje' (para probar que algo SI falla)
CREATE FUNCTION pg_temp.intenta(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- bloquea los asientos y arma la compra, sin pagar. Devuelve un json con los montos o con el error
CREATE FUNCTION pg_temp.cotizar(p_cli INTEGER, p_f BIGINT, p_asi INTEGER[], p_tipos TEXT[]) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_b     RECORD;
    v_c     RECORD;
    v_tipos SMALLINT[];
BEGIN
    SELECT * INTO v_b FROM sp_bloquear_asientos(p_f, p_asi, p_cli);
    IF NOT v_b.exito THEN RETURN jsonb_build_object('error', v_b.cod_resultado); END IF;
    SELECT array_agg(pg_temp.te(t) ORDER BY ord) INTO v_tipos FROM unnest(p_tipos) WITH ORDINALITY AS u(t, ord);
    SELECT * INTO v_c FROM sp_iniciar_compra(p_cli, v_b.ids_reserva, v_tipos);
    IF NOT v_c.exito THEN
        PERFORM sp_liberar_asientos(v_b.ids_reserva, p_cli);
        RETURN jsonb_build_object('error', v_c.cod_resultado);
    END IF;
    RETURN jsonb_build_object('id_compra', v_c.id_compra, 'subtotal', v_c.subtotal, 'descuento', v_c.descuento_total,
                              'cargo', v_c.cargo_servicio, 'total', v_c.total, 'reservas', to_jsonb(v_b.ids_reserva));
END $$;

-- suelta los asientos de una cotizacion (para volver a usarlos)
CREATE FUNCTION pg_temp.soltar(p_cot JSONB, p_cli INTEGER) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT sp_liberar_asientos(ARRAY(SELECT jsonb_array_elements_text(p_cot -> 'reservas')::bigint), p_cli) $$;

-- bloquea, arma la compra y la paga. Devuelve el id de la compra, o NULL si algo fallo
CREATE FUNCTION pg_temp.comprar(p_cli INTEGER, p_f BIGINT, p_asi INTEGER[], p_tipos TEXT[], p_resultado TEXT DEFAULT 'APROBADO') RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_cot JSONB := pg_temp.cotizar(p_cli, p_f, p_asi, p_tipos);
    v_p   RECORD;
BEGIN
    IF v_cot ? 'error' THEN RETURN NULL; END IF;
    SELECT * INTO v_p FROM sp_procesar_pago((v_cot ->> 'id_compra')::bigint, 1::smallint, '4242', 'VISA', p_resultado);
    IF NOT v_p.exito THEN RETURN NULL; END IF;
    RETURN (v_cot ->> 'id_compra')::bigint;
END $$;

-- los boletos de una compra, en orden
CREATE FUNCTION pg_temp.bols(p_compra BIGINT) RETURNS BIGINT[] LANGUAGE sql AS
$$ SELECT array_agg(id_boleto ORDER BY id_boleto) FROM boleto WHERE id_compra = p_compra $$;

CREATE FUNCTION pg_temp.qr(p_boleto BIGINT) RETURNS TEXT LANGUAGE sql AS
$$ SELECT codigo_qr FROM boleto WHERE id_boleto = p_boleto $$;

-- ejecuta una instruccion con otro rol (SET SESSION AUTHORIZATION, igual que si hubiera iniciado sesion con ese usuario)
-- y dice DENEGADO / OK / ERROR: mensaje
CREATE FUNCTION pg_temp.como(p_rol TEXT, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v TEXT;
BEGIN
    EXECUTE format('SET SESSION AUTHORIZATION %I', p_rol);
    BEGIN
        EXECUTE p_sql;
        v := 'OK';
    EXCEPTION WHEN insufficient_privilege THEN v := 'DENEGADO';
              WHEN OTHERS THEN v := 'ERROR: ' || SQLERRM;
    END;
    RESET SESSION AUTHORIZATION;
    RETURN v;
END $$;

-- igual que como() pero la consulta devuelve un solo numero (-1 si no hay permiso)
CREATE FUNCTION pg_temp.como_n(p_rol TEXT, p_sql TEXT) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v BIGINT;
BEGIN
    EXECUTE format('SET SESSION AUTHORIZATION %I', p_rol);
    BEGIN
        EXECUTE p_sql INTO v;
    EXCEPTION WHEN insufficient_privilege THEN v := -1;
    END;
    RESET SESSION AUTHORIZATION;
    RETURN v;
END $$;

-- ---------------------------------------------------------------
-- preparacion: funciones de prueba en la sala de Heredia (5 filas x 8 asientos;
-- A-B = general, C-D = platea, E = vip)
-- ---------------------------------------------------------------
DO $$
DECLARE
    v_her INTEGER;
    v_esc INTEGER;
    v_lun DATE := pg_temp.prox_dia(1);
    v_jue DATE := pg_temp.prox_dia(4);
BEGIN
    SELECT s.id_sala INTO v_her FROM sala s JOIN cine c USING (id_cine) WHERE c.nombre = 'IMAX Heredia' ORDER BY s.id_sala LIMIT 1;
    SELECT s.id_sala INTO v_esc FROM sala s JOIN cine c USING (id_cine) WHERE c.nombre = 'IMAX Escazu' ORDER BY s.id_sala LIMIT 1;
    INSERT INTO cfg VALUES ('sala_heredia', v_her), ('sala_escazu', v_esc);
    INSERT INTO cfg VALUES ('puerta_heredia', (SELECT min(id_puerta) FROM puerta WHERE id_sala = v_her));
    INSERT INTO cfg VALUES ('puerta_escazu',  (SELECT min(id_puerta) FROM puerta WHERE id_sala = v_esc));

    INSERT INTO cfg VALUES ('f_lun',  pg_temp.mk_func(v_her, v_lun, '09:00', 0));
    INSERT INTO cfg VALUES ('f_lun2', pg_temp.mk_func(v_her, v_lun, '12:30', 1));
    INSERT INTO cfg VALUES ('f_lun3', pg_temp.mk_func(v_her, v_lun, '16:00', 2));
    INSERT INTO cfg VALUES ('f_lun4', pg_temp.mk_func(v_her, v_lun, '19:30', 3));
    INSERT INTO cfg VALUES ('f_lun5', pg_temp.mk_func(v_her, v_lun, '23:00', 4));
    INSERT INTO cfg VALUES ('f_mar',  pg_temp.mk_func(v_her, pg_temp.prox_dia(2), '09:00', 1));
    INSERT INTO cfg VALUES ('f_mie',  pg_temp.mk_func(v_her, pg_temp.prox_dia(3), '09:00', 2));
    INSERT INTO cfg VALUES ('f_sab',  pg_temp.mk_func(v_her, pg_temp.prox_dia(6), '09:00', 3));
    INSERT INTO cfg VALUES ('f_chk',  pg_temp.mk_func(v_her, v_jue, '09:00', 0));      -- para el check-in
    INSERT INTO cfg VALUES ('f_canc', pg_temp.mk_func(v_her, v_jue, '12:30', 1));      -- para cancelar la funcion
    INSERT INTO cfg VALUES ('f_adm',  pg_temp.mk_func(v_her, v_jue, '16:00', 2));      -- operaciones del admin
    INSERT INTO cfg VALUES ('f_g01',  pg_temp.mk_func(v_her, v_jue, '19:30', 3));      -- prueba de traslape
END $$;

-- funcion que empieza dentro de 1 hora (para el limite de reembolso de 2 horas)
DO $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO funcion (id_pelicula, id_sala, inicio)
    VALUES ((SELECT min(id_pelicula) FROM pelicula), pg_temp.k('sala_heredia')::int, now() + INTERVAL '1 hour')
    RETURNING id_funcion INTO v_id;
    INSERT INTO cfg VALUES ('f_cercana', v_id);
END $$;

-- ===============================================================
-- G01. CATALOGO Y CARTELERA (RN-01, RN-02) + funciones sin traslape
-- ===============================================================
DO $$
DECLARE
    v_r      TEXT;
    v_inicio TIMESTAMPTZ;
    v_fin    TIMESTAMPTZ;
    v_dur    INTEGER;
BEGIN
    -- RN-01: una funcion que ya paso no sale en la cartelera
    v_r := pg_temp.intenta(format($f$INSERT INTO funcion (id_pelicula, id_sala, inicio) VALUES (1, %s, now() - INTERVAL '5 days')$f$, pg_temp.k('sala_heredia')));
    PERFORM pg_temp.chk('G01', 'RN-01 todo lo que sale en la cartelera empieza en el futuro',
        NOT EXISTS (SELECT 1 FROM v_cartelera WHERE inicio <= now()), v_r);
    PERFORM pg_temp.chk('G01', 'RN-01 las funciones sembradas para los proximos dias si aparecen',
        (SELECT count(*) FROM v_cartelera) >= 20, (SELECT count(*) FROM v_cartelera)::text);

    UPDATE pelicula SET activa = FALSE WHERE id_pelicula = (SELECT id_pelicula FROM funcion WHERE id_funcion = pg_temp.k('f_lun'));
    PERFORM pg_temp.chk('G01', 'RN-01 una pelicula inactiva no sale en la cartelera',
        NOT EXISTS (SELECT 1 FROM v_cartelera WHERE id_funcion = pg_temp.k('f_lun')));
    UPDATE pelicula SET activa = TRUE;

    -- RN-02
    PERFORM pg_temp.chk('G01', 'RN-02 la cartelera siempre trae titulo, sinopsis, clasificacion, horario y direccion',
        (SELECT count(*) FROM v_cartelera WHERE titulo IS NULL OR sinopsis IS NULL OR clasificacion IS NULL OR inicio IS NULL OR direccion IS NULL OR sala IS NULL) = 0);
    v_r := pg_temp.intenta($f$INSERT INTO pelicula (id_clasificacion, titulo, sinopsis, duracion_min) VALUES (1, 'Sin sinopsis', '   ', 100)$f$);
    PERFORM pg_temp.chk('G01', 'RN-02 no se puede crear una pelicula con la sinopsis vacia', v_r LIKE '23514%', v_r);

    SELECT f.inicio, f.fin, p.duracion_min INTO v_inicio, v_fin, v_dur FROM funcion f JOIN pelicula p USING (id_pelicula) WHERE f.id_funcion = pg_temp.k('f_lun');
    PERFORM pg_temp.chk('G01', 'Proceso: fin = inicio + duracion de la pelicula + 20 min de limpieza', v_fin = v_inicio + make_interval(mins => v_dur + 20), (v_fin - v_inicio)::text);

    SELECT inicio INTO v_inicio FROM funcion WHERE id_funcion = pg_temp.k('f_g01');
    v_r := pg_temp.intenta(format($f$INSERT INTO funcion (id_pelicula, id_sala, inicio) VALUES (1, %s, %L)$f$, pg_temp.k('sala_heredia'), v_inicio + INTERVAL '30 minutes'));
    PERFORM pg_temp.chk('G01', 'Proceso: dos funciones traslapadas en la misma sala se rechazan (EXCLUDE)', v_r LIKE '23P01%', v_r);
    v_r := pg_temp.intenta(format($f$INSERT INTO funcion (id_pelicula, id_sala, inicio) VALUES (1, %s, %L)$f$, pg_temp.k('sala_escazu'), v_inicio));
    PERFORM pg_temp.chk('G01', 'Proceso: la misma hora en otra sala si se permite', v_r = 'OK', v_r);
    UPDATE funcion SET estado = 'CANCELADA' WHERE id_funcion = pg_temp.k('f_g01');
    v_r := pg_temp.intenta(format($f$INSERT INTO funcion (id_pelicula, id_sala, inicio) VALUES (1, %s, %L)$f$, pg_temp.k('sala_heredia'), v_inicio));
    PERFORM pg_temp.chk('G01', 'Proceso: una funcion cancelada libera el horario de la sala', v_r = 'OK', v_r);

    PERFORM pg_temp.chk('G01', 'Busqueda por ubicacion: "Heredia" solo trae el cine de Heredia',
        (SELECT count(*) > 0 AND bool_and(cine = 'IMAX Heredia') FROM fn_buscar_funciones('Heredia', NULL, NULL)));
    PERFORM pg_temp.chk('G01', 'Busqueda por genero: "Animacion" solo trae peliculas de ese genero',
        (SELECT count(*) > 0 AND bool_and(generos ILIKE '%Animacion%') FROM fn_buscar_funciones(NULL, NULL, 'Animacion')));
    PERFORM pg_temp.chk('G01', 'Busqueda por fecha: solo trae funciones de ese dia',
        (SELECT count(*) > 0 AND bool_and((inicio AT TIME ZONE 'America/Costa_Rica')::date = pg_temp.prox_dia(1))
           FROM fn_buscar_funciones(NULL, pg_temp.prox_dia(1), NULL)));
END $$;

-- ===============================================================
-- G02. BLOQUEO DE ASIENTOS Y DOBLE VENTA (RN-03, RN-04, RN-05)
-- ===============================================================
DO $$
DECLARE
    f      BIGINT := pg_temp.k('f_lun');
    r      RECORD;
    r2     RECORD;
    v_ids  BIGINT[];
    v_n    INTEGER;
    v_est  TEXT;
    v_msg  TEXT;
BEGIN
    SELECT * INTO r FROM sp_bloquear_asientos(f, ARRAY[pg_temp.asi(f, 'A', 1), pg_temp.asi(f, 'A', 2)], pg_temp.cli(1));
    PERFORM pg_temp.chk('G02', 'RN-05 bloqueo de 2 asientos exitoso', r.exito AND cardinality(r.ids_reserva) = 2, r.mensaje);
    PERFORM pg_temp.chk('G02', 'RN-05 el bloqueo dura 120 segundos',
        r.vence_en BETWEEN clock_timestamp() + INTERVAL '115 seconds' AND clock_timestamp() + INTERVAL '121 seconds', r.vence_en::text);
    v_ids := r.ids_reserva;

    SELECT estado INTO v_est FROM fn_mapa_asientos(f) WHERE fila = 'A' AND numero = 1;
    PERFORM pg_temp.chk('G02', 'RN-03 el mapa muestra A1 como BLOQUEADO', v_est = 'BLOQUEADO', v_est);
    PERFORM pg_temp.chk('G02', 'RN-03 el mapa dice quien tiene bloqueado el asiento',
        (SELECT id_usuario_bloqueo FROM fn_mapa_asientos(f) WHERE fila = 'A' AND numero = 1) = pg_temp.cli(1));
    SELECT estado INTO v_est FROM fn_mapa_asientos(f) WHERE fila = 'A' AND numero = 5;
    PERFORM pg_temp.chk('G02', 'RN-03 el mapa muestra A5 como DISPONIBLE', v_est = 'DISPONIBLE', v_est);
    PERFORM pg_temp.chk('G02', 'RN-03 el mapa trae los 40 asientos de la sala', (SELECT count(*) FROM fn_mapa_asientos(f)) = 40);

    SELECT * INTO r2 FROM sp_bloquear_asiento(f, pg_temp.asi(f, 'A', 2), pg_temp.cli(2));
    PERFORM pg_temp.chk('G02', 'Doble venta: otro cliente no puede bloquear un asiento ya bloqueado', NOT r2.exito AND r2.cod_resultado = 'ASIENTO_OCUPADO', r2.cod_resultado);
    PERFORM pg_temp.chk('G02', 'Auditoria: la colision queda en asiento_auditoria_log',
        EXISTS (SELECT 1 FROM asiento_auditoria_log WHERE evento = 'COLISION' AND id_funcion = f AND id_asiento = pg_temp.asi(f, 'A', 2) AND id_usuario = pg_temp.cli(2)));

    SELECT * INTO r2 FROM sp_bloquear_asientos(f, ARRAY[pg_temp.asi(f, 'B', 1), pg_temp.asi(f, 'A', 1)], pg_temp.cli(2));
    SELECT estado INTO v_est FROM fn_mapa_asientos(f) WHERE fila = 'B' AND numero = 1;
    PERFORM pg_temp.chk('G02', 'Atomicidad: si uno de los asientos falla no se bloquea ninguno (B1 queda libre)', NOT r2.exito AND v_est = 'DISPONIBLE', r2.cod_resultado || ' / ' || v_est);

    SELECT * INTO r2 FROM sp_bloquear_asientos(f, ARRAY(SELECT pg_temp.asi(f, 'C', n) FROM generate_series(1, 7) n), pg_temp.cli(3));
    PERFORM pg_temp.chk('G02', 'RN-04 7 asientos en una compra se rechazan (maximo 6)', NOT r2.exito AND r2.cod_resultado = 'LIMITE_ASIENTOS', r2.cod_resultado);
    SELECT * INTO r2 FROM sp_bloquear_asientos(f, ARRAY(SELECT pg_temp.asi(f, 'C', n) FROM generate_series(1, 6) n), pg_temp.cli(3));
    PERFORM pg_temp.chk('G02', 'RN-04 6 asientos si se permiten', r2.exito, r2.mensaje);
    SELECT * INTO r2 FROM sp_bloquear_asiento(f, pg_temp.asi(f, 'D', 1), pg_temp.cli(3));
    PERFORM pg_temp.chk('G02', 'RN-04 el limite cuenta lo que ya tiene bloqueado (6 + 1)', NOT r2.exito AND r2.cod_resultado = 'LIMITE_ASIENTOS', r2.cod_resultado);
    PERFORM sp_liberar_asientos(ARRAY(SELECT id_reserva FROM reserva_asiento WHERE id_funcion = f AND id_usuario = pg_temp.cli(3) AND estado = 'BLOQUEADO'), pg_temp.cli(3));

    SELECT * INTO r2 FROM sp_bloquear_asiento(f, 99999999, pg_temp.cli(2));
    PERFORM pg_temp.chk('G02', 'Validacion: un asiento que no existe se rechaza', NOT r2.exito AND r2.cod_resultado = 'ASIENTO_INVALIDO', r2.cod_resultado);
    SELECT * INTO r2 FROM sp_bloquear_asiento(f, (SELECT id_asiento FROM asiento WHERE id_sala = pg_temp.k('sala_escazu') LIMIT 1), pg_temp.cli(2));
    PERFORM pg_temp.chk('G02', 'Validacion: un asiento de otra sala se rechaza', NOT r2.exito AND r2.cod_resultado = 'ASIENTO_INVALIDO', r2.cod_resultado);
    SELECT * INTO r2 FROM sp_bloquear_asiento(-1, 1, pg_temp.cli(2));
    PERFORM pg_temp.chk('G02', 'Validacion: una funcion que no existe se rechaza', NOT r2.exito AND r2.cod_resultado = 'FUNCION_NO_EXISTE', r2.cod_resultado);
    SELECT * INTO r2 FROM sp_bloquear_asiento(f, pg_temp.asi(f, 'B', 2), pg_temp.staff('OPERADOR_SALA'));
    PERFORM pg_temp.chk('G02', 'RBAC: un operador de sala no puede bloquear asientos', NOT r2.exito AND r2.cod_resultado = 'ROL_NO_PERMITIDO', r2.cod_resultado);
    SELECT * INTO r2 FROM sp_bloquear_asientos(f, ARRAY[pg_temp.asi(f, 'B', 2), pg_temp.asi(f, 'B', 2)], pg_temp.cli(2));
    PERFORM pg_temp.chk('G02', 'Validacion: el mismo asiento repetido en la seleccion se rechaza', NOT r2.exito AND r2.cod_resultado = 'ASIENTOS_REPETIDOS', r2.cod_resultado);

    v_msg := pg_temp.intenta(format($f$INSERT INTO reserva_asiento (id_funcion, id_sala, id_asiento, id_usuario, estado, bloqueado_hasta)
        VALUES (%s, %s, %s, %s, 'BLOQUEADO', now() + INTERVAL '2 minutes')$f$, f, pg_temp.k('sala_heredia'), pg_temp.asi(f, 'A', 1), pg_temp.cli(2)));
    PERFORM pg_temp.chk('G02', 'UNIQUE parcial: un INSERT directo del mismo asiento activo falla', v_msg LIKE '23505%', v_msg);
    v_msg := pg_temp.intenta(format($f$INSERT INTO reserva_asiento (id_funcion, id_sala, id_asiento, id_usuario, estado, bloqueado_hasta)
        VALUES (%s, %s, %s, %s, 'BLOQUEADO', now() + INTERVAL '2 minutes')$f$, f, pg_temp.k('sala_heredia'),
        (SELECT id_asiento FROM asiento WHERE id_sala = pg_temp.k('sala_escazu') LIMIT 1), pg_temp.cli(2)));
    PERFORM pg_temp.chk('G02', 'FK compuesta: no se puede reservar a mano un asiento de otra sala', v_msg LIKE '23503%', v_msg);

    v_n := sp_liberar_asientos(v_ids, pg_temp.cli(2));
    PERFORM pg_temp.chk('G02', 'Liberar: otro usuario no puede soltar mis asientos', v_n = 0, v_n::text);
    v_n := sp_liberar_asientos(v_ids, pg_temp.cli(1));
    PERFORM pg_temp.chk('G02', 'Liberar: el dueno suelta sus 2 asientos', v_n = 2, v_n::text);
    SELECT * INTO r2 FROM sp_bloquear_asiento(f, pg_temp.asi(f, 'A', 2), pg_temp.cli(2));
    PERFORM pg_temp.chk('G02', 'Un asiento liberado se puede volver a bloquear (el UNIQUE parcial no cuenta los liberados)', r2.exito, r2.mensaje);
    PERFORM sp_liberar_asientos(r2.ids_reserva, pg_temp.cli(2));
END $$;

-- RN-05: expiracion. Primero simulada (se atrasa el reloj de la reserva) y despues con tiempo real
DO $$
DECLARE
    f     BIGINT := pg_temp.k('f_lun');
    r     RECORD;
    r2    RECORD;
    v_est TEXT;
    v_id  BIGINT;
    v_cot JSONB;
    v_n   INTEGER;
BEGIN
    SELECT * INTO r FROM sp_bloquear_asiento(f, pg_temp.asi(f, 'B', 3), pg_temp.cli(1));
    v_id := r.ids_reserva[1];
    UPDATE reserva_asiento SET bloqueado_en = now() - INTERVAL '3 minutes', bloqueado_hasta = now() - INTERVAL '1 minute' WHERE id_reserva = v_id;

    SELECT estado INTO v_est FROM fn_mapa_asientos(f) WHERE fila = 'B' AND numero = 3;
    PERFORM pg_temp.chk('G02', 'RN-05 un bloqueo vencido se ve DISPONIBLE en el mapa', v_est = 'DISPONIBLE', v_est);
    SELECT * INTO r2 FROM sp_bloquear_asiento(f, pg_temp.asi(f, 'B', 3), pg_temp.cli(2));
    PERFORM pg_temp.chk('G02', 'RN-05 otro cliente puede tomar el asiento cuyo bloqueo vencio', r2.exito, r2.mensaje);
    PERFORM pg_temp.chk('G02', 'RN-05 la reserva vieja queda EXPIRADO con motivo TIMEOUT',
        (SELECT estado || '/' || motivo_cierre FROM reserva_asiento WHERE id_reserva = v_id) = 'EXPIRADO/TIMEOUT',
        (SELECT estado || '/' || coalesce(motivo_cierre, '-') FROM reserva_asiento WHERE id_reserva = v_id));
    PERFORM pg_temp.chk('G02', 'Auditoria: el EXPIRADO queda en asiento_auditoria_log', EXISTS (SELECT 1 FROM asiento_auditoria_log WHERE id_reserva = v_id AND evento = 'EXPIRADO'));
    PERFORM sp_liberar_asientos(r2.ids_reserva, pg_temp.cli(2));

    v_cot := pg_temp.cotizar(pg_temp.cli(1), f, ARRAY[pg_temp.asi(f, 'B', 4)], ARRAY['ADULTO']);
    UPDATE reserva_asiento SET bloqueado_en = now() - INTERVAL '3 minutes', bloqueado_hasta = now() - INTERVAL '1 minute'
     WHERE id_reserva = (v_cot -> 'reservas' ->> 0)::bigint;
    UPDATE compra SET expira_en = now() - INTERVAL '1 minute' WHERE id_compra = (v_cot ->> 'id_compra')::bigint;
    v_n := sp_liberar_bloqueos_expirados();
    PERFORM pg_temp.chk('G02', 'RN-05 sp_liberar_bloqueos_expirados libera los bloqueos vencidos', v_n >= 1, v_n::text);
    PERFORM pg_temp.chk('G02', 'RN-05 la compra pendiente queda EXPIRADA y sus boletos ANULADO',
        (SELECT estado FROM compra WHERE id_compra = (v_cot ->> 'id_compra')::bigint) = 'EXPIRADA'
        AND (SELECT bool_and(estado = 'ANULADO') FROM boleto WHERE id_compra = (v_cot ->> 'id_compra')::bigint),
        (SELECT estado FROM compra WHERE id_compra = (v_cot ->> 'id_compra')::bigint));
END $$;

-- tiempo real: el bloqueo se baja a 2 segundos, se espera y se verifica que el asiento se libera
UPDATE parametro_sistema SET valor = '2' WHERE clave = 'bloqueo_segundos';
DO $$
DECLARE
    f     BIGINT := pg_temp.k('f_lun');
    r     RECORD;
    v_est TEXT;
BEGIN
    SELECT * INTO r FROM sp_bloquear_asiento(f, pg_temp.asi(f, 'B', 5), pg_temp.cli(1));
    SELECT estado INTO v_est FROM fn_mapa_asientos(f) WHERE fila = 'B' AND numero = 5;
    PERFORM pg_temp.chk('G02', 'RN-05 (tiempo real) recien bloqueado se ve BLOQUEADO', v_est = 'BLOQUEADO', v_est);
END $$;
SELECT pg_sleep(3) \gset
DO $$
DECLARE
    f     BIGINT := pg_temp.k('f_lun');
    r2    RECORD;
    v_est TEXT;
BEGIN
    SELECT estado INTO v_est FROM fn_mapa_asientos(f) WHERE fila = 'B' AND numero = 5;
    PERFORM pg_temp.chk('G02', 'RN-05 (tiempo real) 3 segundos despues se ve DISPONIBLE', v_est = 'DISPONIBLE', v_est);
    SELECT * INTO r2 FROM sp_bloquear_asiento(f, pg_temp.asi(f, 'B', 5), pg_temp.cli(2));
    PERFORM pg_temp.chk('G02', 'RN-05 (tiempo real) otro cliente lo puede tomar', r2.exito, r2.mensaje);
    PERFORM sp_liberar_asientos(r2.ids_reserva, pg_temp.cli(2));
END $$;
UPDATE parametro_sistema SET valor = '120' WHERE clave = 'bloqueo_segundos';

-- ===============================================================
-- G03. PRECIOS, TARIFAS Y PROMOCIONES (RN-06, RN-07, RN-08)
-- ===============================================================
DO $$
DECLARE
    v_lun BIGINT := pg_temp.k('f_lun2');
    v_mar BIGINT := pg_temp.k('f_mar');
    v_mie BIGINT := pg_temp.k('f_mie');
    v_sab BIGINT := pg_temp.k('f_sab');
    c     JSONB;
    v_imp NUMERIC;
BEGIN
    c := pg_temp.cotizar(pg_temp.cli(1), v_lun, ARRAY[pg_temp.asi(v_lun, 'A', 1), pg_temp.asi(v_lun, 'A', 2)], ARRAY['ADULTO', 'NINO']);
    PERFORM pg_temp.chk('G03', 'RN-08 lunes: adulto + nino = subtotal 16, desc 4, cargo 0.60, total 12.60',
        (c ->> 'subtotal')::numeric = 16 AND (c ->> 'descuento')::numeric = 4 AND (c ->> 'cargo')::numeric = 0.60 AND (c ->> 'total')::numeric = 12.60, c::text);
    SELECT impuesto_incluido INTO v_imp FROM compra WHERE id_compra = (c ->> 'id_compra')::bigint;
    PERFORM pg_temp.chk('G03', 'RN-08 el IVA incluido es total * 13 / 113 (1.45)', v_imp = round(12.60 * 13 / 113, 2), v_imp::text);
    PERFORM pg_temp.chk('G03', 'RN-06 el boleto de nino queda marcado para verificar documento',
        (SELECT bool_or(te.requiere_validacion_doc) FROM boleto b JOIN tipo_entrada te USING (id_tipo_entrada) WHERE b.id_compra = (c ->> 'id_compra')::bigint));
    PERFORM pg_temp.soltar(c, pg_temp.cli(1));

    c := pg_temp.cotizar(pg_temp.cli(1), v_mie, ARRAY[pg_temp.asi(v_mie, 'A', 1), pg_temp.asi(v_mie, 'A', 2)], ARRAY['ADULTO', 'ADULTO']);
    PERFORM pg_temp.chk('G03', 'RN-07 miercoles 2x1: 2 entradas de 6 => subtotal 12, desc 6, total 6.30',
        (c ->> 'subtotal')::numeric = 12 AND (c ->> 'descuento')::numeric = 6 AND (c ->> 'total')::numeric = 6.30, c::text);
    PERFORM pg_temp.chk('G03', 'RN-07 la compra guarda la promocion que se aplico',
        (SELECT id_promocion FROM compra WHERE id_compra = (c ->> 'id_compra')::bigint) IS NOT NULL);
    PERFORM pg_temp.soltar(c, pg_temp.cli(1));

    c := pg_temp.cotizar(pg_temp.cli(1), v_mie, ARRAY[pg_temp.asi(v_mie, 'A', 1), pg_temp.asi(v_mie, 'A', 2), pg_temp.asi(v_mie, 'A', 3)], ARRAY['ADULTO', 'ADULTO', 'ADULTO']);
    PERFORM pg_temp.chk('G03', 'RN-07 miercoles 2x1: con 3 entradas solo 1 es gratis (subtotal 18, desc 6, total 12.60)',
        (c ->> 'subtotal')::numeric = 18 AND (c ->> 'descuento')::numeric = 6 AND (c ->> 'total')::numeric = 12.60, c::text);
    PERFORM pg_temp.soltar(c, pg_temp.cli(1));

    c := pg_temp.cotizar(pg_temp.cli(1), v_mie, ARRAY[pg_temp.asi(v_mie, 'A', 1)], ARRAY['ADULTO']);
    PERFORM pg_temp.chk('G03', 'RN-07 miercoles con 1 sola entrada no hay descuento (6 + 5% = 6.30)',
        (c ->> 'descuento')::numeric = 0 AND (c ->> 'total')::numeric = 6.30
        AND (SELECT id_promocion FROM compra WHERE id_compra = (c ->> 'id_compra')::bigint) IS NULL, c::text);
    PERFORM pg_temp.soltar(c, pg_temp.cli(1));

    c := pg_temp.cotizar(pg_temp.cli(1), v_mie, ARRAY[pg_temp.asi(v_mie, 'A', 1), pg_temp.asi(v_mie, 'A', 2), pg_temp.asi(v_mie, 'C', 1), pg_temp.asi(v_mie, 'C', 2)],
                         ARRAY['ADULTO', 'ADULTO', 'ADULTO', 'ADULTO']);
    PERFORM pg_temp.chk('G03', 'RN-07 el 2x1 se aplica por zona: 2 general (6) + 2 platea (8) => desc 14, total 14.70',
        (c ->> 'subtotal')::numeric = 28 AND (c ->> 'descuento')::numeric = 14 AND (c ->> 'total')::numeric = 14.70, c::text);
    PERFORM pg_temp.soltar(c, pg_temp.cli(1));

    c := pg_temp.cotizar(pg_temp.cli(1), v_mar, ARRAY[pg_temp.asi(v_mar, 'A', 1), pg_temp.asi(v_mar, 'A', 2)], ARRAY['ADULTO', 'ADULTO']);
    PERFORM pg_temp.chk('G03', 'RN-07 martes 10%: 2 x 8 => desc 1.60, cargo 0.72, total 15.12',
        (c ->> 'subtotal')::numeric = 16 AND (c ->> 'descuento')::numeric = 1.60 AND (c ->> 'cargo')::numeric = 0.72 AND (c ->> 'total')::numeric = 15.12, c::text);
    PERFORM pg_temp.soltar(c, pg_temp.cli(1));

    c := pg_temp.cotizar(pg_temp.cli(1), v_sab, ARRAY[pg_temp.asi(v_sab, 'A', 1)], ARRAY['ADULTO']);
    PERFORM pg_temp.chk('G03', 'Tarifa por dia: el sabado una entrada general vale 10 (+5% = 10.50)', (c ->> 'subtotal')::numeric = 10 AND (c ->> 'total')::numeric = 10.50, c::text);
    PERFORM pg_temp.soltar(c, pg_temp.cli(1));

    c := pg_temp.cotizar(pg_temp.cli(1), v_lun, ARRAY[pg_temp.asi(v_lun, 'B', 1)], ARRAY['ADULTO']);
    PERFORM pg_temp.chk('G03', 'RN-08 el total siempre es subtotal - descuento + cargo (lo exige un CHECK)',
        (SELECT total = subtotal - descuento_total + cargo_servicio FROM compra WHERE id_compra = (c ->> 'id_compra')::bigint));
    PERFORM pg_temp.chk('G03', 'Validacion: otro cliente no puede armar una compra con mis reservas',
        (SELECT NOT exito AND cod_resultado = 'RESERVAS_INVALIDAS' FROM sp_iniciar_compra(pg_temp.cli(2), ARRAY[(c -> 'reservas' ->> 0)::bigint], ARRAY[pg_temp.te('ADULTO')])));
    PERFORM pg_temp.chk('G03', 'Validacion: las mismas reservas no se pueden meter en dos compras',
        (SELECT NOT exito AND cod_resultado = 'RESERVA_EN_COMPRA' FROM sp_iniciar_compra(pg_temp.cli(1), ARRAY[(c -> 'reservas' ->> 0)::bigint], ARRAY[pg_temp.te('ADULTO')])));
    PERFORM pg_temp.soltar(c, pg_temp.cli(1));
    c := pg_temp.cotizar(pg_temp.cli(1), v_lun, ARRAY[pg_temp.asi(v_lun, 'B', 2)], ARRAY['CORTESIA']);
    PERFORM pg_temp.chk('G03', 'Validacion: el tipo CORTESIA no se puede usar en una compra normal (no tiene tarifa)', c ->> 'error' = 'SIN_TARIFA', c::text);
END $$;

-- ===============================================================
-- G04. PAGO SIMULADO, EMISION DEL QR Y ATOMICIDAD (RN-09 al RN-12)
-- ===============================================================
DO $$
DECLARE
    f      BIGINT := pg_temp.k('f_lun3');
    v_cmp  BIGINT;
    v_cot  JSONB;
    v_p    RECORD;
    v_msg  TEXT;
BEGIN
    v_cot := pg_temp.cotizar(pg_temp.cli(1), f, ARRAY[pg_temp.asi(f, 'A', 1), pg_temp.asi(f, 'A', 2)], ARRAY['ADULTO', 'ADULTO']);
    v_cmp := (v_cot ->> 'id_compra')::bigint;
    PERFORM pg_temp.chk('G04', 'RN-11 antes de pagar los boletos estan PENDIENTE y sin QR',
        (SELECT bool_and(estado = 'PENDIENTE' AND codigo_qr IS NULL) FROM boleto WHERE id_compra = v_cmp));

    v_msg := pg_temp.intenta(format('UPDATE boleto SET estado = %L WHERE id_compra = %s', 'EMITIDO', v_cmp));
    PERFORM pg_temp.chk('G04', 'RN-11 no se puede emitir un boleto de una compra sin pagar (trigger)', v_msg LIKE '%RN-11%', v_msg);
    v_msg := pg_temp.intenta(format('UPDATE compra SET estado = %L WHERE id_compra = %s', 'PAGADA', v_cmp));
    PERFORM pg_temp.chk('G04', 'RN-11 una compra no pasa a PAGADA si no hay pago aprobado (trigger)', v_msg LIKE '%RN-11%', v_msg);

    SELECT * INTO v_p FROM sp_procesar_pago(v_cmp, 1::smallint, NULL, 'VISA', 'APROBADO');
    PERFORM pg_temp.chk('G04', 'RN-09 con tarjeta se piden los ultimos 4 digitos', NOT v_p.exito AND v_p.cod_resultado = 'TARJETA_INVALIDA', v_p.cod_resultado);
    SELECT * INTO v_p FROM sp_procesar_pago(v_cmp, 1::smallint, '4242424242424242', 'VISA', 'APROBADO');
    PERFORM pg_temp.chk('G04', 'RN-09 el numero completo de la tarjeta se rechaza (solo se aceptan 4 digitos)', NOT v_p.exito AND v_p.cod_resultado = 'TARJETA_INVALIDA', v_p.cod_resultado);
    PERFORM pg_temp.chk('G04', 'RN-09 el esquema no tiene columnas de CVV ni de numero de tarjeta',
        NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'imax'
                    AND (column_name ILIKE '%cvv%' OR column_name ILIKE '%cvc%' OR column_name ILIKE '%numero\_tarjeta%' OR column_name ILIKE '%pan'))
        AND (SELECT character_maximum_length FROM information_schema.columns WHERE table_schema = 'imax' AND table_name = 'pago' AND column_name = 'ultimos4') = 4);

    SELECT * INTO v_p FROM sp_procesar_pago(v_cmp, 1::smallint, '4242', 'VISA', 'APROBADO');
    PERFORM pg_temp.chk('G04', 'Pago aprobado: respuesta exitosa', v_p.exito AND v_p.estado_pago = 'APROBADO', v_p.mensaje);
    PERFORM pg_temp.chk('G04', 'Pago aprobado: la compra queda PAGADA', (SELECT estado FROM compra WHERE id_compra = v_cmp) = 'PAGADA');
    PERFORM pg_temp.chk('G04', 'Pago aprobado: los 2 boletos pasan a EMITIDO con QR',
        (SELECT count(*) = 2 AND bool_and(estado = 'EMITIDO' AND codigo_qr LIKE 'IMX-%' AND emitido_en IS NOT NULL) FROM boleto WHERE id_compra = v_cmp));
    PERFORM pg_temp.chk('G04', 'RN-12 cada boleto tiene un QR distinto', (SELECT count(DISTINCT codigo_qr) = 2 FROM boleto WHERE id_compra = v_cmp));
    PERFORM pg_temp.chk('G04', 'RN-12 el QR queda ligado a una reserva (funcion + asiento + zona)',
        (SELECT count(*) = 2 FROM boleto b JOIN reserva_asiento r USING (id_reserva) JOIN asiento a ON a.id_asiento = r.id_asiento
          WHERE b.id_compra = v_cmp AND r.id_funcion = f AND a.id_tipo_asiento IS NOT NULL AND r.estado = 'VENDIDO'));
    PERFORM pg_temp.chk('G04', 'Pago aprobado: los asientos aparecen OCUPADO en el mapa',
        (SELECT count(*) = 2 FROM fn_mapa_asientos(f) WHERE estado = 'OCUPADO' AND fila = 'A' AND numero IN (1, 2)));
    PERFORM pg_temp.chk('G04', 'RN-09 el pago solo guarda los ultimos 4 digitos', (SELECT ultimos4 FROM pago WHERE id_compra = v_cmp AND estado = 'APROBADO') = '4242');
    SELECT * INTO v_p FROM sp_procesar_pago(v_cmp, 1::smallint, '4242', 'VISA', 'APROBADO');
    PERFORM pg_temp.chk('G04', 'No se puede pagar dos veces la misma compra', NOT v_p.exito AND v_p.cod_resultado = 'YA_PAGADA', v_p.cod_resultado);
    v_msg := pg_temp.intenta(format($f$INSERT INTO pago (id_compra, id_metodo_pago, monto, estado, referencia_pasarela, ultimos4) VALUES (%s, 1, 1, 'APROBADO', 'X2', '1234')$f$, v_cmp));
    PERFORM pg_temp.chk('G04', 'UNIQUE parcial: un segundo pago APROBADO para la misma compra falla', v_msg LIKE '23505%', v_msg);

    PERFORM pg_temp.chk('G04', 'RN-20 transaccion_log tiene el ciclo completo de la compra',
        (SELECT array_agg(evento::text ORDER BY evento) FROM transaccion_log WHERE id_compra = v_cmp)
        = ARRAY['BOLETO_EMITIDO', 'BOLETO_EMITIDO', 'COMPRA_CREADA', 'COMPRA_PAGADA', 'PAGO_APROBADO'],
        (SELECT array_agg(evento ORDER BY evento)::text FROM transaccion_log WHERE id_compra = v_cmp));
    PERFORM pg_temp.chk('G04', 'RN-20 asiento_auditoria_log tiene BLOQUEADO y VENDIDO de cada asiento',
        (SELECT count(*) FILTER (WHERE evento = 'BLOQUEADO') = 2 AND count(*) FILTER (WHERE evento = 'VENDIDO') = 2
           FROM asiento_auditoria_log WHERE id_reserva IN (SELECT id_reserva FROM boleto WHERE id_compra = v_cmp)));

    v_cot := pg_temp.cotizar(pg_temp.cli(2), f, ARRAY[pg_temp.asi(f, 'B', 1), pg_temp.asi(f, 'B', 2)], ARRAY['ADULTO', 'ESTUDIANTE']);
    v_cmp := (v_cot ->> 'id_compra')::bigint;
    SELECT * INTO v_p FROM sp_procesar_pago(v_cmp, 1::smallint, '1111', 'MASTERCARD', 'RECHAZADO');
    PERFORM pg_temp.chk('G04', 'RN-10 pago rechazado: la respuesta es exito = false', NOT v_p.exito AND v_p.estado_pago = 'RECHAZADO', v_p.mensaje);
    PERFORM pg_temp.chk('G04', 'RN-10 pago rechazado: compra FALLIDA, boletos ANULADO y sin QR',
        (SELECT estado FROM compra WHERE id_compra = v_cmp) = 'FALLIDA'
        AND (SELECT bool_and(estado = 'ANULADO' AND codigo_qr IS NULL) FROM boleto WHERE id_compra = v_cmp));
    PERFORM pg_temp.chk('G04', 'RN-10 pago rechazado: los asientos se liberan de inmediato',
        (SELECT count(*) = 2 FROM fn_mapa_asientos(f) WHERE estado = 'DISPONIBLE' AND fila = 'B' AND numero IN (1, 2)));
    PERFORM pg_temp.chk('G04', 'RN-10 pago rechazado: queda el pago RECHAZADO y ninguno aprobado',
        (SELECT count(*) FILTER (WHERE estado = 'RECHAZADO') = 1 AND count(*) FILTER (WHERE estado = 'APROBADO') = 0 FROM pago WHERE id_compra = v_cmp));
    PERFORM pg_temp.chk('G04', 'RN-10 pago rechazado: queda en la bitacora PAGO_RECHAZADO y COMPRA_FALLIDA',
        (SELECT count(*) = 2 FROM transaccion_log WHERE id_compra = v_cmp AND evento IN ('PAGO_RECHAZADO', 'COMPRA_FALLIDA')));
    PERFORM pg_temp.chk('G04', 'RN-10 pago rechazado: otro cliente puede comprar ese asiento enseguida',
        pg_temp.comprar(pg_temp.cli(3), f, ARRAY[pg_temp.asi(f, 'B', 1)], ARRAY['ADULTO']) IS NOT NULL);

    v_cot := pg_temp.cotizar(pg_temp.cli(2), f, ARRAY[pg_temp.asi(f, 'B', 3)], ARRAY['ADULTO']);
    v_cmp := (v_cot ->> 'id_compra')::bigint;
    UPDATE reserva_asiento SET bloqueado_en = now() - INTERVAL '3 minutes', bloqueado_hasta = now() - INTERVAL '1 minute' WHERE id_reserva = (v_cot -> 'reservas' ->> 0)::bigint;
    SELECT * INTO v_p FROM sp_procesar_pago(v_cmp, 1::smallint, '4242', 'VISA', 'APROBADO');
    PERFORM pg_temp.chk('G04', 'RN-05 pagar despues de los 2 minutos se rechaza y deja todo liberado',
        NOT v_p.exito AND v_p.cod_resultado = 'BLOQUEO_EXPIRADO' AND (SELECT estado FROM compra WHERE id_compra = v_cmp) = 'EXPIRADA'
        AND NOT EXISTS (SELECT 1 FROM pago WHERE id_compra = v_cmp), v_p.cod_resultado);

    v_cot := pg_temp.cotizar(pg_temp.cli(2), f, ARRAY[pg_temp.asi(f, 'B', 4)], ARRAY['ADULTO']);
    SELECT * INTO v_p FROM sp_procesar_pago((v_cot ->> 'id_compra')::bigint, (SELECT id_metodo_pago FROM metodo_pago WHERE codigo = 'PAYPAL'), NULL, NULL, 'APROBADO');
    PERFORM pg_temp.chk('G04', 'Los metodos sin tarjeta (PayPal) no piden los 4 digitos', v_p.exito, v_p.mensaje);
END $$;

-- atomicidad: si la transaccion se revierte, el pago completo se revierte (ACID)
DO $$
DECLARE
    f     BIGINT := pg_temp.k('f_lun3');
    v_cot JSONB;
    v_cmp BIGINT;
    v_p   RECORD;
BEGIN
    v_cot := pg_temp.cotizar(pg_temp.cli(4), f, ARRAY[pg_temp.asi(f, 'D', 1)], ARRAY['ADULTO']);
    v_cmp := (v_cot ->> 'id_compra')::bigint;
    BEGIN
        SELECT * INTO v_p FROM sp_procesar_pago(v_cmp, 1::smallint, '4242', 'VISA', 'APROBADO');
        IF NOT v_p.exito THEN RAISE EXCEPTION 'el pago no funciono: %', v_p.mensaje; END IF;
        RAISE EXCEPTION 'rollback forzado';
    EXCEPTION WHEN OTHERS THEN
        NULL;   -- el subbloque se revierte completo, igual que un ROLLBACK
    END;
    PERFORM pg_temp.chk('G04', 'ACID: si la transaccion se revierte el pago se deshace (compra PENDIENTE, sin pago, sin QR)',
        (SELECT estado FROM compra WHERE id_compra = v_cmp) = 'PENDIENTE'
        AND NOT EXISTS (SELECT 1 FROM pago WHERE id_compra = v_cmp)
        AND (SELECT bool_and(estado = 'PENDIENTE' AND codigo_qr IS NULL) FROM boleto WHERE id_compra = v_cmp));
    PERFORM pg_temp.soltar(v_cot, pg_temp.cli(4));
END $$;

-- RN-04 a nivel de tabla: el boleto 7 de una misma compra lo frena el trigger
DO $$
DECLARE
    f      BIGINT := pg_temp.k('f_lun5');
    v_comp BIGINT;
    v_res  BIGINT;
    v_msg  TEXT := 'SIN ERROR';
    v_i    INTEGER;
    v_ok   INTEGER := 0;
BEGIN
    INSERT INTO compra (id_usuario, canal, subtotal, total, expira_en) VALUES (pg_temp.cli(5), 'WEB', 0, 0, now() + INTERVAL '2 minutes') RETURNING id_compra INTO v_comp;
    FOR v_i IN 1 .. 7 LOOP
        INSERT INTO reserva_asiento (id_funcion, id_sala, id_asiento, id_usuario, estado, bloqueado_hasta)
        VALUES (f, pg_temp.k('sala_heredia')::int, pg_temp.asi(f, 'E', v_i), pg_temp.cli(5), 'BLOQUEADO', now() + INTERVAL '2 minutes') RETURNING id_reserva INTO v_res;
        v_msg := pg_temp.intenta(format('INSERT INTO boleto (id_compra, id_reserva, id_tipo_entrada, precio_base, precio_final) VALUES (%s, %s, %s, 8, 8)',
                                        v_comp, v_res, pg_temp.te('ADULTO')));
        EXIT WHEN v_msg <> 'OK';
        v_ok := v_ok + 1;
    END LOOP;
    PERFORM pg_temp.chk('G04', 'RN-04 el trigger no deja un boleto 7 en la misma compra (maximo 6)', v_ok = 6 AND v_msg LIKE '%RN-04%', v_ok || ' boletos entraron; el siguiente: ' || v_msg);
    UPDATE reserva_asiento SET estado = 'LIBERADO', motivo_cierre = 'PRUEBA' WHERE id_funcion = f AND id_usuario = pg_temp.cli(5) AND estado = 'BLOQUEADO';
END $$;

-- ===============================================================
-- G05. CHECK-IN EN LA PUERTA (RN-13 al RN-17)
-- ===============================================================
DO $$
DECLARE
    f       BIGINT := pg_temp.k('f_chk');
    ini     TIMESTAMPTZ;
    v_cmp   BIGINT;
    b       BIGINT[];
    op      INTEGER := pg_temp.staff('OPERADOR_SALA');
    pu      INTEGER := pg_temp.k('puerta_heredia');
    r       RECORD;
    v_n     INTEGER;
BEGIN
    SELECT inicio INTO ini FROM funcion WHERE id_funcion = f;
    v_cmp := pg_temp.comprar(pg_temp.cli(1), f,
        ARRAY[pg_temp.asi(f, 'A', 1), pg_temp.asi(f, 'A', 2), pg_temp.asi(f, 'A', 3), pg_temp.asi(f, 'A', 4), pg_temp.asi(f, 'A', 5)],
        ARRAY['ADULTO', 'ADULTO', 'ADULTO', 'NINO', 'ADULTO']);
    -- se ordenan para que el boleto de nino quede en la posicion 4 (los ids no siguen el orden en que se pidieron)
    SELECT array_agg(id_boleto ORDER BY (id_tipo_entrada = pg_temp.te('NINO')), id_boleto) INTO b FROM boleto WHERE id_compra = v_cmp;
    b := ARRAY[b[1], b[2], b[3], b[5], b[4]];
    PERFORM pg_temp.chk('G05', 'Preparacion: compra de 5 entradas pagada', v_cmp IS NOT NULL AND cardinality(b) = 5, coalesce(v_cmp::text, 'NULL'));

    SELECT * INTO r FROM fn_validar_entrada_interna(pg_temp.qr(b[1]), pu, op, ini - INTERVAL '31 minutes');
    PERFORM pg_temp.chk('G05', 'RN-16 31 min antes de la funcion se rechaza', NOT r.exito AND r.cod_resultado = 'RECHAZADO_HORARIO', r.cod_resultado || ': ' || r.mensaje);
    PERFORM pg_temp.chk('G05', 'RN-16 un rechazo por horario no gasta la entrada (sigue EMITIDO)', (SELECT estado FROM boleto WHERE id_boleto = b[1]) = 'EMITIDO');
    SELECT * INTO r FROM fn_validar_entrada_interna(pg_temp.qr(b[1]), pu, op, ini - INTERVAL '30 minutes');
    PERFORM pg_temp.chk('G05', 'RN-16 exactamente 30 min antes se acepta', r.exito AND r.cod_resultado = 'EXITOSO', r.cod_resultado || ': ' || r.mensaje);
    PERFORM pg_temp.chk('G05', 'RN-13 al ingresar el boleto pasa a USADO con la hora de uso',
        (SELECT estado = 'USADO' AND usado_en = ini - INTERVAL '30 minutes' FROM boleto WHERE id_boleto = b[1]));
    SELECT * INTO r FROM fn_validar_entrada_interna(pg_temp.qr(b[1]), pu, op, ini);
    PERFORM pg_temp.chk('G05', 'RN-14 el mismo QR una segunda vez dice exactamente "Entrada ya utilizada"',
        NOT r.exito AND r.cod_resultado = 'RECHAZADO_DUPLICADO' AND r.mensaje = 'Entrada ya utilizada', r.cod_resultado || ': ' || r.mensaje);

    SELECT * INTO r FROM fn_validar_entrada_interna(pg_temp.qr(b[2]), pu, op, ini + INTERVAL '15 minutes');
    PERFORM pg_temp.chk('G05', 'RN-16 exactamente 15 min despues del inicio se acepta', r.exito, r.cod_resultado || ': ' || r.mensaje);
    SELECT * INTO r FROM fn_validar_entrada_interna(pg_temp.qr(b[3]), pu, op, ini + INTERVAL '15 minutes 1 second');
    PERFORM pg_temp.chk('G05', 'RN-16 15 min y 1 segundo despues del inicio se rechaza', NOT r.exito AND r.cod_resultado = 'RECHAZADO_HORARIO', r.cod_resultado);

    SELECT * INTO r FROM fn_validar_entrada_interna(pg_temp.qr(b[4]), pu, op, ini);
    PERFORM pg_temp.chk('G05', 'RN-06 la entrada de nino aprueba pero avisa que hay que verificar documento',
        r.exito AND r.mensaje ILIKE '%verificar documento%', r.mensaje);

    SELECT * INTO r FROM fn_validar_entrada_interna(pg_temp.qr(b[5]), pg_temp.k('puerta_escazu')::int, op, ini);
    PERFORM pg_temp.chk('G05', 'RN-15 una puerta de otra sala rechaza la entrada', NOT r.exito AND r.cod_resultado = 'RECHAZADO_FUNCION', r.cod_resultado || ': ' || r.mensaje);
    PERFORM pg_temp.chk('G05', 'RN-15 y el boleto no se gasta', (SELECT estado FROM boleto WHERE id_boleto = b[5]) = 'EMITIDO');
    SELECT * INTO r FROM fn_validar_entrada_interna(pg_temp.qr(b[5]), pu, op, ini);
    PERFORM pg_temp.chk('G05', 'RN-15 en la puerta correcta si entra', r.exito, r.cod_resultado);

    SELECT * INTO r FROM fn_validar_entrada_interna('IMX-no-existe', pu, op, ini);
    PERFORM pg_temp.chk('G05', 'Un QR que no existe se rechaza', NOT r.exito AND r.cod_resultado = 'RECHAZADO_INVALIDO', r.cod_resultado);
    SELECT * INTO r FROM fn_validar_entrada_interna(pg_temp.qr(b[3]), pu, pg_temp.cli(1), ini);
    PERFORM pg_temp.chk('G05', 'Un cliente no puede validar entradas (RECHAZADO_OPERADOR)', NOT r.exito AND r.cod_resultado = 'RECHAZADO_OPERADOR', r.cod_resultado);
    SELECT * INTO r FROM fn_validar_entrada_interna(pg_temp.qr(b[3]), 9999, op, ini);
    PERFORM pg_temp.chk('G05', 'Una puerta que no existe se rechaza', NOT r.exito AND r.cod_resultado = 'PUERTA_INVALIDA', r.cod_resultado);

    SELECT * INTO r FROM sp_validar_entrada(pg_temp.qr(b[3]), pu, op);
    PERFORM pg_temp.chk('G05', 'sp_validar_entrada (hora real) rechaza una funcion que es dentro de dias', NOT r.exito AND r.cod_resultado = 'RECHAZADO_HORARIO', r.cod_resultado);

    SELECT count(*) INTO v_n FROM acceso_puerta_log WHERE id_boleto = ANY (b) OR codigo_leido = 'IMX-no-existe';
    PERFORM pg_temp.chk('G05', 'RN-17 cada escaneo, bueno o malo, queda en acceso_puerta_log', v_n = 10, v_n::text);
    PERFORM pg_temp.chk('G05', 'RN-17 el log guarda resultado, puerta y operador',
        (SELECT count(*) FROM acceso_puerta_log WHERE id_boleto = b[1] AND resultado = 'EXITOSO' AND id_puerta = pu AND id_operador = op) = 1);
    v_n := (SELECT count(*) FROM boleto WHERE id_boleto = ANY (b) AND estado = 'USADO');
    PERFORM pg_temp.chk('G05', 'De los 5 boletos quedaron USADO 4 (el 3 nunca entro)', v_n = 4, v_n::text);
END $$;

-- ===============================================================
-- G06. REEMBOLSOS Y CANCELACION DE FUNCION (RN-19)
-- ===============================================================
DO $$
DECLARE
    f      BIGINT := pg_temp.k('f_lun4');
    fc     BIGINT := pg_temp.k('f_cercana');
    adm    INTEGER := pg_temp.staff('ADMIN');
    v_cmp  BIGINT;
    b      BIGINT[];
    r      RECORD;
    v_mon  NUMERIC;
    v_usado BIGINT;
BEGIN
    v_cmp := pg_temp.comprar(pg_temp.cli(1), f, ARRAY[pg_temp.asi(f, 'A', 1), pg_temp.asi(f, 'A', 2)], ARRAY['ADULTO', 'ADULTO']);
    b := pg_temp.bols(v_cmp);

    SELECT * INTO r FROM sp_solicitar_reembolso(b[1], pg_temp.cli(2), 'no es mio');
    PERFORM pg_temp.chk('G06', 'RN-19 otro cliente no puede reembolsar mi entrada', NOT r.exito AND r.cod_resultado = 'NO_AUTORIZADO', r.cod_resultado);
    SELECT * INTO r FROM sp_solicitar_reembolso(b[1], pg_temp.staff('CONTADOR'), 'x');
    PERFORM pg_temp.chk('G06', 'RN-19 un contador no puede pedir reembolsos', NOT r.exito AND r.cod_resultado = 'ROL_NO_PERMITIDO', r.cod_resultado);

    SELECT * INTO r FROM sp_solicitar_reembolso(b[1], pg_temp.cli(1), 'cambio de planes');
    SELECT precio_final INTO v_mon FROM boleto WHERE id_boleto = b[1];
    PERFORM pg_temp.chk('G06', 'RN-19 reembolso dentro del plazo: OK y devuelve el precio del boleto', r.exito AND r.monto_reembolsado = v_mon, r.cod_resultado || ' ' || coalesce(r.monto_reembolsado::text, '-'));
    PERFORM pg_temp.chk('G06', 'RN-19 el boleto queda REEMBOLSADO y el asiento libre',
        (SELECT estado FROM boleto WHERE id_boleto = b[1]) = 'REEMBOLSADO'
        AND (SELECT estado FROM fn_mapa_asientos(f) WHERE fila = 'A' AND numero = 1) = 'DISPONIBLE');
    PERFORM pg_temp.chk('G06', 'RN-19 la compra queda REEMBOLSADA_PARCIAL', (SELECT estado FROM compra WHERE id_compra = v_cmp) = 'REEMBOLSADA_PARCIAL');
    PERFORM pg_temp.chk('G06', 'RN-19 el reembolso queda en la tabla reembolso y en transaccion_log',
        EXISTS (SELECT 1 FROM reembolso WHERE id_boleto = b[1] AND monto = v_mon)
        AND EXISTS (SELECT 1 FROM transaccion_log WHERE id_boleto = b[1] AND evento = 'REEMBOLSO'),
        (SELECT string_agg(tipo, ',') FROM reembolso WHERE id_boleto = b[1]));
    SELECT * INTO r FROM sp_solicitar_reembolso(b[1], pg_temp.cli(1), 'otra vez');
    PERFORM pg_temp.chk('G06', 'RN-19 no se puede reembolsar dos veces el mismo boleto', NOT r.exito AND r.cod_resultado = 'ESTADO_INVALIDO', r.cod_resultado);
    SELECT * INTO r FROM fn_validar_entrada_interna(pg_temp.qr(b[1]), pg_temp.k('puerta_heredia')::int, pg_temp.staff('OPERADOR_SALA'), (SELECT inicio FROM funcion WHERE id_funcion = f));
    PERFORM pg_temp.chk('G06', 'RN-19 el QR de un boleto reembolsado ya no entra', NOT r.exito AND r.cod_resultado = 'RECHAZADO_ESTADO', r.cod_resultado);
    PERFORM pg_temp.chk('G06', 'RN-19 el asiento reembolsado lo puede comprar otro cliente',
        pg_temp.comprar(pg_temp.cli(3), f, ARRAY[pg_temp.asi(f, 'A', 1)], ARRAY['ADULTO']) IS NOT NULL);
    SELECT * INTO r FROM sp_solicitar_reembolso(b[2], pg_temp.cli(1), 'segundo');
    PERFORM pg_temp.chk('G06', 'RN-19 al reembolsar el ultimo boleto la compra queda REEMBOLSADA', r.exito AND (SELECT estado FROM compra WHERE id_compra = v_cmp) = 'REEMBOLSADA', r.cod_resultado);

    v_cmp := pg_temp.comprar(pg_temp.cli(1), fc, ARRAY[pg_temp.asi(fc, 'A', 1)], ARRAY['ADULTO']);
    b := pg_temp.bols(v_cmp);
    PERFORM pg_temp.chk('G06', 'Preparacion: compra para la funcion que empieza en 1 hora', v_cmp IS NOT NULL, coalesce(v_cmp::text, 'NULL'));
    SELECT * INTO r FROM sp_solicitar_reembolso(b[1], pg_temp.cli(1), 'tarde');
    PERFORM pg_temp.chk('G06', 'RN-19 a menos de 2 horas de la funcion el cliente no puede reembolsar', NOT r.exito AND r.cod_resultado = 'FUERA_DE_PLAZO', r.cod_resultado || ': ' || r.mensaje);
    SELECT * INTO r FROM sp_admin_reembolso_forzado(pg_temp.cli(1), b[1], 'x', NULL);
    PERFORM pg_temp.chk('G06', 'RN-19 un cliente no puede hacer reembolso forzado', NOT r.exito AND r.cod_resultado = 'NO_AUTORIZADO', r.cod_resultado);
    SELECT * INTO r FROM sp_admin_reembolso_forzado(adm, b[1], NULL, NULL);
    PERFORM pg_temp.chk('G06', 'RN-19 el reembolso forzado exige motivo', NOT r.exito AND r.cod_resultado = 'MOTIVO_OBLIGATORIO', r.cod_resultado);
    SELECT * INTO r FROM sp_admin_reembolso_forzado(adm, b[1], 'el cliente tuvo un problema en la sala', '10.0.0.5');
    PERFORM pg_temp.chk('G06', 'RN-19 el admin si puede reembolsar fuera de plazo', r.exito, r.cod_resultado || ': ' || r.mensaje);
    PERFORM pg_temp.chk('G06', 'RN-19 el forzado queda como tipo FORZADO con el admin', EXISTS (SELECT 1 FROM reembolso WHERE id_boleto = b[1] AND tipo = 'FORZADO' AND id_admin = adm),
        (SELECT string_agg(tipo, ',') FROM reembolso WHERE id_boleto = b[1]));
    PERFORM pg_temp.chk('G06', 'RN-19 el forzado deja registro en admin_operacion_audit con motivo e IP',
        EXISTS (SELECT 1 FROM admin_operacion_audit WHERE id_usuario_admin = adm AND entidad = 'boleto' AND id_entidad = b[1]::text AND motivo ILIKE '%problema en la sala%' AND ip_origen = '10.0.0.5'::inet),
        (SELECT string_agg(accion || '/' || entidad || '/' || coalesce(host(ip_origen), '-'), ' | ') FROM admin_operacion_audit WHERE id_entidad = b[1]::text));

    SELECT id_boleto INTO v_usado FROM boleto WHERE estado = 'USADO' LIMIT 1;
    SELECT * INTO r FROM sp_solicitar_reembolso(v_usado, pg_temp.cli(1), 'ya entre');
    PERFORM pg_temp.chk('G06', 'RN-19 una entrada ya USADA no se reembolsa', NOT r.exito, r.cod_resultado);
END $$;

DO $$
DECLARE
    fc    BIGINT := pg_temp.k('f_canc');
    adm   INTEGER := pg_temp.staff('ADMIN');
    r     RECORD;
    c1    BIGINT;
    c2    BIGINT;
    v_tot NUMERIC;
    v_n   INTEGER;
BEGIN
    c1 := pg_temp.comprar(pg_temp.cli(1), fc, ARRAY[pg_temp.asi(fc, 'A', 1), pg_temp.asi(fc, 'A', 2)], ARRAY['ADULTO', 'ADULTO']);
    c2 := pg_temp.comprar(pg_temp.cli(2), fc, ARRAY[pg_temp.asi(fc, 'C', 1)], ARRAY['ADULTO']);
    SELECT sum(precio_final) INTO v_tot FROM boleto WHERE id_compra IN (c1, c2);
    SELECT * INTO r FROM sp_cancelar_funcion(pg_temp.cli(1), fc, 'x', NULL);
    PERFORM pg_temp.chk('G06', 'Cancelar funcion: un cliente no puede', NOT r.exito AND r.cod_resultado = 'NO_AUTORIZADO', r.cod_resultado);
    SELECT * INTO r FROM sp_cancelar_funcion(adm, fc, '', NULL);
    PERFORM pg_temp.chk('G06', 'Cancelar funcion: exige motivo', NOT r.exito AND r.cod_resultado = 'MOTIVO_OBLIGATORIO', r.cod_resultado);
    SELECT * INTO r FROM sp_cancelar_funcion(adm, fc, 'falla del proyector', '10.0.0.5');
    PERFORM pg_temp.chk('G06', 'Cancelar funcion: reembolsa los 3 boletos por el monto total', r.exito AND r.boletos_reembolsados = 3 AND r.monto_total = v_tot,
        r.cod_resultado || ' ' || coalesce(r.boletos_reembolsados::text, '-') || ' ' || coalesce(r.monto_total::text, '-') || ' vs ' || v_tot);
    PERFORM pg_temp.chk('G06', 'Cancelar funcion: la funcion queda CANCELADA y desaparece de la cartelera',
        (SELECT estado FROM funcion WHERE id_funcion = fc) = 'CANCELADA' AND NOT EXISTS (SELECT 1 FROM v_cartelera WHERE id_funcion = fc));
    PERFORM pg_temp.chk('G06', 'Cancelar funcion: ya no hay asientos activos y las compras quedan REEMBOLSADA',
        NOT EXISTS (SELECT 1 FROM reserva_asiento WHERE id_funcion = fc AND estado IN ('BLOQUEADO', 'VENDIDO'))
        AND (SELECT bool_and(estado = 'REEMBOLSADA') FROM compra WHERE id_compra IN (c1, c2)));
    SELECT count(*) INTO v_n FROM reembolso WHERE id_boleto = ANY (pg_temp.bols(c1) || pg_temp.bols(c2)) AND tipo = 'CANCELACION_FUNCION';
    PERFORM pg_temp.chk('G06', 'Cancelar funcion: cada reembolso queda como tipo CANCELACION_FUNCION', v_n = 3, v_n::text);
    SELECT * INTO r FROM sp_bloquear_asiento(fc, pg_temp.asi(fc, 'D', 1), pg_temp.cli(3));
    PERFORM pg_temp.chk('G06', 'Cancelar funcion: ya no se pueden bloquear asientos', NOT r.exito AND r.cod_resultado = 'FUNCION_NO_DISPONIBLE', r.cod_resultado);
END $$;

-- ===============================================================
-- G07. OPERACIONES DEL ADMINISTRADOR Y SU AUDITORIA
-- ===============================================================
DO $$
DECLARE
    f      BIGINT := pg_temp.k('f_adm');
    adm    INTEGER := pg_temp.staff('ADMIN');
    r      RECORD;
    v_b    BIGINT;
    v_qr   TEXT;
    v_n    INTEGER;
    v_cmp  BIGINT;
    v_old  NUMERIC;
BEGIN
    SELECT * INTO r FROM sp_admin_otorgar_cortesia(pg_temp.cli(1), f, pg_temp.asi(f, 'E', 1), pg_temp.cli(2), 'x', NULL);
    PERFORM pg_temp.chk('G07', 'Cortesia: un cliente no puede darla', NOT r.exito AND r.cod_resultado = 'NO_AUTORIZADO', r.cod_resultado);
    SELECT * INTO r FROM sp_admin_otorgar_cortesia(adm, f, pg_temp.asi(f, 'E', 1), pg_temp.cli(2), 'invitado de la prensa', '10.0.0.7');
    PERFORM pg_temp.chk('G07', 'Cortesia: el admin la emite con QR', r.exito AND r.codigo_qr LIKE 'IMX-%', r.cod_resultado || ': ' || r.mensaje);
    v_b := r.id_boleto_nuevo;
    PERFORM pg_temp.chk('G07', 'Cortesia: precio 0, compra CORTESIA ya PAGADA, boleto EMITIDO',
        (SELECT b.precio_final = 0 AND b.estado = 'EMITIDO' AND c.canal = 'CORTESIA' AND c.estado = 'PAGADA' AND c.total = 0
           FROM boleto b JOIN compra c USING (id_compra) WHERE b.id_boleto = v_b));
    PERFORM pg_temp.chk('G07', 'Cortesia: queda en admin_operacion_audit con motivo e IP',
        EXISTS (SELECT 1 FROM admin_operacion_audit WHERE id_usuario_admin = adm AND motivo ILIKE '%prensa%' AND ip_origen = '10.0.0.7'::inet));
    SELECT * INTO r FROM sp_solicitar_reembolso(v_b, pg_temp.cli(2), 'quiero mi plata');
    PERFORM pg_temp.chk('G07', 'Cortesia: no se reembolsa', NOT r.exito AND r.cod_resultado = 'CORTESIA', r.cod_resultado);
    SELECT * INTO r FROM sp_admin_otorgar_cortesia(adm, f, pg_temp.asi(f, 'E', 1), pg_temp.cli(3), 'otra', NULL);
    PERFORM pg_temp.chk('G07', 'Cortesia: no se puede dar un asiento ya ocupado', NOT r.exito AND r.cod_resultado = 'ASIENTO_OCUPADO', r.cod_resultado);

    v_cmp := pg_temp.comprar(pg_temp.cli(1), f, ARRAY[pg_temp.asi(f, 'A', 1)], ARRAY['ADULTO']);
    v_b := (pg_temp.bols(v_cmp))[1];
    v_qr := pg_temp.qr(v_b);
    SELECT * INTO r FROM sp_admin_cambiar_asiento(adm, v_b, pg_temp.asi(f, 'E', 1), 'se danio el asiento', '10.0.0.7');
    PERFORM pg_temp.chk('G07', 'Cambio de asiento: no se puede mover a un asiento ocupado', NOT r.exito AND r.cod_resultado = 'ASIENTO_OCUPADO', r.cod_resultado);
    SELECT * INTO r FROM sp_admin_cambiar_asiento(adm, v_b, pg_temp.asi(f, 'A', 7), '', NULL);
    PERFORM pg_temp.chk('G07', 'Cambio de asiento: exige motivo', NOT r.exito AND r.cod_resultado = 'MOTIVO_OBLIGATORIO', r.cod_resultado);
    SELECT * INTO r FROM sp_admin_cambiar_asiento(adm, v_b, pg_temp.asi(f, 'A', 7), 'se danio el asiento', '10.0.0.7');
    PERFORM pg_temp.chk('G07', 'Cambio de asiento: el admin lo mueve a A7', r.exito, r.cod_resultado || ': ' || r.mensaje);
    PERFORM pg_temp.chk('G07', 'Cambio de asiento: A1 queda libre, A7 ocupado y el QR no cambia',
        (SELECT estado FROM fn_mapa_asientos(f) WHERE fila = 'A' AND numero = 1) = 'DISPONIBLE'
        AND (SELECT estado FROM fn_mapa_asientos(f) WHERE fila = 'A' AND numero = 7) = 'OCUPADO'
        AND pg_temp.qr(v_b) = v_qr);
    PERFORM pg_temp.chk('G07', 'Cambio de asiento: queda en admin_operacion_audit con valores antes y despues',
        EXISTS (SELECT 1 FROM admin_operacion_audit WHERE id_usuario_admin = adm AND entidad = 'boleto' AND id_entidad = v_b::text
                AND valores_antes IS NOT NULL AND valores_despues IS NOT NULL AND motivo ILIKE '%asiento%'));

    PERFORM sp_set_contexto(adm, '10.0.0.9'::inet, FALSE);
    SELECT precio INTO v_old FROM tarifa ORDER BY id_tarifa LIMIT 1;
    UPDATE tarifa SET precio = precio + 1 WHERE id_tarifa = (SELECT min(id_tarifa) FROM tarifa);
    PERFORM pg_temp.chk('G07', 'Trigger de auditoria: cambiar una tarifa queda en admin_operacion_audit con el admin y la IP del contexto',
        EXISTS (SELECT 1 FROM admin_operacion_audit WHERE entidad = 'tarifa' AND accion = 'UPDATE' AND id_usuario_admin = adm AND ip_origen = '10.0.0.9'::inet
                AND (valores_antes ->> 'precio')::numeric = v_old AND (valores_despues ->> 'precio')::numeric = v_old + 1));
    UPDATE tarifa SET precio = v_old WHERE id_tarifa = (SELECT min(id_tarifa) FROM tarifa);
    UPDATE parametro_sistema SET valor = '6' WHERE clave = 'max_asientos_por_compra';
    SELECT count(*) INTO v_n FROM admin_operacion_audit WHERE entidad = 'parametro_sistema' AND id_entidad = 'max_asientos_por_compra';
    PERFORM pg_temp.chk('G07', 'Trigger de auditoria: un UPDATE que no cambia nada no genera registro', v_n = 0, v_n::text);
    UPDATE usuario SET id_rol = (SELECT id_rol FROM rol WHERE codigo = 'TAQUILLERO') WHERE id_usuario = pg_temp.cli(5);
    PERFORM pg_temp.chk('G07', 'Trigger de auditoria: cambiar el rol de un usuario queda registrado',
        EXISTS (SELECT 1 FROM admin_operacion_audit WHERE entidad = 'usuario' AND id_entidad = pg_temp.cli(5)::text AND accion = 'UPDATE'));
    UPDATE usuario SET id_rol = (SELECT id_rol FROM rol WHERE codigo = 'CLIENTE') WHERE id_usuario = pg_temp.cli(5);
    PERFORM sp_set_contexto(NULL, NULL, FALSE);
END $$;

-- ===============================================================
-- G08. BITACORAS INALTERABLES Y PARTICIONES (RN-20)
-- ===============================================================
DO $$
DECLARE
    t   TEXT;
    v_r TEXT;
    v_n INTEGER;
BEGIN
    FOREACH t IN ARRAY ARRAY['transaccion_log', 'asiento_auditoria_log', 'acceso_puerta_log', 'admin_operacion_audit'] LOOP
        EXECUTE format('SELECT count(*) FROM %I', t) INTO v_n;
        PERFORM pg_temp.chk('G08', 'RN-20 ' || t || ': tiene registros de las pruebas anteriores', v_n > 0, v_n::text);
        v_r := pg_temp.intenta(format('UPDATE %I SET creado_en = creado_en', t));
        PERFORM pg_temp.chk('G08', 'RN-20 ' || t || ': UPDATE bloqueado', v_r LIKE '%RN-20%', v_r);
        v_r := pg_temp.intenta(format('DELETE FROM %I', t));
        PERFORM pg_temp.chk('G08', 'RN-20 ' || t || ': DELETE bloqueado', v_r LIKE '%RN-20%', v_r);
        v_r := pg_temp.intenta(format('TRUNCATE %I', t));
        PERFORM pg_temp.chk('G08', 'RN-20 ' || t || ': TRUNCATE bloqueado', v_r LIKE '%RN-20%', v_r);
        SELECT count(*) INTO v_n FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhparent WHERE p.relname = t;
        PERFORM pg_temp.chk('G08', 'Particionado: ' || t || ' tiene particiones por rango de fecha', v_n >= 4, v_n::text);
    END LOOP;

    PERFORM pg_temp.chk('G08', 'Particionado: los registros de hoy caen en la particion del mes, no en la DEFAULT',
        (SELECT count(*) FROM transaccion_log WHERE tableoid::regclass::text LIKE '%default') = 0
        AND (SELECT count(*) FROM transaccion_log) > 0,
        (SELECT string_agg(DISTINCT tableoid::regclass::text, ',') FROM transaccion_log));
    PERFORM pg_temp.chk('G08', 'Diseno: las bitacoras no tienen llaves foraneas (referencias logicas, para poder archivar particiones)',
        (SELECT count(*) FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
          WHERE c.contype = 'f' AND t.relname ~ '^(transaccion_log|asiento_auditoria_log|acceso_puerta_log|admin_operacion_audit)') = 0);
    PERFORM pg_temp.chk('G08', 'Archivado: fn_particiones_para_archivar se puede consultar sin error',
        pg_temp.intenta('SELECT * FROM fn_particiones_para_archivar(1)') = 'OK');
END $$;

-- ===============================================================
-- G09. RESTRICCIONES DE INTEGRIDAD Y MAQUINAS DE ESTADO
-- ===============================================================
DO $$
DECLARE
    v_r   TEXT;
    v_cmp BIGINT;
    v_b   BIGINT;
    f     BIGINT := pg_temp.k('f_mar');
    v_a   INTEGER;
BEGIN
    v_r := pg_temp.intenta($f$INSERT INTO usuario (id_rol, nombre, apellidos, correo) VALUES (1, 'Repetido', 'Prueba', 'cliente1@imax.test')$f$);
    PERFORM pg_temp.chk('G09', 'UNIQUE: el correo de un usuario no se repite', v_r LIKE '23505%', v_r);
    v_r := pg_temp.intenta($f$INSERT INTO usuario (id_rol, nombre, apellidos, correo) VALUES (1, 'Mayusculas', 'Prueba', 'CLIENTE9@IMAX.TEST')$f$);
    PERFORM pg_temp.chk('G09', 'CHECK: el correo se guarda en minusculas', v_r LIKE '23514%', v_r);
    v_r := pg_temp.intenta('UPDATE tarifa SET precio = -1 WHERE id_tarifa = (SELECT min(id_tarifa) FROM tarifa)');
    PERFORM pg_temp.chk('G09', 'CHECK: una tarifa no puede ser negativa', v_r LIKE '23514%', v_r);
    v_r := pg_temp.intenta('DELETE FROM pelicula WHERE id_pelicula = (SELECT min(id_pelicula) FROM pelicula)');
    PERFORM pg_temp.chk('G09', 'FK: no se puede borrar una pelicula que tiene funciones', v_r LIKE '23503%', v_r);
    v_r := pg_temp.intenta($f$INSERT INTO funcion (id_pelicula, id_sala, inicio) VALUES (999999, 1, now() + INTERVAL '30 days')$f$);
    PERFORM pg_temp.chk('G09', 'FK: no se puede programar una funcion de una pelicula que no existe', v_r <> 'OK', v_r);

    SELECT a.id_asiento INTO v_a FROM reserva_asiento r JOIN asiento a USING (id_asiento) WHERE r.estado = 'VENDIDO' LIMIT 1;
    v_r := pg_temp.intenta(format('DELETE FROM asiento WHERE id_asiento = %s', v_a));
    PERFORM pg_temp.chk('G09', 'RN-18 no se puede borrar un asiento de una sala con entradas vendidas', v_r LIKE '%RN-18%', v_r);
    v_r := pg_temp.intenta(format('UPDATE sala SET activa = FALSE WHERE id_sala = %s', pg_temp.k('sala_heredia')));
    PERFORM pg_temp.chk('G09', 'RN-18 no se puede desactivar una sala con entradas vendidas', v_r LIKE '%RN-18%', v_r);
    v_r := pg_temp.intenta(format('DELETE FROM sala WHERE id_sala = %s', pg_temp.k('sala_heredia')));
    PERFORM pg_temp.chk('G09', 'RN-18 no se puede borrar una sala con entradas vendidas', v_r LIKE '%RN-18%', v_r);

    v_cmp := pg_temp.comprar(pg_temp.cli(4), f, ARRAY[pg_temp.asi(f, 'A', 1)], ARRAY['ADULTO']);
    v_b := (pg_temp.bols(v_cmp))[1];
    v_r := pg_temp.intenta(format($f$UPDATE compra SET estado = 'PENDIENTE' WHERE id_compra = %s$f$, v_cmp));
    PERFORM pg_temp.chk('G09', 'Estados: una compra PAGADA no puede volver a PENDIENTE', v_r <> 'OK', v_r);
    v_r := pg_temp.intenta(format($f$UPDATE boleto SET estado = 'PENDIENTE' WHERE id_boleto = %s$f$, v_b));
    PERFORM pg_temp.chk('G09', 'Estados: un boleto EMITIDO no puede volver a PENDIENTE', v_r <> 'OK', v_r);
    v_r := pg_temp.intenta(format('UPDATE boleto SET codigo_qr = NULL WHERE id_boleto = %s', v_b));
    PERFORM pg_temp.chk('G09', 'RN-12 CHECK: un boleto EMITIDO no puede quedarse sin QR', v_r <> 'OK', v_r);
    v_r := pg_temp.intenta(format($f$UPDATE reserva_asiento SET estado = 'BLOQUEADO' WHERE id_reserva = (SELECT id_reserva FROM boleto WHERE id_boleto = %s)$f$, v_b));
    PERFORM pg_temp.chk('G09', 'Estados: una reserva VENDIDO no puede volver a BLOQUEADO', v_r <> 'OK', v_r);
    v_r := pg_temp.intenta(format($f$UPDATE reserva_asiento SET id_asiento = %s WHERE id_reserva = (SELECT id_reserva FROM boleto WHERE id_boleto = %s)$f$, pg_temp.asi(f, 'A', 2), v_b));
    PERFORM pg_temp.chk('G09', 'Estados: no se puede cambiar el asiento de una reserva a mano', v_r <> 'OK', v_r);
END $$;

-- ===============================================================
-- G10. RBAC: PRIVILEGIO MINIMO POR ROL
-- ===============================================================
DO $$
DECLARE
    v_n BIGINT;
BEGIN
    PERFORM pg_temp.chk('G10', 'CLIENTE: puede leer la cartelera', pg_temp.como('rol_cliente', 'SELECT 1 FROM v_cartelera LIMIT 1') = 'OK');
    PERFORM pg_temp.chk('G10', 'CLIENTE: no puede leer la tabla compra', pg_temp.como('rol_cliente', 'SELECT 1 FROM compra LIMIT 1') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CLIENTE: no puede insertar en compra', pg_temp.como('rol_cliente', 'INSERT INTO compra (canal) VALUES (''WEB'')') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CLIENTE: no puede tocar boleto', pg_temp.como('rol_cliente', 'UPDATE boleto SET estado = ''EMITIDO''') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CLIENTE: no puede leer pago', pg_temp.como('rol_cliente', 'SELECT 1 FROM pago LIMIT 1') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CLIENTE: no puede leer usuario', pg_temp.como('rol_cliente', 'SELECT 1 FROM usuario LIMIT 1') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CLIENTE: no puede leer las bitacoras', pg_temp.como('rol_cliente', 'SELECT 1 FROM transaccion_log LIMIT 1') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CLIENTE: no puede cambiar tarifas', pg_temp.como('rol_cliente', 'UPDATE tarifa SET precio = 0') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CLIENTE: no puede validar entradas', pg_temp.como('rol_cliente', 'SELECT * FROM sp_validar_entrada(''x'', 1, 1)') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CLIENTE: no puede hacer reembolsos forzados', pg_temp.como('rol_cliente', 'SELECT * FROM sp_admin_reembolso_forzado(1, 1, ''x'', NULL)') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CLIENTE: no puede llamar las funciones internas (reembolso ni check-in con hora)',
        pg_temp.como('rol_cliente', 'SELECT fn_ejecutar_reembolso(1, ''SOLICITUD'', 1, NULL, ''x'')') = 'DENEGADO'
        AND pg_temp.como('rol_cliente', 'SELECT * FROM fn_validar_entrada_interna(''x'', 1, 1, now())') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CLIENTE: si puede usar el flujo de compra (bloquear asientos)', pg_temp.como('rol_cliente', 'SELECT * FROM sp_bloquear_asientos(-1, ARRAY[]::int[], -1)') = 'OK');

    PERFORM sp_set_contexto(pg_temp.cli(1), NULL, FALSE);
    v_n := pg_temp.como_n('rol_cliente', 'SELECT count(*) FROM v_mis_entradas');
    PERFORM pg_temp.chk('G10', 'CLIENTE: v_mis_entradas muestra las entradas del usuario del contexto', v_n > 0, v_n::text);
    PERFORM sp_set_contexto(pg_temp.cli(5), NULL, FALSE);
    v_n := pg_temp.como_n('rol_cliente', 'SELECT count(*) FROM v_mis_entradas WHERE id_usuario <> ' || pg_temp.cli(5));
    PERFORM pg_temp.chk('G10', 'CLIENTE: v_mis_entradas nunca muestra entradas de otro usuario', v_n = 0, v_n::text);
    PERFORM sp_set_contexto(NULL, NULL, FALSE);
    v_n := pg_temp.como_n('rol_cliente', 'SELECT count(*) FROM v_mis_entradas');
    PERFORM pg_temp.chk('G10', 'CLIENTE: sin contexto no ve ninguna entrada', v_n = 0, v_n::text);

    PERFORM pg_temp.chk('G10', 'TAQUILLERO: puede leer su corte de caja', pg_temp.como('rol_taquillero', 'SELECT 1 FROM v_corte_caja_taquillero LIMIT 1') = 'OK');
    PERFORM pg_temp.chk('G10', 'TAQUILLERO: puede leer el catalogo (funcion, tarifa)', pg_temp.como('rol_taquillero', 'SELECT 1 FROM funcion LIMIT 1') = 'OK' AND pg_temp.como('rol_taquillero', 'SELECT 1 FROM tarifa LIMIT 1') = 'OK');
    PERFORM pg_temp.chk('G10', 'TAQUILLERO: no puede cambiar el catalogo', pg_temp.como('rol_taquillero', 'UPDATE funcion SET estado = ''CANCELADA''') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'TAQUILLERO: no puede leer compra ni pago directo', pg_temp.como('rol_taquillero', 'SELECT 1 FROM compra LIMIT 1') = 'DENEGADO' AND pg_temp.como('rol_taquillero', 'SELECT 1 FROM pago LIMIT 1') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'TAQUILLERO: no puede validar entradas', pg_temp.como('rol_taquillero', 'SELECT * FROM sp_validar_entrada(''x'', 1, 1)') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'TAQUILLERO: no puede dar cortesias', pg_temp.como('rol_taquillero', 'SELECT * FROM sp_admin_otorgar_cortesia(1, 1, 1, 1, ''x'', NULL)') = 'DENEGADO');

    PERFORM pg_temp.chk('G10', 'OPERADOR: puede validar entradas', pg_temp.como('rol_operador_sala', 'SELECT * FROM sp_validar_entrada(''x'', 1, 1)') = 'OK');
    PERFORM pg_temp.chk('G10', 'OPERADOR: no puede leer compra, boleto ni pago',
        pg_temp.como('rol_operador_sala', 'SELECT 1 FROM compra LIMIT 1') = 'DENEGADO' AND pg_temp.como('rol_operador_sala', 'SELECT 1 FROM boleto LIMIT 1') = 'DENEGADO'
        AND pg_temp.como('rol_operador_sala', 'SELECT 1 FROM pago LIMIT 1') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'OPERADOR: no puede vender ni pagar', pg_temp.como('rol_operador_sala', 'SELECT * FROM sp_bloquear_asientos(-1, ARRAY[]::int[], -1)') = 'DENEGADO'
        AND pg_temp.como('rol_operador_sala', 'SELECT * FROM sp_procesar_pago(1, 1::smallint, ''1234'', ''VISA'', ''APROBADO'')') = 'DENEGADO');

    PERFORM pg_temp.chk('G10', 'CONTADOR: puede leer compra, pago, reembolso y transaccion_log',
        pg_temp.como('rol_contador', 'SELECT 1 FROM compra LIMIT 1') = 'OK' AND pg_temp.como('rol_contador', 'SELECT 1 FROM pago LIMIT 1') = 'OK'
        AND pg_temp.como('rol_contador', 'SELECT 1 FROM reembolso LIMIT 1') = 'OK' AND pg_temp.como('rol_contador', 'SELECT 1 FROM transaccion_log LIMIT 1') = 'OK');
    PERFORM pg_temp.chk('G10', 'CONTADOR: puede leer el resumen financiero', pg_temp.como('rol_contador', 'SELECT 1 FROM v_resumen_financiero_diario LIMIT 1') = 'OK');
    PERFORM pg_temp.chk('G10', 'CONTADOR: no puede modificar nada (UPDATE compra, INSERT pago, DELETE boleto)',
        pg_temp.como('rol_contador', 'UPDATE compra SET total = 0') = 'DENEGADO' AND pg_temp.como('rol_contador', 'INSERT INTO pago (id_compra) VALUES (1)') = 'DENEGADO'
        AND pg_temp.como('rol_contador', 'DELETE FROM boleto') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CONTADOR: no puede leer usuario ni la auditoria de asientos o administrativa',
        pg_temp.como('rol_contador', 'SELECT 1 FROM usuario LIMIT 1') = 'DENEGADO' AND pg_temp.como('rol_contador', 'SELECT 1 FROM asiento_auditoria_log LIMIT 1') = 'DENEGADO'
        AND pg_temp.como('rol_contador', 'SELECT 1 FROM admin_operacion_audit LIMIT 1') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'CONTADOR: no puede comprar', pg_temp.como('rol_contador', 'SELECT * FROM sp_bloquear_asientos(-1, ARRAY[]::int[], -1)') = 'DENEGADO');

    PERFORM pg_temp.chk('G10', 'ADMIN: puede leer toda la auditoria',
        pg_temp.como('rol_admin', 'SELECT 1 FROM transaccion_log LIMIT 1') = 'OK' AND pg_temp.como('rol_admin', 'SELECT 1 FROM asiento_auditoria_log LIMIT 1') = 'OK'
        AND pg_temp.como('rol_admin', 'SELECT 1 FROM acceso_puerta_log LIMIT 1') = 'OK' AND pg_temp.como('rol_admin', 'SELECT 1 FROM admin_operacion_audit LIMIT 1') = 'OK');
    PERFORM pg_temp.chk('G10', 'ADMIN: no puede alterar las bitacoras (UPDATE, DELETE, TRUNCATE)',
        pg_temp.como('rol_admin', 'UPDATE transaccion_log SET monto = 0') = 'DENEGADO' AND pg_temp.como('rol_admin', 'DELETE FROM admin_operacion_audit') = 'DENEGADO'
        AND pg_temp.como('rol_admin', 'TRUNCATE asiento_auditoria_log') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'ADMIN: no puede tocar compra, boleto ni pago directamente',
        pg_temp.como('rol_admin', 'UPDATE compra SET total = 0') = 'DENEGADO' AND pg_temp.como('rol_admin', 'DELETE FROM boleto') = 'DENEGADO'
        AND pg_temp.como('rol_admin', 'INSERT INTO pago (id_compra) VALUES (1)') = 'DENEGADO');
    PERFORM pg_temp.chk('G10', 'ADMIN: solo puede cambiar rol y estado de un usuario, no su correo',
        pg_temp.como('rol_admin', 'UPDATE usuario SET correo = ''x@y.z'' WHERE FALSE') = 'DENEGADO' AND pg_temp.como('rol_admin', 'UPDATE usuario SET activo = activo WHERE FALSE') = 'OK');
    PERFORM pg_temp.chk('G10', 'ADMIN: puede administrar el catalogo (parametros, tarifas)',
        pg_temp.como('rol_admin', 'UPDATE parametro_sistema SET valor = valor') = 'OK' AND pg_temp.como('rol_admin', 'UPDATE tarifa SET precio = precio') = 'OK');
    PERFORM pg_temp.chk('G10', 'ADMIN: no puede validar entradas', pg_temp.como('rol_admin', 'SELECT * FROM sp_validar_entrada(''x'', 1, 1)') = 'DENEGADO');

    PERFORM pg_temp.chk('G10', 'PUBLIC: no tiene ningun privilegio sobre las tablas del esquema',
        (SELECT count(*) FROM information_schema.role_table_grants WHERE grantee = 'PUBLIC' AND table_schema = 'imax') = 0);
    PERFORM pg_temp.chk('G10', 'Los 5 usuarios app_* pueden iniciar sesion y pertenecen a su rol de grupo',
        (SELECT count(*) FROM pg_roles r JOIN pg_auth_members m ON m.member = r.oid JOIN pg_roles g ON g.oid = m.roleid
          WHERE r.rolname LIKE 'app\_%' AND r.rolcanlogin AND g.rolname = 'rol_' || substr(r.rolname, 5)) = 5);
END $$;

-- ===============================================================
-- G11. CONSISTENCIA GENERAL DE LOS DATOS GENERADOS POR LAS PRUEBAS
-- ===============================================================
DO $$
DECLARE
    v_n BIGINT;
BEGIN
    SELECT count(*) INTO v_n FROM (SELECT 1 FROM reserva_asiento WHERE estado IN ('BLOQUEADO', 'VENDIDO') GROUP BY id_funcion, id_asiento HAVING count(*) > 1) x;
    PERFORM pg_temp.chk('G11', 'Invariante: ningun asiento de ninguna funcion esta activo dos veces', v_n = 0, v_n::text);
    SELECT count(*) INTO v_n FROM compra c WHERE c.estado IN ('PAGADA', 'REEMBOLSADA_PARCIAL', 'REEMBOLSADA') AND c.canal <> 'CORTESIA'
       AND (SELECT count(*) FROM pago p WHERE p.id_compra = c.id_compra AND p.estado = 'APROBADO') <> 1;
    PERFORM pg_temp.chk('G11', 'Invariante: toda compra pagada tiene exactamente un pago aprobado', v_n = 0, v_n::text);
    SELECT count(*) INTO v_n FROM compra c JOIN pago p ON p.id_compra = c.id_compra AND p.estado = 'APROBADO' WHERE p.monto <> c.total;
    PERFORM pg_temp.chk('G11', 'Invariante: el monto del pago aprobado es igual al total de la compra', v_n = 0, v_n::text);
    SELECT count(*) INTO v_n FROM compra c WHERE c.subtotal - c.descuento_total + c.cargo_servicio <> c.total;
    PERFORM pg_temp.chk('G11', 'Invariante: total = subtotal - descuento + cargo en todas las compras', v_n = 0, v_n::text);
    SELECT count(*) INTO v_n FROM boleto WHERE estado IN ('EMITIDO', 'USADO', 'REEMBOLSADO') AND codigo_qr IS NULL;
    PERFORM pg_temp.chk('G11', 'Invariante: todo boleto emitido, usado o reembolsado tiene QR', v_n = 0, v_n::text);
    SELECT count(*) INTO v_n FROM boleto b JOIN reserva_asiento r USING (id_reserva) WHERE b.estado IN ('EMITIDO', 'USADO') AND r.estado <> 'VENDIDO';
    PERFORM pg_temp.chk('G11', 'Invariante: todo boleto vigente tiene su asiento VENDIDO', v_n = 0, v_n::text);
    SELECT count(*) INTO v_n FROM reembolso r JOIN boleto b USING (id_boleto) WHERE b.estado <> 'REEMBOLSADO';
    PERFORM pg_temp.chk('G11', 'Invariante: todo reembolso corresponde a un boleto REEMBOLSADO', v_n = 0, v_n::text);
    PERFORM pg_temp.chk('G11', 'Consulta: v_ocupacion_funcion calcula el porcentaje de ocupacion',
        (SELECT count(*) > 0 AND bool_and(pct_ocupacion BETWEEN 0 AND 100) FROM v_ocupacion_funcion));
    PERFORM pg_temp.chk('G11', 'Consulta: v_resumen_financiero_diario cuadra con los pagos y reembolsos',
        (SELECT coalesce(sum(monto_cobrado), 0) FROM v_resumen_financiero_diario) = (SELECT coalesce(sum(monto), 0) FROM pago WHERE estado = 'APROBADO')
        AND (SELECT coalesce(sum(monto_reembolsado), 0) FROM v_resumen_financiero_diario) = (SELECT coalesce(sum(monto), 0) FROM reembolso),
        (SELECT sum(monto_cobrado)::text || ' / ' || sum(monto_reembolsado)::text FROM v_resumen_financiero_diario));
    PERFORM pg_temp.chk('G11', 'Consulta: v_metricas_tiempo_real responde', pg_temp.intenta('SELECT * FROM v_metricas_tiempo_real') = 'OK');
END $$;

-- ===============================================================
-- RESUMEN
-- ===============================================================
\echo
\echo '======== PRUEBAS QUE FALLARON ========'
SELECT n, grupo, prueba, detalle FROM res WHERE NOT ok ORDER BY n;
\echo
\echo '======== RESUMEN POR GRUPO ========'
SELECT grupo, count(*) AS pruebas, count(*) FILTER (WHERE ok) AS ok, count(*) FILTER (WHERE NOT ok) AS fallan FROM res GROUP BY grupo ORDER BY grupo;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS ok, count(*) FILTER (WHERE NOT ok) AS fallan FROM res;
