# ── VPC ──────────────────────────────────────────────────────────────────────

resource "digitalocean_vpc" "main" {
  name     = "${var.project_name}-vpc"
  region   = var.region
  ip_range = var.vpc_cidr
}

# ── DOKS Cluster ─────────────────────────────────────────────────────────────

resource "digitalocean_kubernetes_cluster" "main" {
  name    = var.project_name
  region  = var.region
  version = var.k8s_version
  vpc_uuid = digitalocean_vpc.main.id

  cluster_subnet = var.cluster_subnet
  service_subnet = var.service_subnet

  destroy_all_associated_resources = true

  node_pool {
    name       = "mgmt"
    size       = var.mgmt_node_size
    node_count = var.mgmt_node_count
  }
}

# ── GPU Node Pool ─────────────────────────────────────────────────────────────

resource "digitalocean_kubernetes_node_pool" "gpu" {
  count      = var.gpu_node_count > 0 ? 1 : 0
  cluster_id = digitalocean_kubernetes_cluster.main.id
  name       = "gpu"
  size       = var.gpu_node_size
  node_count = var.gpu_node_count

  taint {
    key    = "node.digitalocean.com/network-not-tuned"
    value  = "true"
    effect = "NoSchedule"
  }
}

# ── MySQL Cluster ────────────────────────────────────────────────────────────

resource "digitalocean_database_cluster" "mysql" {
  name                 = "${var.project_name}-mysql"
  engine               = "mysql"
  version              = "8"
  size                 = var.db_size
  region               = var.region
  node_count           = var.db_node_count
  private_network_uuid = digitalocean_vpc.main.id
}

resource "digitalocean_database_db" "slurm_acct" {
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = var.db_name
}

resource "digitalocean_database_user" "slurm" {
  cluster_id         = digitalocean_database_cluster.mysql.id
  name               = var.db_user
  mysql_auth_plugin  = var.db_mysql_auth_plugin
}

resource "digitalocean_database_firewall" "mysql" {
  cluster_id = digitalocean_database_cluster.mysql.id

  rule {
    type  = "k8s"
    value = digitalocean_kubernetes_cluster.main.id
  }
}

# ── NFS Share ────────────────────────────────────────────────────────────────

resource "digitalocean_nfs" "shared" {
  region           = var.region
  name             = "${var.project_name}-nfs"
  size             = var.nfs_size_gib
  vpc_id           = digitalocean_vpc.main.id
  performance_tier = var.nfs_performance_tier

  lifecycle {
    ignore_changes = [performance_tier]
  }
}
