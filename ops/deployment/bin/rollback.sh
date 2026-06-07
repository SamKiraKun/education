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
prepare_runtime_directories

[[ -f "${PREVIOUS_RELEASE_ENV_FILE}" ]] || die "No previous release recorded. Rollback is not available yet."

current_tag="$(current_release_tag || true)"
current_sha="$(current_release_sha || true)"
target_tag="$(previous_release_tag)"
target_sha="$(release_value "${PREVIOUS_RELEASE_ENV_FILE}" "DEPLOYED_GIT_SHA")"
tmp_current="$(mktemp)"

if [[ -f "${RELEASE_ENV_FILE}" ]]; then
	cp "${RELEASE_ENV_FILE}" "${tmp_current}"
fi

${SUDO} cp "${PREVIOUS_RELEASE_ENV_FILE}" "${RELEASE_ENV_FILE}"
compose_up_core
compose_up_application

EDUCATION_ENV_FILE="${SERVER_ENV_FILE}" "${PROJECT_ROOT}/healthcheck.sh"

if [[ -s "${tmp_current}" ]]; then
	${SUDO} cp "${tmp_current}" "${PREVIOUS_RELEASE_ENV_FILE}"
fi
rm -f "${tmp_current}"

record_release_history "rollback" "${target_tag}" "${target_sha}" "-"
log "Rollback complete. Active release is ${target_tag}. Previous release was ${current_tag:-none} (${current_sha:-unknown})."
