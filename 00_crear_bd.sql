-- 00_crear_bd.sql
-- Proyecto 2 - Cine IMAX (TI-3600 Bases de Datos)
--
-- Este script se corre UNA sola vez, conectado a la bd "postgres"
-- (no a imax, porque todavia no existe).
-- Despues de correrlo, se conecta a la bd imax y se corren los demas en orden:
--   01_ddl.sql -> 02_triggers.sql -> 03_procedimientos.sql -> 04_rbac.sql -> 05_datos_base.sql
--
-- Nota: en DBeaver hay que ejecutarlo con "Ejecutar script" (Alt+X) y con
-- el auto-commit activado, porque CREATE DATABASE no puede ir dentro de una transaccion.

CREATE DATABASE imax;
