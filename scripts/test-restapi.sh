#!/bin/bash
set -euo pipefail

NAMESPACE="slurm"
LOGIN_POD="deploy/slurm-login-slinky"
KUBECTL="kubectl exec -n ${NAMESPACE} ${LOGIN_POD} --"
LOCAL_PORT=6820
PF_PID=""

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass=0
fail=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; pass=$((pass + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; fail=$((fail + 1)); }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

cleanup() {
    if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
        log_info "Cleaning up port-forward (PID: ${PF_PID})"
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Step 1: Get JWT token ────────────────────────────────────────────────────
log_info "Obtaining JWT token from scontrol..."
TOKEN_OUTPUT=$(${KUBECTL} bash -c 'scontrol token lifespan=600 2>&1') || true
TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oP 'SLURM_JWT=\K.*' || echo "")

if [ -z "$TOKEN" ]; then
    log_fail "Could not obtain JWT token. Output: ${TOKEN_OUTPUT}"
    echo ""
    echo "════════════════════════════════════════"
    echo -e "  REST API Test Summary: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}"
    echo "════════════════════════════════════════"
    exit 1
fi
log_pass "JWT token obtained"

# ── Step 2: Start port-forward ───────────────────────────────────────────────
log_info "Starting port-forward to slurmrestd (localhost:${LOCAL_PORT})..."
kubectl port-forward -n ${NAMESPACE} svc/slurm-restapi ${LOCAL_PORT}:6820 &>/dev/null &
PF_PID=$!
sleep 3

if ! kill -0 "$PF_PID" 2>/dev/null; then
    log_fail "Port-forward failed to start"
    exit 1
fi
log_info "Port-forward active (PID: ${PF_PID})"

BASE_URL="http://localhost:${LOCAL_PORT}"
AUTH_HEADER="X-SLURM-USER-TOKEN: ${TOKEN}"
USER_HEADER="X-SLURM-USER-NAME: root"

# ── Step 3: Auto-detect API version ─────────────────────────────────────────
log_info "Auto-detecting slurmrestd API version..."
API_VERSION=""
for ver in "v0.0.43" "v0.0.42" "v0.0.41" "v0.0.40"; do
    status=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "${AUTH_HEADER}" -H "${USER_HEADER}" \
        "${BASE_URL}/slurm/${ver}/diag" 2>/dev/null || echo "000")
    if [ "$status" = "200" ]; then
        API_VERSION="$ver"
        break
    fi
done

if [ -z "$API_VERSION" ]; then
    log_fail "Could not detect API version (tried v0.0.40-43)"
    # Try without version prefix
    status=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "${AUTH_HEADER}" -H "${USER_HEADER}" \
        "${BASE_URL}/slurm/v0.0.41/ping" 2>/dev/null || echo "000")
    log_info "  Fallback /ping status: ${status}"
    API_VERSION="v0.0.41"
fi
log_pass "API version detected: ${API_VERSION}"

API_BASE="${BASE_URL}/slurm/${API_VERSION}"

# ── Step 4: Test GET endpoints ───────────────────────────────────────────────
test_endpoint() {
    local name="$1"
    local path="$2"
    local url="${API_BASE}${path}"

    status=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "${AUTH_HEADER}" -H "${USER_HEADER}" \
        "$url" 2>/dev/null || echo "000")

    if [ "$status" = "200" ]; then
        log_pass "GET ${path} → ${status}"
    else
        log_fail "GET ${path} → ${status}"
    fi
}

log_info "Testing GET endpoints..."
test_endpoint "diag" "/diag"
test_endpoint "ping" "/ping"
test_endpoint "nodes" "/nodes"
test_endpoint "partitions" "/partitions"
test_endpoint "jobs" "/jobs"

# ── Step 5: Test job submission via POST ─────────────────────────────────────
log_info "Testing job submission via REST API..."
SUBMIT_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "${USER_HEADER}" \
    -H "Content-Type: application/json" \
    -d '{
        "job": {
            "name": "restapi-test",
            "ntasks": 1,
            "cpus_per_task": 1,
            "time_limit": {
                "number": 1,
                "set": true
            },
            "current_working_directory": "/shared/output",
            "standard_output": "/shared/output/restapi-test-%j.out",
            "environment": ["PATH=/usr/bin:/bin"],
            "partition": "all"
        },
        "script": "#!/bin/bash\necho \"REST API test job on $(hostname)\"\nsleep 5\necho done"
    }' \
    "${API_BASE}/job/submit" 2>/dev/null) || true

SUBMIT_HTTP=$(echo "$SUBMIT_RESPONSE" | tail -1)
SUBMIT_BODY=$(echo "$SUBMIT_RESPONSE" | head -n -1)

if [ "$SUBMIT_HTTP" = "200" ]; then
    JOB_ID=$(echo "$SUBMIT_BODY" | grep -oP '"job_id"\s*:\s*\K\d+' || echo "")
    if [ -n "$JOB_ID" ]; then
        log_pass "POST /job/submit → 200 (job_id: ${JOB_ID})"

        # Query the submitted job
        sleep 2
        query_status=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "${AUTH_HEADER}" -H "${USER_HEADER}" \
            "${API_BASE}/job/${JOB_ID}" 2>/dev/null || echo "000")
        if [ "$query_status" = "200" ]; then
            log_pass "GET /job/${JOB_ID} → ${query_status} (job status query works)"
        else
            log_fail "GET /job/${JOB_ID} → ${query_status}"
        fi
    else
        log_pass "POST /job/submit → 200 (could not parse job_id)"
    fi
else
    log_fail "POST /job/submit → ${SUBMIT_HTTP}"
    log_info "  Response: ${SUBMIT_BODY}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo -e "  REST API Test Summary: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}"
echo "════════════════════════════════════════"

[ $fail -eq 0 ] && exit 0 || exit 1
