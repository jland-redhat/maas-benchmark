#!/bin/bash
# benchmark-concurrent-users.sh
# Finds the concurrent user breaking point for the MaaS platform

set -euo pipefail

# ========================================
# Configuration
# ========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results/concurrent-users"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_phase() { echo -e "\n${BLUE}========== $1 ==========${NC}\n" >&2; }
log_success() { echo -e "${CYAN}✅ $1${NC}" >&2; }
log_breaking() { echo -e "\n${RED}🚨 BREAKING POINT: $1${NC}\n" >&2; }

# Environment configuration
HOST="${HOST:-maas.$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo 'example.com')}"
PROTOCOL="${PROTOCOL:-https}"
MODEL_NAME="${MODEL_NAME:-facebook-opt-125m-simulated}"
MODEL_BASE_PATH="${MODEL_BASE_PATH:-llm}"
MODEL_PAYLOAD_ID="${MODEL_PAYLOAD_ID:-facebook/opt-125m}"
MAAS_CR_NAMESPACE="${MAAS_CR_NAMESPACE:-models-as-a-service}"

# Test configuration - ramping VU counts
VU_STAGES="${VU_STAGES:-1 5 10 25 50 100 200}"
STAGE_DURATION="${STAGE_DURATION:-2m}"
SUSTAIN_DURATION="${SUSTAIN_DURATION:-10m}"

# Breaking point thresholds
MAX_P95_LATENCY_MS="${MAX_P95_LATENCY_MS:-5000}"
MAX_ERROR_RATE="${MAX_ERROR_RATE:-0.05}"
MIN_SUCCESS_RATE="${MIN_SUCCESS_RATE:-0.95}"

mkdir -p "$RESULTS_DIR"

# ========================================
# Summary file setup
# ========================================
SUMMARY_FILE="$RESULTS_DIR/concurrent-users-benchmark-$(date +%Y-%m-%d).md"

init_summary() {
  cat > "$SUMMARY_FILE" << 'EOF'
# Concurrent User Breaking Point Benchmark Results

## Run Metadata

| Parameter | Value |
|-----------|-------|
EOF

  echo "| **Executed at** | $(date -u +"%Y-%m-%d %H:%M:%S UTC") |" >> "$SUMMARY_FILE"
  echo "| **Target Host** | \`${HOST}\` |" >> "$SUMMARY_FILE"
  echo "| **Model** | \`${MODEL_NAME}\` |" >> "$SUMMARY_FILE"
  
  cat >> "$SUMMARY_FILE" << 'EOF'

## Test Objective

Find the maximum number of concurrent users the MaaS platform can handle
before performance degrades or errors increase unacceptably.

## Test Architecture

```
                          Load Generator (k6)
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
        ▼                      ▼                      ▼
   ┌────────┐            ┌────────┐            ┌────────┐
   │  VU 1  │            │  VU 2  │    ...     │  VU N  │
   └────┬───┘            └────┬───┘            └────┬───┘
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     MaaS Gateway                                     │
│  ┌──────────┐  ┌───────────┐  ┌───────────┐  ┌─────────────┐       │
│  │  Router  │→│ Authorino │→│ Limitador │→│ Model Server │       │
│  └──────────┘  └───────────┘  └───────────┘  └─────────────┘       │
└─────────────────────────────────────────────────────────────────────┘

Bottleneck Detection Points:
- Router: Connection limits, TLS overhead
- Authorino: API key validation throughput
- Limitador: Rate limit counter operations
- Model Server: Inference capacity
```

## Breaking Point Criteria

| Metric | Healthy | Degraded | Breaking |
|--------|---------|----------|----------|
| p95 Latency | < 1000ms | 1000-5000ms | > 5000ms |
| Error Rate | < 1% | 1-5% | > 5% |
| Success Rate | > 99% | 95-99% | < 95% |

---

## Results Summary

### Ramping Load Test

| VUs | Duration | Avg Latency (ms) | p50 (ms) | p95 (ms) | Success Rate | Error Rate | Status |
|-----|----------|------------------|----------|----------|--------------|------------|--------|
EOF
}

# ========================================
# Benchmark functions
# ========================================

get_auth_token() {
  kubectl create token default -n "${MAAS_CR_NAMESPACE}" --duration=4h 2>/dev/null || echo ""
}

get_api_key() {
  local token_file="$PROJECT_DIR/tokens/concurrent-benchmark/all_tokens.json"
  if [[ -f "$token_file" ]]; then
    jq -r '.free[0].token // empty' "$token_file" 2>/dev/null || echo ""
  fi
}

provision_api_key() {
  local token_dir="$PROJECT_DIR/tokens/concurrent-benchmark"
  mkdir -p "$token_dir"
  
  log_info "Provisioning API key for concurrent user benchmark..."
  
  local auth_token
  auth_token=$(get_auth_token)
  
  local response
  response=$(curl -s -k -X POST "${PROTOCOL}://${HOST}/maas-api/v1/api-keys" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${auth_token}" \
    -d '{"name": "concurrent-benchmark-key", "expiresIn": "4h"}' 2>/dev/null || echo '{}')
  
  local api_key
  api_key=$(echo "$response" | jq -r '.key // empty')
  
  if [[ -n "$api_key" ]]; then
    echo "{\"free\": [{\"user_id\": \"concurrent-benchmark\", \"token\": \"${api_key}\", \"tier\": \"free\"}], \"premium\": []}" > "$token_dir/all_tokens.json"
    log_info "API key provisioned successfully"
    echo "$api_key"
  else
    log_warn "Failed to provision API key"
    echo ""
  fi
}

run_load_stage() {
  local vus=$1
  local duration=$2
  
  log_info "Testing with ${vus} concurrent users for ${duration}..."
  
  local result_file="$RESULTS_DIR/k6_${vus}vus_${TIMESTAMP}.json"
  
  local api_key
  api_key=$(get_api_key)
  if [[ -z "$api_key" ]]; then
    api_key=$(provision_api_key)
  fi
  
  k6 run \
    -e MODE="sustained_load" \
    -e HOST="$HOST" \
    -e PROTOCOL="$PROTOCOL" \
    -e MODEL_NAME="$MODEL_NAME" \
    -e MODEL_BASE_PATH="$MODEL_BASE_PATH" \
    -e MODEL_PAYLOAD_ID="$MODEL_PAYLOAD_ID" \
    -e API_KEY="$api_key" \
    -e VUS="$vus" \
    -e DURATION="$duration" \
    --summary-export="$result_file" \
    "$PROJECT_DIR/k6/concurrent-users-benchmark.js" >&2 2>&1 || true
  
  if [[ -f "$result_file" ]]; then
    local avg p50 p95 success_rate error_rate
    avg=$(jq -r '.metrics.http_req_duration.avg // "N/A"' "$result_file")
    p50=$(jq -r '.metrics.http_req_duration.med // "N/A"' "$result_file")
    p95=$(jq -r '.metrics.http_req_duration["p(95)"] // "N/A"' "$result_file")
    success_rate=$(jq -r '.metrics.success_rate.value // "N/A"' "$result_file")
    error_rate=$(jq -r '.metrics.http_req_failed.value // "N/A"' "$result_file")
    
    echo "${avg}|${p50}|${p95}|${success_rate}|${error_rate}"
  else
    echo "N/A|N/A|N/A|N/A|N/A"
  fi
}

check_breaking_point() {
  local p95=$1
  local success_rate=$2
  local error_rate=$3
  
  local is_breaking=false
  local reason=""
  
  # Check p95 latency
  if [[ "$p95" != "N/A" ]]; then
    local p95_int
    p95_int=$(printf "%.0f" "$p95" 2>/dev/null || echo "0")
    if (( p95_int > MAX_P95_LATENCY_MS )); then
      is_breaking=true
      reason="p95 latency (${p95_int}ms) > ${MAX_P95_LATENCY_MS}ms"
    fi
  fi
  
  # Check success rate
  if [[ "$success_rate" != "N/A" && "$is_breaking" == "false" ]]; then
    local below_min
    below_min=$(echo "$success_rate < $MIN_SUCCESS_RATE" | bc 2>/dev/null || echo "0")
    if [[ "$below_min" == "1" ]]; then
      is_breaking=true
      local success_pct
      success_pct=$(echo "$success_rate * 100" | bc 2>/dev/null || echo "$success_rate")
      reason="Success rate (${success_pct}%) < $(echo "$MIN_SUCCESS_RATE * 100" | bc)%"
    fi
  fi
  
  # Check error rate
  if [[ "$error_rate" != "N/A" && "$is_breaking" == "false" ]]; then
    local above_max
    above_max=$(echo "$error_rate > $MAX_ERROR_RATE" | bc 2>/dev/null || echo "0")
    if [[ "$above_max" == "1" ]]; then
      is_breaking=true
      local error_pct
      error_pct=$(echo "$error_rate * 100" | bc 2>/dev/null || echo "$error_rate")
      reason="Error rate (${error_pct}%) > $(echo "$MAX_ERROR_RATE * 100" | bc)%"
    fi
  fi
  
  if [[ "$is_breaking" == "true" ]]; then
    echo "BREAKING|${reason}"
  else
    echo "OK"
  fi
}

# ========================================
# Main execution
# ========================================
log_phase "Concurrent User Breaking Point Benchmark"
init_summary

BREAKING_POINT=""
BREAKING_REASON=""
LAST_HEALTHY_VUS=0

# Run ramping load test
for vus in $VU_STAGES; do
  log_phase "Stage: ${vus} VUs"
  
  result=$(run_load_stage "$vus" "$STAGE_DURATION")
  IFS='|' read -r avg p50 p95 success_rate error_rate <<< "$result"
  
  # Format values
  avg_fmt=$(printf "%.2f" "$avg" 2>/dev/null || echo "$avg")
  p50_fmt=$(printf "%.2f" "$p50" 2>/dev/null || echo "$p50")
  p95_fmt=$(printf "%.2f" "$p95" 2>/dev/null || echo "$p95")
  success_fmt=$(printf "%.2f%%" "$(echo "$success_rate * 100" | bc 2>/dev/null)" 2>/dev/null || echo "$success_rate")
  error_fmt=$(printf "%.2f%%" "$(echo "$error_rate * 100" | bc 2>/dev/null)" 2>/dev/null || echo "$error_rate")
  
  # Check for breaking point
  check_result=$(check_breaking_point "$p95" "$success_rate" "$error_rate")
  
  if [[ "$check_result" == "OK" ]]; then
    LAST_HEALTHY_VUS=$vus
    status="✅"
    log_success "Stage passed: ${vus} VUs - avg=${avg_fmt}ms, p95=${p95_fmt}ms, success=${success_fmt}"
  else
    status="🚨"
    if [[ -z "$BREAKING_POINT" ]]; then
      BREAKING_POINT=$vus
      BREAKING_REASON="${check_result#BREAKING|}"
      log_breaking "${vus} VUs - ${BREAKING_REASON}"
    fi
  fi
  
  echo "| ${vus} | ${STAGE_DURATION} | ${avg_fmt} | ${p50_fmt} | ${p95_fmt} | ${success_fmt} | ${error_fmt} | ${status} |" >> "$SUMMARY_FILE"
  
  # Stop if breaking point found and we've tested a few more stages
  if [[ -n "$BREAKING_POINT" ]]; then
    log_warn "Breaking point found at ${BREAKING_POINT} VUs, stopping test"
    break
  fi
  
  # Brief pause between stages
  sleep 5
done

# Add breaking point analysis
cat >> "$SUMMARY_FILE" << 'EOF'

---

## Breaking Point Analysis

EOF

if [[ -n "$BREAKING_POINT" ]]; then
  cat >> "$SUMMARY_FILE" << EOF
### 🚨 Breaking Point Detected

| Metric | Value |
|--------|-------|
| **Breaking Point** | ${BREAKING_POINT} concurrent users |
| **Last Healthy** | ${LAST_HEALTHY_VUS} concurrent users |
| **Reason** | ${BREAKING_REASON} |
| **Safe Operating Limit** | $(echo "$LAST_HEALTHY_VUS * 0.8" | bc | cut -d. -f1) concurrent users (80% of last healthy) |

### Recommended Actions

1. **Immediate**: Set concurrent user limit to ${LAST_HEALTHY_VUS}
2. **Scale Out**: Increase replicas of bottleneck component
3. **Monitor**: Watch for degradation at 80% of breaking point

EOF
else
  cat >> "$SUMMARY_FILE" << EOF
### ✅ No Breaking Point Found

| Metric | Value |
|--------|-------|
| **Maximum Tested** | ${LAST_HEALTHY_VUS} concurrent users |
| **All Tests Passed** | ✅ Yes |
| **Recommendation** | Test higher VU counts if needed |

System handled all tested concurrent user counts without hitting thresholds.

EOF
fi

# Finish summary
cat >> "$SUMMARY_FILE" << 'EOF'

---

## Bottleneck Identification

When breaking point is reached, identify the bottleneck:

| Component | Check | Command |
|-----------|-------|---------|
| **Router** | Connection queue depth | `kubectl top pod -l app=router` |
| **Authorino** | CPU/Memory saturation | `kubectl top pod -l app=authorino` |
| **Limitador** | Counter operation latency | `kubectl logs -l app=limitador \| grep latency` |
| **Model Server** | Inference queue depth | `kubectl logs -l serving.kserve.io \| grep queue` |
| **Database** | Connection pool exhaustion | Check PostgreSQL metrics |

---

## Scaling Recommendations

| Component | Default | Breaking Point Action |
|-----------|---------|----------------------|
| Router replicas | 2 | Increase to 4+ |
| Authorino replicas | 2 | Increase to 4+ |
| Limitador replicas | 2 | Increase to 4+ |
| Model Server replicas | 1 | Increase based on throughput needs |
| DB connections | 20 | Increase pool size |

---

## Artifacts

| File | Description |
|------|-------------|
EOF

echo "| \`${SUMMARY_FILE}\` | This summary file |" >> "$SUMMARY_FILE"
echo "| \`${RESULTS_DIR}/k6_*_${TIMESTAMP}.json\` | Individual k6 results |" >> "$SUMMARY_FILE"

cat >> "$SUMMARY_FILE" << 'EOF'

---

## Commands Used

```bash
# Run this benchmark
MODEL_NAME=facebook-opt-125m-simulated \
./scripts/benchmark-concurrent-users.sh

# Custom configuration
VU_STAGES="1 10 25 50 100 200 500" \
STAGE_DURATION="3m" \
MAX_P95_LATENCY_MS=3000 \
./scripts/benchmark-concurrent-users.sh
```
EOF

log_phase "Benchmark Complete"
log_success "Results saved to: ${SUMMARY_FILE}"
cat "$SUMMARY_FILE"
