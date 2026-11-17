# Production PostgreSQL on UpCloud: three nodes with automatic failover (Patroni + etcd), backups to object
# storage (pgBackRest), one monitoring node (Prometheus + Alertmanager) that also runs the weekly restore test.

locals {
  db_ips     = [for i in range(3) : cidrhost(var.private_cidr, 11 + i)]
  monitor_ip = cidrhost(var.private_cidr, 5)
  image      = "Ubuntu Server 24.04 LTS (Noble Numbat)"
  s3_host    = [for e in upcloud_managed_object_storage.backup.endpoint : e.domain_name if e.type == "public"][0]

  # Shared settings, written to /etc/pg-ha.env on every node (root only). The scripts read them from there.
  common_env = {
    CLUSTER           = var.name
    PG_VERSION        = var.pg_version
    PRIVATE_CIDR      = var.private_cidr
    ADMIN_CIDR        = var.admin_cidr
    DB_IPS            = join(" ", local.db_ips)
    MONITOR_IP        = local.monitor_ip
    SYNCHRONOUS       = var.synchronous
    S3_ENDPOINT       = local.s3_host
    S3_REGION         = var.object_storage_region
    S3_BUCKET         = upcloud_managed_object_storage_bucket.backup.name
    S3_KEY            = upcloud_managed_object_storage_user_access_key.backup.access_key_id
    S3_SECRET         = upcloud_managed_object_storage_user_access_key.backup.secret_access_key
    BACKUP_CIPHER     = random_password.backup_cipher.result
    PW_SUPERUSER      = random_password.pg["superuser"].result
    PW_REPLICATION    = random_password.pg["replication"].result
    PW_REWIND         = random_password.pg["rewind"].result
    PW_MONITOR        = random_password.pg["monitor"].result
    PW_APP            = random_password.pg["app"].result
    ALERT_WEBHOOK_URL = var.alert_webhook_url
  }
}

resource "random_password" "pg" {
  for_each = toset(["superuser", "replication", "rewind", "monitor", "app"])
  length   = 32
  special  = false
}

resource "random_password" "backup_cipher" {
  length  = 48
  special = false
}

# ---------- network ----------

resource "upcloud_network" "private" {
  name = "${var.name}-private"
  zone = var.zone

  ip_network {
    address            = var.private_cidr
    dhcp               = true
    dhcp_default_route = false
    family             = "IPv4"
  }
}

# ---------- backup storage ----------

resource "upcloud_managed_object_storage" "backup" {
  name              = "${var.name}-backup"
  region            = var.object_storage_region
  configured_status = "started"

  network {
    family = "IPv4"
    name   = "public"
    type   = "public"
  }
}

resource "upcloud_managed_object_storage_bucket" "backup" {
  service_uuid = upcloud_managed_object_storage.backup.id
  name         = "${var.name}-pgbackrest"
}

resource "upcloud_managed_object_storage_user" "backup" {
  service_uuid = upcloud_managed_object_storage.backup.id
  username     = "${var.name}-pgbackrest"
}

resource "upcloud_managed_object_storage_user_policy" "backup" {
  service_uuid = upcloud_managed_object_storage.backup.id
  username     = upcloud_managed_object_storage_user.backup.username
  name         = "ECSS3FullAccess"
}

resource "upcloud_managed_object_storage_user_access_key" "backup" {
  service_uuid = upcloud_managed_object_storage.backup.id
  username     = upcloud_managed_object_storage_user.backup.username
  status       = "Active"
}

# ---------- database nodes ----------

# Each node sits on a different physical host, so one host failure takes out one node at most.
resource "upcloud_server_group" "db" {
  title                = "${var.name}-db"
  anti_affinity_policy = "strict"
  track_members        = false
}

resource "upcloud_server" "db" {
  count        = 3
  hostname     = "${var.name}-${count.index + 1}"
  zone         = var.zone
  plan         = var.db_plan
  metadata     = true
  firewall     = false # the nodes run their own firewall (ufw), set up before anything listens
  server_group = upcloud_server_group.db.id

  template {
    storage = local.image
    size    = var.db_disk_gb
  }

  network_interface {
    type = "public" # outbound only: packages and the backup bucket. Inbound is SSH from admin_cidr.
  }

  network_interface {
    type       = "private"
    network    = upcloud_network.private.id
    ip_address = local.db_ips[count.index]
  }

  login {
    user            = "admin"
    keys            = [var.admin_ssh_key]
    create_password = false
  }

  user_data = join("\n", [
    "#!/bin/bash",
    "umask 077",
    "cat > /etc/pg-ha.env <<'PGHAENV'",
    join("\n", [for k, v in merge(local.common_env, {
      NODE_NAME = "${var.name}-${count.index + 1}"
      NODE_IP   = local.db_ips[count.index]
    }) : "${k}='${v}'"]),
    "PGHAENV",
    file("${path.module}/scripts/common.sh"),
    file("${path.module}/scripts/db-node.sh"),
  ])

  lifecycle {
    ignore_changes = [user_data] # a node is set up once; changing the script must not rebuild a database server
  }
}

# ---------- monitoring and restore-test node ----------

resource "upcloud_server" "monitor" {
  hostname = "${var.name}-monitor"
  zone     = var.zone
  plan     = var.monitor_plan
  metadata = true
  firewall = false

  template {
    storage = local.image
    size    = var.monitor_disk_gb
  }

  network_interface {
    type = "public"
  }

  network_interface {
    type       = "private"
    network    = upcloud_network.private.id
    ip_address = local.monitor_ip
  }

  login {
    user            = "admin"
    keys            = [var.admin_ssh_key]
    create_password = false
  }

  user_data = join("\n", [
    "#!/bin/bash",
    "umask 077",
    "cat > /etc/pg-ha.env <<'PGHAENV'",
    join("\n", [for k, v in merge(local.common_env, {
      NODE_NAME = "${var.name}-monitor"
      NODE_IP   = local.monitor_ip
    }) : "${k}='${v}'"]),
    "PGHAENV",
    file("${path.module}/scripts/common.sh"),
    file("${path.module}/scripts/monitor-node.sh"),
  ])

  lifecycle {
    ignore_changes = [user_data]
  }
}
