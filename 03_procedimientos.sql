-- 03_procedimientos.sql
-- Proyecto 2 - Cine IMAX (TI-3600 Bases de Datos)
-- Procedimientos (funciones PL/pgSQL) y vistas que usa la interfaz.
-- Va despues de 02_triggers.sql.
--
-- Todos los procedimientos devuelven una fila con (exito, cod_resultado, mensaje, ...)
-- para que la interfaz no tenga que interpretar excepciones.

SET search_path = imax, public;

-- ============================================================
-- A. BLOQUEO TEMPORAL DE ASIENTOS (RN-03, RN-04, RN-05)
-- ============================================================

-- Bloquea uno o varios asientos de una funcion para un usuario. Es todo o nada:
-- si uno de los asientos ya esta ocupado no se bloquea ninguno.
-- La proteccion contra la doble venta la da el indice unico parcial uq_reserva_asiento_activa,
-- aqui solo se atrapa el error para devolver un mensaje bonito.
CREATE OR REPLACE FUNCTION sp_bloquear_asientos(p_id_funcion BIGINT, p_ids_asiento INTEGER[], p_id_usuario INTEGER)
RETURNS TABLE (exito BOOLEAN, cod_resultado TEXT, mensaje TEXT, ids_reserva BIGINT[], vence_en TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
#variable_conflict use_column
DECLARE
    v_rol      TEXT;
    v_func     funcion%ROWTYPE;
    v_max      INTEGER;
    v_actuales INTEGER;
    v_ids      INTEGER[];
    v_ahora    TIMESTAMPTZ := clock_timestamp();
    v_hasta    TIMESTAMPTZ;
    v_asiento  INTEGER;
    v_reservas BIGINT[];
    v_mapa     JSONB := '{}';
    v_id       BIGINT;
    v_nombre   TEXT;
BEGIN
    IF p_ids_asiento IS NULL OR cardinality(p_ids_asiento) = 0 THEN
        RETURN QUERY SELECT FALSE, 'SIN_ASIENTOS', 'Hay que elegir al menos un asiento', NULL::BIGINT[], NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    -- se ordenan los asientos para que dos usuarios con los mismos asientos no se bloqueen entre si (deadlock)
    SELECT array_agg(DISTINCT x ORDER BY x) INTO v_ids FROM unnest(p_ids_asiento) AS x;
    IF cardinality(v_ids) <> cardinality(p_ids_asiento) THEN
        RETURN QUERY SELECT FALSE, 'ASIENTOS_REPETIDOS', 'Hay asientos repetidos en la seleccion', NULL::BIGINT[], NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    v_rol := fn_rol_codigo(p_id_usuario);
    IF v_rol IS NULL OR v_rol NOT IN ('CLIENTE', 'TAQUILLERO') THEN
        RETURN QUERY SELECT FALSE, 'ROL_NO_PERMITIDO', 'Este usuario no puede comprar entradas', NULL::BIGINT[], NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    SELECT * INTO v_func FROM funcion WHERE id_funcion = p_id_funcion;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'FUNCION_NO_EXISTE', 'La funcion no existe', NULL::BIGINT[], NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    -- RN-01: solo se vende lo que esta programado y todavia no empieza
    IF v_func.estado <> 'PROGRAMADA' OR v_func.inicio <= v_ahora
       OR NOT EXISTS (SELECT 1 FROM pelicula WHERE id_pelicula = v_func.id_pelicula AND activa)
       OR NOT EXISTS (SELECT 1 FROM sala WHERE id_sala = v_func.id_sala AND activa) THEN
        RETURN QUERY SELECT FALSE, 'FUNCION_NO_DISPONIBLE', 'La funcion no esta disponible para la venta', NULL::BIGINT[], NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    IF (SELECT count(*) FROM asiento WHERE id_asiento = ANY (v_ids) AND id_sala = v_func.id_sala) <> cardinality(v_ids) THEN
        RETURN QUERY SELECT FALSE, 'ASIENTO_INVALIDO', 'Algun asiento no pertenece a la sala de la funcion', NULL::BIGINT[], NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    -- RN-04: limite de asientos por usuario y funcion (contando los que ya tiene bloqueados)
    v_max := fn_param_int('max_asientos_por_compra');
    SELECT count(*) INTO v_actuales FROM reserva_asiento
     WHERE id_funcion = p_id_funcion AND id_usuario = p_id_usuario AND estado = 'BLOQUEADO' AND bloqueado_hasta > v_ahora;
    IF v_actuales + cardinality(v_ids) > v_max THEN
        RETURN QUERY SELECT FALSE, 'LIMITE_ASIENTOS', 'Maximo ' || v_max || ' asientos por compra', NULL::BIGINT[], NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    -- si algun bloqueo viejo ya vencio, se marca como expirado para que el asiento quede libre
    UPDATE reserva_asiento SET estado = 'EXPIRADO', motivo_cierre = 'TIMEOUT'
     WHERE id_funcion = p_id_funcion AND id_asiento = ANY (v_ids)
       AND estado = 'BLOQUEADO' AND bloqueado_hasta <= v_ahora;

    v_hasta := v_ahora + make_interval(secs => fn_param_int('bloqueo_segundos'));

    BEGIN
        FOREACH v_asiento IN ARRAY v_ids LOOP
            INSERT INTO reserva_asiento (id_funcion, id_sala, id_asiento, id_usuario, estado, bloqueado_en, bloqueado_hasta)
            VALUES (p_id_funcion, v_func.id_sala, v_asiento, p_id_usuario, 'BLOQUEADO', v_ahora, v_hasta)
            RETURNING id_reserva INTO v_id;
            v_mapa := v_mapa || jsonb_build_object(v_asiento::text, v_id);
        END LOOP;
    EXCEPTION WHEN unique_violation THEN
        -- alguien se nos adelanto. El bloque se revierte solo, aqui solo dejamos la huella de la colision
        SELECT fila || numero INTO v_nombre FROM asiento WHERE id_asiento = v_asiento;
        INSERT INTO asiento_auditoria_log (id_funcion, id_asiento, id_usuario, evento, estado_nuevo, detalle)
        VALUES (p_id_funcion, v_asiento, p_id_usuario, 'COLISION', 'BLOQUEADO', 'intento sobre asiento ocupado');
        RETURN QUERY SELECT FALSE, 'ASIENTO_OCUPADO', 'El asiento ' || v_nombre || ' ya no esta disponible', NULL::BIGINT[], NULL::TIMESTAMPTZ;
        RETURN;
    END;

    -- las reservas se devuelven en el mismo orden en que llegaron los asientos
    SELECT array_agg((v_mapa ->> a::text)::bigint ORDER BY ord) INTO v_reservas
      FROM unnest(p_ids_asiento) WITH ORDINALITY AS u(a, ord);

    RETURN QUERY SELECT TRUE, 'OK', 'Asientos bloqueados por ' || fn_param_int('bloqueo_segundos') || ' segundos', v_reservas, v_hasta;
END $$;

-- version para un solo asiento (es la que usa el script de concurrencia)
CREATE OR REPLACE FUNCTION sp_bloquear_asiento(p_id_funcion BIGINT, p_id_asiento INTEGER, p_id_usuario INTEGER)
RETURNS TABLE (exito BOOLEAN, cod_resultado TEXT, mensaje TEXT, ids_reserva BIGINT[], vence_en TIMESTAMPTZ)
LANGUAGE sql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
    SELECT * FROM sp_bloquear_asientos(p_id_funcion, ARRAY[p_id_asiento], p_id_usuario)
$$;

-- el usuario suelta sus asientos antes de pagar. Si ya tenia una compra pendiente, se cancela.
CREATE OR REPLACE FUNCTION sp_liberar_asientos(p_ids_reserva BIGINT[], p_id_usuario INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_n INTEGER;
BEGIN
    WITH lib AS (
        UPDATE reserva_asiento SET estado = 'LIBERADO', motivo_cierre = 'USUARIO'
         WHERE id_reserva = ANY (p_ids_reserva) AND id_usuario = p_id_usuario AND estado = 'BLOQUEADO'
        RETURNING id_reserva
    ), bol AS (
        UPDATE boleto b SET estado = 'ANULADO'
          FROM lib WHERE b.id_reserva = lib.id_reserva AND b.estado = 'PENDIENTE'
        RETURNING b.id_compra
    ), cmp AS (
        UPDATE compra SET estado = 'CANCELADA'
         WHERE id_compra IN (SELECT id_compra FROM bol) AND estado = 'PENDIENTE'
        RETURNING 1
    )
    SELECT count(*) INTO v_n FROM lib;
    RETURN v_n;
END $$;

-- se corre cada pocos segundos (pg_cron) o la llama la app: libera los bloqueos vencidos (RN-05)
-- y cierra las compras que se quedaron sin pagar
CREATE OR REPLACE FUNCTION sp_liberar_bloqueos_expirados()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_n INTEGER;
BEGIN
    WITH exp AS (
        UPDATE reserva_asiento SET estado = 'EXPIRADO', motivo_cierre = 'TIMEOUT'
         WHERE estado = 'BLOQUEADO' AND bloqueado_hasta <= clock_timestamp()
        RETURNING id_reserva
    ), bol AS (
        UPDATE boleto b SET estado = 'ANULADO'
          FROM exp WHERE b.id_reserva = exp.id_reserva AND b.estado = 'PENDIENTE'
        RETURNING b.id_compra
    ), cmp AS (
        UPDATE compra SET estado = 'EXPIRADA'
         WHERE id_compra IN (SELECT id_compra FROM bol) AND estado = 'PENDIENTE'
        RETURNING 1
    )
    SELECT count(*) INTO v_n FROM exp;
    RETURN v_n;
END $$;

-- ============================================================
-- B. COMPRA: calculo de precios (RN-06, RN-07, RN-08)
-- ============================================================

-- Arma la compra a partir de las reservas bloqueadas. Calcula precio base, descuento por tipo
-- de entrada, promocion (2x1 o porcentaje) y cargo por servicio. Deja los boletos PENDIENTES (sin QR).
-- p_canal = WEB: p_id_usuario es el cliente. p_canal = TAQUILLA: p_id_usuario es el taquillero
-- y p_id_cliente es opcional (puede ser una venta sin cuenta).
CREATE OR REPLACE FUNCTION sp_iniciar_compra(
    p_id_usuario INTEGER, p_ids_reserva BIGINT[], p_ids_tipo_entrada SMALLINT[],
    p_canal VARCHAR DEFAULT 'WEB', p_id_cliente INTEGER DEFAULT NULL)
RETURNS TABLE (exito BOOLEAN, cod_resultado TEXT, mensaje TEXT, id_compra BIGINT,
               subtotal NUMERIC, descuento_total NUMERIC, cargo_servicio NUMERIC, total NUMERIC, vence_en TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
#variable_conflict use_column
DECLARE
    v_cant   INTEGER := cardinality(p_ids_reserva);
    v_rol    TEXT;
    v_max    INTEGER := fn_param_int('max_asientos_por_compra');
    v_n      INTEGER;
    v_funcs  INTEGER;
    v_func   funcion%ROWTYPE;
    v_zona   TEXT := coalesce(fn_param('zona_horaria'), 'UTC');
    v_dow    INTEGER;
    v_fecha  DATE;
    v_promo  promocion%ROWTYPE;
    v_lineas JSONB;
    v_sub    NUMERIC;
    v_desc   NUMERIC;
    v_promo_desc NUMERIC;
    v_cargo  NUMERIC;
    v_total  NUMERIC;
    v_imp    NUMERIC;
    v_hasta  TIMESTAMPTZ;
    v_id     BIGINT;
BEGIN
    IF p_canal NOT IN ('WEB', 'TAQUILLA') THEN
        RETURN QUERY SELECT FALSE, 'CANAL_INVALIDO', 'El canal debe ser WEB o TAQUILLA', NULL::BIGINT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    IF v_cant IS NULL OR v_cant = 0 OR v_cant <> coalesce(cardinality(p_ids_tipo_entrada), 0) THEN
        RETURN QUERY SELECT FALSE, 'DATOS_INVALIDOS', 'Cada asiento necesita un tipo de entrada', NULL::BIGINT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    IF v_cant > v_max THEN
        RETURN QUERY SELECT FALSE, 'LIMITE_ASIENTOS', 'Maximo ' || v_max || ' asientos por compra', NULL::BIGINT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    v_rol := fn_rol_codigo(p_id_usuario);
    IF (p_canal = 'WEB' AND v_rol IS DISTINCT FROM 'CLIENTE') OR (p_canal = 'TAQUILLA' AND v_rol IS DISTINCT FROM 'TAQUILLERO') THEN
        RETURN QUERY SELECT FALSE, 'ROL_NO_PERMITIDO', 'El usuario no puede vender por este canal', NULL::BIGINT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    IF p_id_cliente IS NOT NULL AND fn_rol_codigo(p_id_cliente) IS DISTINCT FROM 'CLIENTE' THEN
        RETURN QUERY SELECT FALSE, 'CLIENTE_INVALIDO', 'El cliente indicado no existe', NULL::BIGINT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    -- las reservas tienen que ser de este usuario, seguir bloqueadas y ser de una sola funcion
    SELECT count(*), count(DISTINCT r.id_funcion) INTO v_n, v_funcs
      FROM reserva_asiento r
     WHERE r.id_reserva = ANY (p_ids_reserva) AND r.id_usuario = p_id_usuario
       AND r.estado = 'BLOQUEADO' AND r.bloqueado_hasta > clock_timestamp();
    IF v_n <> v_cant OR (SELECT count(DISTINCT x) FROM unnest(p_ids_reserva) AS x) <> v_cant THEN
        RETURN QUERY SELECT FALSE, 'RESERVAS_INVALIDAS', 'Las reservas no existen, ya vencieron o no son de este usuario', NULL::BIGINT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    IF v_funcs <> 1 THEN
        RETURN QUERY SELECT FALSE, 'FUNCIONES_DISTINTAS', 'Una compra solo puede ser de una funcion', NULL::BIGINT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM boleto b WHERE b.id_reserva = ANY (p_ids_reserva)) THEN
        RETURN QUERY SELECT FALSE, 'RESERVA_EN_COMPRA', 'Alguna reserva ya esta asociada a otra compra', NULL::BIGINT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    SELECT f.* INTO v_func FROM funcion f JOIN reserva_asiento r ON r.id_funcion = f.id_funcion WHERE r.id_reserva = p_ids_reserva[1];
    v_dow   := extract(isodow FROM v_func.inicio AT TIME ZONE v_zona);
    v_fecha := (v_func.inicio AT TIME ZONE v_zona)::date;

    -- RN-07: busca la promocion que aplica ese dia (gana la de menor prioridad)
    SELECT * INTO v_promo FROM promocion pr
     WHERE pr.activa
       AND (pr.dia_semana IS NULL OR pr.dia_semana = v_dow)
       AND (pr.vigente_desde IS NULL OR v_fecha >= pr.vigente_desde)
       AND (pr.vigente_hasta IS NULL OR v_fecha <= pr.vigente_hasta)
     ORDER BY pr.prioridad, pr.id_promocion
     LIMIT 1;

    -- precio de cada asiento. El 2x1 regala los asientos mas baratos de cada zona (la mitad, redondeando hacia abajo)
    WITH base AS (
        SELECT u.id_reserva, u.id_tipo_entrada, a.id_tipo_asiento, t.precio AS precio_base,
               round(t.precio * te.descuento_pct / 100, 2) AS descuento_tipo
          FROM unnest(p_ids_reserva, p_ids_tipo_entrada) AS u(id_reserva, id_tipo_entrada)
          JOIN reserva_asiento r ON r.id_reserva = u.id_reserva
          JOIN asiento a ON a.id_asiento = r.id_asiento
          JOIN tarifa t ON t.id_tipo_asiento = a.id_tipo_asiento AND t.dia_semana = v_dow
          JOIN tipo_entrada te ON te.id_tipo_entrada = u.id_tipo_entrada AND te.codigo <> 'CORTESIA'
    ), orden AS (
        SELECT b.*, (b.precio_base - b.descuento_tipo) AS neto,
               row_number() OVER (PARTITION BY b.id_tipo_asiento ORDER BY (b.precio_base - b.descuento_tipo), b.id_reserva) AS rn,
               count(*) OVER (PARTITION BY b.id_tipo_asiento) AS n
          FROM base b
    )
    SELECT jsonb_agg(jsonb_build_object(
               'id_reserva', o.id_reserva, 'id_tipo_entrada', o.id_tipo_entrada,
               'precio_base', o.precio_base, 'descuento_tipo', o.descuento_tipo,
               'descuento_promo', CASE WHEN v_promo.tipo = '2X1' AND o.rn <= o.n / 2 THEN o.neto
                                       WHEN v_promo.tipo = 'PORCENTAJE' THEN round(o.neto * v_promo.descuento_pct / 100, 2)
                                       ELSE 0 END))
      INTO v_lineas
      FROM orden o;

    IF v_lineas IS NULL OR jsonb_array_length(v_lineas) <> v_cant THEN
        RETURN QUERY SELECT FALSE, 'SIN_TARIFA', 'No hay tarifa definida para algun asiento o tipo de entrada', NULL::BIGINT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    SELECT sum(x.precio_base), sum(x.descuento_tipo + x.descuento_promo), sum(x.descuento_promo)
      INTO v_sub, v_desc, v_promo_desc
      FROM jsonb_to_recordset(v_lineas) AS x(precio_base NUMERIC, descuento_tipo NUMERIC, descuento_promo NUMERIC);

    v_cargo := round((v_sub - v_desc) * fn_param_num('cargo_servicio_pct') / 100, 2);
    v_total := v_sub - v_desc + v_cargo;
    v_imp   := round(v_total * fn_param_num('iva_pct') / (100 + fn_param_num('iva_pct')), 2);
    SELECT min(r.bloqueado_hasta) INTO v_hasta FROM reserva_asiento r WHERE r.id_reserva = ANY (p_ids_reserva);

    INSERT INTO compra (id_usuario, id_taquillero, id_promocion, canal, subtotal, descuento_total, cargo_servicio,
                        total, impuesto_incluido, expira_en)
    VALUES (CASE WHEN p_canal = 'WEB' THEN p_id_usuario ELSE p_id_cliente END,
            CASE WHEN p_canal = 'TAQUILLA' THEN p_id_usuario END,
            CASE WHEN v_promo_desc > 0 THEN v_promo.id_promocion END,
            p_canal, v_sub, v_desc, v_cargo, v_total, v_imp, v_hasta)
    RETURNING compra.id_compra INTO v_id;

    INSERT INTO boleto (id_compra, id_reserva, id_tipo_entrada, estado, precio_base, descuento_tipo, descuento_promo, precio_final)
    SELECT v_id, x.id_reserva, x.id_tipo_entrada, 'PENDIENTE', x.precio_base, x.descuento_tipo, x.descuento_promo,
           x.precio_base - x.descuento_tipo - x.descuento_promo
      FROM jsonb_to_recordset(v_lineas) AS x(id_reserva BIGINT, id_tipo_entrada SMALLINT, precio_base NUMERIC, descuento_tipo NUMERIC, descuento_promo NUMERIC);

    RETURN QUERY SELECT TRUE, 'OK', 'Compra creada, falta el pago', v_id, v_sub, v_desc, v_cargo, v_total, v_hasta;
END $$;

-- ============================================================
-- C. PAGO SIMULADO (RN-09, RN-10, RN-11)
-- ============================================================

-- No existe parametro para el CVV ni el numero completo: la BD jamas los recibe (RN-09).
-- p_resultado_simulado deja probar un pago aprobado o rechazado desde la interfaz.
-- Todo pasa en una sola transaccion: pago, compra, asientos y boletos cambian juntos o no cambian (ACID).
CREATE OR REPLACE FUNCTION sp_procesar_pago(
    p_id_compra BIGINT, p_id_metodo_pago SMALLINT, p_ultimos4 TEXT DEFAULT NULL,
    p_marca VARCHAR DEFAULT NULL, p_resultado_simulado TEXT DEFAULT 'APROBADO')
RETURNS TABLE (exito BOOLEAN, cod_resultado TEXT, mensaje TEXT, id_pago BIGINT, estado_pago TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
#variable_conflict use_column
DECLARE
    v_c        compra%ROWTYPE;
    v_m        metodo_pago%ROWTYPE;
    v_vigentes INTEGER;
    v_total    INTEGER;
    v_ref      VARCHAR(30);
    v_id       BIGINT;
BEGIN
    IF p_resultado_simulado NOT IN ('APROBADO', 'RECHAZADO') THEN
        RETURN QUERY SELECT FALSE, 'RESULTADO_INVALIDO', 'El resultado simulado debe ser APROBADO o RECHAZADO', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;

    -- primero se bloquean las reservas y despues la compra (mismo orden que el job de expiracion, para no hacer deadlock)
    PERFORM 1 FROM reserva_asiento r
     WHERE r.id_reserva IN (SELECT b.id_reserva FROM boleto b WHERE b.id_compra = p_id_compra)
     ORDER BY r.id_reserva FOR UPDATE;
    SELECT * INTO v_c FROM compra WHERE id_compra = p_id_compra FOR UPDATE;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'COMPRA_NO_EXISTE', 'La compra no existe', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;
    IF v_c.estado = 'PAGADA' THEN
        RETURN QUERY SELECT FALSE, 'YA_PAGADA', 'La compra ya fue pagada', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;
    IF v_c.estado <> 'PENDIENTE' THEN
        RETURN QUERY SELECT FALSE, 'COMPRA_NO_PENDIENTE', 'La compra esta en estado ' || v_c.estado, NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;

    SELECT * INTO v_m FROM metodo_pago WHERE id_metodo_pago = p_id_metodo_pago AND activo;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'METODO_INVALIDO', 'Metodo de pago no disponible', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;
    IF v_m.requiere_tarjeta AND (p_ultimos4 IS NULL OR p_ultimos4 !~ '^[0-9]{4}$') THEN
        RETURN QUERY SELECT FALSE, 'TARJETA_INVALIDA', 'Se necesitan los ultimos 4 digitos de la tarjeta', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;

    -- RN-05: si el tiempo de bloqueo ya paso, se libera todo y se cierra la compra
    SELECT count(*) FILTER (WHERE r.estado = 'BLOQUEADO' AND r.bloqueado_hasta > clock_timestamp()), count(*)
      INTO v_vigentes, v_total
      FROM boleto b JOIN reserva_asiento r ON r.id_reserva = b.id_reserva
     WHERE b.id_compra = p_id_compra;
    IF v_vigentes <> v_total THEN
        UPDATE reserva_asiento SET estado = 'EXPIRADO', motivo_cierre = 'TIMEOUT'
         WHERE id_reserva IN (SELECT id_reserva FROM boleto WHERE id_compra = p_id_compra) AND estado = 'BLOQUEADO';
        UPDATE boleto SET estado = 'ANULADO' WHERE id_compra = p_id_compra AND estado = 'PENDIENTE';
        UPDATE compra SET estado = 'EXPIRADA' WHERE id_compra = p_id_compra;
        RETURN QUERY SELECT FALSE, 'BLOQUEO_EXPIRADO', 'Se acabo el tiempo, los asientos fueron liberados', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;

    v_ref := 'SIM-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 20));

    IF p_resultado_simulado = 'APROBADO' THEN
        INSERT INTO pago (id_compra, id_metodo_pago, monto, estado, referencia_pasarela, ultimos4, marca_tarjeta)
        VALUES (p_id_compra, p_id_metodo_pago, v_c.total, 'APROBADO', v_ref, p_ultimos4, p_marca)
        RETURNING pago.id_pago INTO v_id;

        UPDATE compra SET estado = 'PAGADA' WHERE id_compra = p_id_compra;
        UPDATE reserva_asiento SET estado = 'VENDIDO', bloqueado_hasta = NULL, motivo_cierre = NULL
         WHERE id_reserva IN (SELECT id_reserva FROM boleto WHERE id_compra = p_id_compra);
        UPDATE boleto SET estado = 'EMITIDO' WHERE id_compra = p_id_compra AND estado = 'PENDIENTE';   -- aqui el trigger genera el QR

        RETURN QUERY SELECT TRUE, 'APROBADO', 'Pago aprobado, las entradas ya estan emitidas', v_id, 'APROBADO';
    ELSE
        -- RN-10: pago rechazado, no se cobra y los asientos se liberan de una vez
        INSERT INTO pago (id_compra, id_metodo_pago, monto, estado, referencia_pasarela, ultimos4, marca_tarjeta, motivo_rechazo)
        VALUES (p_id_compra, p_id_metodo_pago, v_c.total, 'RECHAZADO', v_ref, p_ultimos4, p_marca, 'Rechazado por la pasarela (simulado)')
        RETURNING pago.id_pago INTO v_id;

        UPDATE reserva_asiento SET estado = 'LIBERADO', motivo_cierre = 'PAGO_FALLIDO'
         WHERE id_reserva IN (SELECT id_reserva FROM boleto WHERE id_compra = p_id_compra);
        UPDATE boleto SET estado = 'ANULADO' WHERE id_compra = p_id_compra AND estado = 'PENDIENTE';
        UPDATE compra SET estado = 'FALLIDA' WHERE id_compra = p_id_compra;

        RETURN QUERY SELECT FALSE, 'RECHAZADO', 'Pago rechazado, los asientos fueron liberados', v_id, 'RECHAZADO';
    END IF;
END $$;

-- ============================================================
-- D. CONTROL DE ACCESO / CHECK-IN (RN-14, RN-15, RN-16)
-- ============================================================

-- version interna: recibe la hora como parametro para poder probar las ventanas de tiempo.
-- Nadie mas que el dueno de la BD la puede llamar.
CREATE OR REPLACE FUNCTION fn_validar_entrada_interna(p_codigo_qr TEXT, p_id_puerta INTEGER, p_id_operador INTEGER, p_ahora TIMESTAMPTZ)
RETURNS TABLE (exito BOOLEAN, cod_resultado TEXT, mensaje TEXT, id_boleto_leido BIGINT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
#variable_conflict use_column
DECLARE
    v_rol  TEXT;
    v_pu   puerta%ROWTYPE;
    v_b    RECORD;
    v_res  TEXT;
    v_msg  TEXT;
    v_n    INTEGER;
BEGIN
    SELECT * INTO v_pu FROM puerta WHERE id_puerta = p_id_puerta;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'PUERTA_INVALIDA', 'La puerta no existe', NULL::BIGINT;
        RETURN;
    END IF;

    v_rol := fn_rol_codigo(p_id_operador);
    IF v_rol IS NULL OR v_rol NOT IN ('OPERADOR_SALA', 'ADMIN') THEN
        INSERT INTO acceso_puerta_log (codigo_leido, id_puerta, id_operador, resultado, mensaje)
        VALUES (left(coalesce(p_codigo_qr, ''), 60), p_id_puerta, p_id_operador, 'RECHAZADO_OPERADOR', 'Usuario sin permiso para validar');
        RETURN QUERY SELECT FALSE, 'RECHAZADO_OPERADOR', 'Este usuario no puede validar entradas', NULL::BIGINT;
        RETURN;
    END IF;

    SELECT b.id_boleto, b.estado, f.id_sala, f.inicio, f.estado AS estado_funcion,
           te.requiere_validacion_doc, te.nombre AS tipo_entrada, a.fila || a.numero AS asiento
      INTO v_b
      FROM boleto b
      JOIN reserva_asiento r ON r.id_reserva = b.id_reserva
      JOIN funcion f ON f.id_funcion = r.id_funcion
      JOIN asiento a ON a.id_asiento = r.id_asiento
      JOIN tipo_entrada te ON te.id_tipo_entrada = b.id_tipo_entrada
     WHERE b.codigo_qr = p_codigo_qr;

    IF NOT FOUND THEN
        v_res := 'RECHAZADO_INVALIDO';  v_msg := 'Codigo QR no valido';
    ELSIF v_b.estado = 'USADO' THEN
        v_res := 'RECHAZADO_DUPLICADO'; v_msg := 'Entrada ya utilizada';                       -- RN-14
    ELSIF v_b.estado <> 'EMITIDO' THEN
        v_res := 'RECHAZADO_ESTADO';    v_msg := 'Entrada no valida (reembolsada o anulada)';
    ELSIF v_b.estado_funcion <> 'PROGRAMADA' THEN
        v_res := 'RECHAZADO_FUNCION';   v_msg := 'La funcion fue cancelada';
    ELSIF v_b.id_sala <> v_pu.id_sala THEN
        v_res := 'RECHAZADO_FUNCION';   v_msg := 'La entrada es de otra sala o funcion';       -- RN-15
    ELSIF p_ahora < v_b.inicio - make_interval(mins => fn_param_int('checkin_min_antes'))
       OR p_ahora > v_b.inicio + make_interval(mins => fn_param_int('checkin_min_despues')) THEN
        v_res := 'RECHAZADO_HORARIO';   v_msg := 'Fuera del horario de ingreso permitido';     -- RN-16
    END IF;

    IF v_res IS NULL THEN
        -- el UPDATE condicionado es lo que garantiza que solo UN escaneo gane si llegan dos al mismo tiempo
        UPDATE boleto SET estado = 'USADO', usado_en = p_ahora
         WHERE id_boleto = v_b.id_boleto AND estado = 'EMITIDO';
        GET DIAGNOSTICS v_n = ROW_COUNT;
        IF v_n = 1 THEN
            v_res := 'EXITOSO';
            v_msg := 'Entrada valida, asiento ' || v_b.asiento
                     || CASE WHEN v_b.requiere_validacion_doc THEN ' (verificar documento: ' || v_b.tipo_entrada || ')' ELSE '' END;
        ELSE
            v_res := 'RECHAZADO_DUPLICADO'; v_msg := 'Entrada ya utilizada';
        END IF;
    END IF;

    INSERT INTO acceso_puerta_log (id_boleto, codigo_leido, id_puerta, id_operador, resultado, mensaje)
    VALUES (v_b.id_boleto, left(coalesce(p_codigo_qr, ''), 60), p_id_puerta, p_id_operador, v_res, left(v_msg, 80));

    RETURN QUERY SELECT v_res = 'EXITOSO', v_res, v_msg, v_b.id_boleto;
END $$;

-- esta es la que usa la interfaz del operador de sala
CREATE OR REPLACE FUNCTION sp_validar_entrada(p_codigo_qr TEXT, p_id_puerta INTEGER, p_id_operador INTEGER)
RETURNS TABLE (exito BOOLEAN, cod_resultado TEXT, mensaje TEXT, id_boleto_leido BIGINT)
LANGUAGE sql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
    SELECT * FROM fn_validar_entrada_interna(p_codigo_qr, p_id_puerta, p_id_operador, clock_timestamp())
$$;

-- ============================================================
-- E. REEMBOLSOS Y CANCELACIONES (RN-19)
-- ============================================================

-- hace el reembolso de un boleto: lo marca, libera el asiento y actualiza la compra.
-- Es interna (nadie la llama directo desde la app, solo los procedimientos de abajo).
CREATE OR REPLACE FUNCTION fn_ejecutar_reembolso(p_id_boleto BIGINT, p_tipo VARCHAR, p_id_solicitante INTEGER, p_id_admin INTEGER, p_motivo VARCHAR)
RETURNS NUMERIC
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_b     boleto%ROWTYPE;
    v_pago  BIGINT;
    v_vivos INTEGER;
BEGIN
    SELECT * INTO v_b FROM boleto WHERE id_boleto = p_id_boleto FOR UPDATE;
    IF NOT FOUND OR v_b.estado <> 'EMITIDO' THEN
        RAISE EXCEPTION 'El boleto % no se puede reembolsar (debe estar EMITIDO)', p_id_boleto;
    END IF;
    SELECT id_pago INTO v_pago FROM pago WHERE id_compra = v_b.id_compra AND estado = 'APROBADO';

    INSERT INTO reembolso (id_boleto, id_pago, id_solicitante, id_admin, tipo, monto, motivo)
    VALUES (p_id_boleto, v_pago, p_id_solicitante, p_id_admin, p_tipo, v_b.precio_final, p_motivo);

    UPDATE boleto SET estado = 'REEMBOLSADO' WHERE id_boleto = p_id_boleto;
    UPDATE reserva_asiento SET estado = 'LIBERADO', motivo_cierre = CASE p_tipo WHEN 'CANCELACION_FUNCION' THEN 'CANCELACION_FUNCION' ELSE 'REEMBOLSO' END
     WHERE id_reserva = v_b.id_reserva;

    SELECT count(*) INTO v_vivos FROM boleto WHERE id_compra = v_b.id_compra AND estado IN ('EMITIDO', 'USADO');
    UPDATE compra SET estado = CASE WHEN v_vivos = 0 THEN 'REEMBOLSADA' ELSE 'REEMBOLSADA_PARCIAL' END
     WHERE id_compra = v_b.id_compra;

    RETURN v_b.precio_final;
END $$;

-- el cliente (o el taquillero que hizo la venta) pide devolver una entrada. Solo hasta X horas antes de la funcion.
CREATE OR REPLACE FUNCTION sp_solicitar_reembolso(p_id_boleto BIGINT, p_id_usuario INTEGER, p_motivo VARCHAR DEFAULT NULL)
RETURNS TABLE (exito BOOLEAN, cod_resultado TEXT, mensaje TEXT, monto_reembolsado NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
#variable_conflict use_column
DECLARE
    v_rol   TEXT := fn_rol_codigo(p_id_usuario);
    v_b     RECORD;
    v_monto NUMERIC;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('CLIENTE', 'TAQUILLERO', 'ADMIN') THEN
        RETURN QUERY SELECT FALSE, 'ROL_NO_PERMITIDO', 'Este usuario no puede pedir reembolsos', NULL::NUMERIC;
        RETURN;
    END IF;

    SELECT b.id_boleto, b.estado, c.id_usuario AS cliente, c.id_taquillero, c.canal, f.inicio, f.estado AS estado_funcion
      INTO v_b
      FROM boleto b
      JOIN compra c ON c.id_compra = b.id_compra
      JOIN reserva_asiento r ON r.id_reserva = b.id_reserva
      JOIN funcion f ON f.id_funcion = r.id_funcion
     WHERE b.id_boleto = p_id_boleto;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'BOLETO_NO_EXISTE', 'El boleto no existe', NULL::NUMERIC;
        RETURN;
    END IF;
    IF (v_rol = 'CLIENTE' AND v_b.cliente IS DISTINCT FROM p_id_usuario)
       OR (v_rol = 'TAQUILLERO' AND v_b.id_taquillero IS DISTINCT FROM p_id_usuario) THEN
        RETURN QUERY SELECT FALSE, 'NO_AUTORIZADO', 'Esta entrada no es de este usuario', NULL::NUMERIC;
        RETURN;
    END IF;
    IF v_b.canal = 'CORTESIA' THEN
        RETURN QUERY SELECT FALSE, 'CORTESIA', 'Las cortesias no se reembolsan', NULL::NUMERIC;
        RETURN;
    END IF;
    IF v_b.estado <> 'EMITIDO' THEN
        RETURN QUERY SELECT FALSE, 'ESTADO_INVALIDO', 'La entrada esta en estado ' || v_b.estado, NULL::NUMERIC;
        RETURN;
    END IF;
    -- RN-19
    IF v_b.estado_funcion <> 'PROGRAMADA' OR clock_timestamp() > v_b.inicio - make_interval(hours => fn_param_int('reembolso_horas_antes')) THEN
        RETURN QUERY SELECT FALSE, 'FUERA_DE_PLAZO', 'Solo se puede reembolsar hasta ' || fn_param_int('reembolso_horas_antes') || ' horas antes de la funcion', NULL::NUMERIC;
        RETURN;
    END IF;

    v_monto := fn_ejecutar_reembolso(p_id_boleto, 'SOLICITUD', p_id_usuario, NULL, p_motivo);
    RETURN QUERY SELECT TRUE, 'OK', 'Reembolso realizado, el asiento quedo libre', v_monto;
END $$;

-- ============================================================
-- F. OPERACIONES MANUALES DEL ADMINISTRADOR (RN-17, RN-20)
-- ============================================================
-- Todas verifican que quien llama sea ADMIN y dejan fila en admin_operacion_audit.

CREATE OR REPLACE FUNCTION sp_admin_reembolso_forzado(p_id_admin INTEGER, p_id_boleto BIGINT, p_motivo VARCHAR, p_ip INET DEFAULT NULL)
RETURNS TABLE (exito BOOLEAN, cod_resultado TEXT, mensaje TEXT, monto_reembolsado NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
#variable_conflict use_column
DECLARE
    v_antes JSONB;
    v_monto NUMERIC;
BEGIN
    IF fn_rol_codigo(p_id_admin) IS DISTINCT FROM 'ADMIN' THEN
        RETURN QUERY SELECT FALSE, 'NO_AUTORIZADO', 'Solo un administrador puede hacer reembolsos forzados', NULL::NUMERIC;
        RETURN;
    END IF;
    IF p_motivo IS NULL OR length(btrim(p_motivo)) = 0 THEN
        RETURN QUERY SELECT FALSE, 'MOTIVO_OBLIGATORIO', 'Hay que indicar el motivo', NULL::NUMERIC;
        RETURN;
    END IF;
    PERFORM set_config('app.id_usuario', p_id_admin::text, true);
    SELECT to_jsonb(b) INTO v_antes FROM boleto b WHERE id_boleto = p_id_boleto;
    IF v_antes IS NULL OR v_antes ->> 'estado' <> 'EMITIDO' THEN
        RETURN QUERY SELECT FALSE, 'ESTADO_INVALIDO', 'El boleto no existe o no esta EMITIDO', NULL::NUMERIC;
        RETURN;
    END IF;

    v_monto := fn_ejecutar_reembolso(p_id_boleto, 'FORZADO', NULL, p_id_admin, p_motivo);   -- sin revisar el plazo de RN-19
    PERFORM fn_registrar_audit_admin(p_id_admin, 'REEMBOLSO_FORZADO', 'boleto', p_id_boleto::text, v_antes,
                                     (SELECT to_jsonb(b) FROM boleto b WHERE id_boleto = p_id_boleto), p_motivo, p_ip);
    RETURN QUERY SELECT TRUE, 'OK', 'Reembolso forzado registrado', v_monto;
END $$;

CREATE OR REPLACE FUNCTION sp_admin_cambiar_asiento(p_id_admin INTEGER, p_id_boleto BIGINT, p_id_asiento_nuevo INTEGER, p_motivo VARCHAR, p_ip INET DEFAULT NULL)
RETURNS TABLE (exito BOOLEAN, cod_resultado TEXT, mensaje TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
#variable_conflict use_column
DECLARE
    v_b       RECORD;
    v_nueva   BIGINT;
    v_antes   JSONB;
BEGIN
    IF fn_rol_codigo(p_id_admin) IS DISTINCT FROM 'ADMIN' THEN
        RETURN QUERY SELECT FALSE, 'NO_AUTORIZADO', 'Solo un administrador puede cambiar asientos';
        RETURN;
    END IF;
    IF p_motivo IS NULL OR length(btrim(p_motivo)) = 0 THEN
        RETURN QUERY SELECT FALSE, 'MOTIVO_OBLIGATORIO', 'Hay que indicar el motivo';
        RETURN;
    END IF;
    PERFORM set_config('app.id_usuario', p_id_admin::text, true);

    SELECT b.id_boleto, b.estado, b.id_reserva, r.id_funcion, r.id_sala, r.id_asiento AS asiento_viejo, r.id_usuario, f.inicio
      INTO v_b
      FROM boleto b JOIN reserva_asiento r ON r.id_reserva = b.id_reserva JOIN funcion f ON f.id_funcion = r.id_funcion
     WHERE b.id_boleto = p_id_boleto FOR UPDATE OF b;
    IF NOT FOUND OR v_b.estado <> 'EMITIDO' OR v_b.inicio <= clock_timestamp() THEN
        RETURN QUERY SELECT FALSE, 'ESTADO_INVALIDO', 'El boleto no existe, no esta EMITIDO o la funcion ya empezo';
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM asiento WHERE id_asiento = p_id_asiento_nuevo AND id_sala = v_b.id_sala) THEN
        RETURN QUERY SELECT FALSE, 'ASIENTO_INVALIDO', 'El asiento nuevo no es de la sala de la funcion';
        RETURN;
    END IF;
    SELECT to_jsonb(x) INTO v_antes FROM (SELECT b.id_boleto, b.codigo_qr, r.id_asiento, r.id_reserva FROM boleto b JOIN reserva_asiento r USING (id_reserva) WHERE b.id_boleto = p_id_boleto) x;

    BEGIN
        INSERT INTO reserva_asiento (id_funcion, id_sala, id_asiento, id_usuario, estado)
        VALUES (v_b.id_funcion, v_b.id_sala, p_id_asiento_nuevo, v_b.id_usuario, 'VENDIDO')
        RETURNING id_reserva INTO v_nueva;
    EXCEPTION WHEN unique_violation THEN
        RETURN QUERY SELECT FALSE, 'ASIENTO_OCUPADO', 'El asiento nuevo ya esta ocupado';
        RETURN;
    END;

    UPDATE boleto SET id_reserva = v_nueva WHERE id_boleto = p_id_boleto;
    UPDATE reserva_asiento SET estado = 'LIBERADO', motivo_cierre = 'CAMBIO_ASIENTO' WHERE id_reserva = v_b.id_reserva;

    PERFORM fn_registrar_audit_admin(p_id_admin, 'CAMBIO_ASIENTO', 'boleto', p_id_boleto::text, v_antes,
                                     jsonb_build_object('id_boleto', p_id_boleto, 'id_asiento', p_id_asiento_nuevo, 'id_reserva', v_nueva),
                                     p_motivo, p_ip);
    RETURN QUERY SELECT TRUE, 'OK', 'Asiento cambiado';
END $$;

CREATE OR REPLACE FUNCTION sp_admin_otorgar_cortesia(p_id_admin INTEGER, p_id_funcion BIGINT, p_id_asiento INTEGER, p_id_cliente INTEGER, p_motivo VARCHAR, p_ip INET DEFAULT NULL)
RETURNS TABLE (exito BOOLEAN, cod_resultado TEXT, mensaje TEXT, id_boleto_nuevo BIGINT, codigo_qr TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
#variable_conflict use_column
DECLARE
    v_func    funcion%ROWTYPE;
    v_precio  NUMERIC;
    v_tipo    SMALLINT;
    v_compra  BIGINT;
    v_reserva BIGINT;
    v_boleto  BIGINT;
    v_qr      TEXT;
    v_zona    TEXT := coalesce(fn_param('zona_horaria'), 'UTC');
BEGIN
    IF fn_rol_codigo(p_id_admin) IS DISTINCT FROM 'ADMIN' THEN
        RETURN QUERY SELECT FALSE, 'NO_AUTORIZADO', 'Solo un administrador puede dar cortesias', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;
    IF p_motivo IS NULL OR length(btrim(p_motivo)) = 0 THEN
        RETURN QUERY SELECT FALSE, 'MOTIVO_OBLIGATORIO', 'Hay que indicar el motivo', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;
    IF fn_rol_codigo(p_id_cliente) IS DISTINCT FROM 'CLIENTE' THEN
        RETURN QUERY SELECT FALSE, 'CLIENTE_INVALIDO', 'El destinatario debe ser un cliente activo', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;
    PERFORM set_config('app.id_usuario', p_id_admin::text, true);

    SELECT * INTO v_func FROM funcion WHERE id_funcion = p_id_funcion;
    IF NOT FOUND OR v_func.estado <> 'PROGRAMADA' OR v_func.inicio <= clock_timestamp() THEN
        RETURN QUERY SELECT FALSE, 'FUNCION_NO_DISPONIBLE', 'La funcion no esta disponible', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;
    SELECT t.precio INTO v_precio
      FROM asiento a JOIN tarifa t ON t.id_tipo_asiento = a.id_tipo_asiento AND t.dia_semana = extract(isodow FROM v_func.inicio AT TIME ZONE v_zona)
     WHERE a.id_asiento = p_id_asiento AND a.id_sala = v_func.id_sala;
    IF v_precio IS NULL THEN
        RETURN QUERY SELECT FALSE, 'ASIENTO_INVALIDO', 'El asiento no es de la sala o no tiene tarifa', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;
    SELECT id_tipo_entrada INTO v_tipo FROM tipo_entrada WHERE codigo = 'CORTESIA';

    BEGIN
        INSERT INTO compra (id_usuario, canal, estado, subtotal, descuento_total, cargo_servicio, total, impuesto_incluido, expira_en)
        VALUES (p_id_cliente, 'CORTESIA', 'PAGADA', v_precio, v_precio, 0, 0, 0, now())
        RETURNING id_compra INTO v_compra;

        INSERT INTO reserva_asiento (id_funcion, id_sala, id_asiento, id_usuario, estado)
        VALUES (p_id_funcion, v_func.id_sala, p_id_asiento, p_id_cliente, 'VENDIDO')
        RETURNING id_reserva INTO v_reserva;
    EXCEPTION WHEN unique_violation THEN
        RETURN QUERY SELECT FALSE, 'ASIENTO_OCUPADO', 'El asiento ya esta ocupado', NULL::BIGINT, NULL::TEXT;
        RETURN;
    END;

    INSERT INTO boleto (id_compra, id_reserva, id_tipo_entrada, estado, precio_base, descuento_tipo, descuento_promo, precio_final)
    VALUES (v_compra, v_reserva, v_tipo, 'EMITIDO', v_precio, v_precio, 0, 0)
    RETURNING id_boleto, boleto.codigo_qr INTO v_boleto, v_qr;

    PERFORM fn_registrar_audit_admin(p_id_admin, 'CORTESIA', 'boleto', v_boleto::text, NULL,
                                     jsonb_build_object('id_funcion', p_id_funcion, 'id_asiento', p_id_asiento, 'id_cliente', p_id_cliente, 'valor_regalado', v_precio),
                                     p_motivo, p_ip);
    RETURN QUERY SELECT TRUE, 'OK', 'Cortesia emitida', v_boleto, v_qr;
END $$;

-- cancela una funcion y devuelve el dinero de todas las entradas emitidas
CREATE OR REPLACE FUNCTION sp_cancelar_funcion(p_id_admin INTEGER, p_id_funcion BIGINT, p_motivo VARCHAR, p_ip INET DEFAULT NULL)
RETURNS TABLE (exito BOOLEAN, cod_resultado TEXT, mensaje TEXT, boletos_reembolsados INTEGER, monto_total NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
#variable_conflict use_column
DECLARE
    v_func   funcion%ROWTYPE;
    v_id     BIGINT;
    v_n      INTEGER := 0;
    v_total  NUMERIC := 0;
BEGIN
    IF fn_rol_codigo(p_id_admin) IS DISTINCT FROM 'ADMIN' THEN
        RETURN QUERY SELECT FALSE, 'NO_AUTORIZADO', 'Solo un administrador puede cancelar funciones', NULL::INTEGER, NULL::NUMERIC;
        RETURN;
    END IF;
    IF p_motivo IS NULL OR length(btrim(p_motivo)) = 0 THEN
        RETURN QUERY SELECT FALSE, 'MOTIVO_OBLIGATORIO', 'Hay que indicar el motivo', NULL::INTEGER, NULL::NUMERIC;
        RETURN;
    END IF;
    PERFORM set_config('app.id_usuario', p_id_admin::text, true);

    SELECT * INTO v_func FROM funcion WHERE id_funcion = p_id_funcion FOR UPDATE;
    IF NOT FOUND OR v_func.estado <> 'PROGRAMADA' THEN
        RETURN QUERY SELECT FALSE, 'ESTADO_INVALIDO', 'La funcion no existe o no esta programada', NULL::INTEGER, NULL::NUMERIC;
        RETURN;
    END IF;

    UPDATE funcion SET estado = 'CANCELADA' WHERE id_funcion = p_id_funcion;

    FOR v_id IN
        SELECT b.id_boleto FROM boleto b JOIN reserva_asiento r ON r.id_reserva = b.id_reserva
         WHERE r.id_funcion = p_id_funcion AND b.estado = 'EMITIDO' ORDER BY b.id_boleto
    LOOP
        v_total := v_total + fn_ejecutar_reembolso(v_id, 'CANCELACION_FUNCION', NULL, p_id_admin, p_motivo);
        v_n := v_n + 1;
    END LOOP;

    -- lo que estaba a medias (bloqueado sin pagar) tambien se suelta
    WITH lib AS (
        UPDATE reserva_asiento SET estado = 'LIBERADO', motivo_cierre = 'CANCELACION_FUNCION'
         WHERE id_funcion = p_id_funcion AND estado = 'BLOQUEADO'
        RETURNING id_reserva
    ), bol AS (
        UPDATE boleto b SET estado = 'ANULADO'
          FROM lib WHERE b.id_reserva = lib.id_reserva AND b.estado = 'PENDIENTE'
        RETURNING b.id_compra
    )
    UPDATE compra SET estado = 'CANCELADA' WHERE id_compra IN (SELECT id_compra FROM bol) AND estado = 'PENDIENTE';

    PERFORM fn_registrar_audit_admin(p_id_admin, 'CANCELACION_FUNCION', 'funcion', p_id_funcion::text, NULL,
                                     jsonb_build_object('boletos_reembolsados', v_n, 'monto_total', v_total), p_motivo, p_ip);
    RETURN QUERY SELECT TRUE, 'OK', 'Funcion cancelada', v_n, v_total;
END $$;

-- ============================================================
-- G. VISTAS Y CONSULTAS PARA LA INTERFAZ
-- ============================================================

-- RN-01 y RN-02: solo funciones activas y futuras, con todos los datos obligatorios
CREATE OR REPLACE VIEW v_cartelera AS
SELECT f.id_funcion, p.id_pelicula, p.titulo, p.sinopsis,
       c.codigo AS clasificacion, c.edad_minima, p.duracion_min, p.poster_url, gx.generos,
       ci.id_cine, ci.nombre AS cine, ci.region, ci.ciudad, ci.direccion,
       s.id_sala, s.nombre AS sala, fp.nombre AS formato,
       f.inicio, f.fin
  FROM funcion f
  JOIN pelicula p ON p.id_pelicula = f.id_pelicula
  JOIN clasificacion c ON c.id_clasificacion = p.id_clasificacion
  JOIN sala s ON s.id_sala = f.id_sala
  JOIN cine ci ON ci.id_cine = s.id_cine
  JOIN formato_proyeccion fp ON fp.id_formato = s.id_formato
  LEFT JOIN LATERAL (
        SELECT string_agg(g.nombre, ', ' ORDER BY g.nombre) AS generos
          FROM pelicula_genero pg JOIN genero g ON g.id_genero = pg.id_genero
         WHERE pg.id_pelicula = p.id_pelicula) gx ON TRUE
 WHERE f.estado = 'PROGRAMADA' AND f.inicio > now()
   AND p.activa AND s.activa AND ci.activo;

-- busqueda de la pantalla de cartelera: ubicacion (cine, ciudad o region), fecha y genero. Lo que venga vacio no filtra.
CREATE OR REPLACE FUNCTION fn_buscar_funciones(p_ubicacion TEXT DEFAULT NULL, p_fecha DATE DEFAULT NULL, p_genero TEXT DEFAULT NULL)
RETURNS SETOF v_cartelera
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = imax, pg_temp AS $$
    SELECT v.*
      FROM v_cartelera v
     WHERE (coalesce(p_ubicacion, '') = '' OR v.cine ILIKE '%' || p_ubicacion || '%'
            OR v.ciudad ILIKE '%' || p_ubicacion || '%' OR v.region ILIKE '%' || p_ubicacion || '%')
       AND (p_fecha IS NULL OR (v.inicio AT TIME ZONE coalesce(fn_param('zona_horaria'), 'UTC'))::date = p_fecha)
       AND (coalesce(p_genero, '') = '' OR v.generos ILIKE '%' || p_genero || '%')
     ORDER BY v.inicio, v.titulo
$$;

-- mapa de la sala (RN-03): un asiento por fila con su estado en este momento.
-- DISPONIBLE (verde), OCUPADO (gris), BLOQUEADO (amarillo). El azul "seleccionado" lo pinta la interfaz
-- cuando id_usuario_bloqueo es el usuario actual.
CREATE OR REPLACE FUNCTION fn_mapa_asientos(p_id_funcion BIGINT)
RETURNS TABLE (id_asiento INTEGER, fila VARCHAR, numero SMALLINT, zona VARCHAR, estado TEXT,
               precio NUMERIC, id_usuario_bloqueo INTEGER, bloqueado_hasta TIMESTAMPTZ)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = imax, pg_temp AS $$
    SELECT a.id_asiento, a.fila, a.numero, ta.nombre,
           CASE WHEN r.estado = 'VENDIDO' THEN 'OCUPADO'
                WHEN r.estado = 'BLOQUEADO' AND r.bloqueado_hasta > clock_timestamp() THEN 'BLOQUEADO'
                ELSE 'DISPONIBLE' END,
           t.precio,
           CASE WHEN r.estado = 'BLOQUEADO' AND r.bloqueado_hasta > clock_timestamp() THEN r.id_usuario END,
           CASE WHEN r.estado = 'BLOQUEADO' AND r.bloqueado_hasta > clock_timestamp() THEN r.bloqueado_hasta END
      FROM funcion f
      JOIN asiento a ON a.id_sala = f.id_sala
      JOIN tipo_asiento ta ON ta.id_tipo_asiento = a.id_tipo_asiento
      LEFT JOIN reserva_asiento r ON r.id_funcion = f.id_funcion AND r.id_asiento = a.id_asiento AND r.estado IN ('BLOQUEADO', 'VENDIDO')
      LEFT JOIN tarifa t ON t.id_tipo_asiento = a.id_tipo_asiento
                        AND t.dia_semana = extract(isodow FROM f.inicio AT TIME ZONE coalesce(fn_param('zona_horaria'), 'UTC'))
     WHERE f.id_funcion = p_id_funcion
     ORDER BY a.fila, a.numero
$$;

-- RN-13: las entradas del cliente actual (el id lo manda la app con sp_set_contexto)
CREATE OR REPLACE VIEW v_mis_entradas AS
SELECT b.id_boleto, b.codigo_qr, b.estado, c.id_compra, c.id_usuario,
       p.titulo, ci.nombre AS cine, ci.direccion, s.nombre AS sala, f.inicio,
       a.fila, a.numero, ta.nombre AS zona, te.nombre AS tipo_entrada, te.requiere_validacion_doc,
       b.precio_final, b.emitido_en
  FROM boleto b
  JOIN compra c ON c.id_compra = b.id_compra
  JOIN reserva_asiento r ON r.id_reserva = b.id_reserva
  JOIN funcion f ON f.id_funcion = r.id_funcion
  JOIN pelicula p ON p.id_pelicula = f.id_pelicula
  JOIN sala s ON s.id_sala = f.id_sala
  JOIN cine ci ON ci.id_cine = s.id_cine
  JOIN asiento a ON a.id_asiento = r.id_asiento
  JOIN tipo_asiento ta ON ta.id_tipo_asiento = a.id_tipo_asiento
  JOIN tipo_entrada te ON te.id_tipo_entrada = b.id_tipo_entrada
 WHERE c.id_usuario = fn_ctx_usuario()
   AND b.estado IN ('EMITIDO', 'USADO', 'REEMBOLSADO');

-- entradas que vendio el taquillero actual (para entregar el boleto con su QR)
CREATE OR REPLACE VIEW v_ventas_taquillero AS
SELECT b.id_boleto, b.codigo_qr, b.estado, c.id_compra, c.id_taquillero,
       p.titulo, s.nombre AS sala, f.inicio, a.fila, a.numero, te.nombre AS tipo_entrada, b.precio_final, c.creada_en
  FROM boleto b
  JOIN compra c ON c.id_compra = b.id_compra
  JOIN reserva_asiento r ON r.id_reserva = b.id_reserva
  JOIN funcion f ON f.id_funcion = r.id_funcion
  JOIN pelicula p ON p.id_pelicula = f.id_pelicula
  JOIN sala s ON s.id_sala = f.id_sala
  JOIN asiento a ON a.id_asiento = r.id_asiento
  JOIN tipo_entrada te ON te.id_tipo_entrada = b.id_tipo_entrada
 WHERE c.id_taquillero = fn_ctx_usuario()
   AND b.estado IN ('EMITIDO', 'USADO', 'REEMBOLSADO');

-- corte de caja del taquillero actual, por dia y metodo de pago
CREATE OR REPLACE VIEW v_corte_caja_taquillero AS
SELECT c.id_taquillero, (pg.creado_en AT TIME ZONE coalesce(fn_param('zona_horaria'), 'UTC'))::date AS dia,
       mp.nombre AS metodo_pago, count(*) AS pagos, sum(pg.monto) AS total_cobrado
  FROM pago pg
  JOIN compra c ON c.id_compra = pg.id_compra
  JOIN metodo_pago mp ON mp.id_metodo_pago = pg.id_metodo_pago
 WHERE pg.estado = 'APROBADO' AND c.id_taquillero = fn_ctx_usuario()
 GROUP BY c.id_taquillero, 2, mp.nombre;

-- ocupacion e ingresos por funcion (dashboard y reporte 1 de gerencia)
CREATE OR REPLACE VIEW v_ocupacion_funcion AS
SELECT f.id_funcion, p.titulo, ci.nombre AS cine, s.nombre AS sala, f.inicio, f.estado,
       cap.capacidad,
       coalesce(v.vendidos, 0) AS asientos_vendidos,
       round(100.0 * coalesce(v.vendidos, 0) / nullif(cap.capacidad, 0), 2) AS pct_ocupacion,
       coalesce(v.ingresos, 0) AS ingresos
  FROM funcion f
  JOIN pelicula p ON p.id_pelicula = f.id_pelicula
  JOIN sala s ON s.id_sala = f.id_sala
  JOIN cine ci ON ci.id_cine = s.id_cine
  CROSS JOIN LATERAL (SELECT count(*) AS capacidad FROM asiento a WHERE a.id_sala = f.id_sala) cap
  LEFT JOIN LATERAL (
        SELECT count(*) AS vendidos, sum(b.precio_final) AS ingresos
          FROM boleto b JOIN reserva_asiento r ON r.id_reserva = b.id_reserva
         WHERE r.id_funcion = f.id_funcion AND b.estado IN ('EMITIDO', 'USADO')) v ON TRUE;

-- para el contador: pagos y reembolsos por dia y metodo de pago
CREATE OR REPLACE VIEW v_resumen_financiero_diario AS
SELECT d.dia, d.metodo_pago, d.pagos_aprobados, d.monto_cobrado, d.impuesto_incluido,
       coalesce(rb.reembolsos, 0) AS reembolsos, coalesce(rb.monto_reembolsado, 0) AS monto_reembolsado,
       d.monto_cobrado - coalesce(rb.monto_reembolsado, 0) AS neto
  FROM (SELECT (pg.creado_en AT TIME ZONE coalesce(fn_param('zona_horaria'), 'UTC'))::date AS dia, pg.id_metodo_pago, mp.nombre AS metodo_pago,
               count(*) AS pagos_aprobados, sum(pg.monto) AS monto_cobrado, sum(c.impuesto_incluido) AS impuesto_incluido
          FROM pago pg JOIN compra c ON c.id_compra = pg.id_compra JOIN metodo_pago mp ON mp.id_metodo_pago = pg.id_metodo_pago
         WHERE pg.estado = 'APROBADO'
         GROUP BY 1, 2, 3) d
  LEFT JOIN (SELECT (rb.creado_en AT TIME ZONE coalesce(fn_param('zona_horaria'), 'UTC'))::date AS dia, pg.id_metodo_pago,
                    count(*) AS reembolsos, sum(rb.monto) AS monto_reembolsado
               FROM reembolso rb JOIN pago pg ON pg.id_pago = rb.id_pago
              GROUP BY 1, 2) rb ON rb.dia = d.dia AND rb.id_metodo_pago = d.id_metodo_pago;

-- metricas en vivo para el dashboard del gerente (una sola fila)
CREATE OR REPLACE VIEW v_metricas_tiempo_real AS
SELECT (SELECT count(*) FROM funcion WHERE estado = 'PROGRAMADA' AND inicio > now() AND inicio < now() + INTERVAL '24 hours') AS funciones_proximas_24h,
       (SELECT count(*) FROM reserva_asiento WHERE estado = 'BLOQUEADO' AND bloqueado_hasta > clock_timestamp()) AS asientos_bloqueados_ahora,
       (SELECT count(*) FROM boleto WHERE emitido_en >= date_trunc('day', now())) AS boletos_emitidos_hoy,
       (SELECT coalesce(sum(monto), 0) FROM pago WHERE estado = 'APROBADO' AND creado_en >= date_trunc('day', now())) AS ingresos_hoy,
       (SELECT count(*) FROM acceso_puerta_log WHERE resultado = 'EXITOSO' AND creado_en >= date_trunc('day', now())) AS ingresos_a_sala_hoy,
       (SELECT count(*) FROM acceso_puerta_log WHERE resultado <> 'EXITOSO' AND creado_en >= date_trunc('day', now())) AS accesos_rechazados_hoy;
