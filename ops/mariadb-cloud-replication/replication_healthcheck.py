#!/usr/bin/env python3
"""Sanitized MariaDB Cloud replication healthcheck.

The script uses the mariadb CLI so it does not require Python database
dependencies inside the Frappe app environment. Credentials are read only from
environment variables and are passed through a temporary defaults file.
"""

from __future__ import annotations

import csv
import json
import os
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TIMEOUT_SECONDS = 20


class ConfigError(RuntimeError):
	pass


def env(name: str, default: str | None = None, required: bool = False) -> str:
	value = os.environ.get(name, default)
	if required and not value:
		raise ConfigError(f"Missing required environment variable: {name}")
	return value or ""


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


def run_mariadb(prefix: str, sql: str, database: str | None = None) -> subprocess.CompletedProcess[str]:
	defaults_file = write_defaults_file(prefix)
	args = [
		"mariadb",
		f"--defaults-extra-file={defaults_file}",
		"--batch",
		"--raw",
	]
	if database:
		args.append(database)
	args.extend(["-e", sql])

	try:
		return subprocess.run(
			args,
			check=False,
			capture_output=True,
			text=True,
			timeout=TIMEOUT_SECONDS,
		)
	finally:
		defaults_file.unlink(missing_ok=True)


def parse_tsv(stdout: str) -> list[dict[str, str]]:
	lines = [line for line in stdout.splitlines() if line.strip()]
	if len(lines) < 2:
		return []
	return list(csv.DictReader(lines, delimiter="\t"))


def check_primary() -> dict[str, Any]:
	status: dict[str, Any] = {"ok": False}

	vars_result = run_mariadb(
		"PRIMARY_DB",
		"SHOW GLOBAL VARIABLES WHERE Variable_name IN "
		"('server_id', 'log_bin', 'binlog_format', 'binlog_row_image', 'gtid_strict_mode')",
	)
	if vars_result.returncode != 0:
		status["error"] = vars_result.stderr.strip()
		return status

	vars_rows = parse_tsv(vars_result.stdout)
	status["variables"] = {row["Variable_name"]: row["Value"] for row in vars_rows}

	gtid_result = run_mariadb("PRIMARY_DB", "SELECT @@GLOBAL.gtid_binlog_pos AS gtid_binlog_pos")
	if gtid_result.returncode == 0:
		rows = parse_tsv(gtid_result.stdout)
		status["gtid_binlog_pos"] = rows[0].get("gtid_binlog_pos") if rows else ""
	else:
		status["gtid_error"] = gtid_result.stderr.strip()

	required = status["variables"]
	status["ok"] = (
		required.get("log_bin", "").upper() == "ON"
		and required.get("binlog_format", "").upper() == "ROW"
		and required.get("gtid_strict_mode", "").upper() in {"ON", "1"}
	)
	return status


def check_cloud() -> dict[str, Any]:
	status: dict[str, Any] = {"ok": False}
	result = run_mariadb("MARIADB_CLOUD", "CALL sky.replication_status()")
	if result.returncode != 0:
		status["error"] = result.stderr.strip()
		return status

	rows = parse_tsv(result.stdout)
	replication = rows[0] if rows else {}
	status["replication"] = replication
	status["ok"] = (
		replication.get("Slave_IO_Running") == "Yes"
		and replication.get("Slave_SQL_Running") == "Yes"
		and not replication.get("Last_IO_Error")
		and not replication.get("Last_SQL_Error")
	)
	return status


def send_alert(payload: dict[str, Any]) -> None:
	webhook = env("SYNC_ALERT_WEBHOOK_URL")
	if not webhook:
		return

	body = json.dumps(payload).encode("utf-8")
	request = urllib.request.Request(
		webhook,
		data=body,
		headers={"Content-Type": "application/json"},
		method="POST",
	)
	urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS).close()


def main() -> int:
	try:
		payload = {
			"timestamp": datetime.now(timezone.utc).isoformat(),
			"primary": check_primary(),
			"cloud": check_cloud(),
		}
		payload["healthy"] = bool(payload["primary"]["ok"] and payload["cloud"]["ok"])
		if not payload["healthy"]:
			send_alert(payload)
			print(json.dumps(payload, indent=2, sort_keys=True))
			return 2

		print(json.dumps(payload, indent=2, sort_keys=True))
		return 0
	except ConfigError as exc:
		print(json.dumps({"healthy": False, "error": str(exc)}, indent=2), file=sys.stderr)
		return 64
	except subprocess.TimeoutExpired:
		print(json.dumps({"healthy": False, "error": "MariaDB healthcheck timed out"}, indent=2), file=sys.stderr)
		return 124


if __name__ == "__main__":
	raise SystemExit(main())
