-- Render this template on the EC2 primary with values from a secret store.
-- Do not commit the rendered file.

CREATE USER IF NOT EXISTS '${PRIMARY_REPLICATION_USER}'@'%'
IDENTIFIED BY '${PRIMARY_REPLICATION_PASSWORD}';

GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.*
TO '${PRIMARY_REPLICATION_USER}'@'%';

FLUSH PRIVILEGES;

SHOW MASTER STATUS;
SELECT @@GLOBAL.gtid_binlog_pos AS gtid_binlog_pos;
