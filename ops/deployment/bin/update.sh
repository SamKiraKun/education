#!/usr/bin/env bash
set -Eeuo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${BIN_DIR}/../lib/common.sh"
init_sudo

rollback_on_error() {
	local previous_tag
	previous_tag="$(previous_release_tag || true)"
	if [[ -n "${previous_tag}" && -f "${PREVIOUS_RELEASE_ENV_FILE}" ]]; then
		warn "Update failed. Reverting containers to image tag ${previous_tag}"
		${SUDO} cp "${PREVIOUS_RELEASE_ENV_FILE}" "${RELEASE_ENV_FILE}"
		compose_up_core
		compose_up_application
	fi
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--env-file)
		[[ $# -ge 2 ]] || die "--env-file requires a value"
		export EDUCATION_ENV_FILE="$2"
		shift 2
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

trap rollback_on_error ERR

load_deployment_env
validate_deployment_env
ensure_clean_git_tree
validate_host_requirements
install_host_dependencies
prepare_runtime_directories
install_server_env_file
EDUCATION_ENV_FILE="${SERVER_ENV_FILE}" "${PROJECT_ROOT}/backup.sh" --scheduled >/dev/null

snapshot_current_release
git_pull_latest

release_sha="$(current_git_sha)"
release_tag="${release_sha}"
build_release_image "${release_tag}"
write_release_env "${RELEASE_ENV_FILE}" "${release_tag}" "${release_sha}" "${APP_BRANCH}"

compose_up_core
compose_up_application
run_site_migration

install_nginx_config
configure_ssl_if_enabled
install_backup_timer_if_enabled

EDUCATION_ENV_FILE="${SERVER_ENV_FILE}" "${PROJECT_ROOT}/healthcheck.sh"
record_release_history "update" "${release_tag}" "${release_sha}" "-"

trap - ERR
log "Update complete. Active release is ${release_tag}"
