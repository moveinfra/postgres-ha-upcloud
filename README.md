# Production PostgreSQL on UpCloud, with failover and tested backups

Terraform that builds a PostgreSQL cluster you run in your own UpCloud account. One command creates it; it
survives the loss of any one server without a person doing anything; it proves every week that its backups
can be restored.

**Status: built and measured on 17 November 2026, on the smallest UpCloud servers (1 CPU, 1 GB) with a
near-empty database.** Built twice from zero, drill run twice, total loss rebuilt once. Not yet run under real load or for more than a day.
The list of what is still missing is at the end.

## Measured

| Test | Result (two runs) |
|---|---|
| Primary powered off with no shutdown while a client wrote a row every 0.2 s | Writes impossible for 36.4 s and 34.6 s, then they continued on a new primary with no change on the client |
| Confirmed writes lost in that failover | 0 of 146, 0 of 147 |
| Old primary powered on again | Rewound itself and followed the new primary as a replica after 33 s and 146 s (most of it boot time), with no commands |
| Newest backup restored on a separate server, started and read | 13 s and 12 s for a 30 MB database (this grows with size) |
| 990 of 1,000 rows deleted by mistake; a copy restored to 5 seconds before the delete (the backup was from before a failover) | All 1,000 rows back, 18 s |
| All three database servers powered off at once during writes, then replaced by new empty servers; nothing left but the bucket | The first new server restored the backup and replayed the archived WAL by itself. 711 of 717 confirmed rows back: the last 1.6 s of writes were lost (by design up to about 60 s, see below). Writable again about 5 minutes after the new servers were created |
| From `terraform apply` to a working three-node cluster | About 12 minutes, of which 6 are UpCloud creating the object storage |

## Disaster recovery, tested

Each of these was run for real, and the numbers are in the table above.

| What goes wrong | What happens | You do |
|---|---|---|
| One database server dies | A replica becomes primary in about 35 s; no confirmed write is lost | Nothing. Power the server on or replace it; it rejoins by itself |
| Someone deletes or damages data | A copy is restored to the second before the mistake, on a separate server | One command, in `RUNBOOK.md`; then copy the rows back |
| All three servers are gone | New servers find the backup in the bucket, restore it and replay the archived WAL | `terraform apply`, wait about 5 minutes |
| A backup is silently unusable | The weekly restore test fails and an alert fires within 8 days | Follow the alert's steps in `RUNBOOK.md` |

A new server never creates an empty database while the bucket holds a backup, and never when the bucket cannot be
reached: it retries.

Run the failover drill yourself: `./drill/failover-drill.sh`. It powers off the primary under load and prints how
long writes stopped and whether any confirmed row is missing.

## What you get

| Part | What it does |
|---|---|
| 3 database servers, each on a different physical host | One primary takes writes, two replicas follow it |
| Patroni + etcd | Notice a dead primary and promote a replica: 35 to 36 seconds in our drills |
| Synchronous replication (default on) | A write is confirmed only when a second server has it, so a failover loses no confirmed write |
| pgBackRest to UpCloud Object Storage | Full backup weekly, differential daily, every WAL segment within a minute: restore to any second |
| Encrypted backups | AES-256, key held outside the bucket |
| Weekly restore test | The newest backup is restored on a separate server, started and read; an alert fires if that has not succeeded for 8 days |
| Prometheus + Alertmanager | 12 alerts, each one written as a sentence about what is wrong |
| Firewall on every server | SSH from one address range; database only from the private network |
| Failover drill script | Powers off the primary under load and prints how long writes stopped and whether any confirmed row was lost |

Four servers in total: three database nodes and one small node for monitoring and restore tests.

## Cost

At the default sizes (3 × 2 CPU / 4 GB, 1 × 1 CPU / 2 GB, object storage), roughly €90 to €110 a month at
UpCloud list prices. Check the current prices before you rely on that. A test run of a few days costs a few euros;
`terraform destroy` removes everything.

## Build it

You need Terraform 1.6+, an UpCloud API token or subaccount, and `jq`.

```sh
export UPCLOUD_TOKEN=...   # or UPCLOUD_USERNAME and UPCLOUD_PASSWORD
cp terraform.tfvars.example terraform.tfvars   # set your SSH key and your own IP address
terraform init
terraform apply
```

The servers set themselves up in about ten minutes. Watch one: `ssh admin@<ip> sudo tail -f /var/log/pg-ha-setup.log`.
Then check the cluster:

```sh
ssh admin@<db ip> sudo -u postgres patronictl -c /etc/patroni/config.yml list
```

Three members, one `Leader`, one `Sync Standby`, one `Replica`, all `running` or `streaming`.

Take the first backup now instead of waiting for 02:15, then run the restore test once:

```sh
ssh admin@<any db ip> sudo systemctl start pg-backup.service
ssh admin@<monitor ip> sudo systemctl start pg-restore-test.service
ssh admin@<monitor ip> sudo journalctl -u pg-restore-test -n 5
```

## Connect an application

```sh
terraform output -raw app_connection_string
```

The string lists all three servers with `target_session_attrs=read-write`. The PostgreSQL driver tries each and
keeps the one that accepts writes, so after a failover the application reconnects on its own. There is no load
balancer or floating address to fail. Supported by libpq (psql, psycopg, PHP, Ruby pg), pgx and the JDBC driver
(`targetServerType=primary`).

The application must be on the private network (`upcloud_network.private`): attach its servers to it.

## Run the failover drill

```sh
./drill/failover-drill.sh
```

It writes one row every 0.2 seconds, powers off the primary after 30 seconds without a shutdown, and prints the
longest time without a successful write and the number of confirmed rows that are missing afterwards. With
synchronous replication that number must be 0.

## See the monitoring

```sh
ssh -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 admin@<monitor ip>
```

Prometheus is then at http://localhost:9090 and Alertmanager at http://localhost:9093. Set `alert_webhook_url`
to have alerts delivered.

## What this is not, yet

Read this before using it for something real.

- **Traffic inside the private network is not encrypted** (PostgreSQL, etcd, Patroni's API). Anyone who can
  attach a server to that network can read it. TLS between the parts is the next piece of work.
- **etcd has no authentication.** Same boundary: the private network.
- **Passwords live in the Terraform state and in each server's user data.** Keep the state somewhere private and
  encrypted. The backup passphrase is there too: store a second copy elsewhere, or a lost state file means
  unreadable backups.
- **Losing all three servers at once loses the newest writes.** WAL reaches the bucket when a segment fills or after 60 seconds, whichever is first, so up to about a minute of confirmed writes can be gone. A single server failing loses nothing.
- **Losing the Terraform state as well is not tested.** The bucket and its keys are created by this Terraform; with the state gone you would import the object storage into a new state first. Keep the state and the backup passphrase in two places.
- **One zone.** It survives a server or a physical host failing, not a whole data centre. Backups are in object
  storage and survive that; the running cluster does not.
- **Database servers have public addresses** for packages and for SSH. Inbound is closed by the firewall on each
  server, but a NAT gateway and a jump host would be tighter.
- **No connection pooler.** Add PgBouncer on the application side if you open many connections.
- **No dashboards.** Prometheus and alerts only.
- **The packaged metrics exporter is old** (0.15, from Ubuntu). One collector is switched off for PostgreSQL 17+, and on replicas it logs a harmless error about replication slots.
- **No major-version upgrade procedure** yet. Minor versions: see the runbook.

## Files

- `main.tf`, `variables.tf`, `outputs.tf`: the infrastructure.
- `scripts/common.sh`: firewall, packages and backup settings, on every server.
- `scripts/db-node.sh`: etcd, Patroni, backups and exporters on a database server.
- `scripts/monitor-node.sh`: Prometheus, alert rules, the restore test.
- `drill/failover-drill.sh`: the failover drill.
- `RUNBOOK.md`: what to do when an alert fires.

## Licence

Apache-2.0. No warranty: test it on your own data before you trust it.

Built by [MoveInfra](https://moveinfra.eu). If you would rather have this installed in your account and kept
running for you, that is what we do.
