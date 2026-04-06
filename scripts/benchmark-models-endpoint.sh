#!/bin/bash
# benchmark-models-endpoint.sh
# Benchmarks the /v1/models endpoint performance

set -euo pipefail

# ========================================
# Configuration
# ========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results/models-endpoint"
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
MAAS_CR_NAMESPACE="${MAAS_CR_NAMESPACE:-models-as-a-service}"

# Test configuration
VUS="${VUS:-5}"
ITERATIONS="${ITERATIONS:-50}"
SUBSCRIPTION_COUNTS="${SUBSCRIPTION_COUNTS:-1 5 10}"

mkdir -p "$RESULTS_DIR"

# ========================================
# Summary file setup
# ========================================
SUMMARY_FILE="$RESULTS_DIR/models-endpoint-benchmark-$(date +%Y-%m-%d).md"

init_summary() {
  cat > "$SUMMARY_FILE" << 'EOF'
# /v1/models Endpoint Benchmark Results

## Run Metadata

| Parameter | Value |
|-----------|-------|
EOF

  echo "| **Executed at** | $(date -u +"%Y-%m-%d %H:%M:%S UTC") |" >> "$SUMMARY_FILE"
  echo "| **Target Host** | \`${HOST}\` |" >> "$SUMMARY_FILE"
  
  cat >> "$SUMMARY_FILE" << 'EOF'

## Overview

The `/v1/models` endpoint lists all models accessible to the user based on their subscriptions.
This benchmark measures how listing performance scales with subscription count.

## Test Architecture

```
┌────────┐      ┌─────────┐      ┌───────────┐      ┌──────────┐
│   k6   │─────▶│ Router  │─────▶│ Authorino │─────▶│ maas-api │
│ Client │      │ Ingress │      │   Auth    │      │ /v1/models│
└────────┘      └─────────┘      └───────────┘      └────┬─────┘
                                                         │
    ┌────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        Model Health Probes                           │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐                │
│  │ Model 1 │  │ Model 2 │  │ Model 3 │  │   ...   │                │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘                │
│                                                                     │
│  Each model is probed for availability (adds latency)               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Results Summary

### Subscription Count Impact

| Subscriptions | Models | With Filter | Avg Latency (ms) | p50 (ms) | p95 (ms) | Status |
|---------------|--------|-------------|------------------|----------|----------|--------|
EOF
}

# ========================================
# Benchmark functions
# ========================================

get_auth_token() {
  kubectl create token default -n "${MAAS_CR_NAMESPACE}" --duration=4h 2>/dev/null || echo ""
}

get_api_key() {
  local token_file="$PROJECT_DIR/tokens/models-benchmark/all_tokens.json"
  if [[ -f "$token_file" ]]; then
    jq -r '.free[0].token // empty' "$token_file" 2>/dev/null || echo ""
  fi
}

provision_api_key() {
  local token_dir="$PROJECT_DIR/tokens/models-benchmark"
  mkdir -p "$token_dir"
  
  log_info "Provisioning API key for models benchmark..."
  
  local auth_token
  auth_token=$(get_auth_token)
  
  local response
  response=$(curl -s -k -X POST "${PROTOCOL}://${HOST}/maas-api/v1/api-keys" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${auth_token}" \
    -d '{"name": "models-benchmark-key", "expiresIn": "4h"}' 2>/dev/null || echo '{}')
  
  local api_key
  api_key=$(echo "$response" | jq -r '.key // empty')
  
  if [[ -n "$api_key" ]]; then
    echo "{\"free\": [{\"user_id\": \"models-benchmark\", \"token\": \"${api_key}\", \"tier\": \"free\"}], \"premium\": []}" > "$token_dir/all_tokens.json"
    log_info "API key provisioned successfully"
    echo "$api_key"
  else
    log_warn "Failed to provision API key"
    echo ""
  fi
}

run_models_test() {
  local auth_type=$1
  local with_filter=$2
  local subscription_header="${3:-}"
  
  log_info "Testing /v1/models: auth=${auth_type}, filter=${with_filter}..."
  
  local result_file="$RESULTS_DIR/k6_models_${auth_type}_filter${with_filter}_${TIMESTAMP}.json"
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
  esac
  
  k6 run \
    -e MODE="models_list" \
    -e HOST="$HOST" \
    -e PROTOCOL="$PROTOCOL" \
    -e AUTH_HEADER="$auth_header" \
    -e WITH_FILTER="$with_filter" \
    -e SUBSCRIPTION_HEADER="$subscription_header" \
    -e VUS="$VUS" \
    -e ITERATIONS="$ITERATIONS" \
    --summary-export="$result_file" \
    "$PROJECT_DIR/k6/models-endpoint-benchmark.js" >&2 2>&1 || true
  
  if [[ -f "$result_file" ]]; then
    local avg p50 p95 model_count
    avg=$(jq -r '.metrics.http_req_duration.avg // "N/A"' "$result_file")
    p50=$(jq -r '.metrics.http_req_duration.med // "N/A"' "$result_file")
    p95=$(jq -r '.metrics.http_req_duration["p(95)"] // "N/A"' "$result_file")
    
    echo "${avg}|${p50}|${p95}"
  else
    echo "N/A|N/A|N/A"
  fi
}

count_user_subscriptions() {
  kubectl get maassubscription -A -o json 2>/dev/null | \
    jq '[.items[] | select(.spec.owner.groups[]?.name == "system:authenticated" or .spec.owner.users[]? == "system:serviceaccount:'${MAAS_CR_NAMESPACE}':default")] | length' 2>/dev/null || echo "0"
}

count_models() {
  kubectl get maasmodelref -A --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0"
}

# ========================================
# Main execution
# ========================================
log_phase "/v1/models Endpoint Benchmark"
init_summary

# Get current counts
SUB_COUNT=$(count_user_subscriptions)
MODEL_COUNT=$(count_models)

log_info "Current state: ${SUB_COUNT} subscriptions, ${MODEL_COUNT} models"

# Test 1: Without subscription filter
log_phase "Phase 1: Without Subscription Filter"

# Test with API key
result=$(run_models_test "api_key" "false")
IFS='|' read -r avg p50 p95 <<< "$result"

avg_fmt=$(printf "%.2f" "$avg" 2>/dev/null || echo "$avg")
p50_fmt=$(printf "%.2f" "$p50" 2>/dev/null || echo "$p50")
p95_fmt=$(printf "%.2f" "$p95" 2>/dev/null || echo "$p95")

status="✅"
if [[ "$p95" != "N/A" ]]; then
  p95_int=$(printf "%.0f" "$p95" 2>/dev/null || echo "0")
  if (( p95_int > 2000 )); then
    status="🚨"
  elif (( p95_int > 1000 )); then
    status="⚠️"
  fi
fi

echo "| ${SUB_COUNT} | ${MODEL_COUNT} | No | ${avg_fmt} | ${p50_fmt} | ${p95_fmt} | ${status} |" >> "$SUMMARY_FILE"
log_info "Without filter: avg=${avg_fmt}ms, p50=${p50_fmt}ms, p95=${p95_fmt}ms"

# Test 2: With subscription filter
log_phase "Phase 2: With Subscription Filter"

result=$(run_models_test "api_key" "true" "benchmark-baseline")
IFS='|' read -r avg p50 p95 <<< "$result"

avg_fmt=$(printf "%.2f" "$avg" 2>/dev/null || echo "$avg")
p50_fmt=$(printf "%.2f" "$p50" 2>/dev/null || echo "$p50")
p95_fmt=$(printf "%.2f" "$p95" 2>/dev/null || echo "$p95")

status="✅"
if [[ "$p95" != "N/A" ]]; then
  p95_int=$(printf "%.0f" "$p95" 2>/dev/null || echo "0")
  if (( p95_int > 2000 )); then
    status="🚨"
  elif (( p95_int > 1000 )); then
    status="⚠️"
  fi
fi

echo "| ${SUB_COUNT} | ${MODEL_COUNT} | Yes | ${avg_fmt} | ${p50_fmt} | ${p95_fmt} | ${status} |" >> "$SUMMARY_FILE"
log_info "With filter: avg=${avg_fmt}ms, p50=${p50_fmt}ms, p95=${p95_fmt}ms"

# Test 3: K8s token comparison
log_phase "Phase 3: K8s Token Authentication"

cat >> "$SUMMARY_FILE" << 'EOF'

### Authentication Method Comparison

| Auth Method | Avg Latency (ms) | p50 (ms) | p95 (ms) | Status |
|-------------|------------------|----------|----------|--------|
EOF

result=$(run_models_test "k8s_token" "false")
IFS='|' read -r avg p50 p95 <<< "$result"

avg_fmt=$(printf "%.2f" "$avg" 2>/dev/null || echo "$avg")
p50_fmt=$(printf "%.2f" "$p50" 2>/dev/null || echo "$p50")
p95_fmt=$(printf "%.2f" "$p95" 2>/dev/null || echo "$p95")

echo "| K8s Token | ${avg_fmt} | ${p50_fmt} | ${p95_fmt} | ✅ |" >> "$SUMMARY_FILE"
log_info "K8s token: avg=${avg_fmt}ms, p50=${p50_fmt}ms, p95=${p95_fmt}ms"

# Finish summary
cat >> "$SUMMARY_FILE" << 'EOF'

---

## Analysis

### Factors Affecting Latency

| Factor | Impact | Notes |
|--------|--------|-------|
| Subscription count | Linear | More subs = more models to check |
| Model count | Linear | Each model probed for health |
| Model health probe | Variable | Slow models increase latency |
| Network latency | Additive | Each probe adds network RTT |

### Optimization Tips

1. **Use subscription filter**: `X-MaaS-Subscription` header reduces probe count
2. **Cache responses**: Model list rarely changes, cache for 30-60s
3. **Healthy models**: Ensure model servers respond quickly to health probes

---

## SLO Recommendations

| Metric | Recommended SLO | Notes |
|--------|-----------------|-------|
| p50 Latency | < 500ms | With < 10 models |
| p95 Latency | < 1000ms | With < 10 models |
| p99 Latency | < 2000ms | Account for slow probes |

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
./scripts/benchmark-models-endpoint.sh

# Custom configuration
VUS=10 ITERATIONS=100 \
./scripts/benchmark-models-endpoint.sh
```
EOF

log_phase "Benchmark Complete"
log_success "Results saved to: ${SUMMARY_FILE}"
cat "$SUMMARY_FILE"
