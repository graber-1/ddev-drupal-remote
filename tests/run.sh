#!/usr/bin/env bash
# Tests for the drupal-remote commands, runnable without DDEV or a server:
# ssh, rsync, git and ddev are stubs that log their arguments.
# Usage: tests/run.sh
# Assertions are single-quoted strings, evaluated later.
# shellcheck disable=SC2016,SC2034

set -uo pipefail

ADDON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${ADDON}/tests/fixtures"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
CALLS="${T}/calls.log"
FAILED=0
PASSED=0

export CALLS
mkdir -p "${T}/bin"
cat > "${T}/bin/stub" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
echo "${name} $*" >> "${CALLS}"
case "${name}:$*" in
  ssh:*"; mysql "*)
    case "$(cat)" in *"SELECT COUNT"*) echo "${FAKE_TABLES:-5}" ;; esac ;;
  ssh:*mysqldump*) cat > /dev/null; echo dump ;;
  git:*status*) printf '%s' "${FAKE_GIT_STATUS:-}" ;;
  git:"rev-list --count HEAD..@{upstream}") echo "${FAKE_GIT_BEHIND:-0}" ;;
  git:"rev-parse --abbrev-ref @{upstream}") echo origin/main ;;
  git:"diff --cached --quiet") exit "${FAKE_GIT_DIFF:-0}" ;;
esac
EOF
chmod +x "${T}/bin/stub"
for name in ssh rsync ddev git sleep; do
  ln -s stub "${T}/bin/${name}"
done
export PATH="${T}/bin:${PATH}"

# project <dir> <fixture config or ""> [manifest]: a fake DDEV project with
# the add-on's commands.
project() {
  mkdir -p "$1/.ddev/commands/host" "$1/config/sync" "$1/web/sites/default"
  touch "$1/.ddev/config.yaml" "$1/config/sync/core.extension.yml"
  cp "${ADDON}/commands/host/"* "${ADDON}/commands/host/.drupal-remote.sh" "$1/.ddev/commands/host/"
  cp "${FIXTURES}/settings.assignment.php" "$1/web/sites/default/settings.remote.php"
  if [ -n "$2" ]; then
    cp "${FIXTURES}/$2" "$1/.ddev/.env.drupal-remote"
  fi
  if [ -n "${3:-}" ]; then
    mkdir -p "$1/.ddev/addon-metadata/drupal-remote"
    touch "$1/.ddev/addon-metadata/drupal-remote/manifest.yaml"
  fi
}

# run <command...>: sets OUT (stdout+stderr) and STATUS, clears the call log.
run() {
  : > "${CALLS}"
  OUT="$("$@" 2>&1)"
  STATUS=$?
}

check() {
  local name="$1"
  shift
  if "$@"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "FAIL: ${name}"
    echo "  output: ${OUT:-}" | head -20
    echo "  calls: $(cat "${CALLS}" 2>/dev/null)" | head -20
  fi
}

has() { [[ "$1" == *"$2"* ]]; }
called() { grep -qF -- "$1" "${CALLS}"; }
not_called() { ! grep -qF -- "$1" "${CALLS}"; }
ssh_called() { grep -q '^ssh ' "${CALLS}"; }

# lib_eval <project> <code>: runs code with the library loaded.
lib_eval() {
  bash -c "set -euo pipefail; source '$1/.ddev/commands/host/.drupal-remote.sh'; load_config; $2"
}

# --- Library -----------------------------------------------------------------

project "${T}/single" single.env
run lib_eval "${T}/single" 'use_env; echo "$SITE_ENV|$REMOTE|$SSH_PORT|$REMOTE_PATH|$URI|$SETTINGS|$CONFIG_DIR|$LOCAL_DB"'
check "single env defaults" [ "${OUT}" = "live|deploy@203.0.113.10|222|~/public_html/example.com|https://example.com|web/sites/default/settings.remote.php|config/sync|db" ]

project "${T}/multi" multi.env
mkdir -p "${T}/multi/config/dev"
touch "${T}/multi/config/dev/core.extension.yml"
for env in live dev; do
  cp "${FIXTURES}/settings.assignment.php" "${T}/multi/web/sites/default/settings.remote.${env}.php"
done
run lib_eval "${T}/multi" 'use_env; echo "$SITE_ENV|$CONFIG_DIR|$LOCAL_DB"'
check "multi env: first one is current without .env.web" [ "${OUT}" = "live|config/sync|db" ]
echo "SITE_STAGE=dev" > "${T}/multi/.ddev/.env.web"
run lib_eval "${T}/multi" 'use_env; echo "$SITE_ENV|$REMOTE|$SSH_PORT|$REMOTE_PATH|$SETTINGS|$CONFIG_DIR|$LOCAL_DB"'
check "multi env: current one from .env.web, per-env overrides" [ "${OUT}" = "dev|deploy@198.51.100.7|2222|~/public_html/dev.example.com|web/sites/default/settings.remote.dev.php|config/dev|dev" ]
run lib_eval "${T}/multi" 'use_env staging'
check "unknown env is rejected" eval '[ "${STATUS}" = 1 ] && has "${OUT}" "Unknown environment" && has "${OUT}" "use one of: live dev"'
run lib_eval "${T}/multi" 'use_env "live dev"'
check "env with a space is rejected" eval '[ "${STATUS}" = 1 ] && has "${OUT}" "Invalid environment"'
run lib_eval "${T}/multi" 'SETTINGS=web/sites/default/settings.remote.php; load_db_settings; echo "$DB_NAME|$DB_USER|$DB_PASS|$DB_HOST|$DB_PORT"'
check "settings parser: assignment style" [ "${OUT}" = "example_db|example_user|s3cret|db.example.com|3306" ]
cp "${FIXTURES}/settings.array.php" "${T}/multi/web/sites/default/settings.array.php"
run lib_eval "${T}/multi" 'SETTINGS=web/sites/default/settings.array.php; load_db_settings; echo "$DB_NAME|$DB_USER|$DB_PASS|$DB_HOST|$DB_PORT"'
check "settings parser: array style" [ "${OUT}" = "array_db|array_user|pa55|db.example.org|3307" ]

project "${T}/unconfigured" ""
run lib_eval "${T}/unconfigured" 'true'
check "missing config is reported" eval '[ "${STATUS}" = 1 ] && has "${OUT}" "Missing ${T}/unconfigured/.ddev/.env.drupal-remote"'

# --- Argument parsing ----------------------------------------------------------

for cmd in sync-from-remote deploy get-files push-db env bulk-update; do
  run "${T}/unconfigured/.ddev/commands/host/${cmd}" --bogus
  check "${cmd} --bogus prints usage" eval '[ "${STATUS}" = 1 ] && has "${OUT}" "Usage: ddev ${cmd}"'
done
run "${T}/single/.ddev/commands/host/deploy" live dev
check "two environments are a usage error" eval '[ "${STATUS}" = 1 ] && has "${OUT}" "Usage: ddev deploy"'

# --- sync-from-remote --------------------------------------------------------

run "${T}/single/.ddev/commands/host/sync-from-remote"
check "sync: config only" eval '[ "${STATUS}" = 0 ] &&
  called "ssh -p 222 deploy@203.0.113.10 cd ~/public_html/example.com && vendor/drush/drush/drush --uri=https://example.com config:export -y" &&
  called "rsync -av --checksum --delete -e ssh -p 222 deploy@203.0.113.10:~/public_html/example.com/config/sync/ ${T}/single/config/sync/" &&
  not_called "mysqldump" && not_called "ddev"'
FAKE_GIT_STATUS=" M config/sync/system.site.yml" run "${T}/single/.ddev/commands/host/sync-from-remote"
check "sync: refuses uncommitted config" eval '[ "${STATUS}" = 1 ] && has "${OUT}" "config/sync/ has uncommitted changes" && ! ssh_called'
run "${T}/single/.ddev/commands/host/sync-from-remote" --database
check "sync --database: dump and import" eval '[ "${STATUS}" = 0 ] && called "mysqldump" &&
  called "ddev import-db --database=db" && called "ddev drush cache:rebuild" && not_called "files/"'
run "${T}/multi/.ddev/commands/host/sync-from-remote" live --files
check "sync another env --files: its DB and files, no cache rebuild" eval '[ "${STATUS}" = 0 ] &&
  called "ddev import-db --database=db" && called "web/sites/default/files/" && not_called "cache:rebuild"'

# --- deploy --------------------------------------------------------------------

run "${T}/single/.ddev/commands/host/deploy" --dry-run
check "deploy --dry-run: rsync only" eval '[ "${STATUS}" = 0 ] && called "rsync -av --delete --dry-run -e ssh -p 222" &&
  called "--filter=P web/sites/default/files/.htaccess --include web/sites/default/files/ --include web/sites/default/files/.htaccess --exclude web/sites/default/files/*" &&
  called "--exclude /legacy_site/ --exclude /*.log ${T}/single/ deploy@203.0.113.10:~/public_html/example.com/" && ! ssh_called'
run "${T}/single/.ddev/commands/host/deploy"
check "deploy: drush deploy when the remote DB has tables" eval '[ "${STATUS}" = 0 ] &&
  called "drush --uri=https://example.com deploy -y"'
FAKE_TABLES=0 run "${T}/single/.ddev/commands/host/deploy"
check "deploy: no drush deploy on an empty remote DB" eval '[ "${STATUS}" = 0 ] && has "${OUT}" "ddev push-db" && not_called "deploy -y"'
run "${T}/multi/.ddev/commands/host/deploy" --dry-run
check "deploy with SETTINGS_TARGET: env settings uploaded separately" eval '[ "${STATUS}" = 0 ] &&
  called "--exclude /web/sites/default/settings.remote.php --exclude /web/sites/default/settings.remote.live.php --exclude /web/sites/default/settings.remote.dev.php" &&
  called "rsync -av --dry-run -e ssh -p 2222 ${T}/multi/web/sites/default/settings.remote.dev.php deploy@198.51.100.7:~/public_html/dev.example.com/web/sites/default/settings.remote.php"'
echo 'REMOTE_DEPLOY_DRUSH=false' >> "${T}/single/.ddev/.env.drupal-remote"
run "${T}/single/.ddev/commands/host/deploy"
check "deploy with REMOTE_DEPLOY_DRUSH=false: rsync only" eval '[ "${STATUS}" = 0 ] && called "rsync" && ! ssh_called'

# --- get-files, env --------------------------------------------------------------

run "${T}/multi/.ddev/commands/host/get-files"
check "get-files: every REMOTE_FILES_PATHS entry" eval '[ "${STATUS}" = 0 ] &&
  called "deploy@198.51.100.7:~/public_html/dev.example.com/web/sites/default/files/ ${T}/multi/web/sites/default/files/" &&
  called "deploy@198.51.100.7:~/public_html/dev.example.com/private_files/ ${T}/multi/private_files/"'
run "${T}/multi/.ddev/commands/host/env"
check "env shows the current one" eval '[ "${STATUS}" = 0 ] && has "${OUT}" "Current environment: dev (config: config/dev, database: dev)"'
run "${T}/multi/.ddev/commands/host/env" live
check "env switches via .env.web" eval '[ "${STATUS}" = 0 ] && grep -qx "SITE_STAGE=live" "${T}/multi/.ddev/.env.web" && called "ddev restart"'

# --- bulk-update discovery -------------------------------------------------------

R="${T}/root"
project "${R}/alpha" single.env manifest
project "${R}/plain" ""
project "${R}/opted-out" single.env manifest
echo 'REMOTE_BULK_UPDATE="false"' >> "${R}/opted-out/.ddev/.env.drupal-remote"
project "${R}/group/beta" single.env manifest
project "${R}/group/beta/web/modules/nested" single.env manifest
project "${R}/group/vendor/gamma" single.env manifest
project "${R}/.hidden/delta" single.env manifest
project "${R}/a/b/c/too-deep" single.env manifest

run bash -c "echo n | '${R}/alpha/.ddev/commands/host/bulk-update'"
check "bulk-update from the top lists projects recursively" eval '[ "${STATUS}" = 0 ] && has "${OUT}" "Projects under ${R}:
  1. alpha
  2. group/beta
  -  opted-out (skipped: REMOTE_BULK_UPDATE=false)
Nothing done." && not_called "ddev"'
run bash -c "echo n | '${R}/group/beta/.ddev/commands/host/bulk-update'"
check "bulk-update from a subfolder lists only its siblings" eval '[ "${STATUS}" = 0 ] && has "${OUT}" "Projects under ${R}/group:
  1. beta
Nothing done."'

run bash -c "echo y | '${R}/alpha/.ddev/commands/host/bulk-update'"
check "bulk-update pauses before every ddev start but the run's first" eval '[ "${STATUS}" = 0 ] &&
  [ "$(grep -B1 "^ddev start$" "${CALLS}")" = "git rev-list --count HEAD..@{upstream}
ddev start
--
sleep 5
ddev start" ] && [ "$(grep -c "^ddev deploy$" "${CALLS}")" = 2 ]'
check "bulk-update with nothing changed pushes without committing" eval '
  has "${OUT}" "Nothing to commit." && not_called "git commit" && [ "$(grep -c "^git push$" "${CALLS}")" = 2 ]'

FAKE_GIT_DIFF=1 run bash -c "echo y | '${R}/alpha/.ddev/commands/host/bulk-update'"
check "bulk-update commits the run's changes after deploy, then pushes" eval '[ "${STATUS}" = 0 ] &&
  [ "$(grep -A4 "^ddev deploy$" "${CALLS}" | head -5)" = "ddev deploy
git add -A
git diff --cached --quiet
git commit -q -m Bulk automatic updates applied
git --no-pager show --stat --format=%h %s HEAD" ] && [ "$(grep -c "^git push$" "${CALLS}")" = 2 ]'

FAKE_GIT_STATUS="?? notes.txt" run bash -c "echo y | '${R}/alpha/.ddev/commands/host/bulk-update'"
check "bulk-update leaves projects with uncommitted changes untouched" eval '[ "${STATUS}" = 1 ] &&
  has "${OUT}" "Uncommitted changes, commit or stash them first:
?? notes.txt" && has "${OUT}" "FAILED       alpha at '"'"'check_git'"'"' (exit 1)" &&
  not_called "git fetch" && not_called "ddev start" && not_called "ddev stop" && not_called "ddev sync-from-remote"'

FAKE_GIT_BEHIND=2 run bash -c "echo y | '${R}/alpha/.ddev/commands/host/bulk-update'"
check "bulk-update leaves projects behind their upstream untouched" eval '[ "${STATUS}" = 1 ] &&
  has "${OUT}" "2 commit(s) behind origin/main, pull first." && has "${OUT}" "FAILED       alpha at '"'"'check_git'"'"' (exit 1)" &&
  called "git fetch -q" && not_called "ddev start" && not_called "ddev sync-from-remote"'

echo "${PASSED} passed, ${FAILED} failed"
(( FAILED == 0 ))
