-- 01_ddl.sql
-- Proyecto 2 - Cine IMAX (TI-3600 Bases de Datos)
-- Creacion del esquema, tablas, llaves y restricciones de integridad.
--
-- Va conectado a la bd imax. Aqui NO se crean indices secundarios a proposito:
-- solo quedan los que salen de las PK, UNIQUE y la restriccion de traslape.
-- Los demas indices estan en 06_indices.sql para poder medir el "antes y despues"
-- con EXPLAIN ANALYZE.

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- para evitar traslapes de funciones en una sala

CREATE SCHEMA IF NOT EXISTS imax;
SET search_path = imax, public;

-- ============================================================
-- 1. SEGURIDAD: roles y usuarios
-- ============================================================

CREATE TABLE rol (
    id_rol       SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo       VARCHAR(20)  NOT NULL,
    nombre       VARCHAR(50)  NOT NULL,
    descripcion  VARCHAR(200),
    CONSTRAINT uq_rol_codigo UNIQUE (codigo)
);

CREATE TABLE usuario (
    id_usuario        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_rol            SMALLINT     NOT NULL REFERENCES rol (id_rol),
    nombre            VARCHAR(60)  NOT NULL,
    apellidos         VARCHAR(80)  NOT NULL,
    correo            VARCHAR(120) NOT NULL,
    telefono          VARCHAR(20),
    fecha_nacimiento  DATE,
    activo            BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_usuario_correo UNIQUE (correo),
    CONSTRAINT ck_usuario_correo CHECK (correo = lower(correo) AND correo ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

-- ============================================================
-- 2. CATALOGO: cines, salas, asientos
-- ============================================================

CREATE TABLE cine (
    id_cine    SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre     VARCHAR(80)  NOT NULL,
    region     VARCHAR(50)  NOT NULL,       -- provincia / estado
    ciudad     VARCHAR(60)  NOT NULL,
    direccion  VARCHAR(200) NOT NULL,
    activo     BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_cine_nombre UNIQUE (nombre)
);

CREATE TABLE formato_proyeccion (
    id_formato  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre      VARCHAR(40) NOT NULL,
    CONSTRAINT uq_formato_nombre UNIQUE (nombre)
);

CREATE TABLE sala (
    id_sala     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_cine     SMALLINT    NOT NULL REFERENCES cine (id_cine),
    id_formato  SMALLINT    NOT NULL REFERENCES formato_proyeccion (id_formato),
    nombre      VARCHAR(40) NOT NULL,
    activa      BOOLEAN     NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_sala_nombre_por_cine UNIQUE (id_cine, nombre)
);

CREATE TABLE tipo_asiento (          -- la "zona" de la sala: general, platea, palco, vip
    id_tipo_asiento  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo           VARCHAR(20) NOT NULL,
    nombre           VARCHAR(40) NOT NULL,
    CONSTRAINT uq_tipo_asiento_codigo UNIQUE (codigo)
);

CREATE TABLE asiento (
    id_asiento       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_sala          INTEGER     NOT NULL REFERENCES sala (id_sala),
    id_tipo_asiento  SMALLINT    NOT NULL REFERENCES tipo_asiento (id_tipo_asiento),
    fila             VARCHAR(2)  NOT NULL,
    numero           SMALLINT    NOT NULL,
    CONSTRAINT uq_asiento_posicion UNIQUE (id_sala, fila, numero),
    -- esta UNIQUE extra es solo para poder armar la llave foranea compuesta de reserva_asiento
    CONSTRAINT uq_asiento_con_sala UNIQUE (id_asiento, id_sala),
    CONSTRAINT ck_asiento_fila   CHECK (fila ~ '^[A-Z]{1,2}$'),
    CONSTRAINT ck_asiento_numero CHECK (numero > 0)
);

CREATE TABLE puerta (               -- totem o punto de lectura de QR de una sala
    id_puerta  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_sala    INTEGER     NOT NULL REFERENCES sala (id_sala),
    nombre     VARCHAR(40) NOT NULL,
    tipo       VARCHAR(10) NOT NULL DEFAULT 'TOTEM',
    CONSTRAINT uq_puerta_nombre_por_sala UNIQUE (id_sala, nombre),
    CONSTRAINT ck_puerta_tipo CHECK (tipo IN ('TOTEM', 'PERSONAL'))
);

-- ============================================================
-- 3. CATALOGO: peliculas y funciones
-- ============================================================

CREATE TABLE clasificacion (
    id_clasificacion  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo            VARCHAR(10)  NOT NULL,
    descripcion       VARCHAR(100) NOT NULL,
    edad_minima       SMALLINT     NOT NULL,
    CONSTRAINT uq_clasificacion_codigo UNIQUE (codigo),
    CONSTRAINT ck_clasificacion_edad CHECK (edad_minima BETWEEN 0 AND 21)
);

CREATE TABLE genero (
    id_genero  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre     VARCHAR(40) NOT NULL,
    CONSTRAINT uq_genero_nombre UNIQUE (nombre)
);

CREATE TABLE pelicula (
    id_pelicula       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_clasificacion  SMALLINT     NOT NULL REFERENCES clasificacion (id_clasificacion),
    titulo            VARCHAR(150) NOT NULL,          -- RN-02: titulo, sinopsis y clasificacion son obligatorios
    sinopsis          TEXT         NOT NULL,
    duracion_min      SMALLINT     NOT NULL,
    poster_url        VARCHAR(300),
    fecha_estreno     DATE,
    activa            BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT ck_pelicula_duracion CHECK (duracion_min BETWEEN 1 AND 600),
    CONSTRAINT ck_pelicula_titulo   CHECK (length(btrim(titulo)) > 0),
    CONSTRAINT ck_pelicula_sinopsis CHECK (length(btrim(sinopsis)) > 0)
);

CREATE TABLE pelicula_genero (
    id_pelicula  INTEGER  NOT NULL REFERENCES pelicula (id_pelicula),
    id_genero    SMALLINT NOT NULL REFERENCES genero (id_genero),
    PRIMARY KEY (id_pelicula, id_genero)
);

CREATE TABLE funcion (
    id_funcion   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_pelicula  INTEGER     NOT NULL REFERENCES pelicula (id_pelicula),
    id_sala      INTEGER     NOT NULL REFERENCES sala (id_sala),
    inicio       TIMESTAMPTZ NOT NULL,
    fin          TIMESTAMPTZ NOT NULL,     -- lo calcula un trigger: inicio + duracion + tiempo de limpieza
    estado       VARCHAR(12) NOT NULL DEFAULT 'PROGRAMADA',
    CONSTRAINT ck_funcion_estado CHECK (estado IN ('PROGRAMADA', 'CANCELADA', 'FINALIZADA')),
    CONSTRAINT ck_funcion_fechas CHECK (fin > inicio),
    CONSTRAINT uq_funcion_con_sala UNIQUE (id_funcion, id_sala),
    -- no puede haber dos funciones activas que se traslapen en la misma sala
    CONSTRAINT ex_funcion_sin_traslape
        EXCLUDE USING gist (id_sala WITH =, tstzrange(inicio, fin) WITH &&)
        WHERE (estado <> 'CANCELADA')
);

-- ============================================================
-- 4. TARIFAS Y PROMOCIONES
-- ============================================================

CREATE TABLE tarifa (               -- matriz de precios: zona x dia de la semana
    id_tarifa        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_tipo_asiento  SMALLINT      NOT NULL REFERENCES tipo_asiento (id_tipo_asiento),
    dia_semana       SMALLINT      NOT NULL,      -- 1 = lunes ... 7 = domingo (isodow)
    precio           NUMERIC(10,2) NOT NULL,
    CONSTRAINT uq_tarifa UNIQUE (id_tipo_asiento, dia_semana),
    CONSTRAINT ck_tarifa_dia    CHECK (dia_semana BETWEEN 1 AND 7),
    CONSTRAINT ck_tarifa_precio CHECK (precio > 0)
);

CREATE TABLE tipo_entrada (         -- adulto, nino, tercera edad, estudiante, cortesia
    id_tipo_entrada         SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo                  VARCHAR(20)  NOT NULL,
    nombre                  VARCHAR(50)  NOT NULL,
    descuento_pct           NUMERIC(5,2) NOT NULL DEFAULT 0,
    requiere_validacion_doc BOOLEAN      NOT NULL DEFAULT FALSE,   -- RN-06
    CONSTRAINT uq_tipo_entrada_codigo UNIQUE (codigo),
    CONSTRAINT ck_tipo_entrada_desc CHECK (descuento_pct BETWEEN 0 AND 100)
);

CREATE TABLE promocion (
    id_promocion   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre         VARCHAR(80)  NOT NULL,
    tipo           VARCHAR(12)  NOT NULL,
    descuento_pct  NUMERIC(5,2),                 -- solo para tipo PORCENTAJE
    dia_semana     SMALLINT,                     -- NULL = cualquier dia
    vigente_desde  DATE,
    vigente_hasta  DATE,
    prioridad      SMALLINT     NOT NULL DEFAULT 1,   -- si aplican varias, gana la de menor numero
    activa         BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT ck_promocion_tipo   CHECK (tipo IN ('2X1', 'PORCENTAJE')),
    CONSTRAINT ck_promocion_pct    CHECK ((tipo = 'PORCENTAJE') = (descuento_pct IS NOT NULL)),
    CONSTRAINT ck_promocion_pct_rango CHECK (descuento_pct IS NULL OR descuento_pct BETWEEN 1 AND 100),
    CONSTRAINT ck_promocion_dia    CHECK (dia_semana IS NULL OR dia_semana BETWEEN 1 AND 7),
    CONSTRAINT ck_promocion_fechas CHECK (vigente_hasta IS NULL OR vigente_desde IS NULL OR vigente_hasta >= vigente_desde)
);

CREATE TABLE metodo_pago (
    id_metodo_pago  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo          VARCHAR(25) NOT NULL,
    nombre          VARCHAR(50) NOT NULL,
    requiere_tarjeta BOOLEAN    NOT NULL DEFAULT FALSE,
    activo          BOOLEAN     NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_metodo_pago_codigo UNIQUE (codigo)
);

CREATE TABLE parametro_sistema (    -- reglas de negocio que se pueden cambiar sin tocar el codigo
    clave        VARCHAR(40)  PRIMARY KEY,
    valor        VARCHAR(100) NOT NULL,
    descripcion  VARCHAR(200)
);

-- ============================================================
-- 5. VENTA: reservas, compras, boletos, pagos, reembolsos
-- ============================================================

CREATE TABLE compra (
    id_compra          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_usuario         INTEGER  REFERENCES usuario (id_usuario),     -- cliente (puede ser NULL en venta de taquilla)
    id_taquillero      INTEGER  REFERENCES usuario (id_usuario),     -- solo si la venta fue presencial
    id_promocion       INTEGER  REFERENCES promocion (id_promocion),
    canal              VARCHAR(10)   NOT NULL,
    estado             VARCHAR(20)   NOT NULL DEFAULT 'PENDIENTE',
    subtotal           NUMERIC(10,2) NOT NULL,
    descuento_total    NUMERIC(10,2) NOT NULL DEFAULT 0,
    cargo_servicio     NUMERIC(10,2) NOT NULL DEFAULT 0,
    total              NUMERIC(10,2) NOT NULL,
    impuesto_incluido  NUMERIC(10,2) NOT NULL DEFAULT 0,
    creada_en          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    expira_en          TIMESTAMPTZ   NOT NULL,
    CONSTRAINT ck_compra_canal  CHECK (canal IN ('WEB', 'TAQUILLA', 'CORTESIA')),
    CONSTRAINT ck_compra_estado CHECK (estado IN ('PENDIENTE', 'PAGADA', 'FALLIDA', 'EXPIRADA',
                                                  'CANCELADA', 'REEMBOLSADA_PARCIAL', 'REEMBOLSADA')),
    CONSTRAINT ck_compra_montos CHECK (subtotal >= 0 AND descuento_total >= 0 AND cargo_servicio >= 0
                                       AND total >= 0 AND impuesto_incluido >= 0),
    CONSTRAINT ck_compra_descuento CHECK (descuento_total <= subtotal),
    -- RN-08: el total es exactamente subtotal - descuentos + cargo por servicio
    CONSTRAINT ck_compra_total CHECK (total = subtotal - descuento_total + cargo_servicio),
    CONSTRAINT ck_compra_cliente CHECK (canal = 'TAQUILLA' OR id_usuario IS NOT NULL),
    CONSTRAINT ck_compra_taquillero CHECK ((canal = 'TAQUILLA') = (id_taquillero IS NOT NULL))
);

CREATE TABLE reserva_asiento (      -- un asiento bloqueado o vendido para una funcion
    id_reserva       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_funcion       BIGINT      NOT NULL,
    id_asiento       INTEGER     NOT NULL,
    id_sala          INTEGER     NOT NULL,     -- repetido a proposito para que las FK compuestas validen que el asiento es de la sala de la funcion
    id_usuario       INTEGER     NOT NULL REFERENCES usuario (id_usuario),   -- quien lo tiene bloqueado / comprado
    estado           VARCHAR(10) NOT NULL DEFAULT 'BLOQUEADO',
    bloqueado_en     TIMESTAMPTZ NOT NULL DEFAULT now(),
    bloqueado_hasta  TIMESTAMPTZ,
    motivo_cierre    VARCHAR(25),
    actualizado_en   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_reserva_funcion FOREIGN KEY (id_funcion, id_sala) REFERENCES funcion (id_funcion, id_sala),
    CONSTRAINT fk_reserva_asiento FOREIGN KEY (id_asiento, id_sala) REFERENCES asiento (id_asiento, id_sala),
    CONSTRAINT ck_reserva_estado CHECK (estado IN ('BLOQUEADO', 'VENDIDO', 'LIBERADO', 'EXPIRADO')),
    CONSTRAINT ck_reserva_bloqueo CHECK (estado <> 'BLOQUEADO' OR bloqueado_hasta IS NOT NULL),
    CONSTRAINT ck_reserva_vigencia CHECK (bloqueado_hasta IS NULL OR bloqueado_hasta > bloqueado_en)
);

-- ESTA ES LA RESTRICCION ANTI DOBLE VENTA.
-- Un asiento de una funcion solo puede tener UNA reserva activa (bloqueada o vendida).
-- Las liberadas o expiradas no cuentan, asi el asiento se puede volver a vender.
CREATE UNIQUE INDEX uq_reserva_asiento_activa
    ON reserva_asiento (id_funcion, id_asiento)
    WHERE estado IN ('BLOQUEADO', 'VENDIDO');

CREATE TABLE boleto (               -- una linea de compra y, ya pagada, la entrada con su QR
    id_boleto        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_compra        BIGINT        NOT NULL REFERENCES compra (id_compra),
    id_reserva       BIGINT        NOT NULL REFERENCES reserva_asiento (id_reserva),
    id_tipo_entrada  SMALLINT      NOT NULL REFERENCES tipo_entrada (id_tipo_entrada),
    estado           VARCHAR(12)   NOT NULL DEFAULT 'PENDIENTE',
    precio_base      NUMERIC(10,2) NOT NULL,
    descuento_tipo   NUMERIC(10,2) NOT NULL DEFAULT 0,
    descuento_promo  NUMERIC(10,2) NOT NULL DEFAULT 0,
    precio_final     NUMERIC(10,2) NOT NULL,
    codigo_qr        VARCHAR(40),
    emitido_en       TIMESTAMPTZ,
    usado_en         TIMESTAMPTZ,
    CONSTRAINT uq_boleto_reserva UNIQUE (id_reserva),
    CONSTRAINT uq_boleto_qr      UNIQUE (codigo_qr),          -- RN-12
    CONSTRAINT ck_boleto_estado  CHECK (estado IN ('PENDIENTE', 'EMITIDO', 'USADO', 'REEMBOLSADO', 'ANULADO')),
    CONSTRAINT ck_boleto_montos  CHECK (precio_base >= 0 AND descuento_tipo >= 0 AND descuento_promo >= 0 AND precio_final >= 0),
    CONSTRAINT ck_boleto_precio  CHECK (precio_final = precio_base - descuento_tipo - descuento_promo),
    -- RN-11: solo los boletos emitidos / usados / reembolsados tienen QR. Pendientes y anulados no.
    CONSTRAINT ck_boleto_qr      CHECK ((estado IN ('EMITIDO', 'USADO', 'REEMBOLSADO')) = (codigo_qr IS NOT NULL)),
    CONSTRAINT ck_boleto_emision CHECK ((codigo_qr IS NOT NULL) = (emitido_en IS NOT NULL)),
    CONSTRAINT ck_boleto_uso     CHECK ((estado = 'USADO') = (usado_en IS NOT NULL))
);

CREATE TABLE pago (
    id_pago              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_compra            BIGINT        NOT NULL REFERENCES compra (id_compra),
    id_metodo_pago       SMALLINT      NOT NULL REFERENCES metodo_pago (id_metodo_pago),
    monto                NUMERIC(10,2) NOT NULL,
    estado               VARCHAR(10)   NOT NULL,
    referencia_pasarela  VARCHAR(30)   NOT NULL,      -- referencia simulada de la pasarela
    ultimos4             CHAR(4),                     -- RN-09: solo los ultimos 4 digitos, nunca el numero completo ni el CVV
    marca_tarjeta        VARCHAR(20),
    motivo_rechazo       VARCHAR(100),
    creado_en            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT uq_pago_referencia UNIQUE (referencia_pasarela),
    CONSTRAINT ck_pago_estado   CHECK (estado IN ('APROBADO', 'RECHAZADO')),
    CONSTRAINT ck_pago_monto    CHECK (monto >= 0),
    CONSTRAINT ck_pago_ultimos4 CHECK (ultimos4 IS NULL OR ultimos4 ~ '^[0-9]{4}$')
);

-- una compra solo puede tener un pago aprobado (evita cobrar dos veces)
CREATE UNIQUE INDEX uq_pago_aprobado_por_compra ON pago (id_compra) WHERE estado = 'APROBADO';

CREATE TABLE reembolso (
    id_reembolso   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_boleto      BIGINT        NOT NULL REFERENCES boleto (id_boleto),
    id_pago        BIGINT        REFERENCES pago (id_pago),     -- NULL si era una cortesia
    id_solicitante INTEGER       REFERENCES usuario (id_usuario),
    id_admin       INTEGER       REFERENCES usuario (id_usuario),
    tipo           VARCHAR(20)   NOT NULL,
    monto          NUMERIC(10,2) NOT NULL,
    motivo         VARCHAR(200),
    creado_en      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT uq_reembolso_boleto UNIQUE (id_boleto),
    CONSTRAINT ck_reembolso_tipo  CHECK (tipo IN ('SOLICITUD', 'CANCELACION_FUNCION', 'FORZADO')),
    CONSTRAINT ck_reembolso_monto CHECK (monto >= 0),
    CONSTRAINT ck_reembolso_forzado CHECK (tipo <> 'FORZADO' OR id_admin IS NOT NULL)
);

-- ============================================================
-- 6. AUDITORIA (5 anios): 4 tablas separadas y particionadas por fecha
-- ============================================================
-- No llevan llaves foraneas a proposito: son bitacoras que escriben mucho,
-- tienen que sobrevivir aunque los datos vivos se archiven, y una FK les
-- agregaria bloqueos en cada insert. Las referencias son "logicas".

CREATE SEQUENCE seq_transaccion_log;
CREATE SEQUENCE seq_asiento_auditoria_log;
CREATE SEQUENCE seq_acceso_puerta_log;
CREATE SEQUENCE seq_admin_operacion_audit;

CREATE TABLE transaccion_log (
    id_log               BIGINT      NOT NULL DEFAULT nextval('seq_transaccion_log'),
    creado_en            TIMESTAMPTZ NOT NULL DEFAULT now(),
    id_compra            BIGINT      NOT NULL,
    id_pago              BIGINT,
    id_boleto            BIGINT,
    id_usuario           INTEGER,
    evento               VARCHAR(30) NOT NULL,
    monto                NUMERIC(10,2),
    impuesto             NUMERIC(10,2),
    id_metodo_pago       SMALLINT,
    referencia_pasarela  VARCHAR(30),
    detalle              VARCHAR(120),
    PRIMARY KEY (id_log, creado_en),
    CONSTRAINT ck_transaccion_log_evento CHECK (evento IN (
        'COMPRA_CREADA', 'COMPRA_PAGADA', 'COMPRA_FALLIDA', 'COMPRA_EXPIRADA', 'COMPRA_CANCELADA',
        'COMPRA_REEMBOLSADA_PARCIAL', 'COMPRA_REEMBOLSADA',
        'PAGO_APROBADO', 'PAGO_RECHAZADO', 'BOLETO_EMITIDO', 'REEMBOLSO'))
) PARTITION BY RANGE (creado_en);

CREATE TABLE asiento_auditoria_log (
    id_log           BIGINT      NOT NULL DEFAULT nextval('seq_asiento_auditoria_log'),
    creado_en        TIMESTAMPTZ NOT NULL DEFAULT now(),
    id_funcion       BIGINT      NOT NULL,
    id_asiento       INTEGER     NOT NULL,
    id_reserva       BIGINT,                 -- NULL cuando fue una colision (la reserva no llego a existir)
    id_usuario       INTEGER,
    evento           VARCHAR(20) NOT NULL,
    estado_anterior  VARCHAR(10),
    estado_nuevo     VARCHAR(10),
    detalle          VARCHAR(60),
    PRIMARY KEY (id_log, creado_en),
    CONSTRAINT ck_asiento_log_evento CHECK (evento IN (
        'BLOQUEADO', 'VENDIDO', 'EXPIRADO', 'LIBERADO', 'LIBERADO_VENTA', 'COLISION'))
) PARTITION BY RANGE (creado_en);

CREATE TABLE acceso_puerta_log (
    id_log        BIGINT      NOT NULL DEFAULT nextval('seq_acceso_puerta_log'),
    creado_en     TIMESTAMPTZ NOT NULL DEFAULT now(),
    id_boleto     BIGINT,                    -- NULL si el codigo leido no existe
    codigo_leido  VARCHAR(60) NOT NULL,
    id_puerta     INTEGER     NOT NULL,
    id_operador   INTEGER,
    resultado     VARCHAR(22) NOT NULL,
    mensaje       VARCHAR(80),
    PRIMARY KEY (id_log, creado_en),
    CONSTRAINT ck_acceso_log_resultado CHECK (resultado IN (
        'EXITOSO', 'RECHAZADO_DUPLICADO', 'RECHAZADO_HORARIO', 'RECHAZADO_FUNCION',
        'RECHAZADO_INVALIDO', 'RECHAZADO_ESTADO', 'RECHAZADO_OPERADOR'))
) PARTITION BY RANGE (creado_en);

CREATE TABLE admin_operacion_audit (
    id_audit          BIGINT      NOT NULL DEFAULT nextval('seq_admin_operacion_audit'),
    creado_en         TIMESTAMPTZ NOT NULL DEFAULT now(),
    id_usuario_admin  INTEGER     NOT NULL,
    id_rol            SMALLINT    NOT NULL,
    ip_origen         INET        NOT NULL,
    accion            VARCHAR(25) NOT NULL,
    entidad           VARCHAR(40) NOT NULL,
    id_entidad        VARCHAR(40),
    valores_antes     JSONB,
    valores_despues   JSONB,
    motivo            VARCHAR(200),
    PRIMARY KEY (id_audit, creado_en),
    CONSTRAINT ck_admin_audit_accion CHECK (accion IN (
        'INSERT', 'UPDATE', 'DELETE', 'CORTESIA', 'CAMBIO_ASIENTO',
        'REEMBOLSO_FORZADO', 'CANCELACION_FUNCION'))
) PARTITION BY RANGE (creado_en);

ALTER SEQUENCE seq_transaccion_log       OWNED BY transaccion_log.id_log;
ALTER SEQUENCE seq_asiento_auditoria_log OWNED BY asiento_auditoria_log.id_log;
ALTER SEQUENCE seq_acceso_puerta_log     OWNED BY acceso_puerta_log.id_log;
ALTER SEQUENCE seq_admin_operacion_audit OWNED BY admin_operacion_audit.id_audit;

-- particion "por si acaso": si algun dia se nos olvida crear la del mes siguiente,
-- los inserts no se caen (una venta no puede fallar por culpa de una bitacora)
CREATE TABLE transaccion_log_default       PARTITION OF transaccion_log       DEFAULT;
CREATE TABLE asiento_auditoria_log_default PARTITION OF asiento_auditoria_log DEFAULT;
CREATE TABLE acceso_puerta_log_default     PARTITION OF acceso_puerta_log     DEFAULT;
CREATE TABLE admin_operacion_audit_default PARTITION OF admin_operacion_audit DEFAULT;

-- funcion para crear las particiones. Las 3 bitacoras grandes son mensuales,
-- la administrativa es anual porque casi no tiene movimiento.
-- Se debe correr cada mes (pg_cron o un job del servidor).
CREATE OR REPLACE FUNCTION fn_crear_particiones_log(p_desde DATE, p_meses INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_mes     DATE;
    v_sig     DATE;
    v_anio    DATE;
    v_tabla   TEXT;
    v_nombre  TEXT;
    v_creadas INTEGER := 0;
BEGIN
    FOR i IN 0 .. p_meses - 1 LOOP
        v_mes := (date_trunc('month', p_desde) + make_interval(months => i))::date;
        v_sig := (v_mes + INTERVAL '1 month')::date;
        FOREACH v_tabla IN ARRAY ARRAY['transaccion_log', 'asiento_auditoria_log', 'acceso_puerta_log'] LOOP
            v_nombre := v_tabla || '_' || to_char(v_mes, 'YYYYMM');
            IF to_regclass('imax.' || v_nombre) IS NULL THEN
                -- los limites van en UTC para que no dependan de la zona horaria de la sesion
                EXECUTE format('CREATE TABLE imax.%I PARTITION OF imax.%I FOR VALUES FROM (%L) TO (%L)',
                               v_nombre, v_tabla, v_mes || ' 00:00:00+00', v_sig || ' 00:00:00+00');
                v_creadas := v_creadas + 1;
            END IF;
        END LOOP;
    END LOOP;

    FOR i IN 0 .. (p_meses / 12) LOOP
        v_anio := (date_trunc('year', p_desde) + make_interval(years => i))::date;
        v_nombre := 'admin_operacion_audit_' || to_char(v_anio, 'YYYY');
        IF to_regclass('imax.' || v_nombre) IS NULL THEN
            EXECUTE format('CREATE TABLE imax.%I PARTITION OF imax.admin_operacion_audit FOR VALUES FROM (%L) TO (%L)',
                           v_nombre, v_anio || ' 00:00:00+00', (v_anio + INTERVAL '1 year')::date || ' 00:00:00+00');
            v_creadas := v_creadas + 1;
        END IF;
    END LOOP;
    RETURN v_creadas;
END;
$$;

-- particiones iniciales: desde el mes pasado hasta 2 anios adelante
SELECT fn_crear_particiones_log((date_trunc('month', now()) - INTERVAL '1 month')::date, 26);

-- lista las particiones mensuales que ya cumplieron los anios de retencion,
-- para archivarlas (DETACH + copia a almacenamiento frio). No borra nada.
CREATE OR REPLACE FUNCTION fn_particiones_para_archivar(p_anios INTEGER DEFAULT 5)
RETURNS TABLE (tabla_padre TEXT, particion TEXT, limite TEXT)
LANGUAGE sql STABLE AS $$
    SELECT p.relname::text, c.relname::text, pg_get_expr(c.relpartbound, c.oid)
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    JOIN pg_class p ON p.oid = i.inhparent
    JOIN pg_namespace n ON n.oid = p.relnamespace
    WHERE n.nspname = 'imax'
      AND p.relname IN ('transaccion_log', 'asiento_auditoria_log', 'acceso_puerta_log', 'admin_operacion_audit')
      AND c.relname !~ '_default$'
      -- la fecha de inicio de la particion se saca de su limite (FROM ('2026-10-01 ...') TO (...))
      AND (substring(pg_get_expr(c.relpartbound, c.oid) FROM '[0-9]{4}-[0-9]{2}-[0-9]{2}'))::date
          < (date_trunc('month', now()) - make_interval(years => p_anios))::date
    ORDER BY c.relname;
$$;

-- que las nuevas sesiones encuentren las tablas sin escribir imax. todo el tiempo
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET search_path = imax, public', current_database());
END $$;
