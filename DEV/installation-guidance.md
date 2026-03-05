# Deploying Slinky (Slurm on Kubernetes) on DigitalOcean DOKS

This guide covers the DOKS-specific setup required to deploy SchedMD's Slinky operator and a Slurm cluster on DigitalOcean Kubernetes. It complements the [official Slinky installation guide](https://github.com/SlinkyProject/slurm-operator) with infrastructure decisions, node scheduling, managed services, and shared storage that the upstream docs do not address.

---

## 1. Infrastructure Prerequisites

Create the following DigitalOcean resources before installing any Helm charts.

### VPC

[Create a VPC](https://docs.digitalocean.com/products/networking/vpc/how-to/create/) in a region that supports managed NFS such as **atl1**.

### DOKS Cluster

[Create a Kubernetes cluster](https://docs.digitalocean.com/products/kubernetes/how-to/create-clusters/) in the same VPC with two node pools:

| Pool | Purpose | Suggested size | Count |
|------|---------|---------------|-------|
| **mgmt** | Slurm control plane, operator, monitoring, login nodes | CPU Optimized 4 vCPU / 8 GiB | 3 |
| **gpu** | Slurm worker nodes (training jobs) | GPU Droplets (e.g., H200, Mi325x) | 2+ |

### GPU Node Taints and Labels (DOKS-managed)

DOKS automatically applies taints and labels to GPU node pools:

| GPU vendor | Auto-applied taint | Auto-applied labels |
|---|---|---|
| NVIDIA | `nvidia.com/gpu:NoSchedule` | `doks.digitalocean.com/gpu-brand: nvidia`, `doks.digitalocean.com/gpu-model: <model>` |
| AMD | `amd.com/gpu:NoSchedule` | `doks.digitalocean.com/gpu-brand: amd`, `doks.digitalocean.com/gpu-model: <model>` |

These taints prevent non-GPU workloads from landing on expensive GPU nodes. Your Slurm worker pods must carry matching tolerations (shown in Section 6).

> **Deployment assumption:** This guide assumes a two-tier layout — one **mgmt** pool of CPU nodes and one or more **GPU** node pools. Since GPU pools carry automatic taints, all non-GPU workloads (Slurm control plane, monitoring, cert-manager, etc.) will naturally schedule on the mgmt nodes without requiring explicit `nodeSelector` rules. If you add untainted CPU-only worker pools, you may need `nodeSelector` or affinity rules to keep infrastructure pods off those nodes.

### Accounting Database (optional — required only for Slurm accounting)

If you want job accounting (`sacct`, `sreport`, fair-share scheduling), you have two options:

**Option A — In-cluster MariaDB (dev/test only):**
The Slinky Helm chart can deploy a MariaDB instance automatically inside the cluster. Simply enable accounting without providing a `storageConfig` block and the chart handles the rest. This is convenient for quick experiments but is **not recommended for production** because the database lifecycle is tied to the Helm release and does not offer managed backups or high availability.

**Option B — Managed MySQL (recommended for production):**
[Create a managed MySQL database](https://docs.digitalocean.com/products/databases/mysql/how-to/create/) in the same VPC. The accounting DB is lightweight — it stores job records, association/QOS metadata, and periodic usage rollups. Write volume is low (roughly one insert per job start and end), so a **single-node, smallest-size instance** (1 vCPU / 1 GB RAM) is sufficient to start with for most clusters. The main benefit of a managed DB is durability, automated backups, and high-availability options as you scale.

- **Engine:** MySQL 8
- **Size:** db-s-1vcpu-1gb (smallest; scale up only if needed)
- **Storage:** 10 GB (sufficient for millions of job records)
- **Connection:** Use the **private host** (VPC network), default managed port `25060`

The managed instance ships with a default `doadmin` user and `defaultdb` database. You need to [add a database and user](https://docs.digitalocean.com/products/databases/mysql/how-to/manage-users-and-databases/) for Slurm:

- **Database name:** `slurm_acct`
- **User:** `slurm`

After creating the user, store its password as a Kubernetes secret (see Section 2).

[Configure trusted sources](https://docs.digitalocean.com/products/databases/mysql/how-to/secure/) on the database to restrict connections to your DOKS cluster and any bastion hosts that need access.

### Managed NFS

The Slurm cluster uses a shared NFS volume mounted across login and worker pods for home directories, job scripts, and shared data. This gives users a familiar HPC experience where files written on a login node are immediately visible to running jobs.

[Create a managed NFS file system](https://docs.digitalocean.com/products/nfs/how-to/create/) in the same VPC. Note that NFS performance scales with the size of the share. Larger shares get higher throughput and IOPS. For a PoC or small workloads, the smallest tier is fine; for production workloads with heavy I/O, size up accordingly.

Note the *Mount Source** from the NFS resource as you will need these for the PV definition in step 4.

---

## 2. Namespace Layout

Create the Slurm namespace:

```bash
kubectl create namespace slurm        # Slinky operator + Slurm cluster
```

cert-manager and kube-prometheus-stack use `--create-namespace` in their Helm install commands to create their namespaces automatically.

If using Slurm accounting (see Section 1), create the database password secret now:

```bash
kubectl create secret generic slurm-db-password \
  --namespace slurm \
  --from-literal=password='<mysql-password>'
```

---

## 3. Prerequisite Helm Charts

Slinky requires **cert-manager** (for webhook TLS) and benefits from **kube-prometheus-stack** (for Slurm metrics and Grafana dashboards). Both should run on management nodes.

### cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

### kube-prometheus-stack

Create `prometheus-values.yaml` to use with helm install below:

```yaml
prometheus:
  prometheusSpec:
    retention: 7d

# Node-exporter runs on ALL nodes (DaemonSet) — tolerate GPU taints
prometheus-node-exporter:
  tolerations:
    - operator: Exists
```

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace prometheus --create-namespace \
  --values prometheus-values.yaml
```



---

## 4. NFS Shared Storage

The official Slinky guide does not cover shared storage. For job scripts, input data, and output files, create a PersistentVolume backed by the managed NFS and a PersistentVolumeClaim that login and worker pods will mount. `server` and `path` values come form the NFS **Mount Source** in the console. 

```yaml
# slurm-nfs-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: slurm-nfs-pv
spec:
  capacity:
    storage: 100Gi # Scheduler hint only (NFS won’t enforce quota)
  accessModes:
    - ReadWriteMany
  storageClassName: "" 
  mountOptions:
    - vers=4.1
    - nconnect=8
  nfs:
    server: <nfs-private-ip>       # e.g., 10.100.32.2
    path: <nfs-mount-path>         # e.g. /2633050/31489843-2785-4493-9ed4-8c9526627981
---
# slurm-nfs-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: slurm-nfs-pvc
  namespace: slurm
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""             # Bind to the static PV
  volumeName: slurm-nfs-pv
  resources:
    requests:
      storage: 100Gi
```

```bash
kubectl apply -f slurm-nfs-pv.yaml
kubectl apply -f slurm-nfs-pvc.yaml
```

Verify the PVC is **Bound** before proceeding:

```bash
kubectl get pvc -n slurm slurm-nfs-pvc
```

---

## 5. Slinky Operator

Install the Slinky operator. The CRDs can be installed as a subchart by setting `crds.enabled=true`:

```bash
helm install slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --set 'crds.enabled=true' \
  --namespace slurm
```

---

## 6. Slurm Cluster

Deploy the Slurm cluster with all DOKS-specific customizations.


Create `slurm-values.yaml` to use with helm install:

```yaml
# ── Controller (slurmctld) ──────────────────────────────────────────────
controller:
  extraConfMap:
    ReturnToService: 2       # Auto-return nodes after transient failures
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      labels:
        release: prometheus  # Must match your Prometheus Helm release name

# ── Accounting (slurmdbd) ──
# Omit this entire block if you do not need accounting.
# If accounting is enabled but storageConfig is omitted, Slinky deploys an
# in-cluster MariaDB automatically (suitable for dev/test only).
# The storageConfig below points to a managed MySQL instance (recommended
# for production).
accounting:
  enabled: true
  storageConfig:
    host: <mysql-private-host>     # <-- REPLACE with managed MySQL private hostname
    port: 25060                    # <-- REPLACE if your managed DB uses a different port
    database: slurm_acct
    username: slurm
    passwordKeyRef:
      name: slurm-db-password      # Secret created in step 1
      key: password

# ── Login Nodes ─────────────────────────────────────────────────────────
loginsets:
  slinky:
    enabled: true
    login:
      volumeMounts:
        - name: shared-nfs
          mountPath: /shared
    podSpec:
      volumes:
        - name: shared-nfs
          persistentVolumeClaim:
            claimName: slurm-nfs-pvc
    service:
      spec:
        type: ClusterIP

# ── GPU Worker Nodes ───────────────────────────────────────────────
#
# AMD example shown below. For NVIDIA nodes, replace:
#   - amd.com/gpu → nvidia.com/gpu  (in tolerations)
#   - gpu-brand label value → nvidia  (in nodeSelector)
#
nodesets:
  slinky:
    replicas: 4                    # <-- REPLACE with your GPU node count
    slurmd:
      volumeMounts:
        - name: shared-nfs
          mountPath: /shared
    partition:
      configMap:
        State: UP
        MaxTime: UNLIMITED
    podSpec:
      nodeSelector:
        doks.digitalocean.com/gpu-brand: amd  # <-- REPLACE with nvidia for NVIDIA nodes
      tolerations:
        - key: amd.com/gpu          # <-- REPLACE with nvidia.com/gpu for NVIDIA nodes
          operator: Exists
          effect: NoSchedule
      volumes:
        - name: shared-nfs
          persistentVolumeClaim:
            claimName: slurm-nfs-pvc
```

```bash
helm install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --namespace slurm \
  --values slurm-values.yaml
```

---

## 7. Verification

After all Helm installs complete, run through these checks:

### Operator

```bash
kubectl get pods -n slurm -l app.kubernetes.io/name=slurm-operator
# Both operator and webhook pods should be Running on mgmt nodes
```

### Slurm Components

```bash
kubectl get pods -n slurm
# Expected: controller, accounting, restapi, login, and worker pods all Running
```

### Node Health

```bash
# Exec into the login pod
kubectl exec -it -n slurm deploy/slurm-login-slinky -- bash

# Inside the pod:
sinfo -N -l
# All nodes should show "idle" state
```

### Accounting

```bash
# Inside a login pod:
sacctmgr show cluster
# Should show your cluster registered with the managed MySQL backend
```

### Shared Storage

```bash
# From a login pod:
echo "hello" > /shared/test.txt

# From a worker pod:
kubectl exec -it -n slurm slurm-worker-slinky-0 -- cat /shared/test.txt
# Should print "hello"
```

### REST API

```bash
# From a login pod, generate a JWT token:
scontrol token lifespan=600

# Port-forward slurmrestd:
kubectl port-forward -n slurm svc/slurm-restapi 6820:6820 &

# Query the API (from your local machine):
curl -s -H "X-SLURM-USER-NAME: root" \
     -H "X-SLURM-USER-TOKEN: <token>" \
     http://localhost:6820/slurmdb/v0.0.43/clusters | jq .
```

### Metrics

```bash
# Port-forward Grafana:
kubectl port-forward -n prometheus svc/prometheus-grafana 3000:80

# Retrieve the admin password:
kubectl get secret -n prometheus prometheus-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d

# Open http://localhost:3000, log in, and verify Slurm metrics appear
# in the Prometheus data source (search for metrics prefixed with slurm_)
```
