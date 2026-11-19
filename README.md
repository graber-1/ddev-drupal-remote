# ddev-drupal-remote

DDEV host commands for Drupal sites hosted on plain SSH servers (shared hosting without CI). They pull config, the database and files from a remote environment, push code and databases to it, and bulk-update every such project in a folder. Each project keeps its settings in `.ddev/.env.drupal-remote`, so the add-on itself holds no hosts, paths or credentials.

## Installation

```
ddev add-on get graber-1/ddev-drupal-remote
```

The first install creates `.ddev/.env.drupal-remote` from the example. Fill it in and commit it, for example with:

```
ddev dotenv set .ddev/.env.drupal-remote --remote-ssh-host=ssh.example.com --remote-ssh-user=deploy \
  --remote-live-path='~/public_html/example.com' --remote-live-uri=https://example.com
```

Requirements:

- SSH key access to the server, plus `rsync`, `mysql`, `mysqldump` and `gzip` there.
- Drupal with drush in `vendor/` in the remote project root, and the remote config sync folder at the same relative path as the local one (`config/sync` by default).
- Each environment's database credentials in a local settings file (`web/sites/default/settings.remote.php` by default). `deploy` uploads it, and the other commands read the database credentials from it. Keep it out of git.

## Commands

All commands take an optional environment name; without it they use the current one (see [Multiple environments](#multiple-environments)).

| Command | What it does |
|---|---|
| `ddev sync-from-remote [env] [--database\|--files]` | Runs `drush config:export` on the remote and rsyncs its config folder into the local one. Refuses to run if the local config folder has uncommitted changes. `--database` also imports the remote database, and `--files` also pulls files. |
| `ddev deploy [env] [--dry-run]` | Rsyncs the code with `--delete`, then runs `drush deploy` there. Public files are left alone except `files/.htaccess`. If the remote database is empty, it skips `drush deploy` and points to `push-db`. `--dry-run` only shows what rsync would change. |
| `ddev get-files [env]` | Pulls `REMOTE_FILES_PATHS` from the remote. |
| `ddev push-db [env] [--force] [--files]` | Replaces the remote database with the local one. Cache, session and log tables go as structure only. A remote database that already has tables needs `--force` and a typed confirmation. `--files` also uploads public files. |
| `ddev env [env]` | Shows or switches the local environment. |
| `ddev bulk-update` | See [Bulk update](#bulk-update). |

Database passwords go to the remote over stdin, never on a command line. Remote drush runs over SSH (`cd <path> && vendor/drush/drush/drush`); no drush alias is needed.

## Configuration

`.ddev/.env.drupal-remote`, where `<ENV>` is an environment name in upper case (`REMOTE_LIVE_PATH`):

| Key | Default | Meaning |
|---|---|---|
| `REMOTE_SSH_HOST`, `REMOTE_SSH_USER` | required | SSH login for all environments |
| `REMOTE_SSH_PORT` | `22` | SSH port |
| `REMOTE_ENVIRONMENTS` | `live` | Space-separated environment names; the first is the default |
| `REMOTE_<ENV>_PATH` | required | Project root on the server, e.g. `~/public_html/example.com` (no spaces) |
| `REMOTE_<ENV>_URI` | – | Passed to remote drush as `--uri` |
| `REMOTE_<ENV>_SETTINGS` | `web/sites/default/settings.remote.php` | Local settings file with that environment's database credentials |
| `REMOTE_<ENV>_CONFIG_DIR` | `config/sync` for the first environment, `config/<env>` for others | Config sync folder, the same locally and remotely |
| `REMOTE_<ENV>_LOCAL_DB` | `db` for the first environment, `<env>` for others | DDEV database the environment is imported into |
| `REMOTE_<ENV>_SSH_HOST`, `_SSH_USER`, `_SSH_PORT` | the global values | Per-environment SSH login |
| `REMOTE_SETTINGS_TARGET` | – | If set, `deploy` keeps every environment's settings file out of the main rsync and uploads the deployed environment's file to this path |
| `REMOTE_ENV_VAR` | `SITE_ENV` | Variable `ddev env` sets in `.ddev/.env.web` |
| `REMOTE_DEPLOY_EXCLUDES` | – | Extra space-separated rsync excludes for `deploy` |
| `REMOTE_DEPLOY_DRUSH` | `true` | `false` makes `deploy` rsync only |
| `REMOTE_FILES_PATHS` | `web/sites/default/files` | Space-separated folders `get-files` pulls |
| `REMOTE_BULK_UPDATE` | `true` | `false` leaves the project out of `bulk-update` |

`deploy` always excludes `.git/`, `.github/`, `.ddev/`, `.claude/`, `.clinerules`, `.DS_Store`, `*.gz`, `web/sites/default/files/*` (except `.htaccess`), `web/sites/simpletest/`, `/private_files/` and `web/.htpasswd`. Excluded paths are also protected from `--delete` on the remote.

## Multiple environments

One local checkout can work against several remote environments (live, dev, …), each with its own config folder and DDEV database:

```
REMOTE_ENVIRONMENTS="live dev"
REMOTE_ENV_VAR="SITE_ENV"
REMOTE_SETTINGS_TARGET="web/sites/default/settings.remote.php"
REMOTE_LIVE_PATH="~/public_html/example.com"
REMOTE_LIVE_SETTINGS="web/sites/default/settings.remote.live.php"
REMOTE_DEV_PATH="~/public_html/dev.example.com"
REMOTE_DEV_SETTINGS="web/sites/default/settings.remote.dev.php"
```

`ddev env dev` writes `SITE_ENV=dev` to `.ddev/.env.web`, restarts DDEV and creates the `dev` database. Drupal has to follow the same variable, both locally and on the server: put this at the end of `settings.php`, and `putenv('SITE_ENV=dev');` in the dev settings file.

```php
$site_env = getenv('SITE_ENV') ?: 'live';
if ($site_env !== 'live') {
  $settings['config_sync_directory'] = '../config/' . $site_env;
  if (getenv('IS_DDEV_PROJECT') === 'true') {
    $databases['default']['default']['database'] = $site_env;
  }
}
```

## Bulk update

`ddev bulk-update` collects the DDEV projects that have this add-on installed, looking in the parent folder of the project it is run from and in its subfolders. It goes up to 3 levels deep and doesn't descend into projects, hidden folders, `vendor` or `node_modules`. Run from `~/sites/a`, it covers everything under `~/sites`. Run from `~/sites/group/b`, it covers only `~/sites/group`. It lists the projects, asks for confirmation, then for each one:

1. `ddev start` if the project was stopped
2. `ddev sync-from-remote --database`
3. `ddev composer update`
4. `ddev drush updb -y`
5. `ddev drush cex -y`
6. `ddev deploy`
7. `ddev stop` if the project was stopped before

A failing step aborts that project and moves on to the next. Ctrl-C stops the current project and skips the rest. The summary and log are written to `bulk-update.log` in the scanned folder. Because `sync-from-remote` refuses uncommitted config, commit each project's exported config after a run.

## Updating

Release a new version, then run `ddev add-on get graber-1/ddev-drupal-remote` in each project and commit the result.

## Development

`tests/run.sh` tests the commands against stubbed `ssh`, `rsync`, `git` and `ddev`; it needs neither DDEV nor a server. CI also runs `shellcheck`. The scripts stay compatible with macOS's bash 3.2.
