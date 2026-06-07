#!/usr/bin/env bash
set -Eeuo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${BIN_DIR}/../lib/common.sh"

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

required_services=(
	db
	redis-cache
	redis-queue
	backend
	websocket
	queue-short
	queue-long
	scheduler
	frontend
)

running_services="$(docker_compose ps --services --status running)"
for service_name in "${required_services[@]}"; do
	printf '%s\n' "${running_services}" | grep -Fxq "${service_name}" || die "Required service is not running: ${service_name}"
done

curl -fsS -H "Host: ${DOMAIN}" "${DEPLOY_HTTP_HEALTH_URL}/api/method/ping" >/dev/null || die "API health check failed."
curl -fsS -H "Host: ${DOMAIN}" "${DEPLOY_HTTP_HEALTH_URL}/student-portal" >/dev/null || die "Frontend health check failed."
docker_compose exec -T backend bash -lc "bench --site '${SITE_NAME}' list-apps | grep -Fxq 'education'" >/dev/null || die "Education app is not installed on ${SITE_NAME}."

log "Health checks passed for ${SITE_NAME}"
