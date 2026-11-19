# shellcheck shell=bash
# Variables set here are used by the commands that source this file.
# shellcheck disable=SC2034
#ddev-generated
# Shared by the drupal-remote host commands; settings come from
# .ddev/.env.drupal-remote (see the add-on's README). Kept bash 3.2-compatible
# for macOS.

LOCAL_BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
COMMANDS_DIR="${LOCAL_BASE}/.ddev/commands/host"
CONFIG_FILE="${LOCAL_BASE}/.ddev/.env.drupal-remote"
WEB_ENV_FILE="${LOCAL_BASE}/.ddev/.env.web"

die() {
  echo "$*" >&2
  exit 1
}

# Prints the calling command's "## Usage:" line and exits.
usage() {
  sed -n 's/^## Usage: /Usage: ddev /p' "$0" >&2
  exit 1
}

upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# setting <KEY> [default]: the value of REMOTE_<KEY>, or the default.
setting() {
  local name="REMOTE_$1"
  printf '%s' "${!name:-${2:-}}"
}

load_config() {
  [ -f "${CONFIG_FILE}" ] || die "Missing ${CONFIG_FILE}; see the drupal-remote README."
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  ENVIRONMENTS="$(setting ENVIRONMENTS live)"
  FIRST_ENV="${ENVIRONMENTS%% *}"
  ENV_VAR="$(setting ENV_VAR SITE_ENV)"
}

# The local environment picked with `ddev env`, the first one by default.
current_env() {
  local env
  env="$(sed -n "s/^${ENV_VAR}=//p" "${WEB_ENV_FILE}" 2>/dev/null | tail -n1 | tr -d "\"'")"
  echo "${env:-${FIRST_ENV}}"
}

# env_setting <env> <KEY> [default]: REMOTE_<ENV>_<KEY>, or the default.
env_setting() {
  setting "$(upper "$1")_$2" "${3:-}"
}

# Settings file with the env's database credentials, relative to LOCAL_BASE.
env_settings_file() {
  env_setting "$1" SETTINGS web/sites/default/settings.remote.php
}

# use_env [env]: sets SITE_ENV (given or current) and its REMOTE (user@host),
# SSH_PORT, REMOTE_PATH, URI, SETTINGS, CONFIG_DIR and LOCAL_DB.
use_env() {
  SITE_ENV="${1:-$(current_env)}"
  case "${SITE_ENV}" in
    '' | *[!a-z0-9_]*) die "Invalid environment '${SITE_ENV}', use one of: ${ENVIRONMENTS}" ;;
  esac
  case " ${ENVIRONMENTS} " in
    *" ${SITE_ENV} "*) ;;
    *) die "Unknown environment '${SITE_ENV}', use one of: ${ENVIRONMENTS}" ;;
  esac

  local host user
  host="$(env_setting "${SITE_ENV}" SSH_HOST "$(setting SSH_HOST)")"
  user="$(env_setting "${SITE_ENV}" SSH_USER "$(setting SSH_USER)")"
  SSH_PORT="$(env_setting "${SITE_ENV}" SSH_PORT "$(setting SSH_PORT 22)")"
  REMOTE_PATH="$(env_setting "${SITE_ENV}" PATH)"
  [ -n "${host}" ] && [ -n "${user}" ] || die "Set REMOTE_SSH_HOST and REMOTE_SSH_USER in ${CONFIG_FILE}."
  [ -n "${REMOTE_PATH}" ] || die "Set REMOTE_$(upper "${SITE_ENV}")_PATH in ${CONFIG_FILE}."
  REMOTE="${user}@${host}"
  URI="$(env_setting "${SITE_ENV}" URI)"
  SETTINGS="$(env_settings_file "${SITE_ENV}")"

  local config_dir=config/sync local_db=db
  if [ "${SITE_ENV}" != "${FIRST_ENV}" ]; then
    config_dir="config/${SITE_ENV}"
    local_db="${SITE_ENV}"
  fi
  CONFIG_DIR="$(env_setting "${SITE_ENV}" CONFIG_DIR "${config_dir}")"
  LOCAL_DB="$(env_setting "${SITE_ENV}" LOCAL_DB "${local_db}")"
}

remote_ssh() {
  ssh -p "${SSH_PORT}" "${REMOTE}" "$@"
}

# Runs the env's own drush on the server. A TTY is requested when there is
# one, so Ctrl-C reaches the remote process.
remote_drush() {
  local tty=() uri=""
  if [ -t 0 ] && [ -t 1 ]; then
    tty=(-t)
  fi
  if [ -n "${URI}" ]; then
    uri=" --uri=$(printf '%q' "${URI}")"
  fi
  ssh ${tty[@]+"${tty[@]}"} -p "${SSH_PORT}" "${REMOTE}" \
    "cd ${REMOTE_PATH} && vendor/drush/drush/drush${uri}$(printf ' %q' "$@")"
}

# parse_setting <file> <key>: a value from a settings file. Handles both the
# assignment style ($databases[...]['database'] = "foo";) and the array-arrow
# style ('database' => 'foo',), with single- or double-quoted values.
parse_setting() {
  sed -n "s/.*'$2'\]\{0,1\}[[:space:]]*=>\{0,1\}[[:space:]]*[\"']\([^\"']*\)[\"'].*/\1/p" "$1" | head -n1
}

# Sets DB_NAME, DB_USER, DB_PASS, DB_HOST and DB_PORT from the env's settings.
load_db_settings() {
  local file="${LOCAL_BASE}/${SETTINGS}"
  [ -f "${file}" ] || die "Remote DB settings not found: ${file}"
  DB_NAME="$(parse_setting "${file}" database)"
  DB_USER="$(parse_setting "${file}" username)"
  DB_PASS="$(parse_setting "${file}" password)"
  DB_HOST="$(parse_setting "${file}" host)"
  DB_PORT="$(parse_setting "${file}" port)"
  DB_PORT="${DB_PORT:-3306}"
  [ -n "${DB_NAME}" ] && [ -n "${DB_USER}" ] && [ -n "${DB_HOST}" ] ||
    die "Could not parse database credentials from ${file}"
}

# remote_mysql_cmd <client> [args]: the remote command line for a MySQL
# client. It reads the password from the first line of stdin, so it never
# shows up in the remote process list.
remote_mysql_cmd() {
  echo "IFS= read -r MYSQL_PWD; export MYSQL_PWD; $1 --default-character-set=utf8mb4 -h '${DB_HOST}' -P '${DB_PORT}' -u '${DB_USER}' ${2:-} '${DB_NAME}'"
}

# remote_mysql [args]: mysql on the server; stdin is the password line, then SQL.
remote_mysql() {
  ssh -C -p "${SSH_PORT}" "${REMOTE}" "$(remote_mysql_cmd mysql "${1:-}")"
}

remote_table_count() {
  printf '%s\nSELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE();\n' "${DB_PASS}" |
    remote_mysql -N
}
