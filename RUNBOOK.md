# Runbook

Every command runs on a database server unless it says otherwise. Shorthand used below:

```sh
alias pctl='sudo -u postgres patronictl -c /etc/patroni/config.yml'
```

First look, always: `pctl list`. It shows each member, its role, its state and how far behind it is.

## Alerts

### PostgresNoPrimary (critical)
No server is accepting writes, or two claim to be primary.

1. `pctl list` on any node that answers.
2. No leader and two or more nodes running: Patroni is choosing, wait 60 seconds. Still none: `sudo journalctl -u patroni -n 50`. The usual reasons are "no healthy replica within the allowed lag" or etcd without quorum (next step).
3. `etcdctl --endpoints=http://127.0.0.1:2379 endpoint status --cluster -w table`. Fewer than two healthy members: bring the failed servers back first. Patroni makes the primary read-only when it cannot reach etcd; that is by design.
4. Only one database node left alive and it must take writes: `pctl failover --candidate <that node> --force`. If synchronous mode refuses because no synchronous replica exists, turn it off for the emergency: `pctl edit-config -s synchronous_mode=false --force`, and turn it back on when a second node is up.

### PostgresNodeDown / NodeDown / EtcdMemberDown (warning)
One server is gone. The cluster keeps working; a second loss stops it. Fix today, not next week.

1. Is the server on? UpCloud control panel or `upctl server show <name>`. Start it.
2. After start it rejoins on its own: Patroni rewinds it if it was the old primary and it follows the new one. Confirm with `pctl list`.
3. It does not rejoin: `sudo journalctl -u patroni -n 80` on that node. Rebuild its copy from the primary: `pctl reinit <cluster> <node>`.
4. The server is lost for good: `terraform taint 'upcloud_server.db[N]'`, `terraform apply`. Before the new server starts, replace the dead member in etcd from a healthy node: `etcdctl member list`, `etcdctl member remove <id>`, `etcdctl member add <name> --peer-urls=http://<ip>:2380`, and on the new server set `ETCD_INITIAL_CLUSTER_STATE=existing` in `/etc/default/etcd` before etcd first starts. (This step is manual today.)

### PostgresMetricsMissing (warning)
The exporter on that node is not answering, so the archive and replication alerts cannot see it. `sudo systemctl status prometheus-postgres-exporter`, then `sudo journalctl -u prometheus-postgres-exporter -n 30`. Usually a restart: `sudo systemctl restart prometheus-postgres-exporter`.

### PostgresReplicaBehind (warning)
A replica is more than 64 MB behind for 5 minutes.

1. `pctl list`: one replica or both? Both: the primary is producing WAL faster than the network or disks take it (a bulk load, a long `VACUUM FULL`). It usually recovers when the job ends.
2. One: look at that node's disk and load (`iostat -x 5`, `df -h`), and its log: `sudo tail -50 /var/lib/postgresql/*/main/log/*.log`.
3. Stuck for an hour: `pctl reinit <cluster> <node>`.

### PostgresWalArchiveFailing (critical)
WAL is not reaching the bucket. Point-in-time recovery is falling behind, and unarchived WAL stays on the primary's disk until it fills.

1. On the primary: `sudo -u postgres pgbackrest --stanza=main check`. The error says which: credentials, endpoint, bucket.
2. `df -h /var/lib/postgresql`. Under 15% free: fix the archive first; do not delete WAL files by hand.
3. Object storage outage at the provider: nothing to fix on our side; watch the disk. If it will fill before storage returns, this is the one case to consider `archive_command: /bin/true` through `pctl edit-config`, knowing that it breaks point-in-time recovery until a new full backup is taken.

### PostgresBackupTooOld (critical)
1. On the primary: `sudo systemctl status pg-backup.service` and `sudo journalctl -u pg-backup -n 50`.
2. Run it by hand: `sudo systemctl start pg-backup.service`.
3. List what exists: `sudo -u postgres pgbackrest --stanza=main info`.

### PostgresRestoreTestTooOld (critical)
The backups have not been proven for 8 days. On the monitor node:

1. `sudo journalctl -u pg-restore-test -n 80`.
2. Run it: `sudo systemctl start pg-restore-test.service`.
3. Out of disk on the monitor node is the usual cause as the database grows: raise `db_disk_gb`.

### PostgresClusterPaused (warning)
Someone paused Patroni for maintenance and did not resume. `pctl resume`.

### DiskFilling (warning)
1. `sudo du -xh /var/lib/postgresql --max-depth=3 | sort -h | tail`.
2. `pg_wal` is the big one: see PostgresWalArchiveFailing, and check for an abandoned replication slot: `select slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) from pg_replication_slots;`
3. The data is the big one: grow the disk (`db_disk_gb`, then `terraform apply`, then grow the filesystem), one replica at a time, primary last after a switchover.

## Planned work

### Move the primary on purpose
`pctl switchover` picks a replica, waits for it to be fully caught up, and swaps. Clients see a few seconds of refused writes.

### Minor PostgreSQL update, or a reboot
One node at a time, replicas first:

1. On a replica: `sudo apt-get update && sudo apt-get install --only-upgrade postgresql-18`, then `pctl restart <cluster> <node>`. Wait until `pctl list` shows it streaming with no lag.
2. Same on the second replica.
3. `pctl switchover` to an updated replica, then update the old primary the same way.

### Change a PostgreSQL setting
`pctl edit-config`, not `postgresql.conf`: Patroni owns that file and applies the change on every node. Settings that need a restart show as "pending restart" in `pctl list`; restart replicas first, then switch over.

### Restore to a point in time
This replaces the cluster's data with an earlier state. Everything written after that time is gone from the running cluster. Decide first whether you only need to *read* old data: if so, restore to the monitor node (`pg-restore-test` shows how) and copy out what you need.

Full cluster restore:

1. `pctl pause`, then stop Patroni on all three nodes: `sudo systemctl stop patroni`.
2. On the node that will be primary: `sudo -u postgres pgbackrest --stanza=main --delta --type=time --target="2026-11-17 14:05:00+00" --target-action=promote restore`.
3. Remove the old cluster state so Patroni accepts the restored data: `pctl remove <cluster>` (it asks you to type the name and a confirmation sentence).
4. Start Patroni on that node; wait until it is the leader. Then on each of the other two: `sudo rm -rf /var/lib/postgresql/18/main && sudo systemctl start patroni`. They copy themselves from the new primary.
5. `pctl resume`. Take a full backup: `sudo -u postgres pgbackrest --stanza=main --type=full backup`.

### Lost everything, bucket and passphrase remain
Nothing to restore by hand. A new server that finds no cluster looks in the bucket first: if a backup is there,
it restores the newest one, replays all archived WAL and becomes the primary; the other two copy from it.

1. `terraform apply` (add `-replace='upcloud_server.db[0]'` and so on if the dead servers still exist). This
   needs the Terraform state. With the state gone too, import the object storage into a new state first and set
   the same cluster name and backup passphrase; that path has not been tested.
2. Wait about 5 minutes. `pctl list` must show one Leader and two streaming replicas.
3. Check your newest data. Writes from the last minute before the loss may be missing (WAL is shipped every 60
   seconds at the latest).
4. Take a full backup: `sudo -u postgres pgbackrest --stanza=main --type=full backup`.

If the bucket cannot be reached, the new servers do not create an empty database; they retry. Look at
`journalctl -u patroni` for the reason.

## Numbers to know

Measured on 17 November 2026: 1 CPU / 1 GB servers, near-empty database. Measure again on your own sizes and data.

| | Target | Measured |
|---|---|---|
| Writes unavailable when the primary dies | under 60 s | 36.4 s, 34.6 s |
| Confirmed writes lost on failover (synchronous) | 0 | 0 of 146, 0 of 147 |
| Old primary back as a replica after power-on | no manual steps | 33 s and 146 s, no manual steps |
| Time to restore the newest backup | depends on size | 12 to 13 s for 30 MB |
| Restore a copy to a chosen second (after a bad delete) | data as it was at that second | all 1,000 rows back, 18 s for 30 MB |
| Newest restorable point after losing all three nodes | under 2 minutes before the loss | 1.6 s before the loss (6 of 717 confirmed rows gone) |
| Time until writable after replacing all three nodes | no manual steps | about 5 minutes from new servers created, no manual steps |
