#!/usr/bin/env bash
set -Eeuo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${BIN_DIR}/../lib/common.sh"
init_sudo

admin_email="${BOOTSTRAP_ADMIN_EMAIL:-}"
admin_full_name="${BOOTSTRAP_ADMIN_FULL_NAME:-}"
admin_password="${BOOTSTRAP_ADMIN_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--env-file)
		[[ $# -ge 2 ]] || die "--env-file requires a value"
		export EDUCATION_ENV_FILE="$2"
		shift 2
		;;
	--email)
		[[ $# -ge 2 ]] || die "--email requires a value"
		admin_email="$2"
		shift 2
		;;
	--full-name)
		[[ $# -ge 2 ]] || die "--full-name requires a value"
		admin_full_name="$2"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

load_deployment_env
validate_deployment_env

if [[ -z "${admin_email}" ]]; then
	read -r -p "Admin email: " admin_email
fi

if [[ -z "${admin_full_name}" ]]; then
	read -r -p "Admin full name: " admin_full_name
fi

if [[ -z "${admin_password}" ]]; then
	read -r -s -p "Admin password: " admin_password
	printf '\n'
	read -r -s -p "Confirm admin password: " admin_password_confirm
	printf '\n'
	[[ "${admin_password}" == "${admin_password_confirm}" ]] || die "Passwords do not match."
fi

validate_password_strength "BOOTSTRAP_ADMIN_PASSWORD" "${admin_password}"

export BOOTSTRAP_ADMIN_EMAIL="${admin_email}"
export BOOTSTRAP_ADMIN_FULL_NAME="${admin_full_name}"
export BOOTSTRAP_ADMIN_PASSWORD="${admin_password}"

docker_compose exec -T \
	-e "BOOTSTRAP_ADMIN_EMAIL=${BOOTSTRAP_ADMIN_EMAIL}" \
	-e "BOOTSTRAP_ADMIN_FULL_NAME=${BOOTSTRAP_ADMIN_FULL_NAME}" \
	-e "BOOTSTRAP_ADMIN_PASSWORD=${BOOTSTRAP_ADMIN_PASSWORD}" \
	backend \
	bench --site "${SITE_NAME}" execute education.deployment.admin_bootstrap.create_first_admin

log "Admin user bootstrap completed for ${admin_email}"
