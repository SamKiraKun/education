#!/usr/bin/env python3
"""Guarded restore helper for MariaDB Cloud secondary data.

Default behavior is report-only. Any write to the EC2 primary requires --apply
and an exact confirmation token. Credentials are read from environment variables.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9_ $-]+$")
TIMEOUT_SECONDS = 3600


class RestoreError(RuntimeError):
	pass


def env(name: str, default: str | None = None, required: bool = False) -> str:
	value = os.environ.get(name, default)
	if required and not value:
		raise RestoreError(f"Missing required environment variable: {name}")
	return value or ""


def validate_identifier(value: str, label: str) -> str:
	if not IDENTIFIER_PATTERN.fullmatch(value):
		raise RestoreError(f"Unsafe {label}: {value!r}")
	return value


def quote_identifier(value: str) -> str:
	validate_identifier(value, "identifier")
	return f"`{value}`"


def sql_literal(value: str) -> str:
	return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def write_defaults_file(prefix: str) -> Path:
	host = env(f"{prefix}_HOST", required=True)
	port = env(f"{prefix}_PORT", "3306")
	user = env(f"{prefix}_USER", required=True)
	password = env(f"{prefix}_PASSWORD", required=True)
	ssl_ca = env("MARIADB_SSL_CA")
	use_ssl = env(f"{prefix}_SSL", "true" if prefix == "MARIADB_CLOUD" else "false").lower() in {
		"1",
		"true",
		"yes",
		"on",
	}

	lines = [
		"[client]",
		f"host={host}",
		f"port={port}",
		f"user={user}",
		f"password={password}",
	]
	if use_ssl:
		lines.append("ssl=1")
	if use_ssl and ssl_ca:
		lines.append(f"ssl-ca={ssl_ca}")
		lines.append("ssl-verify-server-cert=1")

	handle = tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8")
	try:
		handle.write("\n".join(lines))
		handle.write("\n")
		return Path(handle.name)
	finally:
		handle.close()
		os.chmod(handle.name, 0o600)


def run(args: list[str], timeout: int = TIMEOUT_SECONDS) -> subprocess.CompletedProcess[str]:
	return subprocess.run(args, check=False, capture_output=True, text=True, timeout=timeout)


def run_query(prefix: str, sql: str, database: str) -> str:
	defaults_file = write_defaults_file(prefix)
	try:
		result = run(
			[
				"mariadb",
				f"--defaults-extra-file={defaults_file}",
				"--batch",
				"--raw",
				"--skip-column-names",
				database,
				"-e",
				sql,
			]
		)
	finally:
		defaults_file.unlink(missing_ok=True)

	if result.returncode != 0:
		raise RestoreError(result.stderr.strip())
	return result.stdout.strip()


def dump_from_cloud(args: argparse.Namespace, where: str | None, output_file: Path) -> None:
	defaults_file = write_defaults_file("MARIADB_CLOUD")
	database = env("MARIADB_CLOUD_NAME", required=True)
	if args.mode == "full":
		command = [
			"mariadb-dump",
			f"--defaults-extra-file={defaults_file}",
			"--single-transaction",
			"--routines",
			"--events",
			"--triggers",
			"--replace",
			database,
		]
	else:
		command = [
			"mariadb-dump",
			f"--defaults-extra-file={defaults_file}",
			"--single-transaction",
			"--replace",
			"--no-create-info",
		]
		if where:
			command.append(f"--where={where}")
		command.extend([database, validate_identifier(args.table, "table")])

	try:
		result = run(command)
		if result.returncode != 0:
			raise RestoreError(result.stderr.strip())
		output_file.write_text(result.stdout, encoding="utf-8")
	finally:
		defaults_file.unlink(missing_ok=True)


def apply_to_primary(dump_file: Path, database: str | None) -> None:
	defaults_file = write_defaults_file("PRIMARY_DB")
	command = ["mariadb", f"--defaults-extra-file={defaults_file}"]
	if database:
		command.append(database)
	try:
		with dump_file.open("r", encoding="utf-8") as stdin:
			result = subprocess.run(
				command,
				check=False,
				stdin=stdin,
				capture_output=True,
				text=True,
				timeout=TIMEOUT_SECONDS,
			)
		if result.returncode != 0:
			raise RestoreError(result.stderr.strip())
	finally:
		defaults_file.unlink(missing_ok=True)


def build_report(args: argparse.Namespace, dump_file: Path, conflict_count: int | None) -> dict[str, Any]:
	return {
		"timestamp": datetime.now(timezone.utc).isoformat(),
		"mode": args.mode,
		"table": args.table,
		"key_column": args.key_column,
		"key_value": args.key_value,
		"dump_file": str(dump_file),
		"applied": bool(args.apply),
		"conflict_count_on_primary": conflict_count,
		"overwrite_allowed": bool(args.allow_overwrite),
	}


def main() -> int:
	parser = argparse.ArgumentParser(description="Restore selected data from MariaDB Cloud to the EC2 primary.")
	parser.add_argument("--mode", choices=["record", "table", "full"], required=True)
	parser.add_argument("--table", help="MariaDB table name, for example tabStudent")
	parser.add_argument("--key-column", default="name")
	parser.add_argument("--key-value")
	parser.add_argument("--output-dir", default="restore-reports")
	parser.add_argument("--apply", action="store_true")
	parser.add_argument("--allow-overwrite", action="store_true")
	parser.add_argument("--confirm", default="")
	args = parser.parse_args()

	if args.mode in {"record", "table"} and not args.table:
		raise RestoreError("--table is required for record and table restore")
	if args.mode == "record" and not args.key_value:
		raise RestoreError("--key-value is required for record restore")

	output_dir = Path(args.output_dir)
	output_dir.mkdir(parents=True, exist_ok=True)
	stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
	dump_file = output_dir / f"{stamp}-{args.mode}.sql"
	report_file = output_dir / f"{stamp}-{args.mode}-report.json"

	where = None
	conflict_count: int | None = None
	primary_db = env("PRIMARY_DB_NAME", required=True)

	if args.mode == "record":
		table = quote_identifier(args.table)
		key_column = quote_identifier(args.key_column)
		where = f"{key_column} = {sql_literal(args.key_value)}"
		count_sql = f"SELECT COUNT(*) FROM {table} WHERE {where}"
		conflict_count = int(run_query("PRIMARY_DB", count_sql, primary_db) or "0")
	elif args.mode == "table":
		table = quote_identifier(args.table)
		count_sql = f"SELECT COUNT(*) FROM {table}"
		conflict_count = int(run_query("PRIMARY_DB", count_sql, primary_db) or "0")

	if conflict_count and not args.allow_overwrite:
		raise RestoreError(
			"Primary already contains matching data. Re-run with --allow-overwrite "
			"after reviewing the report and confirming the conflict is expected."
		)

	dump_from_cloud(args, where, dump_file)

	if args.apply:
		expected = {
			"record": "RESTORE_RECORD_TO_PRIMARY",
			"table": "RESTORE_TABLE_TO_PRIMARY",
			"full": "RESTORE_FULL_DATABASE_TO_PRIMARY",
		}[args.mode]
		if args.confirm != expected:
			raise RestoreError(f"--confirm must be exactly {expected!r}")
		apply_to_primary(dump_file, primary_db)

	report = build_report(args, dump_file, conflict_count)
	report_file.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
	print(json.dumps(report, indent=2, sort_keys=True))
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
