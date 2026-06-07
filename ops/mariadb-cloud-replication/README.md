# MariaDB Cloud Replication Runbook

This ERP runs on Frappe/ERPNext and uses MariaDB as its transactional database.
The production-safe synchronization layer is MariaDB replication, not duplicate
writes inside Frappe business logic. That keeps the EC2 database authoritative,
captures framework tables and raw SQL changes, and avoids scattering sync code
across DocTypes.

## Architecture

```
Frappe / ERPNext application
        |
        v
EC2 MariaDB primary
        |
        | row-based binlog / GTID replication
        v
MariaDB Cloud secondary
```

The application continues reading and writing only the EC2 primary. MariaDB
Cloud is maintained as an actively synchronized secondary that can be used for
restore or promoted manually during a disaster recovery event.

## Secret Handling

Do not commit rendered config files or real credentials. Use a root-owned env
file, systemd environment, AWS Secrets Manager, SSM Parameter Store, or your
deployment secret manager.

Required MariaDB Cloud values:

- `MARIADB_CLOUD_HOST=serverless-europe-west9.sysp0000.db2.skysql.com`
- `MARIADB_CLOUD_PORT=4049`
- `MARIADB_CLOUD_USER`
- `MARIADB_CLOUD_PASSWORD`

The username and password must be provided at deployment time only.

## Primary Setup

1. Add `primary.cnf` settings to the EC2 MariaDB config.
2. Restart MariaDB during a maintenance window.
3. Render `create_primary_replication_user.sql.tpl` from secrets.
4. Run the rendered SQL on the EC2 primary.
5. Take an initial consistent backup from the primary and restore it into MariaDB Cloud.
6. Capture `@@GLOBAL.gtid_binlog_pos` from the EC2 primary.
7. Render and run `configure_cloud_replica.sql.tpl` on MariaDB Cloud.

Use TLS for replication whenever MariaDB Cloud can reach the EC2 primary over
an encrypted connection. Prefer private connectivity over a public `0.0.0.0`
database listener.

## Health Monitoring

`replication_healthcheck.py` checks:

- EC2 primary binlog and GTID settings
- MariaDB Cloud inbound replication status
- IO and SQL replication thread state
- last IO or SQL replication error

Example:

```bash
set -a
. ./env.production
set +a
python3 ops/mariadb-cloud-replication/replication_healthcheck.py
```

Run it from cron, systemd timer, CloudWatch Agent, or your monitoring system.
Set `SYNC_ALERT_WEBHOOK_URL` to notify administrators on failures.

Systemd templates are included in `systemd/`. They assume:

- repo path: `/opt/frappe/education`
- env file: `/etc/education/mariadb-cloud-replication.env`
- service user: `frappe`

Adjust those values for your server before installing the unit files.

## Restore

`restore_from_cloud.py` is intentionally guarded. It writes a report by default
and will not write to the EC2 primary unless `--apply` and an exact confirmation
token are provided.

Record restore:

```bash
python3 ops/mariadb-cloud-replication/restore_from_cloud.py \
  --mode record \
  --table tabStudent \
  --key-column name \
  --key-value STUD-0001
```

Table restore:

```bash
python3 ops/mariadb-cloud-replication/restore_from_cloud.py \
  --mode table \
  --table tabStudent
```

Full database restore should normally be tested into a staging database first:

```bash
python3 ops/mariadb-cloud-replication/restore_from_cloud.py \
  --mode full
```

To apply a restore to production, review the generated report and use the exact
confirmation token shown by the script error for the selected mode.

## Operational Notes

- Primary failure means the ERP write fails and no cloud write is attempted.
- Primary success with replication outage leaves data on the primary binlog.
- MariaDB replication retries from the last binlog or GTID position.
- Idempotency is provided by binlog ordering and primary keys, not duplicate app writes.
- Repeated replication failures should page an administrator.
- Schema changes must be applied through the primary and replicated forward.
- Do not write application traffic to MariaDB Cloud unless failover has been explicitly approved.

## References

- MariaDB Cloud exposes `sky.change_external_primary_gtid`, `sky.start_replication`,
  and `sky.replication_status` for inbound external primary replication.
- MariaDB Cloud backup documentation recommends replica-based backups to avoid
  disrupting the primary write workload.
