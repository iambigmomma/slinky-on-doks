variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "nyc2"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "slinky-poc"
}

# ── VPC ──────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.100.32.0/20"
}

# ── Kubernetes ───────────────────────────────────────────────────────────────

variable "k8s_version" {
  description = "DOKS Kubernetes version slug"
  type        = string
  default     = "1.34.1-do.5"
}

variable "cluster_subnet" {
  description = "CIDR for Kubernetes pod network"
  type        = string
  default     = "10.156.0.0/16"
}

variable "service_subnet" {
  description = "CIDR for Kubernetes service network"
  type        = string
  default     = "10.157.0.0/16"
}

variable "mgmt_node_size" {
  description = "Droplet size for management node pool"
  type        = string
  default     = "c-4"
}

variable "mgmt_node_count" {
  description = "Number of management nodes"
  type        = number
  default     = 3
}

variable "compute_node_size" {
  description = "Droplet size for compute node pool"
  type        = string
  default     = "c-4"
}

variable "compute_node_count" {
  description = "Number of compute nodes"
  type        = number
  default     = 4
}

# ── Database ─────────────────────────────────────────────────────────────────

variable "db_size" {
  description = "Database droplet size slug"
  type        = string
  default     = "db-s-1vcpu-2gb"
}

variable "db_node_count" {
  description = "Number of database nodes"
  type        = number
  default     = 1
}

variable "db_name" {
  description = "Name of the Slurm accounting database"
  type        = string
  default     = "slurm_acct"
}

variable "db_user" {
  description = "Database user for Slurm"
  type        = string
  default     = "slurm"
}

variable "db_mysql_auth_plugin" {
  description = "MySQL authentication plugin"
  type        = string
  default     = "caching_sha2_password"
}

# ── NFS ──────────────────────────────────────────────────────────────────────

variable "nfs_size_gib" {
  description = "NFS share size in GiB"
  type        = number
  default     = 1024
}

variable "nfs_performance_tier" {
  description = "NFS performance tier"
  type        = string
  default     = "high"
}
