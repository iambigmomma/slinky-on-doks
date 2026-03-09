apiVersion: v1
kind: Pod
metadata:
  name: gpu-probe
  namespace: slurm
spec:
  restartPolicy: Never
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: doks.digitalocean.com/gpu-brand
                operator: Exists
  tolerations:
    - key: __GPU_TAINT_KEY__
      operator: Exists
      effect: NoSchedule
  containers:
    - name: probe
      image: ubuntu:24.04
      command: ["sleep", "300"]
      resources:
        limits:
          __GPU_RESOURCE_KEY__: 1
