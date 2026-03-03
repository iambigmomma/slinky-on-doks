SHELL := /bin/bash
.DEFAULT_GOAL := help
TF := terraform -chdir=terraform

CLUSTER_NAME := $(shell $(TF) output -raw cluster_name 2>/dev/null || echo "slinky-poc")

# ── Infrastructure (Terraform) ───────────────────────────────────────────────

.PHONY: infra/init
infra/init: ## Initialize Terraform providers and backend
	$(TF) init

.PHONY: infra/plan
infra/plan: ## Preview infrastructure changes
	$(TF) plan

.PHONY: infra/apply
infra/apply: ## Provision DOKS, MySQL, NFS, VPC
	$(TF) apply -auto-approve

.PHONY: infra/destroy
infra/destroy: ## Destroy all infrastructure
	$(TF) destroy -auto-approve

.PHONY: infra/output
infra/output: ## Print all Terraform outputs
	$(TF) output

# ── Prerequisites (Helm + Manifests) ─────────────────────────────────────────

.PHONY: prereqs/install
prereqs/install: ## Install cert-manager, prometheus, metrics-server
	helm repo add jetstack https://charts.jetstack.io --force-update
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo update
	helm upgrade --install cert-manager jetstack/cert-manager \
		--set crds.enabled=true \
		--values helm/prerequisites/cert-manager-values.yaml \
		--namespace cert-manager --create-namespace \
		--wait
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
		--values helm/prerequisites/prometheus-values.yaml \
		--namespace prometheus --create-namespace \
		--wait

.PHONY: prereqs/status
prereqs/status: ## Check pod status across prerequisite namespaces
	@echo "=== cert-manager ==="
	kubectl get pods -n cert-manager
	@echo ""
	@echo "=== prometheus ==="
	kubectl get pods -n prometheus
	@echo ""
	@echo "=== metrics-server ==="
	-kubectl get pods -n kube-system -l k8s-app=metrics-server

.PHONY: prereqs/uninstall
prereqs/uninstall: ## Uninstall all prerequisites
	-helm uninstall prometheus -n prometheus
	-helm uninstall cert-manager -n cert-manager
	-kubectl delete namespace prometheus --ignore-not-found
	-kubectl delete namespace cert-manager --ignore-not-found

# ── NFS (PV/PVC from Managed NFS) ────────────────────────────────────────────

.PHONY: nfs/configure
nfs/configure: ## Generate NFS PV from template, create namespace, apply PV + PVC
	@NFS_HOST=$$($(TF) output -raw nfs_host) && \
	NFS_PATH=$$($(TF) output -raw nfs_mount_path) && \
	sed "s|__NFS_HOST__|$$NFS_HOST|g; s|__NFS_PATH__|$$NFS_PATH|g" \
		manifests/nfs-pv.yaml.tpl > manifests/nfs-pv.yaml && \
	kubectl apply -f manifests/slurm-namespace.yaml && \
	kubectl apply -f manifests/nfs-pv.yaml && \
	kubectl apply -f manifests/nfs-pvc.yaml

.PHONY: nfs/test
nfs/test: ## Deploy busybox pod to verify NFS read/write
	@echo "Deploying NFS test pod..."
	kubectl apply -f manifests/nfs-test-pod.yaml
	@echo "Waiting for pod to be ready..."
	kubectl wait --for=condition=Ready pod/nfs-test -n slurm --timeout=60s
	@echo "Testing write..."
	kubectl exec nfs-test -n slurm -- sh -c 'echo "NFS test $$(date)" > /mnt/nfs/test-file.txt'
	@echo "Testing read..."
	kubectl exec nfs-test -n slurm -- cat /mnt/nfs/test-file.txt
	@echo "Cleaning up..."
	kubectl delete pod nfs-test -n slurm --ignore-not-found

.PHONY: nfs/status
nfs/status: ## Check PV/PVC binding status
	@echo "=== PersistentVolumes ==="
	kubectl get pv
	@echo ""
	@echo "=== PersistentVolumeClaims ==="
	kubectl get pvc -A

# ── Slinky / Slurm ──────────────────────────────────────────────────────────

.PHONY: slinky/install-operator
slinky/install-operator: ## Install slurm-operator CRDs and operator
	helm upgrade --install slurm-operator-crds \
		oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
		--namespace slinky --create-namespace \
		--wait
	helm upgrade --install slurm-operator \
		oci://ghcr.io/slinkyproject/charts/slurm-operator \
		--values helm/slinky/values-operator.yaml \
		--namespace slinky --create-namespace \
		--wait

.PHONY: slinky/install-slurm
slinky/install-slurm: ## Install Slurm cluster
	helm upgrade --install slurm \
		oci://ghcr.io/slinkyproject/charts/slurm \
		--values helm/slinky/values-slurm.yaml \
		--namespace slurm --create-namespace \
		--wait --timeout 10m

.PHONY: slinky/update-slurm
slinky/update-slurm: ## Helm upgrade Slurm cluster with updated values
	helm upgrade slurm \
		oci://ghcr.io/slinkyproject/charts/slurm \
		--values helm/slinky/values-slurm.yaml \
		--namespace slurm \
		--wait --timeout 10m

.PHONY: slinky/status
slinky/status: ## Show pods across slinky + slurm namespaces
	@echo "=== Slinky Operator ==="
	kubectl get pods -n slinky
	@echo ""
	@echo "=== Slurm Cluster ==="
	kubectl get pods -n slurm
	@echo ""
	@echo "=== Slurm Node Status ==="
	-kubectl exec -n slurm deploy/slurm-login -- sinfo 2>/dev/null || echo "(login pod not ready)"

.PHONY: slinky/uninstall
slinky/uninstall: ## Uninstall Slurm cluster, operator, CRDs
	-helm uninstall slurm -n slurm
	-helm uninstall slurm-operator -n slinky
	-helm uninstall slurm-operator-crds -n slinky
	-kubectl delete namespace slurm --ignore-not-found
	-kubectl delete namespace slinky --ignore-not-found

.PHONY: slinky/logs
slinky/logs: ## Tail operator and controller logs
	@echo "=== Slurm Operator Logs ==="
	kubectl logs -n slinky -l app.kubernetes.io/name=slurm-operator --tail=50 --prefix
	@echo ""
	@echo "=== Slurm Controller Logs ==="
	-kubectl logs -n slurm -l app.kubernetes.io/component=slurmctld --tail=50 --prefix

# ── Slurm Operations ─────────────────────────────────────────────────────────

.PHONY: slurm/shell
slurm/shell: ## Interactive shell on the login pod
	kubectl exec -it -n slurm deploy/slurm-login -- /bin/bash

.PHONY: slurm/info
slurm/info: ## Run sinfo, squeue, and show partitions
	@echo "=== sinfo ==="
	kubectl exec -n slurm deploy/slurm-login -- sinfo
	@echo ""
	@echo "=== squeue ==="
	kubectl exec -n slurm deploy/slurm-login -- squeue
	@echo ""
	@echo "=== partitions ==="
	kubectl exec -n slurm deploy/slurm-login -- scontrol show partitions

.PHONY: slurm/submit-test
slurm/submit-test: ## Copy job scripts to NFS and submit basic test jobs
	scripts/submit-test-jobs.sh

.PHONY: slurm/run-validation
slurm/run-validation: ## Run the full validation suite
	scripts/run-validation-suite.sh

.PHONY: slurm/test-restapi
slurm/test-restapi: ## Test slurmrestd API endpoints
	scripts/test-restapi.sh

# ── Observability ─────────────────────────────────────────────────────────────

.PHONY: obs/grafana
obs/grafana: ## Port-forward Grafana to localhost:3000
	@echo "Grafana available at http://localhost:3000 (admin/prom-operator)"
	kubectl port-forward -n prometheus svc/prometheus-grafana 3000:80

.PHONY: obs/prometheus
obs/prometheus: ## Port-forward Prometheus to localhost:9090
	@echo "Prometheus available at http://localhost:9090"
	kubectl port-forward -n prometheus svc/prometheus-kube-prometheus-prometheus 9090:9090

# ── Lifecycle / Compound Targets ──────────────────────────────────────────────

.PHONY: up
up: infra/apply prereqs/install nfs/configure slinky/install-operator slinky/install-slurm ## Full deploy: infra -> prereqs -> nfs -> slinky

.PHONY: down
down: slinky/uninstall prereqs/uninstall infra/destroy ## Full teardown: slinky -> prereqs -> infra

.PHONY: status
status: infra/output prereqs/status nfs/status slinky/status slurm/info ## Show status of all components

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z/_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'
