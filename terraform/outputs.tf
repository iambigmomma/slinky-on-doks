# ── Cluster ───────────────────────────────────────────────────────────────────

output "cluster_id" {
  description = "DOKS cluster ID"
  value       = digitalocean_kubernetes_cluster.main.id
}

output "cluster_endpoint" {
  description = "DOKS cluster API endpoint"
  value       = digitalocean_kubernetes_cluster.main.endpoint
}

output "cluster_name" {
  description = "DOKS cluster name"
  value       = digitalocean_kubernetes_cluster.main.name
}

output "kubeconfig" {
  description = "Kubeconfig for the DOKS cluster"
  value       = digitalocean_kubernetes_cluster.main.kube_config[0].raw_config
  sensitive   = true
}

output "k8s_version" {
  description = "Kubernetes version"
  value       = digitalocean_kubernetes_cluster.main.version
}

# ── VPC ──────────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = digitalocean_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = digitalocean_vpc.main.ip_range
}

# ── Database ─────────────────────────────────────────────────────────────────

output "db_host" {
  description = "MySQL private hostname"
  value       = digitalocean_database_cluster.mysql.private_host
}

output "db_port" {
  description = "MySQL port"
  value       = digitalocean_database_cluster.mysql.port
}

output "db_name" {
  description = "MySQL database name"
  value       = digitalocean_database_db.slurm_acct.name
}

output "db_user" {
  description = "MySQL user"
  value       = digitalocean_database_user.slurm.name
}

output "db_password" {
  description = "MySQL password"
  value       = digitalocean_database_user.slurm.password
  sensitive   = true
}

# ── NFS ──────────────────────────────────────────────────────────────────────

output "nfs_host" {
  description = "NFS server hostname"
  value       = digitalocean_nfs.shared.host
}

output "nfs_mount_path" {
  description = "NFS mount path"
  value       = digitalocean_nfs.shared.mount_path
}

output "nfs_id" {
  description = "NFS share ID"
  value       = digitalocean_nfs.shared.id
}
