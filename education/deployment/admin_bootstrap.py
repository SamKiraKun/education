from __future__ import annotations

import json
import os
import re
from typing import Any

import frappe


EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _value(name: str, fallback: str | None = None) -> str:
	value = os.environ.get(name, fallback or "")
	return value.strip()


def _validate_email(email: str) -> str:
	if not EMAIL_PATTERN.fullmatch(email):
		raise frappe.ValidationError(f"Invalid admin email address: {email}")
	return email


def _validate_password(password: str) -> str:
	if len(password) < 14:
		raise frappe.ValidationError("Admin password must be at least 14 characters long.")
	if not re.search(r"[A-Z]", password):
		raise frappe.ValidationError("Admin password must include an uppercase letter.")
	if not re.search(r"[a-z]", password):
		raise frappe.ValidationError("Admin password must include a lowercase letter.")
	if not re.search(r"[0-9]", password):
		raise frappe.ValidationError("Admin password must include a number.")
	if not re.search(r"[^A-Za-z0-9]", password):
		raise frappe.ValidationError("Admin password must include a symbol.")
	return password


def _split_name(full_name: str) -> tuple[str, str]:
	parts = [part for part in full_name.strip().split() if part]
	if not parts:
		raise frappe.ValidationError("Full name is required.")
	if len(parts) == 1:
		return parts[0], ""
	return parts[0], " ".join(parts[1:])


def create_first_admin(email: str | None = None, password: str | None = None, full_name: str | None = None) -> dict[str, Any]:
	email = _validate_email(email or _value("BOOTSTRAP_ADMIN_EMAIL"))
	password = _validate_password(password or _value("BOOTSTRAP_ADMIN_PASSWORD"))
	full_name = full_name or _value("BOOTSTRAP_ADMIN_FULL_NAME")
	first_name, last_name = _split_name(full_name)

	if frappe.db.exists("User", email):
		raise frappe.ValidationError(f"User already exists: {email}")

	user = frappe.get_doc(
		{
			"doctype": "User",
			"email": email,
			"enabled": 1,
			"first_name": first_name,
			"last_name": last_name,
			"full_name": full_name,
			"new_password": password,
			"send_welcome_email": 0,
			"user_type": "System User",
			"roles": [{"role": "System Manager"}],
		}
	)
	user.insert(ignore_permissions=True)
	frappe.db.commit()

	frappe.logger("education.deployment").info(
		json.dumps(
			{
				"event": "bootstrap_admin_created",
				"user": email,
				"roles": ["System Manager"],
			},
			sort_keys=True,
		)
	)

	return {
		"email": email,
		"full_name": full_name,
		"roles": ["System Manager"],
		"status": "created",
	}
