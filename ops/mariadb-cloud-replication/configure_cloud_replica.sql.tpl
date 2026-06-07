-- Run this on MariaDB Cloud after restoring an initial copy of the EC2 primary.
-- Render from environment variables or a secret manager; do not commit rendered SQL.
-- PRIMARY_GTID_POSITION should come from SELECT @@GLOBAL.gtid_binlog_pos on EC2.

CALL sky.change_external_primary_gtid(
  '${PRIMARY_REPLICATION_HOST}',
  ${PRIMARY_REPLICATION_PORT},
  '${PRIMARY_GTID_POSITION}',
  ${MARIADB_REPLICATION_USE_SSL}
);

CALL sky.change_connect_retry(30);
CALL sky.change_heartbeat_period(5);
CALL sky.start_replication();
CALL sky.replication_status();
