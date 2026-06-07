# Production Deployment Guide

This repository is a Frappe app, not a full bench checkout. The deployment
workflow in this directory wraps the app in a production container stack with:

- Docker Engine + Docker Compose on Ubuntu 24.04
- MariaDB primary database
- Redis cache and queue services
- Frappe web, websocket, scheduler, and worker containers
- Host Nginx reverse proxy with Let's Encrypt support
- Image-based release updates and rollback support
- Manual and scheduled backups

## Entrypoints

From a fresh clone on the Ubuntu EC2 server:

```bash
git clone https://github.com/SamKiraKun/education.git
cd education
cp ops/deployment/env.production.example ops/deployment/.env.production
nano ops/deployment/.env.production
./validate-env.sh --host-checks
./deploy.sh
```

After the first deploy:

```bash
./create-admin.sh
./backup.sh
./update.sh
./rollback.sh
./healthcheck.sh
```

## Environment Workflow

Create the deployment env file:

```bash
cp ops/deployment/env.production.example ops/deployment/.env.production
```

Edit it:

```bash
nano ops/deployment/.env.production
```

Validate it before startup:

```bash
./validate-env.sh
./validate-env.sh --host-checks
```

`./deploy.sh` copies the validated file to `/etc/education/education.env` with
restricted permissions and all runtime commands reuse that server-side file.
The loader accepts standard `KEY=VALUE` lines and also supports quoted values
when a setting contains spaces.

## Database Variables

The deployment env file defines the primary MariaDB settings used by the stack:

| Variable | Purpose | Notes |
| --- | --- | --- |
| `DB_HOST` | MariaDB hostname used by Frappe containers | Defaults to `db` inside Compose |
| `DB_PORT` | MariaDB port used by Frappe containers | Defaults to `3306` |
| `SITE_DB_NAME` | Database schema name created for the Frappe site | Safe to change only before first deploy |
| `SITE_DB_PASSWORD` | Password stored in the site config for the Frappe site database | Secret, requires restart and usually a site config update |
| `DB_ROOT_USER` | MariaDB administrative user for site bootstrap and restore | Defaults to `root` |
| `DB_ROOT_PASSWORD` | MariaDB administrative password for bootstrap, migration, and restore operations | Secret, rotate carefully |

About `DB_USER`:

Frappe manages the site database user during `bench new-site`. In this workflow
the effective site DB user follows the site database created by Frappe, so the
operator mainly controls `SITE_DB_NAME` and `SITE_DB_PASSWORD`.

## Application Variables

Core variables from [env.production.example](D:/cloned projects/frappe ERP/education/ops/deployment/env.production.example:1):

| Variable | Purpose | Example | Restart required |
| --- | --- | --- | --- |
| `APP_BRANCH` | Git branch pulled by `./update.sh` | `develop` | No, only next update |
| `SITE_NAME` | Frappe site identifier | `education.example.com` | Yes |
| `DOMAIN` | Public hostname served by Nginx and Certbot | `education.example.com` | Yes |
| `FRAPPE_IMAGE_TAG` | Base Frappe/ERPNext image tag used for custom image builds | `develop` | Yes, next build |
| `CUSTOM_IMAGE` | Local image repository name | `education/custom` | Yes, next build |
| `COMPOSE_PROJECT_NAME` | Docker Compose project namespace | `education` | Yes |
| `FRAPPE_HTTP_PORT` | Loopback port exposed by the frontend container | `8080` | Yes |
| `ADMIN_PASSWORD` | Initial `Administrator` password used by `bench new-site` | strong secret | Only on first deploy unless reset manually |
| `ENABLE_LETSENCRYPT` | Turns on Certbot automation | `true` or `false` | Nginx reload / deploy |
| `LETSENCRYPT_EMAIL` | Contact email for certificate issuance | `admin@example.com` | Nginx reload / deploy |
| `BACKUP_ROOT` | Host path for manual and scheduled backups | `/opt/education/backups` | No |
| `BACKUP_RETENTION_DAYS` | Retention window for old backup directories | `14` | No |
| `BACKUP_ON_CALENDAR` | Systemd timer schedule | `"*-*-* 03:30:00"` | Timer reinstall |

Security rules:

- Do not commit `ops/deployment/.env.production`
- Use long random passwords for `ADMIN_PASSWORD`, `DB_ROOT_PASSWORD`, and `SITE_DB_PASSWORD`
- Keep `/etc/education/education.env` readable by root only
- Do not expose Docker ports publicly except the host Nginx listener

## Fresh Server Setup

`./deploy.sh` handles first-time Ubuntu server setup:

1. Validates Ubuntu, memory, disk, and outbound network access
2. Installs Git, curl, jq, Nginx, Certbot, and Docker Engine
3. Builds a custom Frappe image from this repository
4. Starts MariaDB, Redis, configurator, and application containers
5. Creates the Frappe site if it does not exist
6. Runs migrations
7. Installs and reloads host Nginx
8. Requests a Let's Encrypt certificate when enabled
9. Installs the scheduled backup timer when enabled
10. Runs final health checks

## First Admin Creation

The first non-default admin should be created after the stack is healthy:

```bash
./create-admin.sh
```

Non-interactive usage:

```bash
BOOTSTRAP_ADMIN_EMAIL=admin@example.com \
BOOTSTRAP_ADMIN_FULL_NAME="ERP Admin" \
BOOTSTRAP_ADMIN_PASSWORD='Use-A-Long-Random-Password!' \
./create-admin.sh
```

The bootstrap path:

- validates email syntax
- enforces strong password rules
- prevents duplicate users
- grants `System Manager`
- writes an audit entry through the Frappe logger

The implementation lives in [admin_bootstrap.py](D:/cloned projects/frappe ERP/education/education/deployment/admin_bootstrap.py:1).

## Deployment Commands

Fresh deploy:

```bash
./deploy.sh
```

Update to the latest branch head:

```bash
./update.sh
```

Health verification:

```bash
./healthcheck.sh
```

Manual backup:

```bash
./backup.sh
```

Rollback to the previous built image:

```bash
./rollback.sh
```

## Rollback Strategy

`./update.sh` snapshots the current release before building a new image. If the
update fails after the new image is activated, the script automatically switches
the containers back to the previous image tag.

`./rollback.sh` performs a manual image rollback using the recorded
`previous-release.env`.

Scope of rollback:

- Restores the previous application image
- Restores the previous runtime release metadata
- Does not automatically restore the MariaDB schema or data

Before each update, a backup is taken. If a schema change must be reversed, use
the backup set or the MariaDB Cloud restore workflow in
[ops/mariadb-cloud-replication/README.md](D:/cloned projects/frappe ERP/education/ops/mariadb-cloud-replication/README.md:1).

## Backup and Restore

Manual backups are created with:

```bash
./backup.sh
```

That script:

- runs `bench --site <site> backup --with-files`
- copies the newest DB and file archives out of the backend container
- backs up `site_config.json`
- backs up `/etc/education/education.env`
- backs up the active Nginx config
- backs up the active release metadata

Scheduled backups:

```bash
sudo systemctl status education-backup.timer
sudo systemctl list-timers education-backup.timer
```

Restore a local backup to the same site:

```bash
sudo docker compose \
  --project-name education \
  --env-file /etc/education/education.env \
  --env-file /opt/education/state/release.env \
  -f ops/deployment/compose/compose.production.yaml \
  exec -T backend \
  bash -lc "bench --site '${SITE_NAME}' restore /home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups/<database.sql.gz> --with-public-files /home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups/<files.tar> --with-private-files /home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups/<private-files.tar>"
```

Restore from the MariaDB Cloud secondary:

```bash
python3 ops/mariadb-cloud-replication/restore_from_cloud.py --mode record --table tabStudent --key-value STUD-0001
```

## SSL and Nginx

Nginx configuration is rendered from
[education.conf.template](D:/cloned projects/frappe ERP/education/ops/deployment/nginx/education.conf.template:1)
and installed to `/etc/nginx/sites-available/education.conf`.

Let's Encrypt is enabled when:

- `ENABLE_LETSENCRYPT=true`
- `LETSENCRYPT_EMAIL` is set
- the domain already points to the server

Useful commands:

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo certbot certificates
sudo certbot renew --dry-run
```

## Troubleshooting

Container status:

```bash
sudo docker compose \
  --project-name education \
  --env-file /etc/education/education.env \
  --env-file /opt/education/state/release.env \
  -f ops/deployment/compose/compose.production.yaml ps
```

Backend logs:

```bash
sudo docker compose \
  --project-name education \
  --env-file /etc/education/education.env \
  --env-file /opt/education/state/release.env \
  -f ops/deployment/compose/compose.production.yaml logs -f backend
```

Validate app installation:

```bash
sudo docker compose \
  --project-name education \
  --env-file /etc/education/education.env \
  --env-file /opt/education/state/release.env \
  -f ops/deployment/compose/compose.production.yaml exec -T backend \
  bench --site "${SITE_NAME}" list-apps
```

Re-run health checks:

```bash
./healthcheck.sh
```
