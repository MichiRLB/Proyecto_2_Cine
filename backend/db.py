import os
from contextlib import contextmanager
from dotenv import load_dotenv
import psycopg
from psycopg.rows import dict_row

load_dotenv()

@contextmanager
def conexion():
	config = {
		"host": "localhost",
		"port": "5432",
		"dbname": "imax_proyecto",
		"user": "postgres",
		"password": "postgres",
		"row_factory": dict_row,
		"options": "-c search_path=imax,public",
		"connect_timeout": 5,
	}
	with psycopg.connect(**config) as conn:
		yield conn


def consultar(sql, parametros=()):
	with conexion() as conn:
		return conn.execute(sql, parametros).fetchall()


def consultar_uno(sql, parametros=()):
	with conexion() as conn:
		return conn.execute(sql, parametros).fetchone()
