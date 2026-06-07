#!/usr/bin/env bash
set -Eeuo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${BIN_DIR}/../lib/common.sh"

host_checks=false

while [[ $# -gt 0 ]]; do
	case "$1" in
	--env-file)
		[[ $# -ge 2 ]] || die "--env-file requires a value"
		export EDUCATION_ENV_FILE="$2"
		shift 2
		;;
	--host-checks)
		host_checks=true
		shift
		;;
	*)
		die "Unknown argument: $1"
		;;
	esac
done

load_deployment_env
validate_deployment_env

if bool_true "${host_checks}"; then
	validate_host_requirements
fi

log "Environment validation passed for ${SITE_NAME}"
