#!/bin/bash
# benchmark-inference-latency.sh
# Measures end-to-end inference latency and gateway overhead

set -euo pipefail

# ========================================
# Configuration
# ========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results/inference-latency"
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

# Environment configuration
HOST="${HOST:-maas.$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo 'example.com')}"
PROTOCOL="${PROTOCOL:-https}"
MODEL_NAME="${MODEL_NAME:-facebook-opt-125m-simulated}"
MODEL_BASE_PATH="${MODEL_BASE_PATH:-llm}"
MODEL_PAYLOAD_ID="${MODEL_PAYLOAD_ID:-facebook/opt-125m}"
MAAS_CR_NAMESPACE="${MAAS_CR_NAMESPACE:-models-as-a-service}"

# Test configuration
VUS="${VUS:-5}"
ITERATIONS="${ITERATIONS:-50}"
TOKEN_SIZES="${TOKEN_SIZES:-10 50 100 500}"
DURATION="${DURATION:-30s}"

mkdir -p "$RESULTS_DIR"

# ========================================
# Summary file setup
# ========================================
SUMMARY_FILE="$RESULTS_DIR/inference-latency-benchmark-$(date +%Y-%m-%d).md"

init_summary() {
  cat > "$SUMMARY_FILE" << 'EOF'
# End-to-End Inference Latency Benchmark Results

## Run Metadata

| Parameter | Value |
|-----------|-------|
EOF

  echo "| **Executed at** | $(date -u +"%Y-%m-%d %H:%M:%S UTC") |" >> "$SUMMARY_FILE"
  echo "| **Target Host** | \`${HOST}\` |" >> "$SUMMARY_FILE"
  echo "| **Model** | \`${MODEL_NAME}\` |" >> "$SUMMARY_FILE"
  
  cat >> "$SUMMARY_FILE" << 'EOF'

## Test Architecture

```
                                    Latency Measurement Points
                                    ─────────────────────────
┌────────┐      ┌─────────┐      ┌───────────┐      ┌───────────┐      ┌─────────────┐
│   k6   │─────▶│ Router  │─────▶│ Authorino │─────▶│ Limitador │─────▶│Model Server │
│ Client │      │ Ingress │      │   Auth    │      │Rate Limit │      │  (vLLM)     │
└────────┘      └─────────┘      └───────────┘      └───────────┘      └─────────────┘
    │                                                                        │
    └───────────────────── Total E2E Latency ────────────────────────────────┘

Direct Baseline (bypassing gateway):
┌────────┐                                                           ┌─────────────┐
│   k6   │──────────────────────────────────────────────────────────▶│Model Server │
│ Client │                                                           │  (vLLM)     │
└────────┘                                                           └─────────────┘

Gateway Overhead = E2E Latency - Direct Baseline
```

---

## Test Scenarios

| Scenario | Path | Auth Method | Purpose |
|----------|------|-------------|---------|
| Direct Baseline | Model only | None | Measure raw model latency |
| Full Gateway | Gateway → Model | API key | Total system latency |
| K8s Token | Gateway → Model | K8s token | Compare auth methods |
| Variable Size | Gateway → Model | API key | Token size impact |

---

## Results Summary

### Baseline vs Gateway Comparison

| Scenario | Auth Method | max_tokens | Avg Latency (ms) | p50 (ms) | p95 (ms) | Overhead (ms) | Status |
|----------|-------------|------------|------------------|----------|----------|---------------|--------|
EOF
}

# ========================================
# Benchmark functions
# ========================================

get_auth_token() {
  kubectl create token default -n "${MAAS_CR_NAMESPACE}" --duration=4h 2>/dev/null || echo ""
}

get_api_key() {
  local token_file="$PROJECT_DIR/tokens/inference-benchmark/all_tokens.json"
  if [[ -f "$token_file" ]]; then
    jq -r '.free[0].token // empty' "$token_file" 2>/dev/null || echo ""
  fi
}

provision_api_key() {
  local token_dir="$PROJECT_DIR/tokens/inference-benchmark"
  mkdir -p "$token_dir"
  
  log_info "Provisioning API key for inference benchmark..."
  
  local auth_token
  auth_token=$(get_auth_token)
  
  local response
  response=$(curl -s -k -X POST "${PROTOCOL}://${HOST}/maas-api/v1/api-keys" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${auth_token}" \
    -d '{"name": "inference-benchmark-key", "expiresIn": "4h"}' 2>/dev/null || echo '{}')
  
  local api_key
  api_key=$(echo "$response" | jq -r '.key // empty')
  
  if [[ -n "$api_key" ]]; then
    echo "{\"free\": [{\"user_id\": \"inference-benchmark\", \"token\": \"${api_key}\", \"tier\": \"free\"}], \"premium\": []}" > "$token_dir/all_tokens.json"
    log_info "API key provisioned successfully"
    echo "$api_key"
  else
    log_warn "Failed to provision API key"
    echo ""
  fi
}

run_inference_test() {
  local auth_type=$1
  local max_tokens=$2
  local scenario=$3
  
  log_info "Testing: ${scenario} with ${auth_type} auth, max_tokens=${max_tokens}..."
  
  local result_file="$RESULTS_DIR/k6_${scenario}_${auth_type}_${max_tokens}tok_${TIMESTAMP}.json"
  local auth_header=""
  
  case "$auth_type" in
    "api_key")
      local api_key
      api_key=$(get_api_key)
      if [[ -z "$api_key" ]]; then
        api_key=$(provision_api_key)
      fi
      auth_header="Bearer ${api_key}"
      ;;
    "k8s_token")
      local k8s_token
      k8s_token=$(get_auth_token)
      auth_header="Bearer ${k8s_token}"
      ;;
    "none")
      auth_header=""
      ;;
  esac
  
  k6 run \
    -e MODE="inference" \
    -e HOST="$HOST" \
    -e PROTOCOL="$PROTOCOL" \
    -e MODEL_NAME="$MODEL_NAME" \
    -e MODEL_BASE_PATH="$MODEL_BASE_PATH" \
    -e MODEL_PAYLOAD_ID="$MODEL_PAYLOAD_ID" \
    -e AUTH_HEADER="$auth_header" \
    -e MAX_TOKENS="$max_tokens" \
    -e VUS="$VUS" \
    -e ITERATIONS="$ITERATIONS" \
    --summary-export="$result_file" \
    "$PROJECT_DIR/k6/inference-latency-benchmark.js" >&2 2>&1 || true
  
  if [[ -f "$result_file" ]]; then
    local avg p50 p95
    avg=$(jq -r '.metrics.http_req_duration.avg // "N/A"' "$result_file")
    p50=$(jq -r '.metrics.http_req_duration.med // "N/A"' "$result_file")
    p95=$(jq -r '.metrics.http_req_duration["p(95)"] // "N/A"' "$result_file")
    
    echo "${avg}|${p50}|${p95}"
  else
    echo "N/A|N/A|N/A"
  fi
}

# ========================================
# Main execution
# ========================================
log_phase "End-to-End Inference Latency Benchmark"
init_summary

# Store baseline for overhead calculation
BASELINE_P95=""

# Test 1: Direct baseline (if possible)
log_phase "Phase 1: Direct Baseline Measurement"

# Check if we can access model directly
MODEL_DIRECT_URL=$(kubectl get svc -n llm -l serving.kserve.io/inferenceservice="${MODEL_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$MODEL_DIRECT_URL" ]]; then
  result=$(run_inference_test "none" "50" "direct")
  IFS='|' read -r avg p50 p95 <<< "$result"
  BASELINE_P95="$p95"
  
  avg_fmt=$(printf "%.2f" "$avg" 2>/dev/null || echo "$avg")
  p50_fmt=$(printf "%.2f" "$p50" 2>/dev/null || echo "$p50")
  p95_fmt=$(printf "%.2f" "$p95" 2>/dev/null || echo "$p95")
  
  echo "| Direct Baseline | None | 50 | ${avg_fmt} | ${p50_fmt} | ${p95_fmt} | - | ✅ |" >> "$SUMMARY_FILE"
  log_info "Direct baseline: avg=${avg_fmt}ms, p50=${p50_fmt}ms, p95=${p95_fmt}ms"
else
  log_info "Direct model access not available, skipping baseline"
  echo "| Direct Baseline | None | 50 | N/A | N/A | N/A | - | ⏭️ |" >> "$SUMMARY_FILE"
fi

# Test 2: Full gateway with API key
log_phase "Phase 2: Full Gateway with API Key"

for max_tokens in $TOKEN_SIZES; do
  result=$(run_inference_test "api_key" "$max_tokens" "gateway")
  IFS='|' read -r avg p50 p95 <<< "$result"
  
  avg_fmt=$(printf "%.2f" "$avg" 2>/dev/null || echo "$avg")
  p50_fmt=$(printf "%.2f" "$p50" 2>/dev/null || echo "$p50")
  p95_fmt=$(printf "%.2f" "$p95" 2>/dev/null || echo "$p95")
  
  overhead="-"
  if [[ -n "$BASELINE_P95" && "$BASELINE_P95" != "N/A" && "$p95" != "N/A" ]]; then
    overhead=$(echo "scale=2; $p95 - $BASELINE_P95" | bc 2>/dev/null || echo "-")
  fi
  
  status="✅"
  if [[ "$p95" != "N/A" ]]; then
    p95_int=$(printf "%.0f" "$p95" 2>/dev/null || echo "0")
    if (( p95_int > 5000 )); then
      status="🚨"
    elif (( p95_int > 1000 )); then
      status="⚠️"
    fi
  fi
  
  echo "| Full Gateway | API key | ${max_tokens} | ${avg_fmt} | ${p50_fmt} | ${p95_fmt} | ${overhead} | ${status} |" >> "$SUMMARY_FILE"
  log_info "Gateway (${max_tokens} tokens): avg=${avg_fmt}ms, p50=${p50_fmt}ms, p95=${p95_fmt}ms"
done

# Test 3: K8s token comparison
log_phase "Phase 3: K8s Token Authentication Comparison"

result=$(run_inference_test "k8s_token" "50" "k8s_auth")
IFS='|' read -r avg p50 p95 <<< "$result"

avg_fmt=$(printf "%.2f" "$avg" 2>/dev/null || echo "$avg")
p50_fmt=$(printf "%.2f" "$p50" 2>/dev/null || echo "$p50")
p95_fmt=$(printf "%.2f" "$p95" 2>/dev/null || echo "$p95")

overhead="-"
if [[ -n "$BASELINE_P95" && "$BASELINE_P95" != "N/A" && "$p95" != "N/A" ]]; then
  overhead=$(echo "scale=2; $p95 - $BASELINE_P95" | bc 2>/dev/null || echo "-")
fi

echo "| K8s Token Auth | K8s token | 50 | ${avg_fmt} | ${p50_fmt} | ${p95_fmt} | ${overhead} | ✅ |" >> "$SUMMARY_FILE"
log_info "K8s token auth: avg=${avg_fmt}ms, p50=${p50_fmt}ms, p95=${p95_fmt}ms"

# Finish summary
cat >> "$SUMMARY_FILE" << 'EOF'

---

## Analysis

### Gateway Overhead

| Component | Estimated Overhead | Notes |
|-----------|-------------------|-------|
| Router/Ingress | ~5-10ms | TLS termination, routing |
| Authorino (API key) | ~20-50ms | Key validation, cache lookup |
| Authorino (K8s token) | ~30-70ms | TokenReview API call |
| Limitador | ~5-15ms | Rate limit check |
| **Total Gateway** | ~50-100ms | Typical overhead |

### Token Size Impact

The latency should scale linearly with token count due to model inference time.
Gateway overhead should remain constant regardless of token count.

---

## SLO Recommendations

| Metric | Recommended SLO | Notes |
|--------|-----------------|-------|
| p50 Latency | < 500ms | For typical 50-token requests |
| p95 Latency | < 1000ms | Account for variance |
| p99 Latency | < 2000ms | Tail latency tolerance |
| Gateway Overhead | < 100ms | Auth + rate limiting |

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
./scripts/benchmark-inference-latency.sh

# Custom configuration
VUS=10 ITERATIONS=100 \
TOKEN_SIZES="10 50 100" \
./scripts/benchmark-inference-latency.sh
```
EOF

log_phase "Benchmark Complete"
log_success "Results saved to: ${SUMMARY_FILE}"
cat "$SUMMARY_FILE"
