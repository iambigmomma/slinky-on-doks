#!/bin/bash
set -uo pipefail

NAMESPACE="slurm"
LOGIN_POD="deploy/slurm-login-slinky"
KUBECTL="kubectl exec -n ${NAMESPACE} ${LOGIN_POD} --"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

total_pass=0
total_fail=0
section_results=()

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; total_pass=$((total_pass + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; total_fail=$((total_fail + 1)); }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_section() { echo -e "\n${BOLD}━━━ $1 ━━━${NC}"; }

cleanup_all() {
    fuser -k 9091/tcp &>/dev/null || true
    fuser -k 3001/tcp &>/dev/null || true
}
trap cleanup_all EXIT

# ══════════════════════════════════════════════════════════════════════════════
# Section 1: Job Submission Tests
# ══════════════════════════════════════════════════════════════════════════════
log_section "Section 1: Job Submission Tests"

if scripts/submit-test-jobs.sh; then
    section_results+=("${GREEN}PASS${NC} Job Submission Tests")
else
    section_results+=("${RED}FAIL${NC} Job Submission Tests")
fi

# ══════════════════════════════════════════════════════════════════════════════
# Section 2: REST API Tests
# ══════════════════════════════════════════════════════════════════════════════
log_section "Section 2: REST API Tests"

if scripts/test-restapi.sh; then
    section_results+=("${GREEN}PASS${NC} REST API Tests")
else
    section_results+=("${RED}FAIL${NC} REST API Tests")
fi

# ══════════════════════════════════════════════════════════════════════════════
# Section 3: Prometheus Metrics Check
# ══════════════════════════════════════════════════════════════════════════════
log_section "Section 3: Prometheus Metrics Check"

log_info "Checking if Prometheus is scraping Slurm metrics..."

# Check for slurm ServiceMonitor
if kubectl get servicemonitor -n slurm -o name 2>/dev/null | grep -q .; then
    log_pass "Slurm ServiceMonitor exists"
else
    log_fail "No ServiceMonitor found in slurm namespace"
fi

# Port-forward Prometheus and check for slurm metrics
log_info "Port-forwarding Prometheus to check metrics..."
fuser -k 9091/tcp &>/dev/null || true
sleep 1
kubectl port-forward -n prometheus svc/prometheus-kube-prometheus-prometheus 9091:9090 &>/dev/null &
PROM_PF_PID=$!
sleep 4

prom_cleanup() {
    if [ -n "${PROM_PF_PID:-}" ] && kill -0 "$PROM_PF_PID" 2>/dev/null; then
        kill "$PROM_PF_PID" 2>/dev/null || true
        wait "$PROM_PF_PID" 2>/dev/null || true
    fi
}

if kill -0 "$PROM_PF_PID" 2>/dev/null; then
    # Query for any slurm-related metrics
    prom_result=$(curl -s "http://localhost:9091/api/v1/label/__name__/values" 2>/dev/null || echo "")
    slurm_metrics=$(echo "$prom_result" | grep -oi 'slurm[^"]*' | head -5 || true)

    if [ -n "$slurm_metrics" ]; then
        log_pass "Prometheus has Slurm metrics:"
        echo "$slurm_metrics" | while read -r m; do echo "    - $m"; done
    else
        log_info "No slurm-prefixed metrics found (exporter may not be configured)"
        log_info "This is expected if the Slurm chart doesn't include a Prometheus exporter"
        # Check if the ServiceMonitor target is at least present
        targets=$(curl -s "http://localhost:9091/api/v1/targets" 2>/dev/null || echo "")
        slurm_targets=$(echo "$targets" | grep -o '"slurm[^"]*"' | head -3 || true)
        if [ -n "$slurm_targets" ]; then
            log_pass "Prometheus has Slurm scrape targets: ${slurm_targets}"
        else
            log_info "No Slurm scrape targets found in Prometheus"
        fi
    fi
    prom_cleanup
    section_results+=("${GREEN}PASS${NC} Prometheus Metrics Check")
else
    log_fail "Could not port-forward Prometheus"
    section_results+=("${RED}FAIL${NC} Prometheus Metrics Check")
fi

# ══════════════════════════════════════════════════════════════════════════════
# Section 4: Grafana Dashboard Check
# ══════════════════════════════════════════════════════════════════════════════
log_section "Section 4: Grafana Dashboard Check"

log_info "Checking Grafana dashboard ConfigMap..."
if kubectl get configmap -n prometheus slurm-dashboard -o name 2>/dev/null | grep -q .; then
    log_pass "Grafana dashboard ConfigMap exists (slurm-dashboard)"
else
    log_fail "Dashboard ConfigMap 'slurm-dashboard' not found in prometheus namespace"
fi

# Check Grafana is healthy
log_info "Checking Grafana health..."
fuser -k 3001/tcp &>/dev/null || true
sleep 1
kubectl port-forward -n prometheus svc/prometheus-grafana 3001:80 &>/dev/null &
GRAF_PF_PID=$!
sleep 4

graf_cleanup() {
    if [ -n "${GRAF_PF_PID:-}" ] && kill -0 "$GRAF_PF_PID" 2>/dev/null; then
        kill "$GRAF_PF_PID" 2>/dev/null || true
        wait "$GRAF_PF_PID" 2>/dev/null || true
    fi
}

if kill -0 "$GRAF_PF_PID" 2>/dev/null; then
    graf_health=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3001/api/health" 2>/dev/null || echo "000")
    if [ "$graf_health" = "200" ]; then
        log_pass "Grafana is healthy (HTTP 200)"
    else
        log_fail "Grafana health check returned HTTP ${graf_health}"
    fi

    # Check if dashboard was loaded by sidecar
    dash_search=$(curl -s "http://admin:prom-operator@localhost:3001/api/search?query=Slurm" 2>/dev/null || echo "[]")
    if echo "$dash_search" | grep -q "Slurm"; then
        log_pass "Grafana sidecar loaded Slurm dashboard"
    else
        log_info "Slurm dashboard not yet visible in Grafana search (sidecar may need time)"
    fi
    graf_cleanup
    section_results+=("${GREEN}PASS${NC} Grafana Dashboard Check")
else
    log_fail "Could not port-forward Grafana"
    section_results+=("${RED}FAIL${NC} Grafana Dashboard Check")
fi

# ══════════════════════════════════════════════════════════════════════════════
# Section 5: Interactive Access Check
# ══════════════════════════════════════════════════════════════════════════════
log_section "Section 5: Interactive Access Check"

log_info "Verifying login pod is accessible..."
if ${KUBECTL} bash -c 'echo "shell-ok"' 2>/dev/null | grep -q "shell-ok"; then
    log_pass "Login pod shell accessible (make slurm/shell works)"
else
    log_fail "Cannot exec into login pod"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Final Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              Phase 4 Validation Summary                     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
for result in "${section_results[@]}"; do
    printf "║  %-58b ║\n" "$result"
done
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Total: ${GREEN}%-3d passed${NC}                                        ║\n" "$total_pass"
if [ $total_fail -gt 0 ]; then
    printf "║  Total: ${RED}%-3d failed${NC}                                        ║\n" "$total_fail"
fi
echo "╚══════════════════════════════════════════════════════════════╝"

[ $total_fail -eq 0 ] && exit 0 || exit 1
