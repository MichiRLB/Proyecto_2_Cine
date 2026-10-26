-- 06_indices.sql
-- Proyecto 2 - Cine IMAX (TI-3600 Bases de Datos)
-- Indices secundarios. Se dejan para el final A PROPOSITO: 01_ddl.sql solo crea los indices que
-- exigen las reglas (PK y UNIQUE), asi la persona de pruebas puede medir con EXPLAIN ANALYZE
-- "antes" (sin este archivo) y "despues" (con este archivo).
--
-- Cada indice dice para que consulta o proceso esta pensado. Es seguro correrlo mas de una vez.

SET search_path = imax, public;

-- ---------- bloqueo y expiracion de asientos (lo mas caliente del sistema) ----------
-- sp_liberar_bloqueos_expirados y la expiracion perezosa buscan bloqueos vencidos
CREATE INDEX IF NOT EXISTS ix_reserva_bloqueo_vence ON reserva_asiento (bloqueado_hasta) WHERE estado = 'BLOQUEADO';
-- RN-04: cuantos asientos tiene bloqueados este usuario en esta funcion
CREATE INDEX IF NOT EXISTS ix_reserva_usuario_funcion ON reserva_asiento (id_usuario, id_funcion) WHERE estado = 'BLOQUEADO';
-- fn_mapa_asientos y v_ocupacion_funcion: asientos vendidos de una funcion
CREATE INDEX IF NOT EXISTS ix_reserva_funcion_vendido ON reserva_asiento (id_funcion) WHERE estado = 'VENDIDO';
-- llaves foraneas compuestas hacia funcion y asiento
CREATE INDEX IF NOT EXISTS ix_reserva_asiento_sala ON reserva_asiento (id_asiento, id_sala);
CREATE INDEX IF NOT EXISTS ix_reserva_funcion_sala ON reserva_asiento (id_funcion, id_sala);

-- ---------- compra, boleto, pago ----------
CREATE INDEX IF NOT EXISTS ix_boleto_compra          ON boleto (id_compra);
CREATE INDEX IF NOT EXISTS ix_boleto_tipo_entrada    ON boleto (id_tipo_entrada);
CREATE INDEX IF NOT EXISTS ix_compra_usuario         ON compra (id_usuario, creada_en DESC);            -- "mis compras"
CREATE INDEX IF NOT EXISTS ix_compra_taquillero      ON compra (id_taquillero, creada_en DESC) WHERE id_taquillero IS NOT NULL;   -- corte de caja
CREATE INDEX IF NOT EXISTS ix_compra_pendientes      ON compra (expira_en) WHERE estado = 'PENDIENTE';   -- limpieza de compras vencidas
CREATE INDEX IF NOT EXISTS ix_compra_promocion       ON compra (id_promocion) WHERE id_promocion IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_pago_compra            ON pago (id_compra);
CREATE INDEX IF NOT EXISTS ix_pago_metodo            ON pago (id_metodo_pago);
CREATE INDEX IF NOT EXISTS ix_pago_creado            ON pago (creado_en);                              -- reportes financieros por dia
CREATE INDEX IF NOT EXISTS ix_reembolso_pago         ON reembolso (id_pago);
CREATE INDEX IF NOT EXISTS ix_reembolso_creado       ON reembolso (creado_en);
CREATE INDEX IF NOT EXISTS ix_reembolso_solicitante  ON reembolso (id_solicitante);

-- ---------- catalogo y cartelera ----------
-- v_cartelera / fn_buscar_funciones: funciones programadas por fecha
CREATE INDEX IF NOT EXISTS ix_funcion_inicio         ON funcion (inicio) WHERE estado = 'PROGRAMADA';
CREATE INDEX IF NOT EXISTS ix_funcion_pelicula       ON funcion (id_pelicula, inicio);
CREATE INDEX IF NOT EXISTS ix_pelicula_genero_genero ON pelicula_genero (id_genero);                   -- busqueda por genero
CREATE INDEX IF NOT EXISTS ix_pelicula_clasificacion ON pelicula (id_clasificacion);
CREATE INDEX IF NOT EXISTS ix_sala_formato           ON sala (id_formato);
CREATE INDEX IF NOT EXISTS ix_asiento_tipo           ON asiento (id_tipo_asiento);
CREATE INDEX IF NOT EXISTS ix_usuario_rol            ON usuario (id_rol);

-- ---------- bitacoras (se crean en la tabla padre y se replican en cada particion) ----------
CREATE INDEX IF NOT EXISTS ix_translog_compra    ON transaccion_log (id_compra, creado_en);
CREATE INDEX IF NOT EXISTS ix_translog_boleto    ON transaccion_log (id_boleto, creado_en) WHERE id_boleto IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_asientolog_funcion ON asiento_auditoria_log (id_funcion, id_asiento, creado_en);
CREATE INDEX IF NOT EXISTS ix_asientolog_usuario ON asiento_auditoria_log (id_usuario, creado_en);
CREATE INDEX IF NOT EXISTS ix_accesolog_boleto   ON acceso_puerta_log (id_boleto, creado_en) WHERE id_boleto IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_accesolog_puerta   ON acceso_puerta_log (id_puerta, creado_en);
CREATE INDEX IF NOT EXISTS ix_adminlog_admin     ON admin_operacion_audit (id_usuario_admin, creado_en);
CREATE INDEX IF NOT EXISTS ix_adminlog_entidad   ON admin_operacion_audit (entidad, id_entidad, creado_en);

ANALYZE;
