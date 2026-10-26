-- 02_triggers.sql
-- Proyecto 2 - Cine IMAX (TI-3600 Bases de Datos)
-- Funciones de apoyo y triggers (reglas que la BD hace cumplir sola).
-- Va despues de 01_ddl.sql.

SET search_path = imax, public;

-- ============================================================
-- A. FUNCIONES DE APOYO
-- ============================================================

-- lee un parametro de la tabla parametro_sistema
-- (SECURITY DEFINER para que las vistas de cada rol puedan leer los parametros sin tener acceso a la tabla)
CREATE OR REPLACE FUNCTION fn_param(p_clave TEXT) RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = imax, pg_temp
AS $$ SELECT valor FROM imax.parametro_sistema WHERE clave = p_clave $$;

CREATE OR REPLACE FUNCTION fn_param_int(p_clave TEXT) RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = imax, pg_temp AS $$ SELECT imax.fn_param(p_clave)::integer $$;

CREATE OR REPLACE FUNCTION fn_param_num(p_clave TEXT) RETURNS NUMERIC
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = imax, pg_temp AS $$ SELECT imax.fn_param(p_clave)::numeric $$;

-- id del usuario de la aplicacion. La app lo manda con sp_set_contexto
-- (no hay login real, entonces la BD se entera de quien es por aqui)
CREATE OR REPLACE FUNCTION fn_ctx_usuario() RETURNS INTEGER
LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.id_usuario', true), '')::integer $$;

CREATE OR REPLACE FUNCTION sp_set_contexto(p_id_usuario INTEGER, p_ip INET DEFAULT NULL, p_solo_transaccion BOOLEAN DEFAULT FALSE)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config('app.id_usuario', coalesce(p_id_usuario::text, ''), p_solo_transaccion);
    PERFORM set_config('app.ip', coalesce(host(p_ip), ''), p_solo_transaccion);
END $$;

-- codigo del rol de un usuario activo (NULL si no existe o esta inactivo)
CREATE OR REPLACE FUNCTION fn_rol_codigo(p_id_usuario INTEGER) RETURNS VARCHAR
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = imax, pg_temp AS $$
    SELECT r.codigo FROM usuario u JOIN rol r ON r.id_rol = u.id_rol
    WHERE u.id_usuario = p_id_usuario AND u.activo
$$;

CREATE OR REPLACE FUNCTION fn_es_superusuario() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = imax, pg_temp AS $$
    SELECT coalesce((SELECT rolsuper FROM pg_roles WHERE rolname = session_user), FALSE)
$$;

-- RN-18: true si la sala tiene asientos bloqueados o vendidos para funciones que todavia no pasan
CREATE OR REPLACE FUNCTION fn_sala_tiene_ventas_activas(p_id_sala INTEGER) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = imax, pg_temp AS $$
    SELECT EXISTS (
        SELECT 1
        FROM reserva_asiento r
        JOIN funcion f ON f.id_funcion = r.id_funcion
        WHERE r.id_sala = p_id_sala
          AND f.estado = 'PROGRAMADA'
          AND f.inicio > now()
          AND (r.estado = 'VENDIDO' OR (r.estado = 'BLOQUEADO' AND r.bloqueado_hasta > clock_timestamp()))
    )
$$;

-- guarda una fila en la bitacora administrativa (la usan los triggers y los sp_admin_*)
CREATE OR REPLACE FUNCTION fn_registrar_audit_admin(
    p_id_admin INTEGER, p_accion VARCHAR, p_entidad VARCHAR, p_id_entidad VARCHAR,
    p_antes JSONB, p_despues JSONB, p_motivo VARCHAR DEFAULT NULL, p_ip INET DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_rol SMALLINT;
    v_ip  INET;
BEGIN
    SELECT id_rol INTO v_rol FROM usuario WHERE id_usuario = p_id_admin;
    IF v_rol IS NULL THEN
        RAISE EXCEPTION 'El usuario administrador % no existe', p_id_admin;
    END IF;
    v_ip := coalesce(p_ip, nullif(current_setting('app.ip', true), '')::inet, inet_client_addr(), '127.0.0.1'::inet);

    INSERT INTO admin_operacion_audit (id_usuario_admin, id_rol, ip_origen, accion, entidad, id_entidad,
                                       valores_antes, valores_despues, motivo)
    VALUES (p_id_admin, v_rol, v_ip, p_accion, p_entidad, p_id_entidad, p_antes, p_despues, p_motivo);
END $$;

-- ============================================================
-- B. TRIGGERS DE CATALOGO
-- ============================================================

-- funcion: calcula la hora de fin (duracion + limpieza) y revisa que la pelicula y la sala esten activas
CREATE OR REPLACE FUNCTION trg_funcion_antes() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_dur  SMALLINT;
    v_act  BOOLEAN;
    v_sala BOOLEAN;
BEGIN
    IF TG_OP = 'INSERT' OR NEW.id_pelicula <> OLD.id_pelicula OR NEW.inicio <> OLD.inicio THEN
        SELECT duracion_min, activa INTO v_dur, v_act FROM pelicula WHERE id_pelicula = NEW.id_pelicula;
        NEW.fin := NEW.inicio + make_interval(mins => v_dur + coalesce(fn_param_int('limpieza_min'), 20));
    END IF;
    IF TG_OP = 'INSERT' THEN
        SELECT activa INTO v_sala FROM sala WHERE id_sala = NEW.id_sala;
        IF NOT v_act THEN RAISE EXCEPTION 'La pelicula % no esta activa', NEW.id_pelicula; END IF;
        IF NOT v_sala THEN RAISE EXCEPTION 'La sala % no esta activa', NEW.id_sala; END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_funcion_antes
    BEFORE INSERT OR UPDATE ON funcion
    FOR EACH ROW EXECUTE FUNCTION trg_funcion_antes();

-- RN-18: no se toca una sala (ni sus asientos) si tiene ventas activas
CREATE OR REPLACE FUNCTION trg_proteger_sala() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
BEGIN
    IF TG_OP = 'DELETE'
       OR NEW.id_cine <> OLD.id_cine OR NEW.id_formato <> OLD.id_formato
       OR (OLD.activa AND NOT NEW.activa) THEN
        IF fn_sala_tiene_ventas_activas(OLD.id_sala) THEN
            RAISE EXCEPTION 'RN-18: la sala % tiene entradas vendidas o reservadas para funciones programadas, no se puede modificar', OLD.id_sala;
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_proteger_sala
    BEFORE UPDATE OR DELETE ON sala
    FOR EACH ROW EXECUTE FUNCTION trg_proteger_sala();

CREATE OR REPLACE FUNCTION trg_proteger_asiento() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_sala INTEGER;
BEGIN
    v_sala := CASE WHEN TG_OP = 'INSERT' THEN NEW.id_sala ELSE OLD.id_sala END;
    IF fn_sala_tiene_ventas_activas(v_sala) THEN
        RAISE EXCEPTION 'RN-18: la sala % tiene entradas vendidas o reservadas para funciones programadas, no se puede cambiar su mapa de asientos', v_sala;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_proteger_asiento
    BEFORE INSERT OR UPDATE OR DELETE ON asiento
    FOR EACH ROW EXECUTE FUNCTION trg_proteger_asiento();

-- ============================================================
-- C. TRIGGERS DE LA MAQUINA DE ESTADOS (reserva, compra, boleto)
-- ============================================================

-- reserva: solo se permiten ciertos cambios de estado
CREATE OR REPLACE FUNCTION trg_reserva_antes() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.id_funcion <> OLD.id_funcion OR NEW.id_asiento <> OLD.id_asiento OR NEW.id_usuario <> OLD.id_usuario THEN
        RAISE EXCEPTION 'No se puede cambiar la funcion, el asiento ni el usuario de una reserva';
    END IF;
    IF NEW.estado <> OLD.estado THEN
        IF NOT ((OLD.estado = 'BLOQUEADO' AND NEW.estado IN ('VENDIDO', 'LIBERADO', 'EXPIRADO'))
             OR (OLD.estado = 'VENDIDO'   AND NEW.estado = 'LIBERADO')) THEN
            RAISE EXCEPTION 'Cambio de estado de reserva no permitido: % -> %', OLD.estado, NEW.estado;
        END IF;
    END IF;
    NEW.actualizado_en := now();
    RETURN NEW;
END $$;

CREATE TRIGGER trg_reserva_antes
    BEFORE UPDATE ON reserva_asiento
    FOR EACH ROW EXECUTE FUNCTION trg_reserva_antes();

-- compra: estados validos y RN-11 (no se marca pagada sin un pago aprobado)
CREATE OR REPLACE FUNCTION trg_compra_antes() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.estado NOT IN ('PENDIENTE') AND NOT (NEW.estado = 'PAGADA' AND NEW.canal = 'CORTESIA') THEN
            RAISE EXCEPTION 'Una compra nueva debe empezar PENDIENTE (solo las cortesias pueden nacer PAGADA)';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.estado <> OLD.estado THEN
        IF NOT ((OLD.estado = 'PENDIENTE' AND NEW.estado IN ('PAGADA', 'FALLIDA', 'EXPIRADA', 'CANCELADA'))
             OR (OLD.estado IN ('PAGADA', 'REEMBOLSADA_PARCIAL') AND NEW.estado IN ('REEMBOLSADA_PARCIAL', 'REEMBOLSADA'))) THEN
            RAISE EXCEPTION 'Cambio de estado de compra no permitido: % -> %', OLD.estado, NEW.estado;
        END IF;
        IF NEW.estado = 'PAGADA' AND NOT EXISTS (SELECT 1 FROM pago WHERE id_compra = NEW.id_compra AND estado = 'APROBADO') THEN
            RAISE EXCEPTION 'RN-11: la compra % no tiene un pago aprobado', NEW.id_compra;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_compra_antes
    BEFORE INSERT OR UPDATE ON compra
    FOR EACH ROW EXECUTE FUNCTION trg_compra_antes();

-- boleto: RN-04 (maximo por compra), RN-11 (QR solo con pago aprobado), RN-12 (QR unico) y RN-14 (un boleto usado no regresa)
CREATE OR REPLACE FUNCTION trg_boleto_antes() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_compra compra%ROWTYPE;
    v_n      INTEGER;
BEGIN
    SELECT * INTO v_compra FROM compra WHERE id_compra = NEW.id_compra;

    IF TG_OP = 'INSERT' THEN
        SELECT count(*) INTO v_n FROM boleto WHERE id_compra = NEW.id_compra AND estado <> 'ANULADO';
        IF v_n >= fn_param_int('max_asientos_por_compra') THEN
            RAISE EXCEPTION 'RN-04: una compra no puede tener mas de % boletos', fn_param_int('max_asientos_por_compra');
        END IF;
        IF NEW.estado NOT IN ('PENDIENTE') AND NOT (NEW.estado = 'EMITIDO' AND v_compra.canal = 'CORTESIA') THEN
            RAISE EXCEPTION 'Un boleto nuevo debe empezar PENDIENTE (solo las cortesias nacen EMITIDO)';
        END IF;
    ELSE
        IF NEW.id_reserva <> OLD.id_reserva AND OLD.estado <> 'EMITIDO' THEN
            RAISE EXCEPTION 'Solo se puede cambiar el asiento de un boleto EMITIDO';
        END IF;
        IF NEW.estado <> OLD.estado THEN
            IF NOT ((OLD.estado = 'PENDIENTE' AND NEW.estado IN ('EMITIDO', 'ANULADO'))
                 OR (OLD.estado = 'EMITIDO'   AND NEW.estado IN ('USADO', 'REEMBOLSADO'))) THEN
                RAISE EXCEPTION 'Cambio de estado de boleto no permitido: % -> %', OLD.estado, NEW.estado;
            END IF;
        END IF;
    END IF;

    -- al emitirse: la compra tiene que estar pagada y aqui se genera el QR
    IF NEW.estado = 'EMITIDO' AND (TG_OP = 'INSERT' OR OLD.estado <> 'EMITIDO') THEN
        IF v_compra.estado <> 'PAGADA' THEN
            RAISE EXCEPTION 'RN-11: no se puede emitir un boleto de la compra % porque no esta pagada', NEW.id_compra;
        END IF;
        NEW.codigo_qr  := 'IMX-' || upper(replace(gen_random_uuid()::text, '-', ''));
        NEW.emitido_en := now();
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_boleto_antes
    BEFORE INSERT OR UPDATE ON boleto
    FOR EACH ROW EXECUTE FUNCTION trg_boleto_antes();

-- ============================================================
-- D. TRIGGERS DE AUDITORIA AUTOMATICA (bitacoras)
-- ============================================================

-- cada cambio de estado de una reserva queda en asiento_auditoria_log
CREATE OR REPLACE FUNCTION trg_reserva_auditoria() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_evento VARCHAR(20);
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO asiento_auditoria_log (id_funcion, id_asiento, id_reserva, id_usuario, evento, estado_anterior, estado_nuevo)
        VALUES (NEW.id_funcion, NEW.id_asiento, NEW.id_reserva, NEW.id_usuario, NEW.estado, NULL, NEW.estado);
    ELSIF NEW.estado <> OLD.estado THEN
        v_evento := CASE
            WHEN NEW.estado = 'VENDIDO'  THEN 'VENDIDO'
            WHEN NEW.estado = 'EXPIRADO' THEN 'EXPIRADO'
            WHEN OLD.estado = 'VENDIDO'  THEN 'LIBERADO_VENTA'
            ELSE 'LIBERADO' END;
        INSERT INTO asiento_auditoria_log (id_funcion, id_asiento, id_reserva, id_usuario, evento, estado_anterior, estado_nuevo, detalle)
        VALUES (NEW.id_funcion, NEW.id_asiento, NEW.id_reserva, NEW.id_usuario, v_evento, OLD.estado, NEW.estado, NEW.motivo_cierre);
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_reserva_auditoria
    AFTER INSERT OR UPDATE ON reserva_asiento
    FOR EACH ROW EXECUTE FUNCTION trg_reserva_auditoria();

-- compra, pago, boleto y reembolso alimentan transaccion_log
CREATE OR REPLACE FUNCTION trg_compra_log() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO transaccion_log (id_compra, id_usuario, evento, monto, impuesto, detalle)
        VALUES (NEW.id_compra, coalesce(NEW.id_usuario, NEW.id_taquillero), 'COMPRA_CREADA', NEW.total, NEW.impuesto_incluido, NEW.canal);
        IF NEW.estado = 'PAGADA' THEN   -- cortesia
            INSERT INTO transaccion_log (id_compra, id_usuario, evento, monto, impuesto, detalle)
            VALUES (NEW.id_compra, NEW.id_usuario, 'COMPRA_PAGADA', NEW.total, NEW.impuesto_incluido, NEW.canal);
        END IF;
    ELSIF NEW.estado <> OLD.estado THEN
        INSERT INTO transaccion_log (id_compra, id_usuario, evento, monto, impuesto, detalle)
        VALUES (NEW.id_compra, coalesce(NEW.id_usuario, NEW.id_taquillero), 'COMPRA_' || NEW.estado, NEW.total, NEW.impuesto_incluido, NEW.canal);
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_compra_log
    AFTER INSERT OR UPDATE OF estado ON compra
    FOR EACH ROW EXECUTE FUNCTION trg_compra_log();

CREATE OR REPLACE FUNCTION trg_pago_log() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_c compra%ROWTYPE;
BEGIN
    SELECT * INTO v_c FROM compra WHERE id_compra = NEW.id_compra;
    INSERT INTO transaccion_log (id_compra, id_pago, id_usuario, evento, monto, impuesto, id_metodo_pago, referencia_pasarela, detalle)
    VALUES (NEW.id_compra, NEW.id_pago, coalesce(v_c.id_usuario, v_c.id_taquillero), 'PAGO_' || NEW.estado, NEW.monto,
            v_c.impuesto_incluido, NEW.id_metodo_pago, NEW.referencia_pasarela, NEW.motivo_rechazo);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_pago_log
    AFTER INSERT ON pago
    FOR EACH ROW EXECUTE FUNCTION trg_pago_log();

CREATE OR REPLACE FUNCTION trg_boleto_log() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_c compra%ROWTYPE;
BEGIN
    IF NEW.estado = 'EMITIDO' AND (TG_OP = 'INSERT' OR OLD.estado <> 'EMITIDO') THEN
        SELECT * INTO v_c FROM compra WHERE id_compra = NEW.id_compra;
        INSERT INTO transaccion_log (id_compra, id_boleto, id_usuario, evento, monto, detalle)
        VALUES (NEW.id_compra, NEW.id_boleto, coalesce(v_c.id_usuario, v_c.id_taquillero), 'BOLETO_EMITIDO', NEW.precio_final, NEW.codigo_qr);
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_boleto_log
    AFTER INSERT OR UPDATE OF estado ON boleto
    FOR EACH ROW EXECUTE FUNCTION trg_boleto_log();

CREATE OR REPLACE FUNCTION trg_reembolso_log() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_compra BIGINT;
BEGIN
    SELECT id_compra INTO v_compra FROM boleto WHERE id_boleto = NEW.id_boleto;
    INSERT INTO transaccion_log (id_compra, id_pago, id_boleto, id_usuario, evento, monto, detalle)
    VALUES (v_compra, NEW.id_pago, NEW.id_boleto, coalesce(NEW.id_admin, NEW.id_solicitante), 'REEMBOLSO', NEW.monto, NEW.tipo);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_reembolso_log
    AFTER INSERT ON reembolso
    FOR EACH ROW EXECUTE FUNCTION trg_reembolso_log();

-- bitacora administrativa automatica para las tablas de configuracion.
-- Parametro del trigger: nombre de la columna que es la llave primaria.
CREATE OR REPLACE FUNCTION trg_audit_admin() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = imax, pg_temp AS $$
DECLARE
    v_uid   INTEGER;
    v_antes JSONB;
    v_desp  JSONB;
    v_pk    TEXT;
BEGIN
    -- carga masiva (seed): solo un superusuario puede apagar la auditoria con app.modo_carga = on
    IF coalesce(current_setting('app.modo_carga', true), '') = 'on' AND fn_es_superusuario() THEN
        RETURN NULL;
    END IF;

    v_antes := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END;
    v_desp  := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END;
    IF TG_OP = 'UPDATE' AND v_antes = v_desp THEN
        RETURN NULL;
    END IF;
    v_pk := coalesce(v_desp, v_antes) ->> TG_ARGV[0];

    v_uid := fn_ctx_usuario();
    IF v_uid IS NULL THEN
        IF fn_es_superusuario() THEN
            SELECT id_usuario INTO v_uid FROM usuario WHERE correo = 'sistema@imax.test';
        END IF;
        IF v_uid IS NULL THEN
            RAISE EXCEPTION 'Operacion administrativa sin usuario identificado (falta llamar sp_set_contexto)';
        END IF;
    END IF;

    PERFORM fn_registrar_audit_admin(v_uid, TG_OP, TG_TABLE_NAME::varchar, v_pk, v_antes, v_desp,
                                     nullif(current_setting('app.motivo', true), ''));
    RETURN NULL;
END $$;

CREATE TRIGGER trg_audit_pelicula  AFTER INSERT OR UPDATE OR DELETE ON pelicula
    FOR EACH ROW EXECUTE FUNCTION trg_audit_admin('id_pelicula');
CREATE TRIGGER trg_audit_funcion   AFTER INSERT OR UPDATE OR DELETE ON funcion
    FOR EACH ROW EXECUTE FUNCTION trg_audit_admin('id_funcion');
CREATE TRIGGER trg_audit_sala      AFTER INSERT OR UPDATE OR DELETE ON sala
    FOR EACH ROW EXECUTE FUNCTION trg_audit_admin('id_sala');
CREATE TRIGGER trg_audit_tarifa    AFTER INSERT OR UPDATE OR DELETE ON tarifa
    FOR EACH ROW EXECUTE FUNCTION trg_audit_admin('id_tarifa');
CREATE TRIGGER trg_audit_promocion AFTER INSERT OR UPDATE OR DELETE ON promocion
    FOR EACH ROW EXECUTE FUNCTION trg_audit_admin('id_promocion');
CREATE TRIGGER trg_audit_parametro AFTER INSERT OR UPDATE OR DELETE ON parametro_sistema
    FOR EACH ROW EXECUTE FUNCTION trg_audit_admin('clave');
CREATE TRIGGER trg_audit_usuario   AFTER UPDATE ON usuario
    FOR EACH ROW WHEN (OLD.id_rol IS DISTINCT FROM NEW.id_rol OR OLD.activo IS DISTINCT FROM NEW.activo)
    EXECUTE FUNCTION trg_audit_admin('id_usuario');
CREATE TRIGGER trg_audit_usuario_alta AFTER INSERT ON usuario
    FOR EACH ROW EXECUTE FUNCTION trg_audit_admin('id_usuario');

-- ============================================================
-- E. BITACORAS INALTERABLES
-- ============================================================
-- Nadie puede hacer UPDATE, DELETE ni TRUNCATE sobre las 4 bitacoras (ni siquiera el admin).
-- Archivar una particion vieja se hace con DETACH PARTITION desde el dueno de la BD.

CREATE OR REPLACE FUNCTION trg_bitacora_inmutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'RN-20: la bitacora % es inalterable, no se permite %', TG_TABLE_NAME, TG_OP;
END $$;

CREATE TRIGGER trg_inmutable_transaccion BEFORE UPDATE OR DELETE ON transaccion_log
    FOR EACH ROW EXECUTE FUNCTION trg_bitacora_inmutable();
CREATE TRIGGER trg_inmutable_asiento BEFORE UPDATE OR DELETE ON asiento_auditoria_log
    FOR EACH ROW EXECUTE FUNCTION trg_bitacora_inmutable();
CREATE TRIGGER trg_inmutable_acceso BEFORE UPDATE OR DELETE ON acceso_puerta_log
    FOR EACH ROW EXECUTE FUNCTION trg_bitacora_inmutable();
CREATE TRIGGER trg_inmutable_admin BEFORE UPDATE OR DELETE ON admin_operacion_audit
    FOR EACH ROW EXECUTE FUNCTION trg_bitacora_inmutable();

CREATE TRIGGER trg_inmutable_transaccion_trunc BEFORE TRUNCATE ON transaccion_log
    FOR EACH STATEMENT EXECUTE FUNCTION trg_bitacora_inmutable();
CREATE TRIGGER trg_inmutable_asiento_trunc BEFORE TRUNCATE ON asiento_auditoria_log
    FOR EACH STATEMENT EXECUTE FUNCTION trg_bitacora_inmutable();
CREATE TRIGGER trg_inmutable_acceso_trunc BEFORE TRUNCATE ON acceso_puerta_log
    FOR EACH STATEMENT EXECUTE FUNCTION trg_bitacora_inmutable();
CREATE TRIGGER trg_inmutable_admin_trunc BEFORE TRUNCATE ON admin_operacion_audit
    FOR EACH STATEMENT EXECUTE FUNCTION trg_bitacora_inmutable();
