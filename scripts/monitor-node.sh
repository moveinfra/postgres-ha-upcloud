# ---- monitor-node.sh: Prometheus, Alertmanager and the weekly restore test ----
apt-get install -y prometheus prometheus-alertmanager

RESTORE_DIR=/var/lib/postgresql/restore-test
write_pgbackrest_conf "$RESTORE_DIR"

targets() { # $1 = port; prints a YAML list of the three database nodes
  local out=""
  for ip in $DB_IPS; do out="$out'$ip:$1', "; done
  echo "[${out%, }]"
}
all_nodes="$(targets 9100)"
all_nodes="${all_nodes%]}, '127.0.0.1:9100']"

cat >/etc/prometheus/prometheus.yml <<CONF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
rule_files:
  - /etc/prometheus/pg-ha.rules.yml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['127.0.0.1:9093']
scrape_configs:
  - job_name: node
    static_configs:
      - targets: $all_nodes
  - job_name: postgres
    static_configs:
      - targets: $(targets 9187)
  - job_name: patroni
    static_configs:
      - targets: $(targets 8008)
  - job_name: etcd
    static_configs:
      - targets: $(targets 2379)
CONF

cat >/etc/prometheus/pg-ha.rules.yml <<'CONF'
groups:
  - name: pg-ha
    rules:
      - alert: PostgresNoPrimary
        expr: (sum(patroni_primary) or vector(0)) != 1
        for: 1m
        labels: {severity: critical}
        annotations: {summary: "The cluster has {{ $value }} primaries; it must have exactly one. Writes are failing or at risk."}
      - alert: PostgresNodeDown
        expr: up{job="patroni"} == 0
        for: 2m
        labels: {severity: warning}
        annotations: {summary: "{{ $labels.instance }} is not answering. The cluster survives one node down, not two."}
      - alert: PostgresNotRunning
        expr: patroni_postgres_running == 0
        for: 2m
        labels: {severity: warning}
        annotations: {summary: "Patroni is up on {{ $labels.instance }} but PostgreSQL is not running."}
      - alert: PostgresMetricsMissing
        expr: up{job="postgres"} == 0
        for: 5m
        labels: {severity: warning}
        annotations: {summary: "No database metrics from {{ $labels.instance }}. The archive and replication alerts are blind for that node."}
      - alert: PostgresReplicaBehind
        expr: (scalar(max(patroni_xlog_location)) - patroni_xlog_replayed_location) > 67108864 and patroni_replica == 1
        for: 5m
        labels: {severity: warning}
        annotations: {summary: "Replica {{ $labels.instance }} is more than 64 MB behind the primary."}
      - alert: PostgresWalArchiveFailing
        expr: increase(pg_stat_archiver_failed_count[15m]) > 0
        for: 15m
        labels: {severity: critical}
        annotations: {summary: "WAL is not reaching the backup bucket from {{ $labels.instance }}. Point-in-time recovery is falling behind and the disk will fill."}
      - alert: PostgresBackupTooOld
        expr: time() - max(pg_backup_last_success_timestamp) > 26 * 3600
        for: 10m
        labels: {severity: critical}
        annotations: {summary: "No backup finished in the last 26 hours."}
      - alert: PostgresRestoreTestTooOld
        expr: time() - pg_restore_test_last_success_timestamp > 8 * 86400
        for: 10m
        labels: {severity: critical}
        annotations: {summary: "No successful restore test in 8 days. The backups are unproven."}
      - alert: PostgresClusterPaused
        expr: max(patroni_is_paused) == 1
        for: 1h
        labels: {severity: warning}
        annotations: {summary: "Patroni has been paused for an hour: automatic failover is off."}
      - alert: EtcdMemberDown
        expr: up{job="etcd"} == 0
        for: 2m
        labels: {severity: warning}
        annotations: {summary: "etcd on {{ $labels.instance }} is down. Losing a second one stops failover and makes the primary read-only."}
      - alert: DiskFilling
        expr: node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} < 0.2
        for: 10m
        labels: {severity: warning}
        annotations: {summary: "Less than 20% disk left on {{ $labels.instance }}."}
      - alert: NodeDown
        expr: up{job="node"} == 0
        for: 2m
        labels: {severity: warning}
        annotations: {summary: "{{ $labels.instance }} is unreachable."}
CONF

if [ -n "$ALERT_WEBHOOK_URL" ]; then
  receiver="    webhook_configs:
      - url: '$ALERT_WEBHOOK_URL'
        send_resolved: true"
else
  receiver=""
fi
cat >/etc/prometheus/alertmanager.yml <<CONF
route:
  receiver: default
  group_by: [alertname]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
receivers:
  - name: default
$receiver
CONF

# Weekly restore test: fetch the newest backup, start it as a throwaway server, read every catalog, report.
cat >/usr/local/bin/pg-restore-test <<SCRIPT
#!/bin/bash
set -euo pipefail
BIN=$PGBIN
D=$RESTORE_DIR
OUT=$TEXTFILE_DIR/pg_restore_test.prom
PORT=5599
SCRIPT
cat >>/usr/local/bin/pg-restore-test <<'SCRIPT'
started=$(date +%s)
cleanup() {
  "$BIN/pg_ctl" -D "$D" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$D"
}
trap cleanup EXIT
cleanup
mkdir -m 700 "$D"

backup_ts=$(pgbackrest --stanza=main --output=json info | jq '[.[0].backup[].timestamp.stop] | max')
pgbackrest --stanza=main --type=immediate --target-action=promote restore

# Start it isolated: local socket only, no archiving, its own port.
"$BIN/pg_ctl" -D "$D" -w -t 1800 -l "$D/restore-test.log" start -o "-p $PORT -c listen_addresses='' \
  -c archive_mode=off -c hba_file=$D/pg_hba.conf -c ident_file=$D/pg_ident.conf -c cluster_name=restore-test"
for _ in $(seq 600); do
  [ "$(psql -p "$PORT" -d postgres -qAtc 'select pg_is_in_recovery()')" = f ] && break
  sleep 1
done
[ "$(psql -p "$PORT" -d postgres -qAtc 'select pg_is_in_recovery()')" = f ]
"$BIN/pg_dumpall" -p "$PORT" --schema-only >/dev/null
bytes=$(psql -p "$PORT" -d postgres -qAtc 'select sum(pg_database_size(oid)) from pg_database')

now=$(date +%s)
cat >"$OUT" <<PROM
# HELP pg_restore_test_last_success_timestamp When the newest backup was last restored and read successfully.
# TYPE pg_restore_test_last_success_timestamp gauge
pg_restore_test_last_success_timestamp $now
# HELP pg_restore_test_duration_seconds How long the restore took: the real time to recover from backup.
# TYPE pg_restore_test_duration_seconds gauge
pg_restore_test_duration_seconds $((now - started))
# HELP pg_restore_test_backup_timestamp End time of the backup that was restored.
# TYPE pg_restore_test_backup_timestamp gauge
pg_restore_test_backup_timestamp $backup_ts
# HELP pg_restore_test_database_bytes Size of the restored databases.
# TYPE pg_restore_test_database_bytes gauge
pg_restore_test_database_bytes $bytes
PROM
echo "restore test ok: backup from $(date -d "@$backup_ts" -Is), $bytes bytes, $((now - started)) s"
SCRIPT

# Used by the failover drill: writes one row every 0.2 s through the normal client connection string and
# reports how long writes were impossible and whether any confirmed row is missing afterwards.
cat >/usr/local/bin/pg-drill-writer <<'SCRIPT'
#!/bin/bash
# usage: sudo pg-drill-writer SECONDS
set -uo pipefail
. /etc/pg-ha.env
hosts="$(echo "$DB_IPS" | sed 's/ /:5432,/g'):5432"
URL="postgresql://app:$PW_APP@$hosts/app?target_session_attrs=read-write&connect_timeout=2"
LOG=/var/log/pg-drill.log
psql "$URL" -qc "create table if not exists drill (id bigserial primary key, ts timestamptz not null default clock_timestamp()); truncate drill" || exit 1
end=$(($(date +%s) + ${1:-120}))
: >"$LOG"
while [ "$(date +%s)" -lt "$end" ]; do
  t=$(date +%s.%N)
  if psql "$URL" -qAtc "insert into drill default values" >/dev/null 2>&1; then echo "$t ok" >>"$LOG"; else echo "$t fail" >>"$LOG"; fi
  sleep 0.2
done
rows=$(psql "$URL" -qAtc "select count(*) from drill")
awk -v rows="$rows" '
  $2 == "ok" { ok++; if (prev && $1 - prev > gap) { gap = $1 - prev; from = prev; to = $1 } prev = $1 }
  $2 == "fail" { fail++ }
  END {
    printf "confirmed writes: %d\nrows in table:    %d\nconfirmed but missing: %d\nfailed attempts:  %d\n", ok, rows, ok - rows, fail
    printf "longest time without a successful write: %.1f s\n", gap
  }' "$LOG"
SCRIPT
chmod 755 /usr/local/bin/pg-restore-test /usr/local/bin/pg-drill-writer
metric_file pg_restore_test.prom

cat >/etc/systemd/system/pg-restore-test.service <<'UNIT'
[Unit]
Description=Restore the newest PostgreSQL backup and check it
[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/pg-restore-test
UNIT
cat >/etc/systemd/system/pg-restore-test.timer <<'UNIT'
[Unit]
Description=Weekly PostgreSQL restore test
[Timer]
OnCalendar=Mon *-*-* 04:30:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT

rm -f /usr/sbin/policy-rc.d
systemctl daemon-reload
systemctl enable --now prometheus prometheus-alertmanager prometheus-node-exporter pg-restore-test.timer
systemctl restart prometheus prometheus-alertmanager
echo "== $(date -Is) setup of $NODE_NAME finished"
