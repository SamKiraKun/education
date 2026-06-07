#!/usr/bin/env bash
set -Eeuo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${BIN_DIR}/../lib/common.sh"
init_sudo

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

load_deployment_env
validate_deployment_env
validate_host_requirements
install_host_dependencies
prepare_runtime_directories
install_server_env_file

release_sha="$(current_git_sha)"
release_tag="${release_sha}"
snapshot_current_release
build_release_image "${release_tag}"
write_release_env "${RELEASE_ENV_FILE}" "${release_tag}" "${release_sha}" "${APP_BRANCH}"

compose_up_core
run_site_creation
compose_up_application
run_site_migration

install_nginx_config
configure_ssl_if_enabled
install_backup_timer_if_enabled

EDUCATION_ENV_FILE="${SERVER_ENV_FILE}" "${PROJECT_ROOT}/healthcheck.sh"
record_release_history "deploy" "${release_tag}" "${release_sha}" "-"

log "Deployment complete for ${SITE_NAME} using image ${CUSTOM_IMAGE}:${release_tag}"
