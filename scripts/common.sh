# ---- common.sh: runs first on every node (as root, once, from cloud-init) ----
set -euo pipefail
exec >>/var/log/pg-ha-setup.log 2>&1
chmod 600 /etc/pg-ha.env /var/log/pg-ha-setup.log
umask 022 # the env file above was written under 077; from here on files are world-readable unless chmod says otherwise
set -a
# shellcheck disable=SC1091
. /etc/pg-ha.env
set +a
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
PGBIN=/usr/lib/postgresql/$PG_VERSION/bin
PGDATA=/var/lib/postgresql/$PG_VERSION/main
TEXTFILE_DIR=/var/lib/prometheus/node-exporter
echo "== $(date -Is) setup of $NODE_NAME starts"

# Firewall before anything listens: SSH from the admin range, everything from the private network, nothing else.
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$ADMIN_CIDR" to any port 22 proto tcp
ufw allow from "$PRIVATE_CIDR"
ufw --force enable
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || true # socket-activated on Ubuntu 24.04: nothing to reload until the first connection

# The private address must be up; everything binds to it.
for _ in $(seq 60); do
  ip -4 -o addr | grep -q " $NODE_IP/" && break
  sleep 2
done
ip -4 -o addr | grep -q " $NODE_IP/" || { echo "private address $NODE_IP never came up"; exit 1; }

# Packages must not start services with their default settings; we start each one after writing its config.
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get update
apt-get install -y curl ca-certificates jq gnupg postgresql-common
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
mkdir -p /etc/postgresql-common/createcluster.d
echo "create_main_cluster = false" >/etc/postgresql-common/createcluster.d/pg-ha.conf
apt-get install -y "postgresql-$PG_VERSION" pgbackrest prometheus-node-exporter unattended-upgrades
systemctl disable postgresql.service || true

# Backup repository settings: the same on every node, so any node can back up, restore or rebuild itself.
write_pgbackrest_conf() { # $1 = data directory this node restores into or backs up from
  mkdir -p /etc/pgbackrest
  chmod 755 /etc/pgbackrest
  rm -f /etc/pgbackrest.conf
  cat >/etc/pgbackrest/pgbackrest.conf <<CONF
[global]
repo1-type=s3
repo1-s3-endpoint=$S3_ENDPOINT
repo1-s3-region=$S3_REGION
repo1-s3-bucket=$S3_BUCKET
repo1-s3-key=$S3_KEY
repo1-s3-key-secret=$S3_SECRET
repo1-s3-uri-style=path
repo1-path=/$CLUSTER
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=$BACKUP_CIPHER
repo1-retention-full=2
repo1-retention-diff=6
start-fast=y
process-max=2
compress-type=zst
log-level-console=warn
log-level-file=info

[main]
pg1-path=$1
CONF
  chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
  chmod 600 /etc/pgbackrest/pgbackrest.conf
}

# A metric file the postgres user may write; node_exporter publishes it.
metric_file() {
  mkdir -p "$TEXTFILE_DIR"
  touch "$TEXTFILE_DIR/$1"
  chown postgres:postgres "$TEXTFILE_DIR/$1"
  chmod 644 "$TEXTFILE_DIR/$1"
}
