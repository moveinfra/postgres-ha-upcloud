# ---- db-node.sh: one of the three database nodes ----
apt-get install -y etcd-server etcd-client patroni python3-etcd prometheus-postgres-exporter

# etcd: the three nodes vote on who is primary. Two of three must agree, so one node can fail.
n=0
initial=""
for ip in $DB_IPS; do
  n=$((n + 1))
  initial="$initial$CLUSTER-$n=http://$ip:2380,"
done
cat >/etc/default/etcd <<CONF
ETCD_NAME=$NODE_NAME
ETCD_DATA_DIR=/var/lib/etcd/$CLUSTER
ETCD_LISTEN_PEER_URLS=http://$NODE_IP:2380
ETCD_LISTEN_CLIENT_URLS=http://$NODE_IP:2379,http://127.0.0.1:2379
ETCD_INITIAL_ADVERTISE_PEER_URLS=http://$NODE_IP:2380
ETCD_ADVERTISE_CLIENT_URLS=http://$NODE_IP:2379
ETCD_INITIAL_CLUSTER=${initial%,}
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=$CLUSTER
ETCD_AUTO_COMPACTION_RETENTION=1
CONF

write_pgbackrest_conf "$PGDATA"

# Patroni: starts PostgreSQL, watches it, and promotes a replica when the primary is gone.
mkdir -p /etc/patroni
etcd_hosts=""
for ip in $DB_IPS; do etcd_hosts="$etcd_hosts$ip:2379,"; done
cat >/etc/patroni/config.yml <<CONF
scope: $CLUSTER
namespace: /service/
name: $NODE_NAME

restapi:
  listen: 0.0.0.0:8008
  connect_address: $NODE_IP:8008

etcd3:
  hosts: ${etcd_hosts%,}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: $SYNCHRONOUS
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"
        archive_mode: "on"
        archive_command: "pgbackrest --stanza=main archive-push %p"
        archive_timeout: 60
        password_encryption: scram-sha-256
        log_checkpoints: "on"
        log_lock_waits: "on"
      recovery_conf:
        restore_command: "pgbackrest --stanza=main archive-get %f %p"
  method: restore_or_init
  restore_or_init:
    command: /usr/local/bin/pg-bootstrap
    keep_existing_recovery_conf: true
    no_params: true
  post_bootstrap: /usr/local/bin/pg-post-bootstrap

postgresql:
  listen: 0.0.0.0:5432
  connect_address: $NODE_IP:5432
  data_dir: $PGDATA
  bin_dir: $PGBIN
  pgpass: /var/lib/postgresql/.pgpass_patroni
  authentication:
    superuser:
      username: postgres
      password: $PW_SUPERUSER
    replication:
      username: replicator
      password: $PW_REPLICATION
    rewind:
      username: rewind
      password: $PW_REWIND
  pg_hba:
    - local all all peer
    - host all all 127.0.0.1/32 scram-sha-256
    - host replication replicator $PRIVATE_CIDR scram-sha-256
    - host all all $PRIVATE_CIDR scram-sha-256
  create_replica_methods:
    - pgbackrest
    - basebackup
  pgbackrest:
    command: pgbackrest --stanza=main --delta restore
    keep_data: true
    no_params: true
  basebackup:
    checkpoint: fast

watchdog:
  mode: automatic
  device: /dev/watchdog
  safety_margin: 5
CONF
cat >/etc/patroni/bootstrap.env <<CONF
PW_MONITOR='$PW_MONITOR'
PW_APP='$PW_APP'
CONF
chown -R postgres:postgres /etc/patroni
chmod 700 /etc/patroni
chmod 600 /etc/patroni/*

# Runs once, on the node that creates the cluster. If the bucket already holds a backup of this cluster
# (all three nodes were lost and rebuilt), restore it and replay the archived WAL. Otherwise start empty.
# If the bucket cannot be read, fail: Patroni retries, and an empty database never replaces a lost one.
cat >/usr/local/bin/pg-bootstrap <<SCRIPT
#!/bin/bash
set -euo pipefail
backups=\$(pgbackrest --stanza=main --output=json info | jq '[.[].backup[]?] | length')
mkdir -p "$PGDATA"
chmod 700 "$PGDATA"
if [ "\$backups" -gt 0 ]; then
  echo "pg-bootstrap: \$backups backups in the bucket, restoring the newest"
  pgbackrest --stanza=main restore
else
  echo "pg-bootstrap: no backup in the bucket, creating an empty database"
  $PGBIN/initdb -D "$PGDATA" --encoding=UTF8 --data-checksums
fi
SCRIPT

# Runs after pg-bootstrap, on the same node: roles, the app database, and the backup repository.
# Safe to run on a restored database: it creates only what is missing and sets the current passwords.
cat >/usr/local/bin/pg-post-bootstrap <<'SCRIPT'
#!/bin/bash
set -euo pipefail
. /etc/patroni/bootstrap.env
psql -v ON_ERROR_STOP=1 -U postgres -d postgres -v mon="$PW_MONITOR" -v app="$PW_APP" <<'SQL'
SELECT 'CREATE ROLE monitor LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'monitor') \gexec
SELECT 'CREATE ROLE app LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app') \gexec
ALTER ROLE monitor PASSWORD :'mon';
ALTER ROLE app PASSWORD :'app';
GRANT pg_monitor TO monitor;
SELECT 'CREATE DATABASE app OWNER app' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'app') \gexec
SQL
pgbackrest --stanza=main stanza-create
SCRIPT

# Daily backup. The timer runs on all three nodes; only the current primary takes the backup.
cat >/usr/local/bin/pg-backup <<'SCRIPT'
#!/bin/bash
set -euo pipefail
OUT=/var/lib/prometheus/node-exporter/pg_backup.prom
if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8008/primary || true)" = 200 ]; then
  type=diff
  [ "$(date +%u)" = 7 ] && type=full
  pgbackrest --stanza=main --type="$type" backup
fi
last=$(pgbackrest --stanza=main --output=json info | jq '[.[0].backup[].timestamp.stop] | max // 0')
printf '# HELP pg_backup_last_success_timestamp End time of the newest backup in the repository.\n# TYPE pg_backup_last_success_timestamp gauge\npg_backup_last_success_timestamp %s\n' "$last" >"$OUT"
SCRIPT
chmod 755 /usr/local/bin/pg-bootstrap /usr/local/bin/pg-post-bootstrap /usr/local/bin/pg-backup
metric_file pg_backup.prom

cat >/etc/systemd/system/pg-backup.service <<'UNIT'
[Unit]
Description=PostgreSQL backup to object storage (acts only on the primary)
After=patroni.service
[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/pg-backup
UNIT
cat >/etc/systemd/system/pg-backup.timer <<'UNIT'
[Unit]
Description=Daily PostgreSQL backup
[Timer]
OnCalendar=*-*-* 02:15:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT

# Our own unit, so the behaviour does not depend on the packaged one. The watchdog resets the machine if
# Patroni hangs while it holds the primary role, so two primaries cannot exist at once.
cat >/etc/systemd/system/patroni.service <<'UNIT'
[Unit]
Description=Patroni (PostgreSQL with automatic failover)
After=network-online.target etcd.service
Wants=network-online.target
[Service]
Type=simple
User=postgres
Group=postgres
ExecStartPre=-+/sbin/modprobe softdog
ExecStartPre=-+/bin/chown postgres /dev/watchdog
ExecStart=/usr/bin/patroni /etc/patroni/config.yml
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
TimeoutSec=30
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT

# The packaged exporter (0.15) reads pg_stat_bgwriter columns that PostgreSQL 17 removed: that collector is off.
cat >/etc/default/prometheus-postgres-exporter <<CONF
DATA_SOURCE_NAME='postgresql://monitor:$PW_MONITOR@127.0.0.1:5432/postgres?sslmode=disable'
ARGS='--no-collector.stat_bgwriter'
CONF
chown root:prometheus /etc/default/prometheus-postgres-exporter
chmod 640 /etc/default/prometheus-postgres-exporter

echo "export PATRONICTL_CONFIG_FILE=/etc/patroni/config.yml" >/etc/profile.d/patroni.sh

rm -f /usr/sbin/policy-rc.d
systemctl daemon-reload
systemctl enable etcd patroni pg-backup.timer prometheus-node-exporter prometheus-postgres-exporter
systemctl start --no-block etcd # it waits for a second member before it reports ready
for _ in $(seq 150); do
  etcdctl --endpoints=http://127.0.0.1:2379 endpoint health >/dev/null 2>&1 && break
  sleep 2
done
etcdctl --endpoints=http://127.0.0.1:2379 endpoint health
systemctl start patroni pg-backup.timer
systemctl restart prometheus-node-exporter prometheus-postgres-exporter
echo "== $(date -Is) setup of $NODE_NAME finished"
