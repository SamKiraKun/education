from __future__ import annotations

import argparse
import os
import re
import sys

import MySQLdb


IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9_]+$")
INITIALIZED_EXIT_CODE = 0
UNINITIALIZED_EXIT_CODE = 10


def _required_env(name: str) -> str:
	value = os.environ.get(name, "").strip()
	if not value:
		raise ValueError(f"Missing required environment variable: {name}")
	return value


def _validated_identifier(name: str) -> str:
	if not IDENTIFIER_PATTERN.fullmatch(name):
		raise ValueError(f"Invalid database identifier: {name}")
	return name


def _database_settings() -> tuple[str, int, str, str, str, str]:
	db_host = _required_env("DB_HOST")
	db_port = int(_required_env("DB_PORT"))
	root_user = _required_env("DB_ROOT_USER")
	root_password = _required_env("DB_ROOT_PASSWORD")
	site_db_name = _validated_identifier(_required_env("SITE_DB_NAME"))
	site_db_password = _required_env("SITE_DB_PASSWORD")
	return db_host, db_port, root_user, root_password, site_db_name, site_db_password


def ensure_site_database_principal() -> None:
	db_host, db_port, root_user, root_password, site_db_name, site_db_password = _database_settings()

	connection = MySQLdb.connect(
		host=db_host,
		port=db_port,
		user=root_user,
		password=root_password,
		database="mysql",
		charset="utf8mb4",
	)
	try:
		connection.autocommit(True)
		cursor = connection.cursor()
		try:
			cursor.execute(
				f"CREATE DATABASE IF NOT EXISTS `{site_db_name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
			)
			cursor.execute("CREATE USER IF NOT EXISTS %s@'%%' IDENTIFIED BY %s", (site_db_name, site_db_password))
			cursor.execute("ALTER USER %s@'%%' IDENTIFIED BY %s", (site_db_name, site_db_password))
			cursor.execute(f"GRANT ALL PRIVILEGES ON `{site_db_name}`.* TO %s@'%%'", (site_db_name,))
			cursor.execute("FLUSH PRIVILEGES")
		finally:
			cursor.close()
	finally:
		connection.close()


def site_database_is_initialized() -> bool:
	db_host, db_port, root_user, root_password, site_db_name, _ = _database_settings()
	connection = MySQLdb.connect(
		host=db_host,
		port=db_port,
		user=root_user,
		password=root_password,
		database="information_schema",
		charset="utf8mb4",
	)
	try:
		cursor = connection.cursor()
		try:
			cursor.execute(
				"""
				SELECT 1
				FROM tables
				WHERE table_schema = %s AND table_name = 'tabDefaultValue'
				LIMIT 1
				""",
				(site_db_name,),
			)
			return cursor.fetchone() is not None
		finally:
			cursor.close()
	finally:
		connection.close()


if __name__ == "__main__":
	parser = argparse.ArgumentParser()
	parser.add_argument("--check-initialized", action="store_true")
	args = parser.parse_args()

	ensure_site_database_principal()

	if args.check_initialized:
		sys.exit(INITIALIZED_EXIT_CODE if site_database_is_initialized() else UNINITIALIZED_EXIT_CODE)
