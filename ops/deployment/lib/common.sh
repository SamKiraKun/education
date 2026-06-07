#!/usr/bin/env bash
set -Eeuo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${DEPLOY_ROOT}/../.." && pwd)"
DEPLOY_ENV_DIR="${DEPLOY_ROOT}"
DEFAULT_ENV_FILE="${DEPLOY_ENV_DIR}/.env.production"
DEFAULT_ENV_FALLBACK="${DEPLOY_ENV_DIR}/.env"
DEPLOY_NGINX_TEMPLATE="${DEPLOY_ROOT}/nginx/education.conf.template"
BACKUP_SERVICE_TEMPLATE="${DEPLOY_ROOT}/systemd/education-backup.service.template"
BACKUP_TIMER_TEMPLATE="${DEPLOY_ROOT}/systemd/education-backup.timer.template"
COMPOSE_FILE="${DEPLOY_ROOT}/compose/compose.production.yaml"
CONTAINERFILE_PATH="${DEPLOY_ROOT}/docker/Containerfile"
export PROJECT_ROOT DEPLOY_ROOT COMPOSE_FILE

timestamp() {
	date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
	printf '[%s] %s\n' "$(timestamp)" "$*"
}

warn() {
	printf '[%s] WARNING: %s\n' "$(timestamp)" "$*" >&2
}

die() {
	printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2
	exit 1
}

ensure_safe_absolute_dir() {
	local dir_path="$1"
	[[ -n "${dir_path}" ]] || die "Directory path must not be empty."
	[[ "${dir_path}" == /* ]] || die "Directory path must be absolute: ${dir_path}"
	[[ "${dir_path}" != "/" ]] || die "Refusing to operate on the filesystem root."
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

require_cmd() {
	command_exists "$1" || die "Required command not found: $1"
}

bool_true() {
	case "${1,,}" in
	1|true|yes|on) return 0 ;;
	*) return 1 ;;
	esac
}

init_sudo() {
	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		SUDO=""
	elif command_exists sudo; then
		SUDO="sudo"
	else
		die "This command requires root or sudo access."
	fi
	export SUDO
}

resolve_env_file() {
	if [[ -n "${EDUCATION_ENV_FILE:-}" ]]; then
		printf '%s\n' "${EDUCATION_ENV_FILE}"
		return
	fi

	if [[ -f "${DEFAULT_ENV_FILE}" ]]; then
		printf '%s\n' "${DEFAULT_ENV_FILE}"
		return
	fi

	if [[ -f "${DEFAULT_ENV_FALLBACK}" ]]; then
		printf '%s\n' "${DEFAULT_ENV_FALLBACK}"
		return
	fi

	die "Missing deployment env file. Copy ops/deployment/env.production.example to ops/deployment/.env.production."
}

load_env_assignment_file() {
	local env_file="$1"
	local line key raw_value value

	while IFS= read -r line || [[ -n "${line}" ]]; do
		line="${line%$'\r'}"
		line="${line#"${line%%[![:space:]]*}"}"
		[[ -z "${line}" || "${line}" == \#* ]] && continue

		if [[ "${line}" == export\ * ]]; then
			line="${line#export }"
		fi

		[[ "${line}" == *"="* ]] || die "Invalid environment line in ${env_file}: ${line}"

		key="${line%%=*}"
		raw_value="${line#*=}"
		key="${key%"${key##*[![:space:]]}"}"
		key="${key#"${key%%[![:space:]]*}"}"
		[[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid environment variable name in ${env_file}: ${key}"

		value="${raw_value}"
		if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
			value="${value:1:-1}"
		elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
			value="${value:1:-1}"
		fi

		printf -v "${key}" '%s' "${value}"
		export "${key}"
	done < "${env_file}"
}

default_db_name() {
	local slug
	slug="${APP_NAME:-education}_prod"
	printf '%s\n' "${slug//-/_}"
}

load_deployment_env() {
	DEPLOY_ENV_FILE="$(resolve_env_file)"
	load_env_assignment_file "${DEPLOY_ENV_FILE}"

	export APP_NAME="${APP_NAME:-education}"
	export APP_BRANCH="${APP_BRANCH:-$(git -C "${PROJECT_ROOT}" branch --show-current 2>/dev/null || printf 'develop')}"
	export SITE_NAME="${SITE_NAME:-}"
	export DOMAIN="${DOMAIN:-${SITE_NAME}}"
	export FRAPPE_IMAGE="${FRAPPE_IMAGE:-frappe/erpnext}"
	export FRAPPE_IMAGE_TAG="${FRAPPE_IMAGE_TAG:-develop}"
	export CUSTOM_IMAGE="${CUSTOM_IMAGE:-education/custom}"
	export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-education}"
	export TARGET_PLATFORM="${TARGET_PLATFORM:-linux/amd64}"
	export FRAPPE_HTTP_PORT="${FRAPPE_HTTP_PORT:-8080}"
	export DB_HOST="${DB_HOST:-db}"
	export DB_PORT="${DB_PORT:-3306}"
	export DB_ROOT_USER="${DB_ROOT_USER:-root}"
	export DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
	export SITE_DB_NAME="${SITE_DB_NAME:-$(default_db_name)}"
	export SITE_DB_PASSWORD="${SITE_DB_PASSWORD:-}"
	export MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11.8}"
	export REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
	export REDIS_CACHE="${REDIS_CACHE:-redis-cache:6379}"
	export REDIS_QUEUE="${REDIS_QUEUE:-redis-queue:6379}"
	export SOCKETIO_PORT="${SOCKETIO_PORT:-9000}"
	export GUNICORN_THREADS="${GUNICORN_THREADS:-4}"
	export GUNICORN_WORKERS="${GUNICORN_WORKERS:-2}"
	export GUNICORN_TIMEOUT="${GUNICORN_TIMEOUT:-120}"
	export CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-50m}"
	export ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
	export ENABLE_LETSENCRYPT="${ENABLE_LETSENCRYPT:-false}"
	export LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
	export LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-false}"
	export UPSTREAM_REAL_IP_ADDRESS="${UPSTREAM_REAL_IP_ADDRESS:-127.0.0.1}"
	export UPSTREAM_REAL_IP_HEADER="${UPSTREAM_REAL_IP_HEADER:-X-Forwarded-For}"
	export UPSTREAM_REAL_IP_RECURSIVE="${UPSTREAM_REAL_IP_RECURSIVE:-off}"
	export MIN_FREE_DISK_GB="${MIN_FREE_DISK_GB:-20}"
	export MIN_MEMORY_GB="${MIN_MEMORY_GB:-4}"
	export DEPLOY_BASE_DIR="${DEPLOY_BASE_DIR:-/opt/education}"
	export SERVER_ENV_FILE="${SERVER_ENV_FILE:-/etc/education/education.env}"
	export BACKUP_ROOT="${BACKUP_ROOT:-${DEPLOY_BASE_DIR}/backups}"
	export BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
	export BACKUP_ON_CALENDAR="${BACKUP_ON_CALENDAR:-*-*-* 03:30:00}"
	export ENABLE_BACKUP_TIMER="${ENABLE_BACKUP_TIMER:-true}"
	export DOCKER_BUILD_NO_CACHE="${DOCKER_BUILD_NO_CACHE:-false}"

	export DEPLOY_STATE_DIR="${DEPLOY_BASE_DIR}/state"
	export DEPLOY_LOG_DIR="${DEPLOY_BASE_DIR}/logs"
	export RELEASE_ENV_FILE="${DEPLOY_STATE_DIR}/release.env"
	export PREVIOUS_RELEASE_ENV_FILE="${DEPLOY_STATE_DIR}/previous-release.env"
	export RELEASE_HISTORY_FILE="${DEPLOY_STATE_DIR}/release-history.tsv"
	export DEPLOY_HTTP_HEALTH_URL="http://127.0.0.1:${FRAPPE_HTTP_PORT}"
}

validate_domain_like() {
	local value="$1"
	[[ "${value}" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid domain or site name: ${value}"
}

validate_integer() {
	local name="$1"
	local value="$2"
	[[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be an integer. Current value: ${value}"
}

validate_password_strength() {
	local name="$1"
	local value="$2"
	[[ ${#value} -ge 14 ]] || die "${name} must be at least 14 characters."
	[[ "${value}" =~ [A-Z] ]] || die "${name} must include an uppercase letter."
	[[ "${value}" =~ [a-z] ]] || die "${name} must include a lowercase letter."
	[[ "${value}" =~ [0-9] ]] || die "${name} must include a number."
	[[ "${value}" =~ [^A-Za-z0-9] ]] || die "${name} must include a symbol."
}

validate_deployment_env() {
	local required_vars=(
		SITE_NAME
		DOMAIN
		FRAPPE_IMAGE
		FRAPPE_IMAGE_TAG
		CUSTOM_IMAGE
		DB_ROOT_PASSWORD
		SITE_DB_NAME
		SITE_DB_PASSWORD
		ADMIN_PASSWORD
	)

	for var_name in "${required_vars[@]}"; do
		[[ -n "${!var_name:-}" ]] || die "Missing required environment variable: ${var_name}"
	done

	validate_domain_like "${SITE_NAME}"
	validate_domain_like "${DOMAIN}"
	validate_integer "FRAPPE_HTTP_PORT" "${FRAPPE_HTTP_PORT}"
	validate_integer "DB_PORT" "${DB_PORT}"
	validate_integer "SOCKETIO_PORT" "${SOCKETIO_PORT}"
	validate_integer "GUNICORN_THREADS" "${GUNICORN_THREADS}"
	validate_integer "GUNICORN_WORKERS" "${GUNICORN_WORKERS}"
	validate_integer "GUNICORN_TIMEOUT" "${GUNICORN_TIMEOUT}"
	validate_integer "MIN_FREE_DISK_GB" "${MIN_FREE_DISK_GB}"
	validate_integer "MIN_MEMORY_GB" "${MIN_MEMORY_GB}"
	validate_integer "BACKUP_RETENTION_DAYS" "${BACKUP_RETENTION_DAYS}"

	validate_password_strength "DB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}"
	validate_password_strength "SITE_DB_PASSWORD" "${SITE_DB_PASSWORD}"
	validate_password_strength "ADMIN_PASSWORD" "${ADMIN_PASSWORD}"

	if bool_true "${ENABLE_LETSENCRYPT}"; then
		[[ -n "${LETSENCRYPT_EMAIL}" ]] || die "LETSENCRYPT_EMAIL is required when ENABLE_LETSENCRYPT=true"
		[[ "${LETSENCRYPT_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Invalid LETSENCRYPT_EMAIL value."
	fi
}

validate_host_requirements() {
	require_cmd awk
	require_cmd curl
	require_cmd df
	require_cmd free
	require_cmd git
	require_cmd grep
	require_cmd sed
	require_cmd tee

	if [[ ! -f /etc/os-release ]]; then
		die "This deploy workflow supports Ubuntu Linux only."
	fi

	# shellcheck disable=SC1091
	source /etc/os-release
	[[ "${ID}" == "ubuntu" ]] || die "Unsupported operating system: ${ID}. Expected Ubuntu."
	if [[ "${VERSION_ID}" != "24.04" ]]; then
		warn "Detected Ubuntu ${VERSION_ID}. This workflow is tuned for Ubuntu 24.04 LTS."
	fi

	local free_disk_gb
	free_disk_gb="$(df -Pk / | awk 'NR==2 { printf "%d", $4 / 1024 / 1024 }')"
	(( free_disk_gb >= MIN_FREE_DISK_GB )) || die "Insufficient disk space. Need ${MIN_FREE_DISK_GB} GB free on /, found ${free_disk_gb} GB."

	local memory_gb
	memory_gb="$(free -g | awk '/^Mem:/ { print $2 }')"
	(( memory_gb >= MIN_MEMORY_GB )) || die "Insufficient memory. Need ${MIN_MEMORY_GB} GB RAM, found ${memory_gb} GB."

	curl -fsSLI https://github.com >/dev/null || die "Network connectivity check to GitHub failed."
	curl -fsSLI https://download.docker.com >/dev/null || die "Network connectivity check to Docker failed."
}

install_host_dependencies() {
	init_sudo
	export DEBIAN_FRONTEND=noninteractive

	log "Installing required Ubuntu packages"
	${SUDO} apt-get update -y
	${SUDO} apt-get install -y ca-certificates curl git gnupg jq nginx certbot python3-certbot-nginx openssl

	if ! command_exists docker || ! docker compose version >/dev/null 2>&1; then
		log "Installing Docker Engine and Docker Compose plugin from the official Docker repository"
		${SUDO} install -m 0755 -d /etc/apt/keyrings
		if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
			curl -fsSL https://download.docker.com/linux/ubuntu/gpg | ${SUDO} tee /etc/apt/keyrings/docker.asc >/dev/null
			${SUDO} chmod a+r /etc/apt/keyrings/docker.asc
		fi
		local arch codename
		arch="$(dpkg --print-architecture)"
		# shellcheck disable=SC1091
		source /etc/os-release
		codename="${VERSION_CODENAME}"
		printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' "${arch}" "${codename}" | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null
		${SUDO} apt-get update -y
		${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
		${SUDO} systemctl enable --now docker
	fi

	${SUDO} systemctl enable --now nginx
}

prepare_runtime_directories() {
	init_sudo
	ensure_safe_absolute_dir "${DEPLOY_BASE_DIR}"
	ensure_safe_absolute_dir "${DEPLOY_STATE_DIR}"
	ensure_safe_absolute_dir "${DEPLOY_LOG_DIR}"
	ensure_safe_absolute_dir "${BACKUP_ROOT}"
	${SUDO} install -d -m 0755 "${DEPLOY_BASE_DIR}" "${DEPLOY_STATE_DIR}" "${DEPLOY_LOG_DIR}" "${BACKUP_ROOT}"
	${SUDO} install -d -m 0750 "$(dirname "${SERVER_ENV_FILE}")"
}

render_env_value() {
	local value="$1"

	if [[ "${value}" =~ [[:space:]#\"\'\\] ]]; then
		value="${value//\\/\\\\}"
		value="${value//\"/\\\"}"
		printf '"%s"' "${value}"
	else
		printf '%s' "${value}"
	fi
}

install_server_env_file() {
	init_sudo
	local tmp_file
	local var_name
	local runtime_vars=(
		APP_NAME
		APP_BRANCH
		SITE_NAME
		DOMAIN
		FRAPPE_IMAGE
		FRAPPE_IMAGE_TAG
		CUSTOM_IMAGE
		COMPOSE_PROJECT_NAME
		FRAPPE_HTTP_PORT
		TARGET_PLATFORM
		DB_HOST
		DB_PORT
		DB_ROOT_USER
		DB_ROOT_PASSWORD
		SITE_DB_NAME
		SITE_DB_PASSWORD
		MARIADB_IMAGE
		REDIS_IMAGE
		REDIS_CACHE
		REDIS_QUEUE
		SOCKETIO_PORT
		GUNICORN_THREADS
		GUNICORN_WORKERS
		GUNICORN_TIMEOUT
		CLIENT_MAX_BODY_SIZE
		ADMIN_PASSWORD
		ENABLE_LETSENCRYPT
		LETSENCRYPT_EMAIL
		LETSENCRYPT_STAGING
		UPSTREAM_REAL_IP_ADDRESS
		UPSTREAM_REAL_IP_HEADER
		UPSTREAM_REAL_IP_RECURSIVE
		MIN_FREE_DISK_GB
		MIN_MEMORY_GB
		DEPLOY_BASE_DIR
		SERVER_ENV_FILE
		BACKUP_ROOT
		BACKUP_RETENTION_DAYS
		BACKUP_ON_CALENDAR
		ENABLE_BACKUP_TIMER
		DOCKER_BUILD_NO_CACHE
	)

	tmp_file="$(mktemp)"
	{
		printf '# Generated by ops/deployment/bin/deploy.sh on %s\n' "$(timestamp)"
		for var_name in "${runtime_vars[@]}"; do
			printf '%s=' "${var_name}"
			render_env_value "${!var_name}"
			printf '\n'
		done
	} > "${tmp_file}"

	${SUDO} install -m 0600 "${tmp_file}" "${SERVER_ENV_FILE}"
	rm -f "${tmp_file}"
}

current_git_sha() {
	git -C "${PROJECT_ROOT}" rev-parse --short=12 HEAD
}

ensure_clean_git_tree() {
	git -C "${PROJECT_ROOT}" diff --quiet || die "Working tree has unstaged changes. Commit or stash them before running update."
	git -C "${PROJECT_ROOT}" diff --cached --quiet || die "Working tree has staged but uncommitted changes. Commit them before running update."
}

build_release_image() {
	local tag="$1"
	local build_args=(
		--build-arg "BASE_IMAGE=${FRAPPE_IMAGE}"
		--build-arg "BASE_TAG=${FRAPPE_IMAGE_TAG}"
		--tag "${CUSTOM_IMAGE}:${tag}"
		--file "${CONTAINERFILE_PATH}"
	)
	if bool_true "${DOCKER_BUILD_NO_CACHE}"; then
		build_args+=(--no-cache)
	fi

	log "Building release image ${CUSTOM_IMAGE}:${tag}"
	${SUDO} docker build "${build_args[@]}" "${PROJECT_ROOT}"
}

write_release_env() {
	local path="$1"
	local tag="$2"
	local sha="$3"
	local branch="$4"
	${SUDO} tee "${path}" >/dev/null <<EOF
CUSTOM_TAG=${tag}
DEPLOYED_GIT_SHA=${sha}
DEPLOYED_GIT_BRANCH=${branch}
DEPLOYED_AT=$(timestamp)
EOF
	${SUDO} chmod 0640 "${path}"
}

snapshot_current_release() {
	if [[ -f "${RELEASE_ENV_FILE}" ]]; then
		${SUDO} cp "${RELEASE_ENV_FILE}" "${PREVIOUS_RELEASE_ENV_FILE}"
		${SUDO} chmod 0640 "${PREVIOUS_RELEASE_ENV_FILE}"
	fi
}

release_value() {
	local file="$1"
	local key="$2"
	[[ -f "${file}" ]] || return 1
	grep -E "^${key}=" "${file}" | tail -n 1 | cut -d= -f2-
}

current_release_tag() {
	release_value "${RELEASE_ENV_FILE}" "CUSTOM_TAG"
}

current_release_sha() {
	release_value "${RELEASE_ENV_FILE}" "DEPLOYED_GIT_SHA"
}

previous_release_tag() {
	release_value "${PREVIOUS_RELEASE_ENV_FILE}" "CUSTOM_TAG"
}

record_release_history() {
	local action="$1"
	local tag="$2"
	local sha="$3"
	local backup_ref="$4"
	if [[ ! -f "${RELEASE_HISTORY_FILE}" ]]; then
		${SUDO} tee "${RELEASE_HISTORY_FILE}" >/dev/null <<'EOF'
timestamp	action	image_tag	git_sha	branch	backup_ref
EOF
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(timestamp)" "${action}" "${tag}" "${sha}" "${APP_BRANCH}" "${backup_ref}" | ${SUDO} tee -a "${RELEASE_HISTORY_FILE}" >/dev/null
}

docker_compose() {
	${SUDO} docker compose \
		--project-name "${COMPOSE_PROJECT_NAME}" \
		--env-file "${SERVER_ENV_FILE}" \
		--env-file "${RELEASE_ENV_FILE}" \
		-f "${COMPOSE_FILE}" \
		"$@"
}

compose_up_core() {
	docker_compose up -d db redis-cache redis-queue configurator
}

compose_up_application() {
	docker_compose up -d backend websocket queue-short queue-long scheduler frontend
}

site_exists() {
	docker_compose run --rm backend bash -lc "bench list-sites | grep -Fxq '${SITE_NAME}'"
}

run_site_creation() {
	log "Creating site ${SITE_NAME}"
	docker_compose run --rm create-site
}

run_site_migration() {
	log "Running site migrations"
	docker_compose run --rm migrate
}

render_nginx_config() {
	local tmp_file
	tmp_file="$(mktemp)"
	sed \
		-e "s/__DOMAIN__/${DOMAIN}/g" \
		-e "s/__FRAPPE_HTTP_PORT__/${FRAPPE_HTTP_PORT}/g" \
		-e "s/__CLIENT_MAX_BODY_SIZE__/${CLIENT_MAX_BODY_SIZE}/g" \
		"${DEPLOY_NGINX_TEMPLATE}" > "${tmp_file}"
	printf '%s\n' "${tmp_file}"
}

install_nginx_config() {
	init_sudo
	local tmp_file
	tmp_file="$(render_nginx_config)"
	${SUDO} install -m 0644 "${tmp_file}" /etc/nginx/sites-available/education.conf
	rm -f "${tmp_file}"
	if [[ ! -L /etc/nginx/sites-enabled/education.conf ]]; then
		${SUDO} ln -s /etc/nginx/sites-available/education.conf /etc/nginx/sites-enabled/education.conf
	fi
	if [[ -L /etc/nginx/sites-enabled/default ]]; then
		${SUDO} rm -f /etc/nginx/sites-enabled/default
	fi
	${SUDO} nginx -t
	${SUDO} systemctl reload nginx
}

configure_ssl_if_enabled() {
	if ! bool_true "${ENABLE_LETSENCRYPT}"; then
		return 0
	fi

	local certbot_args=(
		--nginx
		--non-interactive
		--agree-tos
		--redirect
		--email "${LETSENCRYPT_EMAIL}"
		-d "${DOMAIN}"
	)
	if bool_true "${LETSENCRYPT_STAGING}"; then
		certbot_args+=(--staging)
	fi

	log "Requesting or renewing Let's Encrypt certificate for ${DOMAIN}"
	${SUDO} certbot "${certbot_args[@]}"
}

render_systemd_template() {
	local template_path="$1"
	local output_path="$2"
	local tmp_file
	tmp_file="$(mktemp)"
	sed \
		-e "s#__PROJECT_ROOT__#${PROJECT_ROOT}#g" \
		-e "s#__SERVER_ENV_FILE__#${SERVER_ENV_FILE}#g" \
		-e "s#__BACKUP_ON_CALENDAR__#${BACKUP_ON_CALENDAR}#g" \
		"${template_path}" > "${tmp_file}"
	${SUDO} install -m 0644 "${tmp_file}" "${output_path}"
	rm -f "${tmp_file}"
}

install_backup_timer_if_enabled() {
	if ! bool_true "${ENABLE_BACKUP_TIMER}"; then
		return 0
	fi

	init_sudo
	render_systemd_template "${BACKUP_SERVICE_TEMPLATE}" /etc/systemd/system/education-backup.service
	render_systemd_template "${BACKUP_TIMER_TEMPLATE}" /etc/systemd/system/education-backup.timer
	${SUDO} systemctl daemon-reload
	${SUDO} systemctl enable --now education-backup.timer
}

backend_container_id() {
	docker_compose ps -q backend
}

copy_from_backend() {
	local source_path="$1"
	local destination_path="$2"
	local container_id
	container_id="$(backend_container_id)"
	[[ -n "${container_id}" ]] || die "Backend container is not available."
	${SUDO} docker cp "${container_id}:${source_path}" "${destination_path}"
}

git_pull_latest() {
	log "Pulling latest code from origin/${APP_BRANCH}"
	git -C "${PROJECT_ROOT}" fetch origin "${APP_BRANCH}"
	git -C "${PROJECT_ROOT}" checkout "${APP_BRANCH}"
	git -C "${PROJECT_ROOT}" pull --ff-only origin "${APP_BRANCH}"
}
