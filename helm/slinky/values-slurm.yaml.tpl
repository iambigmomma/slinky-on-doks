# Slurm Cluster on DOKS — GPU worker values
# Generated from values-slurm.yaml.tpl by `make slinky/configure`

# ── Controller (slurmctld) ───────────────────────────────────────────────────
controller:
  extraConfMap:
    ReturnToService: 2
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      labels:
        release: prometheus

# ── Accounting (slurmdbd) ───────────────────────────────────────────────────
accounting:
  enabled: true
  storageConfig:
    host: __DB_HOST__
    port: 25060
    database: slurm_acct
    username: slurm
    passwordKeyRef:
      name: slurm-db-password
      key: password

# ── Login Nodes ──────────────────────────────────────────────────────────────
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

# ── GPU Worker Nodes ────────────────────────────────────────────────────────
nodesets:
  slinky:
    replicas: __GPU_NODE_COUNT__
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
        doks.digitalocean.com/gpu-brand: __GPU_VENDOR__
      tolerations:
        - key: __GPU_TAINT_KEY__
          operator: Exists
          effect: NoSchedule
      volumes:
        - name: shared-nfs
          persistentVolumeClaim:
            claimName: slurm-nfs-pvc
