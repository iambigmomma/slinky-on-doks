# Deploying Slinky (Slurm on Kubernetes) on DigitalOcean DOKS

This guide covers the DOKS-specific setup required to deploy SchedMD's Slinky operator and a Slurm cluster on DigitalOcean Kubernetes. It complements the [official Slinky installation guide](https://github.com/SlinkyProject/slurm-operator) with infrastructure decisions, node scheduling, managed services, and shared storage that the upstream docs do not address.

---

## 1. Infrastructure Prerequisites

Create the following DigitalOcean resources before installing any Helm charts.

### VPC

Create a VPC in a region that supports managed NFS such as **atl1**.

### DOKS Cluster

Create a Kubernetes cluster in the same VPC with two node pools:

| Pool | Purpose | Suggested size | Count |
|------|---------|---------------|-------|
| **mgmt** | Slurm control plane, operator, monitoring, login nodes | General-purpose 4 vCPU / 8 GiB | 3 |
| **gpu** | Slurm worker nodes (training jobs) | GPU Droplets (e.g., H200, Mi325x) | 4+ |

### GPU Node Taints and Labels (DOKS-managed)

DOKS automatically applies taints and labels to GPU node pools:

| GPU vendor | Auto-applied taint | Auto-applied labels |
|---|---|---|
| NVIDIA | `nvidia.com/gpu:NoSchedule` | `doks.digitalocean.com/gpu-brand: nvidia`, `doks.digitalocean.com/gpu-model: <model>` |
| AMD | `amd.com/gpu:NoSchedule` | `doks.digitalocean.com/gpu-brand: amd`, `doks.digitalocean.com/gpu-model: <model>` |

These taints prevent non-GPU workloads from landing on expensive GPU nodes. Your Slurm worker pods must carry matching tolerations (shown in Section 6).

### GPU Device Plugin

**NVIDIA nodes:** DOKS pre-installs the NVIDIA drivers, CUDA toolkit, and container toolkit, but you must deploy the [NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin) via Helm so that `nvidia.com/gpu` resources appear in the kubelet:

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

helm install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --set tolerations[0].key=nvidia.com/gpu \
  --set tolerations[0].operator=Exists \
  --set tolerations[0].effect=NoSchedule
```

> You do **not** need the full NVIDIA GPU Operator — DOKS handles drivers and the container toolkit.

**AMD nodes:** DOKS automatically deploys the ROCm drivers and the AMD device plugin. No additional installation is required — `amd.com/gpu` resources are available out of the box.

### Managed MySQL (optional — required only for Slurm accounting)

If you want job accounting (`sacct`, `sreport`, fair-share scheduling), create a managed MySQL database in the same VPC:

- **Engine:** MySQL 8
- **Database name:** `slurm_acct`
- **User:** `slurm`
- **Connection:** Use the **private host** (VPC network), default managed port `25060`

After creation, store the password as a Kubernetes secret (see Section 2).

### Managed NFS

Create a managed NFS file system in the same VPC. Note the **private IP** and **mount path** from the NFS resource — you will need these for the PV definition in step 4.

---

## 2. Namespace Layout

Create two namespaces:

```bash
kubectl create namespace slurm        # Slinky operator + Slurm cluster
kubectl create namespace prometheus   # Monitoring stack
```

cert-manager installs into its own namespace by default (`cert-manager`).

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
  --set crds.enabled=true \
  --values cert-manager-values.yaml
```

`cert-manager-values.yaml` — pin all components to management nodes:

```yaml
# Controller (top-level keys — not nested under controller:)
nodeSelector:
  doks.digitalocean.com/node-pool: mgmt

webhook:
  nodeSelector:
    doks.digitalocean.com/node-pool: mgmt

cainjector:
  nodeSelector:
    doks.digitalocean.com/node-pool: mgmt

startupapicheck:
  nodeSelector:
    doks.digitalocean.com/node-pool: mgmt
```

### kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace prometheus \
  --values prometheus-values.yaml
```

`prometheus-values.yaml` — schedule control-plane components on mgmt nodes, node-exporter everywhere:

```yaml
prometheus:
  prometheusSpec:
    nodeSelector:
      doks.digitalocean.com/node-pool: mgmt
    retention: 7d

alertmanager:
  alertmanagerSpec:
    nodeSelector:
      doks.digitalocean.com/node-pool: mgmt

grafana:
  nodeSelector:
    doks.digitalocean.com/node-pool: mgmt

kube-state-metrics:
  nodeSelector:
    doks.digitalocean.com/node-pool: mgmt

prometheusOperator:
  nodeSelector:
    doks.digitalocean.com/node-pool: mgmt
  admissionWebhooks:
    patch:
      nodeSelector:
        doks.digitalocean.com/node-pool: mgmt

# Node-exporter runs on ALL nodes (DaemonSet)
prometheus-node-exporter:
  tolerations:
    - operator: Exists
```

---

## 4. NFS Shared Storage

The official Slinky guide does not cover shared storage. For job scripts, input data, and output files, create a PersistentVolume backed by the managed NFS and a PersistentVolumeClaim that login and worker pods will mount.

```yaml
# slurm-nfs-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: slurm-nfs-pv
spec:
  capacity:
    storage: 100Gi          # Adjust to your NFS size
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: <nfs-private-ip>       # e.g., 10.100.32.2
    path: <nfs-mount-path>         # from NFS resource details
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

Install the Slinky operator with node affinity set to management nodes.

```bash
helm install slinky-operator oci://ghcr.io/slinkyproject/charts/slinky-operator \
  --namespace slurm \
  --values values-operator.yaml
```

`values-operator.yaml`:

```yaml
operator:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: doks.digitalocean.com/node-pool
                operator: In
                values: [mgmt]

webhook:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: doks.digitalocean.com/node-pool
                operator: In
                values: [mgmt]
```

---

## 6. Slurm Cluster

Deploy the Slurm cluster with all DOKS-specific customizations.

```bash
helm install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --namespace slurm \
  --values values-slurm.yaml
```

`values-slurm.yaml` — full annotated example:

```yaml
# ── Controller (slurmctld) ──────────────────────────────────────────────
controller:
  persistence:
    enabled: true
    storageClassName: null   # Uses default StorageClass (do-block-storage)
  extraConfMap:
    ReturnToService: 2       # Auto-return nodes after transient failures
  podSpec:
    nodeSelector:
      doks.digitalocean.com/node-pool: mgmt
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      labels:
        release: prometheus  # Must match your Prometheus Helm release name
      interval: 30s

# ── REST API (slurmrestd) ───────────────────────────────────────────────
restapi:
  replicas: 1
  podSpec:
    nodeSelector:
      doks.digitalocean.com/node-pool: mgmt

# ── Accounting (slurmdbd) — omit this block if not using accounting ──
accounting:
  enabled: true
  storageConfig:
    host: <mysql-private-host>     # Managed MySQL private hostname
    port: 25060                    # Managed MySQL default port
    database: slurm_acct
    username: slurm
    passwordKeyRef:
      name: slurm-db-password      # Secret created in step 1
      key: password
  podSpec:
    nodeSelector:
      doks.digitalocean.com/node-pool: mgmt

# ── Login Nodes ─────────────────────────────────────────────────────────
loginsets:
  slinky:
    enabled: true
    replicas: 1
    login:
      volumeMounts:
        - name: shared-nfs
          mountPath: /shared
    podSpec:
      nodeSelector:
        doks.digitalocean.com/node-pool: mgmt
      volumes:
        - name: shared-nfs
          persistentVolumeClaim:
            claimName: slurm-nfs-pvc
    service:
      spec:
        type: ClusterIP

# ── GPU Worker Nodes ───────────────────────────────────────────────
#
# NVIDIA example shown below. For AMD nodes, replace:
#   - nvidia.com/gpu → amd.com/gpu  (in resources AND tolerations)
#   - gpu-brand nodeSelector value → amd
#
nodesets:
  gpu:
    enabled: true
    replicas: 4                    # Match your GPU node count
    slurmd:
      resources:
        requests:
          cpu: 3
          memory: 5Gi
          nvidia.com/gpu: 1        # GPUs per worker pod (amd.com/gpu for AMD)
        limits:
          cpu: 3
          memory: 5Gi
          nvidia.com/gpu: 1        # Adjust to GPUs-per-node
      volumeMounts:
        - name: shared-nfs
          mountPath: /shared
    useResourceLimits: true        # Slurm sees container limits as node resources
    partition:
      enabled: true
      configMap:
        State: UP
        MaxTime: UNLIMITED
    podSpec:
      nodeSelector:
        doks.digitalocean.com/node-pool: gpu
      tolerations:                 # Matches the DOKS-managed taint on GPU nodes
        - key: nvidia.com/gpu       # Use amd.com/gpu for AMD nodes
          operator: Exists
          effect: NoSchedule
      volumes:
        - name: shared-nfs
          persistentVolumeClaim:
            claimName: slurm-nfs-pvc

# ── Partitions ──────────────────────────────────────────────────────────
partitions:
  all:
    enabled: true
    nodesets:
      - ALL
    configMap:
      State: UP
      Default: "YES"
      MaxTime: UNLIMITED
```

---

## 7. Verification

After all Helm installs complete, run through these checks:

### Operator

```bash
kubectl get pods -n slurm -l app.kubernetes.io/name=slinky-operator
# Both operator and webhook pods should be Running on mgmt nodes
```

### Slurm Components

```bash
kubectl get pods -n slurm
# Expected: controller, accounting, restapi, login, and worker pods all Running
```

### GPU Visibility

```bash
# NVIDIA — verify GPUs are visible to worker pods:
kubectl exec -it -n slurm slurm-worker-gpu-0 -- nvidia-smi

# AMD — verify GPUs are visible to worker pods:
kubectl exec -it -n slurm slurm-worker-gpu-0 -- rocm-smi
```

### Node Health

```bash
# Exec into the login pod
kubectl exec -it -n slurm deploy/slurm-login-slinky -- bash

# Inside the pod:
sinfo -N -l
# All nodes should show "idle" state with GRES listing gpu resources

# NVIDIA:
srun -N1 --gres=gpu:1 nvidia-smi

# AMD:
srun -N1 --gres=gpu:1 rocm-smi
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
kubectl exec -it -n slurm slurm-worker-gpu-0 -- cat /shared/test.txt
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
