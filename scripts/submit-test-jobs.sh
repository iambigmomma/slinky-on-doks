#!/bin/bash
set -euo pipefail

NAMESPACE="slurm"
LOGIN_POD="deploy/slurm-login-slinky"
KUBECTL="kubectl exec -n ${NAMESPACE} ${LOGIN_POD} --"
POLL_INTERVAL=5
TIMEOUT=300  # 5 minutes

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass=0
fail=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; pass=$((pass + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; fail=$((fail + 1)); }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# ── Step 1: Create directories on NFS ────────────────────────────────────────
log_info "Creating /shared/jobs/ and /shared/output/ on NFS..."
${KUBECTL} bash -c 'mkdir -p /shared/jobs /shared/output'

# ── Step 2: Copy job scripts to NFS ──────────────────────────────────────────
log_info "Copying job scripts to NFS..."
for script in jobs/*.sh; do
    name=$(basename "$script")
    kubectl exec -i -n ${NAMESPACE} ${LOGIN_POD} -- bash -c "cat > /shared/jobs/${name}" < "$script"
    ${KUBECTL} chmod +x "/shared/jobs/${name}"
    log_info "  Copied ${name}"
done

# Verify scripts are on NFS
script_count=$(${KUBECTL} bash -c 'ls /shared/jobs/*.sh 2>/dev/null | wc -l')
if [ "$script_count" -ge 4 ]; then
    log_pass "Job scripts present on NFS (${script_count} files)"
else
    log_fail "Expected 4+ job scripts on NFS, found ${script_count}"
fi

# ── Step 3: Submit test jobs ─────────────────────────────────────────────────
log_info "Submitting cpu_stress.sh (single-node)..."
CPU_JOB_ID=$(${KUBECTL} bash -c 'sbatch /shared/jobs/cpu_stress.sh 2>&1' | grep -oP '\d+$')
if [ -n "$CPU_JOB_ID" ]; then
    log_info "  cpu_stress submitted as job ${CPU_JOB_ID}"
else
    log_fail "Failed to submit cpu_stress.sh"
    CPU_JOB_ID=""
fi

log_info "Submitting multi_node_mock.sh (multi-node)..."
MULTI_JOB_ID=$(${KUBECTL} bash -c 'sbatch /shared/jobs/multi_node_mock.sh 2>&1' | grep -oP '\d+$')
if [ -n "$MULTI_JOB_ID" ]; then
    log_info "  multi_node_mock submitted as job ${MULTI_JOB_ID}"
else
    log_fail "Failed to submit multi_node_mock.sh"
    MULTI_JOB_ID=""
fi

# ── Step 4: Poll until both complete ─────────────────────────────────────────
if [ -n "$CPU_JOB_ID" ] || [ -n "$MULTI_JOB_ID" ]; then
    log_info "Waiting for jobs to complete (timeout: ${TIMEOUT}s)..."
    elapsed=0
    while [ $elapsed -lt $TIMEOUT ]; do
        pending=0
        if [ -n "$CPU_JOB_ID" ]; then
            state=$(${KUBECTL} bash -c "sacct -j ${CPU_JOB_ID} -n -o State -X 2>/dev/null | tr -d ' '" || echo "UNKNOWN")
            if [[ "$state" != "COMPLETED" && "$state" != "FAILED" && "$state" != "CANCELLED" && "$state" != "TIMEOUT" ]]; then
                pending=1
            fi
        fi
        if [ -n "$MULTI_JOB_ID" ]; then
            state=$(${KUBECTL} bash -c "sacct -j ${MULTI_JOB_ID} -n -o State -X 2>/dev/null | tr -d ' '" || echo "UNKNOWN")
            if [[ "$state" != "COMPLETED" && "$state" != "FAILED" && "$state" != "CANCELLED" && "$state" != "TIMEOUT" ]]; then
                pending=1
            fi
        fi
        if [ $pending -eq 0 ]; then
            break
        fi
        log_info "  Jobs still running... (${elapsed}s elapsed)"
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    if [ $elapsed -ge $TIMEOUT ]; then
        log_fail "Timed out waiting for jobs to complete"
    fi
fi

# ── Step 5: Validate results ─────────────────────────────────────────────────

# Validate single-node job
if [ -n "$CPU_JOB_ID" ]; then
    cpu_state=$(${KUBECTL} bash -c "sacct -j ${CPU_JOB_ID} -n -o State -X 2>/dev/null | tr -d ' '")
    if [ "$cpu_state" = "COMPLETED" ]; then
        log_pass "Single-node job ${CPU_JOB_ID} completed (sacct: COMPLETED)"
    else
        log_fail "Single-node job ${CPU_JOB_ID} state: ${cpu_state}"
    fi

    if ${KUBECTL} bash -c "test -f /shared/output/cpu_stress-${CPU_JOB_ID}.out" 2>/dev/null; then
        log_pass "Single-node output file exists on NFS"
    else
        log_fail "Single-node output file not found at /shared/output/cpu_stress-${CPU_JOB_ID}.out"
    fi
fi

# Validate multi-node job
if [ -n "$MULTI_JOB_ID" ]; then
    multi_state=$(${KUBECTL} bash -c "sacct -j ${MULTI_JOB_ID} -n -o State -X 2>/dev/null | tr -d ' '")
    if [ "$multi_state" = "COMPLETED" ]; then
        log_pass "Multi-node job ${MULTI_JOB_ID} completed (sacct: COMPLETED)"
    else
        log_fail "Multi-node job ${MULTI_JOB_ID} state: ${multi_state}"
    fi

    if ${KUBECTL} bash -c "test -f /shared/output/multi_node-${MULTI_JOB_ID}.out" 2>/dev/null; then
        log_pass "Multi-node output file exists on NFS"
    else
        log_fail "Multi-node output file not found at /shared/output/multi_node-${MULTI_JOB_ID}.out"
    fi

    # Check that multi-node used 2+ nodes
    node_count=$(${KUBECTL} bash -c "sacct -j ${MULTI_JOB_ID} -n -o NNodes -X 2>/dev/null | tr -d ' '")
    if [ -n "$node_count" ] && [ "$node_count" -ge 2 ] 2>/dev/null; then
        log_pass "Multi-node job used ${node_count} nodes"
    else
        log_fail "Multi-node job node count: ${node_count:-unknown} (expected >= 2)"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo -e "  Submit Test Summary: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}"
echo "════════════════════════════════════════"

[ $fail -eq 0 ] && exit 0 || exit 1
