-- 04_rbac.sql
-- Proyecto 2 - Cine IMAX (TI-3600 Bases de Datos)
-- Control de acceso por roles (RBAC) con privilegio minimo, segun la matriz del proyecto.
-- Va despues de 03_procedimientos.sql.
--
-- Hay un rol de grupo por perfil (rol_*) que tiene los permisos, y un usuario de login
-- (app_*) por perfil para que la interfaz se conecte. Las contrasenas son de demostracion:
-- hay que cambiarlas antes de usar esto en serio.
--
-- Como la app no tiene login real, la interfaz le dice a la BD quien es el usuario con
--     SELECT sp_set_contexto(<id_usuario>);
-- justo despues de conectarse. Las vistas "mis entradas" y "corte de caja" y la bitacora
-- administrativa usan ese dato.

SET search_path = imax, public;

-- ---------- roles de grupo y usuarios de login ----------
DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['cliente', 'taquillero', 'operador_sala', 'contador', 'admin'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_' || r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', 'rol_' || r);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_' || r) THEN
            EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L IN ROLE %I', 'app_' || r, 'imax_demo_' || r, 'rol_' || r);
        END IF;
    END LOOP;
END $$;

-- ---------- punto de partida: nadie tiene nada ----------
REVOKE ALL ON SCHEMA imax FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA imax FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA imax FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA imax FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA imax REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

GRANT USAGE ON SCHEMA imax TO rol_cliente, rol_taquillero, rol_operador_sala, rol_contador, rol_admin;

-- funciones de lectura que usan las vistas (si no, la vista falla con "permission denied for function")
GRANT EXECUTE ON FUNCTION fn_ctx_usuario(), fn_param(TEXT), fn_param_int(TEXT), fn_param_num(TEXT)
  TO rol_cliente, rol_taquillero, rol_operador_sala, rol_contador, rol_admin;

-- ---------- CLIENTE: ve la cartelera, compra y ve solo sus entradas ----------
GRANT SELECT ON v_cartelera, v_mis_entradas TO rol_cliente;
GRANT SELECT ON tipo_entrada, metodo_pago, promocion TO rol_cliente;     -- para armar la pantalla de pago
GRANT EXECUTE ON FUNCTION
    fn_buscar_funciones(TEXT, DATE, TEXT),
    fn_mapa_asientos(BIGINT),
    sp_set_contexto(INTEGER, INET, BOOLEAN),
    sp_bloquear_asientos(BIGINT, INTEGER[], INTEGER),
    sp_bloquear_asiento(BIGINT, INTEGER, INTEGER),
    sp_liberar_asientos(BIGINT[], INTEGER),
    sp_iniciar_compra(INTEGER, BIGINT[], SMALLINT[], VARCHAR, INTEGER),
    sp_procesar_pago(BIGINT, SMALLINT, TEXT, VARCHAR, TEXT),
    sp_solicitar_reembolso(BIGINT, INTEGER, VARCHAR)
  TO rol_cliente;

-- ---------- TAQUILLERO: igual que el cliente pero en venta presencial + su corte de caja ----------
GRANT SELECT ON pelicula, clasificacion, genero, pelicula_genero, cine, formato_proyeccion, sala, tipo_asiento,
                asiento, funcion, tarifa, tipo_entrada, promocion, metodo_pago, puerta TO rol_taquillero;
GRANT SELECT ON v_cartelera, v_ventas_taquillero, v_corte_caja_taquillero TO rol_taquillero;
GRANT EXECUTE ON FUNCTION
    fn_buscar_funciones(TEXT, DATE, TEXT),
    fn_mapa_asientos(BIGINT),
    sp_set_contexto(INTEGER, INET, BOOLEAN),
    sp_bloquear_asientos(BIGINT, INTEGER[], INTEGER),
    sp_bloquear_asiento(BIGINT, INTEGER, INTEGER),
    sp_liberar_asientos(BIGINT[], INTEGER),
    sp_iniciar_compra(INTEGER, BIGINT[], SMALLINT[], VARCHAR, INTEGER),
    sp_procesar_pago(BIGINT, SMALLINT, TEXT, VARCHAR, TEXT),
    sp_solicitar_reembolso(BIGINT, INTEGER, VARCHAR)
  TO rol_taquillero;

-- ---------- OPERADOR DE SALA: solo lee el catalogo y valida QR ----------
GRANT SELECT ON pelicula, clasificacion, genero, pelicula_genero, cine, formato_proyeccion, sala, tipo_asiento,
                asiento, funcion, tipo_entrada, puerta TO rol_operador_sala;
GRANT SELECT ON v_cartelera TO rol_operador_sala;
GRANT EXECUTE ON FUNCTION
    fn_buscar_funciones(TEXT, DATE, TEXT),
    sp_set_contexto(INTEGER, INET, BOOLEAN),
    sp_validar_entrada(TEXT, INTEGER, INTEGER)
  TO rol_operador_sala;

-- ---------- CONTADOR: lectura y exportacion de lo financiero, sin tocar nada ----------
GRANT SELECT ON pelicula, cine, sala, funcion, metodo_pago, tipo_entrada, promocion TO rol_contador;
GRANT SELECT ON compra, pago, reembolso, boleto, transaccion_log TO rol_contador;
GRANT SELECT ON v_cartelera, v_ocupacion_funcion, v_resumen_financiero_diario TO rol_contador;
GRANT EXECUTE ON FUNCTION sp_set_contexto(INTEGER, INET, BOOLEAN), fn_buscar_funciones(TEXT, DATE, TEXT) TO rol_contador;

-- ---------- ADMINISTRADOR: configura todo y lee toda la auditoria, pero no puede alterar las bitacoras ----------
GRANT SELECT, INSERT, UPDATE, DELETE ON pelicula, clasificacion, genero, pelicula_genero, cine, formato_proyeccion, sala,
                                        tipo_asiento, asiento, funcion, tarifa, tipo_entrada, promocion, metodo_pago,
                                        puerta, parametro_sistema TO rol_admin;
GRANT SELECT ON rol, usuario TO rol_admin;
GRANT INSERT ON usuario TO rol_admin;                               -- alta de personal
GRANT UPDATE (id_rol, activo) ON usuario TO rol_admin;              -- asignar o revocar roles (queda en la bitacora)
GRANT SELECT ON compra, boleto, reserva_asiento, pago, reembolso TO rol_admin;
GRANT SELECT ON transaccion_log, asiento_auditoria_log, acceso_puerta_log, admin_operacion_audit TO rol_admin;
GRANT SELECT ON v_cartelera, v_ocupacion_funcion, v_resumen_financiero_diario, v_metricas_tiempo_real TO rol_admin;
GRANT EXECUTE ON FUNCTION
    fn_buscar_funciones(TEXT, DATE, TEXT),
    fn_mapa_asientos(BIGINT),
    fn_particiones_para_archivar(INTEGER),
    sp_set_contexto(INTEGER, INET, BOOLEAN),
    sp_liberar_bloqueos_expirados(),
    sp_solicitar_reembolso(BIGINT, INTEGER, VARCHAR),
    sp_admin_reembolso_forzado(INTEGER, BIGINT, VARCHAR, INET),
    sp_admin_cambiar_asiento(INTEGER, BIGINT, INTEGER, VARCHAR, INET),
    sp_admin_otorgar_cortesia(INTEGER, BIGINT, INTEGER, INTEGER, VARCHAR, INET),
    sp_cancelar_funcion(INTEGER, BIGINT, VARCHAR, INET)
  TO rol_admin;

-- Nota: ningun rol tiene INSERT/UPDATE/DELETE sobre compra, boleto, reserva_asiento, pago, reembolso ni las
-- bitacoras. Todo eso solo cambia a traves de los procedimientos (SECURITY DEFINER), que validan las reglas.
