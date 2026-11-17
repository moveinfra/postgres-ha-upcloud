locals {
  public_ip = { for s in concat(upcloud_server.db, [upcloud_server.monitor]) :
  s.hostname => [for n in s.network_interface : n.ip_address if n.type == "public"][0] }
}

output "ssh" {
  description = "SSH targets (reachable from admin_cidr only)"
  value       = { for host, ip in local.public_ip : host => "admin@${ip}" }
}

output "private_ips" {
  value = { db = local.db_ips, monitor = local.monitor_ip }
}

output "app_connection_string" {
  description = "For applications on the private network. The driver tries each host and keeps the one that accepts writes, so a failover needs no change on the client."
  value       = "postgresql://app:${random_password.pg["app"].result}@${join(",", [for ip in local.db_ips : "${ip}:5432"])}/app?target_session_attrs=read-write&connect_timeout=3"
  sensitive   = true
}

output "backup_bucket" {
  value = "s3://${upcloud_managed_object_storage_bucket.backup.name} at ${local.s3_host}"
}

output "backup_cipher" {
  description = "Backups are encrypted with this passphrase. Store a copy outside this state file: without it the backups cannot be read."
  value       = random_password.backup_cipher.result
  sensitive   = true
}

output "name" {
  value = var.name
}
