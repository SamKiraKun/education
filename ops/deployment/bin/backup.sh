#!/usr/bin/env bash
set -Eeuo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${BIN_DIR}/../lib/common.sh"

label=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--env-file)
		[[ $# -ge 2 ]] || die "--env-file requires a value"
		export EDUCATION_ENV_FILE="$2"
		shift 2
		;;
	--label)
		[[ $# -ge 2 ]] || die "--label requires a value"
		label="$2"
		shift 2
		;;
	--scheduled)
		shift
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

load_deployment_env
validate_deployment_env
prepare_runtime_directories

backup_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="${BACKUP_ROOT}/${backup_stamp}"
if [[ -n "${label}" ]]; then
	backup_dir="${backup_dir}-${label}"
fi

${SUDO} install -d -m 0750 "${backup_dir}"

log "Creating Frappe backup for ${SITE_NAME}"
docker_compose exec -T backend bash -lc "bench --site '${SITE_NAME}' backup --with-files"

mapfile -t backup_files < <(docker_compose exec -T backend bash -lc "cd 'sites/${SITE_NAME}/private/backups' && ls -1t | head -n 8")
for backup_file in "${backup_files[@]}"; do
	[[ -n "${backup_file}" ]] || continue
	copy_from_backend "/home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups/${backup_file}" "${backup_dir}/"
done

copy_from_backend "/home/frappe/frappe-bench/sites/${SITE_NAME}/site_config.json" "${backup_dir}/site_config.json"

if [[ -f "${SERVER_ENV_FILE}" ]]; then
	${SUDO} cp "${SERVER_ENV_FILE}" "${backup_dir}/education.env"
fi
if [[ -f /etc/nginx/sites-available/education.conf ]]; then
	${SUDO} cp /etc/nginx/sites-available/education.conf "${backup_dir}/education.nginx.conf"
fi
if [[ -f /etc/education/mariadb-cloud-replication.env ]]; then
	${SUDO} cp /etc/education/mariadb-cloud-replication.env "${backup_dir}/mariadb-cloud-replication.env"
fi
if [[ -f "${RELEASE_ENV_FILE}" ]]; then
	${SUDO} cp "${RELEASE_ENV_FILE}" "${backup_dir}/release.env"
fi

printf 'site=%s\ncreated_at=%s\nrelease_tag=%s\ngit_sha=%s\n' \
	"${SITE_NAME}" "$(timestamp)" "$(current_release_tag || true)" "$(current_release_sha || true)" | ${SUDO} tee "${backup_dir}/manifest.txt" >/dev/null

ensure_safe_absolute_dir "${BACKUP_ROOT}"
find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime +"${BACKUP_RETENTION_DAYS}" -exec ${SUDO} rm -rf {} +
log "Backup complete at ${backup_dir}"
printf '%s\n' "${backup_dir}"
