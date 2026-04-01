#!/usr/bin/env bash
# benchmark-subscription-scale.sh - Test how many subscriptions cause bottlenecks
#
# Creates N subscriptions (each with M users) and measures:
# 1. Controller reconciliation time
# 2. Request latency at different subscription counts
# 3. Rate limit counter overhead
#
# Automatically detects bottlenecks and stops when:
# - Reconciliation time exceeds threshold
# - Success rate drops below threshold
# - p95 latency exceeds threshold
#
# Usage:
#   ./scripts/benchmark-subscription-scale.sh
#
# Environment:
#   SUBSCRIPTION_COUNTS   Space-separated subscription counts to test (default: "1 10 25 50 100 150 200 300 400 500 750 1000")
#   USERS_PER_SUBSCRIPTION Number of users per subscription (default: 3)
#   MAAS_CR_NAMESPACE     Namespace for MaaS CRs (default: opendatahub)
#   MODEL_NAME            Model to use for benchmarking (default: facebook-opt-125m-simulated)
#   MODEL_NAMESPACE       Namespace where MaaSModelRef lives (default: llm)
#   TOKEN_LIMIT           Token limit per user (default: 100000)
#   TOKEN_WINDOW          Rate limit window (default: 1m)
#   BURST_VUS             VUs for k6 burst test (default: 5)
#   BURST_ITERATIONS      Iterations per k6 test (default: 50)
#   RESULTS_DIR           Directory for results (default: results/subscription-scale)
#   CLEANUP_AFTER         If set, cleanup subscriptions after test (default: true)
#   SKIP_K6               If set, skip k6 load tests (only measure reconciliation)
#   STOP_ON_BOTTLENECK    Stop testing when bottleneck detected (default: true)
#   MAX_RECONCILE_TIME    Max reconciliation time before bottleneck (default: 300 seconds)
#   MIN_SUCCESS_RATE      Min success rate before bottleneck (default: 0.90)
#   MAX_P95_LATENCY       Max p95 latency before bottleneck (default: 10000 ms)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

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
log_bottleneck() { echo -e "\n${RED}🚨 BOTTLENECK DETECTED: $1${NC}\n" >&2; }
log_success() { echo -e "${CYAN}✅ $1${NC}" >&2; }

# Configuration
SUBSCRIPTION_COUNTS="${SUBSCRIPTION_COUNTS:-1 10 25 50 100 150 200 300 400 500 750 1000}"
USERS_PER_SUBSCRIPTION="${USERS_PER_SUBSCRIPTION:-3}"

# Bottleneck thresholds
STOP_ON_BOTTLENECK="${STOP_ON_BOTTLENECK:-true}"
MAX_RECONCILE_TIME="${MAX_RECONCILE_TIME:-300}"      # 5 minutes
MIN_SUCCESS_RATE="${MIN_SUCCESS_RATE:-0.90}"         # 90%
MAX_P95_LATENCY="${MAX_P95_LATENCY:-10000}"          # 10 seconds
MAAS_CR_NAMESPACE="${MAAS_CR_NAMESPACE:-opendatahub}"
MODEL_NAME="${MODEL_NAME:-facebook-opt-125m-simulated}"
MODEL_NAMESPACE="${MODEL_NAMESPACE:-llm}"
MODEL_BASE_PATH="${MODEL_BASE_PATH:-llm}"
MODEL_PAYLOAD_ID="${MODEL_PAYLOAD_ID:-facebook/opt-125m}"
TOKEN_LIMIT="${TOKEN_LIMIT:-100000}"
TOKEN_WINDOW="${TOKEN_WINDOW:-1m}"
BURST_VUS="${BURST_VUS:-5}"
BURST_ITERATIONS="${BURST_ITERATIONS:-50}"
RESULTS_DIR="${RESULTS_DIR:-$PROJECT_DIR/results/subscription-scale}"
CLEANUP_AFTER="${CLEANUP_AFTER:-true}"
SKIP_K6="${SKIP_K6:-}"

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}"
HOST="${HOST:-maas.${CLUSTER_DOMAIN}}"
PROTOCOL="${PROTOCOL:-https}"

mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_FORMATTED=$(date +%Y-%m-%d)
SUMMARY_FILE="$RESULTS_DIR/subscription-scale-benchmark-${DATE_FORMATTED}.md"

# Get cluster info
OCP_VERSION=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"' | head -1)
K6_VERSION=$(k6 version 2>/dev/null | head -1 || echo "unknown")

# Initialize summary with comprehensive format
cat > "$SUMMARY_FILE" << 'HEADER_EOF'
# Subscription Scale Benchmark Results - DATE_PLACEHOLDER

## Run Metadata

| Parameter | Value |
|-----------|-------|
| **Executed at** | DATETIME_PLACEHOLDER |
| **Repo** | `maas-benchmark` |
| **Target Host** | `HOST_PLACEHOLDER` |
| **Protocol** | `PROTOCOL_PLACEHOLDER` |
| **Testing Focus** | MaaSSubscription scale limits and bottleneck detection |

## Test Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                              k6                                      │
│                    (Load Testing Tool)                               │
│         Simulates N virtual users with API keys                      │
└─────────────────────────────┬───────────────────────────────────────┘
                              │ HTTPS POST /v1/completions
                              │ Headers: Authorization, x-maas-subscription
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     MaaS Gateway (OpenShift)                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐   │
│  │    Router    │ → │   Authorino   │ → │      Limitador        │   │
│  │  (Ingress)   │    │    (Auth)     │    │   (Rate Limiting)    │   │
│  │              │    │              │    │                      │   │
│  │ TLS terminate│    │ API key      │    │ TokenRateLimitPolicy │   │
│  │ Route to svc │    │ validation   │    │ per subscription     │   │
│  └──────────────┘    └──────────────┘    └──────────────────────┘   │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        Model Server                                  │
│                  (LLM Simulator / KServe)                           │
│              MODEL_PLACEHOLDER                                       │
│                                                                     │
│              Returns: { choices: [...], usage: {...} }              │
└─────────────────────────────────────────────────────────────────────┘
```

### Metrics Measured

| Metric | Description | Source |
|--------|-------------|--------|
| **Reconcile Time** | Time for MaaSSubscriptions to become Active | kubectl + timer |
| **p50 Latency** | Median request latency (50th percentile) | k6 |
| **p95 Latency** | 95th percentile latency | k6 |
| **Success Rate** | HTTP 2xx-3xx responses / total requests | k6 |
| **Auth Failures** | HTTP 401/403 responses | k6 |
| **Rate Limit Hits** | HTTP 429 responses | k6 |

## Test Environment
HEADER_EOF

# Replace placeholders with actual values
sed -i.bak "s/DATE_PLACEHOLDER/${DATE_FORMATTED}/g" "$SUMMARY_FILE"
sed -i.bak "s/DATETIME_PLACEHOLDER/$(date -u +"%Y-%m-%d %H:%M:%S UTC")/g" "$SUMMARY_FILE"
sed -i.bak "s/HOST_PLACEHOLDER/${HOST}/g" "$SUMMARY_FILE"
sed -i.bak "s/PROTOCOL_PLACEHOLDER/${PROTOCOL}/g" "$SUMMARY_FILE"
sed -i.bak "s/MODEL_PLACEHOLDER/${MODEL_NAME}/g" "$SUMMARY_FILE"
rm -f "${SUMMARY_FILE}.bak"

cat >> "$SUMMARY_FILE" << EOF

### Infrastructure

| Component | Details |
|-----------|---------|
| **OpenShift Version** | ${OCP_VERSION} |
| **Cluster Domain** | ${CLUSTER_DOMAIN} |
| **k6 Version** | ${K6_VERSION} |

### Test Configuration

| Parameter | Value |
|-----------|-------|
| **Subscription Counts Tested** | ${SUBSCRIPTION_COUNTS} |
| **Users per Subscription** | ${USERS_PER_SUBSCRIPTION} |
| **Token Limit per User** | ${TOKEN_LIMIT} |
| **Token Window** | ${TOKEN_WINDOW} |
| **k6 Burst VUs** | ${BURST_VUS} |
| **k6 Burst Iterations** | ${BURST_ITERATIONS} |
| **Model** | ${MODEL_NAME} |

### Bottleneck Thresholds

| Threshold | Value |
|-----------|-------|
| **MAX_RECONCILE_TIME** | ${MAX_RECONCILE_TIME}s |
| **MIN_SUCCESS_RATE** | $(echo "$MIN_SUCCESS_RATE * 100" | bc)% |
| **MAX_P95_LATENCY** | ${MAX_P95_LATENCY}ms |

---

## Results Summary

| Subscriptions | Total Users | Reconcile Time (s) | p50 (ms) | p95 (ms) | Success Rate | Errors | Status |
|---------------|-------------|-------------------|----------|----------|--------------|--------|--------|
EOF

cleanup_all_subscriptions() {
  log_info "Cleaning up all benchmark subscriptions..."
  kubectl delete maassubscription -n "$MAAS_CR_NAMESPACE" -l app.kubernetes.io/part-of=subscription-scale-benchmark --ignore-not-found=true 2>/dev/null || true
  kubectl delete maasauthpolicy -n "$MAAS_CR_NAMESPACE" -l app.kubernetes.io/part-of=subscription-scale-benchmark --ignore-not-found=true 2>/dev/null || true
  # Clean up tokens
  rm -rf "$PROJECT_DIR/tokens/subscription-scale" 2>/dev/null || true
}

create_subscriptions() {
  local count=$1
  local users_per_sub=$2
  
  log_info "Creating ${count} subscriptions with ${users_per_sub} users each..."
  
  local total_users=$((count * users_per_sub))
  local token_dir="$PROJECT_DIR/tokens/subscription-scale"
  mkdir -p "$token_dir"
  
  # Create API keys for all users
  log_info "Provisioning API keys for ${total_users} users..."
  local all_tokens='{"free":[],"premium":[]}'
  
  # Get a K8s token for API key creation (use provided ADMIN_TOKEN or create one)
  local auth_token="${ADMIN_TOKEN:-}"
  if [[ -z "$auth_token" ]]; then
    auth_token=$(kubectl create token default -n "${MAAS_CR_NAMESPACE}" --duration=4h 2>/dev/null || echo "")
  fi
  
  for ((s=1; s<=count; s++)); do
    for ((u=1; u<=users_per_sub; u++)); do
      local user_id="sub${s}-user${u}"
      # Create API key via MaaS API (uses /maas-api/v1/api-keys endpoint)
      local response
      response=$(curl -s -k -X POST "${PROTOCOL}://${HOST}/maas-api/v1/api-keys" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${auth_token}" \
        -d "{\"name\": \"${user_id}\", \"expiresIn\": \"4h\"}" 2>/dev/null || echo '{}')
      
      local token
      token=$(echo "$response" | jq -r '.key // empty')
      
      if [[ -n "$token" ]]; then
        all_tokens=$(echo "$all_tokens" | jq --arg uid "$user_id" --arg tok "$token" \
          '.free += [{"user_id": $uid, "token": $tok, "tier": "free"}]')
      else
        # Fallback: generate sample token for dry runs
        all_tokens=$(echo "$all_tokens" | jq --arg uid "$user_id" --arg tok "sample-token-${user_id}" \
          '.free += [{"user_id": $uid, "token": $tok, "tier": "free"}]')
      fi
    done
  done
  
  echo "$all_tokens" > "$token_dir/all_tokens.json"
  log_info "Created ${total_users} API keys"
  
  # Create MaaS subscriptions
  local start_time
  start_time=$(date +%s.%N)
  
  for ((s=1; s<=count; s++)); do
    local sub_name="scale-benchmark-sub-${s}"
    local users_yaml=""
    
    for ((u=1; u<=users_per_sub; u++)); do
      users_yaml="${users_yaml}
    - \"sub${s}-user${u}\""
    done
    
    # Create MaaSAuthPolicy
    kubectl apply -f - >&2 <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: ${sub_name}-auth
  namespace: ${MAAS_CR_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: subscription-scale-benchmark
    benchmark-subscription-index: "${s}"
spec:
  modelRefs:
    - name: ${MODEL_NAME}
      namespace: ${MODEL_NAMESPACE:-llm}
  subjects:
    users:${users_yaml}
    groups: []
EOF

    # Create MaaSSubscription
    kubectl apply -f - >&2 <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: ${sub_name}
  namespace: ${MAAS_CR_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: subscription-scale-benchmark
    benchmark-subscription-index: "${s}"
spec:
  priority: 20
  owner:
    users:${users_yaml}
    groups: []
  modelRefs:
    - name: ${MODEL_NAME}
      namespace: ${MODEL_NAMESPACE:-llm}
      tokenRateLimits:
        - limit: ${TOKEN_LIMIT}
          window: ${TOKEN_WINDOW}
EOF
  done
  
  local create_time
  create_time=$(date +%s.%N)
  local create_duration
  create_duration=$(echo "$create_time - $start_time" | bc)
  
  log_info "Created ${count} subscriptions in ${create_duration}s"
  
  # Wait for reconciliation (scale timeout with subscription count)
  log_info "Waiting for all subscriptions to become Active..."
  local reconcile_start
  reconcile_start=$(date +%s.%N)
  
  # Dynamic timeout: base 60 attempts + 1 per 10 subscriptions, max 300 attempts (10 min)
  local max_attempts=$(( 60 + count / 10 ))
  [[ $max_attempts -gt 300 ]] && max_attempts=300
  
  local all_active=false
  for attempt in $(seq 1 $max_attempts); do
    local active_count
    active_count=$(kubectl get maassubscription -n "$MAAS_CR_NAMESPACE" \
      -l app.kubernetes.io/part-of=subscription-scale-benchmark \
      -o jsonpath='{.items[*].status.phase}' 2>/dev/null | tr ' ' '\n' | grep -c "Active" 2>/dev/null || echo "0")
    # Ensure active_count is a valid number
    active_count=$(echo "$active_count" | tr -d '[:space:]' | head -1)
    [[ -z "$active_count" || ! "$active_count" =~ ^[0-9]+$ ]] && active_count=0
    
    if [[ "$active_count" -ge "$count" ]]; then
      all_active=true
      break
    fi
    
    # Log progress every 10 attempts or when count changes
    if [[ $((attempt % 10)) -eq 0 ]] || [[ "$attempt" -eq 1 ]]; then
      log_info "  Active: ${active_count}/${count} (attempt ${attempt}/${max_attempts})"
    fi
    sleep 2
  done
  
  local reconcile_end
  reconcile_end=$(date +%s.%N)
  local reconcile_duration
  reconcile_duration=$(echo "$reconcile_end - $reconcile_start" | bc)
  
  if [[ "$all_active" == "true" ]]; then
    log_info "All ${count} subscriptions are Active (reconcile time: ${reconcile_duration}s)"
  else
    log_warn "Not all subscriptions became Active within timeout (reconcile time: ${reconcile_duration}s)"
  fi
  
  echo "$reconcile_duration"
}

run_k6_test() {
  local sub_count=$1
  local result_file="$RESULTS_DIR/k6_${sub_count}subs_${TIMESTAMP}.json"
  
  # Wait for rate limit counters to reset (default: 30s, set RATE_LIMIT_WAIT=0 to skip)
  local rate_limit_wait="${RATE_LIMIT_WAIT:-30}"
  if [[ "$rate_limit_wait" -gt 0 ]]; then
    log_info "Waiting ${rate_limit_wait}s for rate limit counters to settle..."
    sleep "$rate_limit_wait"
  fi
  
  log_info "Running k6 load test with ${sub_count} subscriptions..."
  
  # Pick a random subscription to test
  local test_sub_index=$(( (RANDOM % sub_count) + 1 ))
  local test_user="sub${test_sub_index}-user1"
  local subscription_header="scale-benchmark-sub-${test_sub_index}"
  
  # Get token for test user
  # Use relative path from k6 script location (k6 open() is relative to script)
  local token_file="../tokens/subscription-scale/all_tokens.json"
  local token_file_abs="$PROJECT_DIR/tokens/subscription-scale/all_tokens.json"
  local test_token
  test_token=$(jq -r --arg user "$test_user" '.free[] | select(.user_id == $user) | .token' "$token_file_abs" 2>/dev/null || echo "")
  
  if [[ -z "$test_token" || "$test_token" == "null" ]]; then
    log_warn "No token found for ${test_user}, using sample tokens"
    export USE_SAMPLE_TOKENS=true
  fi
  
  # Run k6 with subscription header
  # MODEL_BASE_PATH defaults to "llm" for LLMInferenceService HTTPRoutes
  k6 run \
    -e MODE="burst" \
    -e BURST_ITERATIONS="$BURST_ITERATIONS" \
    -e BURST_VUS="$BURST_VUS" \
    -e HOST="$HOST" \
    -e PROTOCOL="$PROTOCOL" \
    -e MODEL_NAME="$MODEL_NAME" \
    -e MODEL_BASE_PATH="${MODEL_BASE_PATH:-llm}" \
    -e MODEL_PAYLOAD_ID="${MODEL_PAYLOAD_ID:-facebook/opt-125m}" \
    -e MAAS_SUBSCRIPTION_HEADER="$subscription_header" \
    -e TOKEN_FILE_PATH="$token_file" \
    -e USE_SAMPLE_TOKENS="${USE_SAMPLE_TOKENS:-false}" \
    --summary-export="$result_file" \
    "$PROJECT_DIR/k6/maas-performance-test.js" >&2 2>&1 || true
  
  # Extract metrics from k6 summary export
  if [[ -f "$result_file" ]]; then
    local p50 p95 success_rate errors
    # k6 exports p(90) and p(95) directly, use med for p50
    p50=$(jq -r '.metrics.http_req_duration.med // "N/A"' "$result_file")
    p95=$(jq -r '.metrics.http_req_duration["p(95)"] // "N/A"' "$result_file")
    # success_rate.value is 0-1 where 1 = 100% success
    success_rate=$(jq -r '.metrics.success_rate.value // "N/A"' "$result_file")
    # http_req_failed.value is 0-1 where 0 = 0% failures
    errors=$(jq -r '.metrics.http_req_failed.value // "N/A"' "$result_file")
    
    echo "${p50}|${p95}|${success_rate}|${errors}"
  else
    echo "N/A|N/A|N/A|N/A"
  fi
}

measure_controller_metrics() {
  local sub_count=$1
  
  log_info "Measuring controller metrics with ${sub_count} subscriptions..."
  
  # Get controller pod
  local controller_pod
  controller_pod=$(kubectl get pods -n maas-system -l app=maas-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -n "$controller_pod" ]]; then
    # Check controller CPU/memory
    local resources
    resources=$(kubectl top pod "$controller_pod" -n maas-system 2>/dev/null || echo "N/A")
    log_info "Controller resources: $resources"
  fi
  
  # Count TokenRateLimitPolicies created
  local trlp_count
  trlp_count=$(kubectl get tokenratelimitpolicy -A -l app.kubernetes.io/managed-by=maas-controller 2>/dev/null | wc -l || echo "0")
  log_info "TokenRateLimitPolicies: $trlp_count"
}

# Bottleneck detection function
check_bottleneck() {
  local reconcile_time=$1
  local p95=$2
  local success_rate=$3
  local sub_count=$4
  
  local bottleneck_found=false
  local bottleneck_reason=""
  
  # Check reconciliation time
  local reconcile_int
  reconcile_int=$(printf "%.0f" "$reconcile_time" 2>/dev/null || echo "0")
  if [[ "$reconcile_int" -gt "$MAX_RECONCILE_TIME" ]]; then
    bottleneck_found=true
    bottleneck_reason="Reconciliation time (${reconcile_time}s) exceeded threshold (${MAX_RECONCILE_TIME}s)"
  fi
  
  # Check p95 latency (if not skipped)
  if [[ "$p95" != "SKIPPED" && "$p95" != "N/A" ]]; then
    local p95_int
    p95_int=$(printf "%.0f" "$p95" 2>/dev/null || echo "0")
    if [[ "$p95_int" -gt "$MAX_P95_LATENCY" ]]; then
      bottleneck_found=true
      bottleneck_reason="${bottleneck_reason:+$bottleneck_reason; }p95 latency (${p95}ms) exceeded threshold (${MAX_P95_LATENCY}ms)"
    fi
  fi
  
  # Check success rate (if not skipped)
  if [[ "$success_rate" != "SKIPPED" && "$success_rate" != "N/A" ]]; then
    local below_threshold
    below_threshold=$(echo "$success_rate < $MIN_SUCCESS_RATE" | bc 2>/dev/null || echo "0")
    if [[ "$below_threshold" == "1" ]]; then
      bottleneck_found=true
      local success_pct
      success_pct=$(echo "$success_rate * 100" | bc 2>/dev/null || echo "$success_rate")
      local min_pct
      min_pct=$(echo "$MIN_SUCCESS_RATE * 100" | bc 2>/dev/null || echo "$MIN_SUCCESS_RATE")
      bottleneck_reason="${bottleneck_reason:+$bottleneck_reason; }Success rate (${success_pct}%) below threshold (${min_pct}%)"
    fi
  fi
  
  if [[ "$bottleneck_found" == "true" ]]; then
    echo "BOTTLENECK|${bottleneck_reason}"
  else
    echo "OK"
  fi
}

# Main execution
log_phase "Subscription Scale Benchmark (up to 1000 subscriptions)"
log_info "Bottleneck thresholds:"
log_info "  Max reconcile time: ${MAX_RECONCILE_TIME}s"
log_info "  Min success rate: $(echo "$MIN_SUCCESS_RATE * 100" | bc)%"
log_info "  Max p95 latency: ${MAX_P95_LATENCY}ms"
log_info "  Stop on bottleneck: ${STOP_ON_BOTTLENECK}"
echo ""

# Cleanup any previous benchmark resources
cleanup_all_subscriptions

BOTTLENECK_FOUND=false
BOTTLENECK_AT=""
BOTTLENECK_REASON=""
LAST_HEALTHY_COUNT=0

for sub_count in $SUBSCRIPTION_COUNTS; do
  log_phase "Testing with ${sub_count} subscription(s)"
  
  # Create subscriptions and measure reconciliation
  reconcile_time=$(create_subscriptions "$sub_count" "$USERS_PER_SUBSCRIPTION")
  
  # Calculate total users
  total_users=$((sub_count * USERS_PER_SUBSCRIPTION))
  
  # Measure controller metrics
  measure_controller_metrics "$sub_count"
  
  # Run k6 test (unless skipped)
  if [[ -z "$SKIP_K6" ]]; then
    k6_result=$(run_k6_test "$sub_count")
    IFS='|' read -r p50 p95 success_rate errors <<< "$k6_result"
  else
    p50="SKIPPED"
    p95="SKIPPED"
    success_rate="SKIPPED"
    errors="SKIPPED"
  fi
  
  # Format metrics for table
  p50_fmt=$(printf "%.2f" "$p50" 2>/dev/null || echo "$p50")
  p95_fmt=$(printf "%.2f" "$p95" 2>/dev/null || echo "$p95")
  success_fmt=$(printf "%.2f%%" "$(echo "$success_rate * 100" | bc 2>/dev/null)" 2>/dev/null || echo "$success_rate")
  errors_fmt=$(printf "%.4f" "$errors" 2>/dev/null || echo "$errors")
  reconcile_fmt=$(printf "%.2f" "$reconcile_time" 2>/dev/null || echo "$reconcile_time")
  
  # Check for bottleneck
  bottleneck_check=$(check_bottleneck "$reconcile_time" "$p95" "$success_rate" "$sub_count")
  
  if [[ "$bottleneck_check" == "OK" ]]; then
    LAST_HEALTHY_COUNT=$sub_count
    status_indicator="✅"
  else
    status_indicator="🚨"
    if [[ "$BOTTLENECK_FOUND" == "false" ]]; then
      BOTTLENECK_FOUND=true
      BOTTLENECK_AT=$sub_count
      BOTTLENECK_REASON="${bottleneck_check#BOTTLENECK|}"
    fi
  fi
  
  # Append to summary with status
  echo "| ${sub_count} | ${total_users} | ${reconcile_fmt} | ${p50_fmt} | ${p95_fmt} | ${success_fmt} | ${errors_fmt} | ${status_indicator} |" >> "$SUMMARY_FILE"
  
  log_info "Results for ${sub_count} subscriptions:"
  log_info "  Reconcile time: ${reconcile_fmt}s"
  log_info "  p50 latency: ${p50_fmt}ms"
  log_info "  p95 latency: ${p95_fmt}ms"
  log_info "  Success rate: ${success_fmt}"
  
  # Handle bottleneck
  if [[ "$bottleneck_check" != "OK" ]]; then
    log_bottleneck "${bottleneck_check#BOTTLENECK|}"
    
    if [[ "$STOP_ON_BOTTLENECK" == "true" ]]; then
      log_warn "Stopping test due to bottleneck (STOP_ON_BOTTLENECK=true)"
      log_info "Last healthy subscription count: ${LAST_HEALTHY_COUNT}"
      break
    else
      log_warn "Continuing despite bottleneck (STOP_ON_BOTTLENECK=false)"
    fi
  else
    log_success "No bottleneck detected at ${sub_count} subscriptions"
  fi
  
  # Cleanup before next iteration
  if [[ "$CLEANUP_AFTER" == "true" ]]; then
    cleanup_all_subscriptions
    sleep 5  # Allow controller to process deletions
  fi
done

# Final summary
cat >> "$SUMMARY_FILE" << EOF

---

## Bottleneck Analysis

EOF

if [[ "$BOTTLENECK_FOUND" == "true" ]]; then
  BUFFER_80=$((LAST_HEALTHY_COUNT * 80 / 100))
  BUFFER_50=$((LAST_HEALTHY_COUNT * 50 / 100))
  cat >> "$SUMMARY_FILE" << EOF
### 🚨 Bottleneck Detected

| Metric | Value |
|--------|-------|
| **Bottleneck Detected** | ✅ Yes |
| **First Bottleneck At** | ${BOTTLENECK_AT} subscriptions |
| **Last Healthy Count** | ${LAST_HEALTHY_COUNT} subscriptions |
| **Bottleneck Reason** | ${BOTTLENECK_REASON} |

### Recommended Limits

| Limit Type | Value |
|------------|-------|
| **Safe Operating Limit** | ${LAST_HEALTHY_COUNT} subscriptions |
| **With 80% Buffer** | ${BUFFER_80} subscriptions |
| **With 50% Buffer** | ${BUFFER_50} subscriptions |

EOF
else
  MAX_TESTED=$(echo $SUBSCRIPTION_COUNTS | awk '{print $NF}')
  cat >> "$SUMMARY_FILE" << EOF
### ✅ No Bottleneck Found

| Metric | Value |
|--------|-------|
| **Bottleneck Detected** | ❌ No |
| **Maximum Tested** | ${MAX_TESTED} subscriptions |
| **All Tests Passed** | ✅ Yes |

System handled all tested subscription counts (up to ${MAX_TESTED}) without hitting thresholds.

EOF
fi

cat >> "$SUMMARY_FILE" << EOF
---

## Scaling Recommendations

| If Bottleneck Is | Recommendation |
|------------------|----------------|
| **Controller (slow reconciliation)** | Increase replicas, check resource limits, review etcd performance |
| **Limitador (high latency)** | Scale replicas, check memory, review counter count |
| **Auth (failures)** | Check Authorino logs, verify API key validity |
| **Success Rate (errors)** | Check model server capacity, review rate limits |

### Quick Fixes

\`\`\`bash
# If controller is bottleneck
kubectl scale deployment maas-controller -n maas-system --replicas=2

# If Limitador is bottleneck
kubectl scale deployment limitador -n kuadrant-system --replicas=2
\`\`\`

---

## Commands Used

### Run This Benchmark

\`\`\`bash
cd ~/go/src/github.com/ai-engineering/maas-benchmark

# Command used for this run
SUBSCRIPTION_COUNTS="${SUBSCRIPTION_COUNTS}" \\
USERS_PER_SUBSCRIPTION=${USERS_PER_SUBSCRIPTION} \\
MAX_RECONCILE_TIME=${MAX_RECONCILE_TIME} \\
MIN_SUCCESS_RATE=${MIN_SUCCESS_RATE} \\
MAX_P95_LATENCY=${MAX_P95_LATENCY} \\
./scripts/benchmark-subscription-scale.sh
\`\`\`

### Cleanup

\`\`\`bash
kubectl delete maassubscription -n ${MAAS_CR_NAMESPACE} \\
  -l app.kubernetes.io/part-of=subscription-scale-benchmark

kubectl delete maasauthpolicy -n ${MAAS_CR_NAMESPACE} \\
  -l app.kubernetes.io/part-of=subscription-scale-benchmark

rm -rf tokens/subscription-scale/
\`\`\`

---

## Artifacts

| File | Description |
|------|-------------|
| \`${SUMMARY_FILE}\` | This summary file |
| \`${RESULTS_DIR}/k6_*_${TIMESTAMP}.json\` | Individual k6 results |

---

## Related Documents

- [Subscription Scale Testing Guide](../docs/SUBSCRIPTION-SCALE-TESTING.md)
- [Load Testing Guide](../docs/LOAD-TESTING-GUIDE.md)
- [Scale Testing Plan](../docs/SCALE-TESTING-PLAN.md)

---

## Conclusion

EOF

if [[ "$BOTTLENECK_FOUND" == "true" ]]; then
  cat >> "$SUMMARY_FILE" << EOF
### Summary

- **Subscriptions tested**: 1 to ${BOTTLENECK_AT}
- **Bottleneck found**: ✅ Yes at ${BOTTLENECK_AT} subscriptions
- **Safe operating limit**: ${LAST_HEALTHY_COUNT} subscriptions
- **Primary constraint**: ${BOTTLENECK_REASON}

### Key Findings

1. System handled up to ${LAST_HEALTHY_COUNT} subscriptions without issues
2. Bottleneck detected at ${BOTTLENECK_AT} subscriptions
3. Recommended production limit: ${BUFFER_80} subscriptions (80% of safe limit)
EOF
else
  cat >> "$SUMMARY_FILE" << EOF
### Summary

- **Subscriptions tested**: 1 to ${MAX_TESTED}
- **Bottleneck found**: ❌ No
- **All tests passed**: ✅ Yes
- **System is healthy** up to ${MAX_TESTED} subscriptions

### Key Findings

1. System handled all tested subscription counts without issues
2. No bottleneck detected up to ${MAX_TESTED} subscriptions
3. Consider testing higher counts if needed
EOF
fi

log_phase "Benchmark Complete"

if [[ "$BOTTLENECK_FOUND" == "true" ]]; then
  echo ""
  log_bottleneck "Bottleneck found at ${BOTTLENECK_AT} subscriptions"
  log_info "Reason: ${BOTTLENECK_REASON}"
  log_info "Recommended safe limit: ${LAST_HEALTHY_COUNT} subscriptions"
  echo ""
fi

log_info "Full results: $SUMMARY_FILE"
echo ""
cat "$SUMMARY_FILE"
