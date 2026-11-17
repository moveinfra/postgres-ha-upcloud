variable "name" {
  description = "Prefix for every resource and the Patroni cluster name"
  type        = string
  default     = "pg-ha"
}

variable "zone" {
  description = "UpCloud zone for the servers, e.g. fi-hel1 or de-fra1"
  type        = string
  default     = "fi-hel1"
}

variable "object_storage_region" {
  description = "UpCloud Managed Object Storage region for backups, e.g. europe-1"
  type        = string
  default     = "europe-1"
}

variable "db_plan" {
  description = "Server plan for each of the three database nodes"
  type        = string
  default     = "2xCPU-4GB"
}

variable "monitor_plan" {
  description = "Server plan for the monitoring and restore-test node"
  type        = string
  default     = "1xCPU-2GB"
}

variable "db_disk_gb" {
  description = "Disk size of each database node"
  type        = number
  default     = 80
}

variable "monitor_disk_gb" {
  description = "Disk size of the monitoring node. The restore test needs room for a full copy of the database."
  type        = number
  default     = 50
}

variable "pg_version" {
  description = "PostgreSQL major version, installed from apt.postgresql.org"
  type        = string
  default     = "18"
}

variable "admin_ssh_key" {
  description = "Public SSH key for the admin user on every node"
  type        = string
}

variable "admin_cidr" {
  description = "The only address range allowed to reach SSH, e.g. 203.0.113.7/32"
  type        = string
}

variable "private_cidr" {
  description = "Private network the cluster talks on. Clients must be attached to it."
  type        = string
  default     = "10.10.0.0/24"
}

variable "synchronous" {
  description = "true: a write is confirmed only after a second node has it (no confirmed write is lost on failover). false: faster writes, up to a few seconds may be lost."
  type        = bool
  default     = true
}

variable "alert_webhook_url" {
  description = "Alertmanager sends alerts here as a JSON POST (ntfy, Slack-compatible relay, your own endpoint). Empty: alerts are only visible in the Alertmanager UI."
  type        = string
  default     = ""
}
