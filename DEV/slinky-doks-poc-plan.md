# Slinky on DOKS: Proof of Concept Implementation Plan

## Objective

Validate that Slurm, deployed via the Slinky operator (v1.0.0), functions correctly on DigitalOcean Kubernetes Service (DOKS). This PoC validates both the Slinky integration layer and Slurm itself as a workload manager. Beyond infrastructure validation, a key goal is building hands-on competency with Slurm concepts, commands, and operational patterns (partitions, job lifecycle, accounting, fairshare, priority, queuing, etc.) so that conversations with customers are grounded in direct experience.

No GPUs are involved; all jobs are CPU-based mocks simulating training workload patterns.

## Assumptions

These are defaults for questions not explicitly answered. Flag anything that needs changing before we start.

- **Droplet sizes**: Management pool: `c-4` CPU-optimized (3 nodes). Compute pool: `c-4` CPU-optimized (4 nodes).
- **slurmrestd**: Included. Useful for programmatic job submission demos and future API integration.
- **Terraform state**: Local. Throwaway PoC, not worth setting up S3 backend.
- **Slinky version**: v1.0.0 (GA released November 20, 2025).
- **Repo structure**: Single repo, directories below.

```
slinky-doks-poc/
├── Makefile             # Primary interface for all deploy/manage/teardown operations
├── terraform/           # DOKS cluster, managed DB, managed NFS, VPC, firewall
├── helm/
│   ├── prerequisites/   # cert-manager, prometheus, metrics-server values
│   └── slinky/          # slurm-operator and slurm chart values overrides
├── manifests/           # Any raw K8s manifests (PV/PVC for NFS, RBAC, etc.)
├── jobs/                # Sample Slurm job scripts
├── scripts/             # Helper scripts (validation, restapi tests, etc.)
└── docs/                # Notes, findings, screenshots
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     DOKS Cluster (VPC)                      │
│                                                             │
│  ┌─────────────────────────┐  ┌──────────────────────────┐  │
│  │   Management Node Pool  │  │   Compute Node Pool      │  │
│  │   (c-4 x 3)            │  │   (c-4 x 4)             │  │
│  │                         │  │   GPU taints simulated   │  │
│  │  - slurmctld           │  │  - slurmd pods (NodeSet) │  │
│  │  - slurmdbd            │  │    one per node          │  │
│  │  - slurmrestd          │  │                          │  │
│  │  - slurm-exporter      │  │                          │  │
│  │  - slurm-operator      │  │                          │  │
│  │  - login pod           │  │                          │  │
│  │  - cert-manager        │  │                          │  │
│  │  - prometheus/grafana  │  │                          │  │
│  └─────────────────────────┘  └──────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  DO Managed MySQL (db-s-1vcpu-2gb)                   │   │
│  │  slurmdbd accounting database                        │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  DO Managed NFS (1 TiB)                              │   │
│  │  Shared filesystem: job scripts, output, /home       │   │
│  │  Mounted via PV/PVC (ReadWriteMany) to all pods      │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

Node affinity/taints enforce separation: management workloads on the management pool, slurmd pods on the compute pool. The compute pool has GPU-style taints applied to simulate DigitalOcean's automatic GPU node taints (see reference below). The managed NFS share and managed MySQL are both attached to the same VPC as the DOKS cluster.


---

## Makefile Targets

The `Makefile` is the primary interface for deploying, updating, configuring, and tearing down the PoC. Targets are organized to mirror the deployment lifecycle and can be composed or run individually.

```makefile
# Infrastructure (Terraform)
infra/init              # terraform init
infra/plan              # terraform plan
infra/apply             # terraform apply (provisions DOKS, MySQL, NFS, VPC)
infra/destroy           # terraform destroy
infra/output            # terraform output (prints endpoints, NFS mount info, DB conn string)

# Prerequisites (Helm + manifests)
prereqs/install         # Install cert-manager, prometheus, metrics-server
prereqs/status          # Check pod status across prerequisite namespaces
prereqs/uninstall       # Uninstall all prerequisites

# NFS (PV/PVC from managed NFS)
nfs/configure           # Generate PV/PVC manifests from terraform output, apply them
nfs/test                # Deploy a busybox pod, write a test file, verify read/write
nfs/status              # Check PV/PVC binding status

# Slinky / Slurm
slinky/install-operator # Install slurm-operator CRDs + operator
slinky/install-slurm    # Install Slurm cluster (controller, accounting, compute, login, etc.)
slinky/update-slurm     # Helm upgrade Slurm cluster (apply updated values)
slinky/status           # kubectl get pods across slinky + slurm namespaces, sinfo summary
slinky/uninstall        # Uninstall Slurm cluster, operator, CRDs (in order)
slinky/logs             # Tail operator and controller logs

# Slurm Operations (from login pod)
slurm/shell             # kubectl exec into login pod (interactive shell)
slurm/info              # Run sinfo, squeue, scontrol show partitions from login pod
slurm/submit-test       # Copy job scripts to NFS, submit basic test jobs
slurm/run-validation    # Run the full validation suite (Phase 4 tests)
slurm/test-restapi      # Test slurmrestd API endpoints

# Observability
obs/grafana             # Port-forward Grafana to localhost:3000
obs/prometheus          # Port-forward Prometheus to localhost:9090

# Lifecycle / Compound Targets
up                      # infra/apply -> prereqs/install -> nfs/configure -> slinky/install-operator -> slinky/install-slurm
down                    # slinky/uninstall -> prereqs/uninstall -> infra/destroy
status                  # infra/output + prereqs/status + nfs/status + slinky/status + slurm/info
```

The compound targets (`up`, `down`, `status`) are the happy-path shortcuts. Individual targets allow re-running or debugging specific layers without tearing everything down. The `slinky/update-slurm` target is critical during Phase 3 iteration when tuning Helm values.

### Deliverables
- `Makefile` at the repo root


---

## Phase 1: Infrastructure Provisioning (Terraform)

**Goal**: Standing DOKS cluster with two node pools, managed MySQL, managed NFS, VPC, and firewall rules.

Scaffold all Terraform files and the Makefile together in this phase. Use the reference links below to fetch current documentation and verify resource schemas rather than relying on training data. After generating all files, run `make infra/init` and `make infra/apply` to provision the infrastructure, then execute the validation checks and report the status of each item.

### Reference Links

- **DO Terraform Provider Reference**: https://docs.digitalocean.com/reference/terraform/reference/
- **DO Terraform Resources (full list)**: https://docs.digitalocean.com/reference/terraform/reference/resources/
- **`digitalocean_kubernetes_cluster`**: https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/kubernetes_cluster
- **`digitalocean_kubernetes_node_pool`**: https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/kubernetes_node_pool
- **`digitalocean_database_cluster` (MySQL)**: https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/database_cluster
- **`digitalocean_database_db`**: https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/database_db
- **`digitalocean_database_user`**: https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/database_user
- **`digitalocean_database_firewall`**: https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/database_firewall
- **`digitalocean_database_mysql_config`**: https://docs.digitalocean.com/reference/terraform/reference/resources/database_mysql_config/
- **`digitalocean_nfs_share`**: https://docs.digitalocean.com/reference/terraform/reference/resources/nfs_share/
- **`digitalocean_nfs_vpc_attachment`**: https://docs.digitalocean.com/reference/terraform/reference/resources/nfs_vpc_attachment/
- **Using NFS with DOKS (PV/PVC setup)**: https://docs.digitalocean.com/products/kubernetes/how-to/use-nfs-storage/
- **Creating NFS shares**: https://docs.digitalocean.com/products/nfs/how-to/create/
- **`digitalocean_vpc`**: https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/vpc
- **Automatic GPU node taints**: https://docs.digitalocean.com/products/kubernetes/details/managed/#automatic-application-of-labels-and-taints-to-nodes

### Tasks

1. **CIDR allocation**: Before writing Terraform, use `doctl` to list existing VPCs, DOKS clusters, and their CIDR ranges. The VPC CIDR, cluster service subnet, and cluster pod subnet must all be unique and non-overlapping across the entire team. Choose CIDRs that do not conflict with any existing allocations.

2. **VPC**: Create a dedicated VPC for the PoC in a single region (e.g., `nyc3`) using the unique CIDR determined above.

3. **DOKS cluster**: Create with two node pools, specifying the unique cluster service and pod subnet CIDRs.
   - `mgmt` pool: `c-4`, 3 nodes, labels `role=management`, taint `role=management:NoSchedule`.
   - `compute` pool: `c-4`, 4 nodes, labels `role=compute`, taint `role=compute:NoSchedule`. Additionally, apply GPU-style taints to simulate DigitalOcean's automatic GPU node taints. Fetch the reference link above to determine the exact taint key/value/effect that DO applies to GPU nodes, then replicate those taints on this pool via the Terraform node pool `taint` block.

4. **Managed MySQL**: `db-s-1vcpu-2gb`, single node, MySQL 8. Create a `slurm_acct` database and user. Firewall restricted to the DOKS cluster (use `digitalocean_database_firewall` with `type=k8s` and the cluster ID).

5. **Managed NFS**: Create a `digitalocean_nfs_share` (1 TiB, sized for reasonable throughput, not just capacity) in the same region. Attach to the VPC via `digitalocean_nfs_vpc_attachment`. This provides the shared filesystem for Slurm job scripts, output, and user home directories.

6. **Outputs**: Cluster endpoint, kubeconfig, database connection string (host, port, user, password as sensitive outputs), NFS share host IP and mount path (needed for PV/PVC manifests).

### Deliverables
- `terraform/main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`
- `terraform/terraform.tfvars.example`

### Validation
After deploying, check and report the status of each item:
- [ ] `kubectl get nodes` shows 7 nodes with correct labels and taints (including GPU-style taints on compute nodes).
- [ ] MySQL is reachable from within the cluster VPC.
- [ ] NFS share is in `Active` status and attached to the VPC.
- [ ] `make infra/output` prints all connection details.


---

## Phase 2: Prerequisites & Platform Services

**Goal**: Install all dependencies that Slinky requires, plus the observability stack and NFS PV/PVC.

Generate Helm values files with the correct tolerations/nodeSelectors for management pool placement. Generate the NFS PV/PVC manifests using the connection details from `make infra/output`. After generating all files, run `make prereqs/install` and `make nfs/configure` to deploy, then execute the validation checks and report the status of each item.

### Tasks

1. **cert-manager**: Required by the slurm-operator for webhook TLS.
   ```
   helm install cert-manager jetstack/cert-manager \
     --set crds.enabled=true \
     --namespace cert-manager --create-namespace
   ```

2. **kube-prometheus-stack**: Prometheus + Grafana. Will be used by the slurm-exporter.
   ```
   helm install prometheus prometheus-community/kube-prometheus-stack \
     --set installCRDs=true \
     --namespace prometheus --create-namespace
   ```
   Add tolerations for management pool taint.

3. **metrics-server**: If not already present on DOKS (check first; DOKS may include it).

4. **NFS PV/PVC**: Create a PersistentVolume pointing at the managed NFS share (using the host IP and mount path from `make infra/output`), and a PersistentVolumeClaim with `ReadWriteMany` access mode. Follow the DO guide at https://docs.digitalocean.com/products/kubernetes/how-to/use-nfs-storage/ for the exact manifest structure.

   **Important**: DO NFS enforces root squashing. Containers running as root (UID 0) can read but not write. Slurm pods must be configured to run as a non-root user (e.g., `slurm` user with a specific UID/GID) or the NFS share permissions need to be set accordingly. This will need to be addressed in the Slinky Helm values.

5. **Namespace setup**: Create `slinky` (operator), `slurm` (cluster), `prometheus`, `cert-manager` namespaces as needed by Helm.

### Deliverables
- `helm/prerequisites/` with values files for each chart
- `manifests/nfs-pv-pvc.yaml`

### Validation
After deploying, check and report the status of each item:
- [ ] `make prereqs/status` shows all pods running.
- [ ] `make nfs/test` confirms read/write access from a busybox pod (as non-root user).
- [ ] Grafana accessible via `make obs/grafana`.


---

## Phase 3: Slinky Operator & Slurm Cluster Deployment

**Goal**: Deploy the Slinky operator and stand up a functional Slurm cluster.

This is the most iterative phase. Start from the Slinky Helm chart's default values, then layer in customizations (external DB, node placement, NFS mounts, root squash workarounds). Use `make slinky/update-slurm` to iterate on values without full reinstalls. Fetch the reference links below for current Helm chart schemas and configuration options. The compute NodeSet tolerations must include both the `role=compute` taint and the GPU-style taints applied in Phase 1. After generating all files, deploy and iterate until the cluster is functional, then execute the validation checks and report the status of each item.

### Reference Links

- **Slinky operator docs**: https://slinky.schedmd.com/projects/slurm-operator
- **Slinky operator GitHub**: https://github.com/SlinkyProject/slurm-operator
- **Quickstart guide**: https://github.com/SlinkyProject/slurm-operator/blob/main/docs/quickstart.md
- **Installation guide (v0.4+)**: https://slinky.schedmd.com/projects/slurm-operator/en/release-0.4/installation.html
- **Slinky Helm charts (OCI)**: `oci://ghcr.io/slinkyproject/charts/slurm-operator-crds`, `oci://ghcr.io/slinkyproject/charts/slurm-operator`, `oci://ghcr.io/slinkyproject/charts/slurm`
- **Slinky container images**: https://github.com/orgs/SlinkyProject/packages
- **AWS EKS reference deployment**: https://aws.amazon.com/blogs/containers/running-slurm-on-amazon-eks-with-slinky/
- **AMD GPU Operator Slinky example** (useful for values structure): https://instinct.docs.amd.com/projects/gpu-operator/en/main/slinky/slinky-example.html

### Tasks

1. **Install slurm-operator CRDs and operator** (`make slinky/install-operator`):
   ```
   helm install slurm-operator-crds \
     oci://ghcr.io/slinkyproject/charts/slurm-operator-crds

   helm install slurm-operator \
     oci://ghcr.io/slinkyproject/charts/slurm-operator \
     --values=values-operator.yaml \
     --namespace=slinky --create-namespace
   ```

2. **Configure `values-slurm.yaml`** with overrides for:
   - **External database**: Point slurmdbd at the managed MySQL instance (host, port, user, password via K8s Secret). Disable the default in-cluster MariaDB.
   - **NodeSet**: Configure compute NodeSet with `nodeSelector: role=compute`, tolerations for both the compute taint and the GPU-style taints, replica count of 4 (one slurmd pod per compute node).
   - **Controller/Accounting/Login/RestAPI**: `nodeSelector: role=management`, toleration for management taint.
   - **NFS volume mounts**: Mount the managed NFS PVC to all slurmd, login, and controller pods at a shared path (e.g., `/slurm/shared`). Ensure pods run as non-root to satisfy DO NFS root squash.
   - **slurm-exporter**: Enable with `slurm-exporter.enabled=true`.
   - **slurmrestd**: Enable for API access.
   - **Partitions**: Define a `compute` partition spanning all NodeSet nodes.
   - **Login**: Configure with SSH access (rootSshAuthorizedKeys) for interactive testing.

3. **Install the Slurm cluster** (`make slinky/install-slurm`):
   ```
   helm install slurm oci://ghcr.io/slinkyproject/charts/slurm \
     --values=values-slurm.yaml \
     --namespace=slurm --create-namespace
   ```

4. **Create Kubernetes Secret** for the managed MySQL credentials before the Helm install.

### Deliverables
- `helm/slinky/values-operator.yaml`
- `helm/slinky/values-slurm.yaml`
- `manifests/slurm-db-secret.yaml` (templated, not committed with real creds)

### Validation
After deploying (iterating as needed), check and report the status of each item:
- [ ] `make slinky/status` shows all pods running.
- [ ] `make slurm/shell` then `sinfo` shows all 4 compute nodes as `idle`.
- [ ] `scontrol show partitions` confirms the `compute` partition.
- [ ] `sacctmgr show cluster` confirms accounting is connected to managed MySQL.


---

## Phase 4: Job Submission & Slurm Operations

**Goal**: Demonstrate Slurm scheduling behaviors through Slinky and build hands-on familiarity with Slurm commands and concepts.

This phase is intentionally exploratory. Generate the job scripts and the validation/test runner scripts listed in Deliverables. Then deploy the job scripts to NFS via `make slurm/submit-test`. The interactive Slurm CLI exploration described in the test suite (4a through 4g) will be done manually via `make slurm/shell`. After generating and deploying the scripts, execute the automated validation and report the status of each item.

### Test Suite

All jobs are submitted from the login pod via `make slurm/shell`, then `sbatch` or `srun`.

#### 4a. Cluster Orientation (Learn the Slurm CLI)
Before submitting jobs, explore the cluster state:
- `sinfo` -- view partition and node state (idle, alloc, drain, down)
- `sinfo -N -l` -- detailed per-node view with CPU/memory
- `scontrol show nodes` -- full node configuration details
- `scontrol show partitions` -- partition configuration, limits, defaults
- `scontrol show config` -- full Slurm configuration dump
- `sacctmgr show cluster` -- verify accounting cluster registration
- `sacctmgr show account` -- view accounts
- `sacctmgr show user` -- view users
- `sacctmgr show qos` -- view quality-of-service levels

#### 4b. Basic Job Submit/Complete
- `srun hostname` -- interactive allocation, immediate execution.
- `sbatch --wrap="hostname && sleep 30"` -- batch job, confirm output captured on NFS.
- `squeue` while job runs -- observe job state transitions (PD -> R -> CG).
- `sacct -j <jobid> --format=JobID,JobName,Partition,State,ExitCode,Elapsed,NodeList` -- verify accounting records in managed MySQL.
- `scontrol show job <jobid>` -- detailed job information.

#### 4c. Multi-Node Job
- Submit a job requesting multiple nodes: `sbatch -N 2 --ntasks-per-node=2 mpi_mock.sh`
- The mock script runs a CPU-intensive workload (e.g., `stress-ng` or a Python matrix multiply) on each node.
- Verify `squeue` shows the job allocated across 2 nodes.
- Verify `sacct` records the multi-node allocation.
- Experiment with `srun` within the job to understand task distribution.

#### 4d. Job Arrays
- Submit a job array: `sbatch --array=0-9 array_job.sh`
- Each array task does a parameterized sleep + CPU work.
- Verify `squeue` shows array tasks with the `_N` suffix notation.
- Verify all 10 tasks complete and produce individual output files on NFS.
- Try `scancel --array=5-9` to cancel a subset mid-run.

#### 4e. Priority, Queuing & Fairshare
- Fill the cluster: submit enough jobs to consume all 4 compute nodes.
- Submit additional jobs -- verify they queue (state `PD` in `squeue`) with reason `Resources`.
- Submit a high-priority job: `sbatch --priority=1000 ...` -- verify it jumps the queue.
- Use `sprio` to inspect job priority factors.
- Use `sshare` to view fairshare data (will be minimal with a fresh cluster, but demonstrates the concept).
- Experiment with `scontrol hold <jobid>` and `scontrol release <jobid>`.

#### 4f. Partitions & QoS (if time permits)
- Create a second partition via `scontrol` or by updating slurm.conf through `make slinky/update-slurm`.
- Test submitting jobs to specific partitions: `sbatch -p <partition> ...`
- Experiment with job time limits and see what happens when a job exceeds its wall time.

#### 4g. slurmrestd API
- `make slurm/test-restapi` to submit a job and retrieve status via the REST API.
- Demonstrates programmatic integration path.

### Mock Job Scripts

```bash
# jobs/cpu_stress.sh -- simulates a training epoch
#!/bin/bash
#SBATCH --job-name=cpu-stress
#SBATCH --time=00:05:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2

echo "Job $SLURM_JOB_ID on $(hostname) started at $(date)"
stress-ng --cpu 2 --timeout 120s --metrics-brief
echo "Job $SLURM_JOB_ID completed at $(date)"
```

```bash
# jobs/multi_node_mock.sh -- simulates distributed training
#!/bin/bash
#SBATCH --job-name=multi-node
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --time=00:05:00

srun bash -c 'echo "Task $SLURM_PROCID on $(hostname): starting work" && \
  python3 -c "
import time
import random
size = 500
a = [[random.random() for _ in range(size)] for _ in range(size)]
b = [[random.random() for _ in range(size)] for _ in range(size)]
result = [[sum(x*y for x,y in zip(row,col)) for col in zip(*b)] for row in a]
print(f\"Completed matrix {size}x{size} multiply\")
" && echo "Task $SLURM_PROCID done"'
```

```bash
# jobs/array_job.sh -- simulates hyperparameter sweep
#!/bin/bash
#SBATCH --job-name=hp-sweep
#SBATCH --array=0-9
#SBATCH --time=00:03:00
#SBATCH --ntasks=1

echo "Array task $SLURM_ARRAY_TASK_ID on $(hostname)"
SLEEP_TIME=$((SLURM_ARRAY_TASK_ID * 10 + 30))
echo "Simulating training with param_id=$SLURM_ARRAY_TASK_ID for ${SLEEP_TIME}s"
stress-ng --cpu 1 --timeout ${SLEEP_TIME}s --metrics-brief
echo "Task $SLURM_ARRAY_TASK_ID complete"
```

### Deliverables
- `jobs/cpu_stress.sh`, `jobs/multi_node_mock.sh`, `jobs/array_job.sh`, `jobs/queue_filler.sh`
- `scripts/run-validation-suite.sh` -- automated script that submits all tests and collects results
- `scripts/test-restapi.sh` -- curl-based slurmrestd test
- `docs/slurm-commands-cheatsheet.md` -- personal reference of commands used and what they do

### Validation
After deploying job scripts and running the automated validation suite, report the status of each item:
- [ ] All jobs complete successfully (exit code 0).
- [ ] `sacct` shows correct node allocations, runtimes, and exit codes.
- [ ] Job output files appear on NFS.
- [ ] Queue behavior matches expectations (pending -> running transitions).
- [ ] REST API returns correct job state.


---

## Phase 5: Observability & Node State Exploration

**Goal**: Confirm metrics flow and explore the Kubernetes / Slurm state boundary.

Generate the Grafana dashboard configuration and any investigation scripts. Deploy the dashboard, then execute the validation checks. The drain exploration (5c, 5d) will be done interactively. Report the status of each validation item.

### Tasks

#### 5a. Grafana Dashboard
- Import or create a Slurm dashboard using metrics from the slurm-exporter.
- Key metrics: `slurm_nodes_total`, `slurm_nodes_idle`, `slurm_nodes_alloc`, `slurm_jobs_pending`, `slurm_jobs_running`.
- Capture screenshots during job submission bursts.

#### 5b. Slurm Node State and Pod Conditions
- The Slinky operator reflects Slurm node states as pod conditions on NodeSet pods (Idle, Allocated, Mixed, Down, Drain). Verify this:
  - While jobs run, check `kubectl get pods -n slurm -o yaml` for the compute pods -- confirm conditions reflect `Allocated` or `Mixed`.
  - When idle, confirm conditions reflect `Idle`.

#### 5c. Node Drain Exploration (Investigative)
- **Kubernetes to Slurm direction**: `kubectl cordon` a compute node, then `kubectl drain` it (with appropriate flags). Observe:
  - Does the slurmd pod get evicted?
  - Does Slurm mark that node as `Down` or `Drain`?
  - Do pending jobs avoid it?
  - What happens to a running job on that node?
- **Document findings.** The expectation is that this may partially work (pod eviction triggers Slurm to mark the node down) but there is no automated health-signal propagation from Kubernetes node conditions into Slurm scheduling decisions -- which is the gap identified in our SUNK analysis.

#### 5d. Operator-Initiated Drain
- Scale down the NodeSet replica count from 4 to 3 via `make slinky/update-slurm` or `kubectl edit`.
- The operator documentation states it marks nodes as `Drain` before termination. Verify this behaves gracefully with running jobs.

### Deliverables
- `docs/grafana-dashboard.json` (exported)
- `docs/node-state-findings.md` -- documented observations from 5b, 5c, 5d
- Screenshots in `docs/screenshots/`

### Validation
After deploying the dashboard, report the status of each item:
- [ ] Grafana shows Slurm metrics updating in real-time.
- [ ] Pod conditions accurately reflect Slurm node state.
- [ ] Node drain findings documented with specific observations.


---

## Phase 6: Cleanup & Documentation

**Goal**: Tear everything down cleanly and produce a findings summary.

Run `make down` to tear down all resources, then generate the findings and cost summary documents. Report the status of each validation item.

### Tasks

1. **Teardown**: `make down` handles reverse-order Helm uninstalls followed by `terraform destroy`.

2. **Findings document**: Summarize what worked, what didn't, any DOKS-specific issues encountered (e.g., NFS root squash workarounds, network policy gaps, DOKS-specific Kubernetes version constraints).

3. **Cost summary**: Document actual spend for the PoC duration.

### Deliverables
- `docs/findings-summary.md`
- `docs/cost-summary.md`

### Validation
- [ ] All cloud resources destroyed (verify via `doctl` or DO console).
- [ ] Findings and cost summary documents complete.


---

## Key Risks & Mitigations

**DOKS Kubernetes version compatibility**: Slinky v1.0.0 targets specific K8s versions. Check compatibility with DOKS's current default version before provisioning. Pin the cluster version in Terraform if needed.

**External database configuration**: The Slinky Helm chart's default is an in-cluster MariaDB. Pointing slurmdbd at an external MySQL requires careful values overrides (connection string, credentials secret, disabling the built-in MariaDB subchart). This is the most likely area to require debugging.

**NFS root squash**: DO managed NFS enforces root squashing. Slurm containers typically run as root by default. The Slinky Helm values will need `securityContext` overrides to run slurmd/login pods with a non-root user (or at minimum, write operations need to happen as non-root). This may require custom UID/GID configuration in the container image or `runAsUser` in the pod spec. Reference: https://docs.digitalocean.com/products/kubernetes/how-to/use-nfs-storage/

**slurmd pod scheduling**: Each slurmd pod needs to land on a dedicated compute node (one-to-one mapping). This requires either `podAntiAffinity` or resource requests that effectively consume the node. The Slinky NodeSet CRD may handle this natively -- verify during Phase 3.

**stress-ng availability**: The default Slinky container images are minimal. The mock jobs need `stress-ng` and `python3`. Options: build a custom slurmd image, install at runtime via job scripts, or use pure bash workloads (dd, openssl speed) that don't require extra packages.


---

## Implementation Notes

This plan is structured in six sequential phases. Each phase will be requested one at a time, with review between phases. The Makefile is the primary interface; all deploy/update/teardown operations go through `make` targets.

For each phase:
1. Generate all files specified in that phase's Deliverables.
2. Deploy by running the appropriate `make` targets.
3. Execute the Validation checks.
4. Report the status of each validation item (pass/fail with details).

Use the Reference Links provided in each phase to fetch current documentation rather than relying on training data for resource schemas, Helm chart values, or API details.
