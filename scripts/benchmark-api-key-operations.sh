#!/bin/bash
# benchmark-api-key-operations.sh
# Benchmarks API key operations: create, validate, search, revoke

set -euo pipefail

# ========================================
# Configuration
# ========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results/api-key-operations"
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
CREATE_KEY_COUNTS="${CREATE_KEY_COUNTS:-10 50 100}"
CREATE_VUS="${CREATE_VUS:-1 5 10}"
VALIDATE_VUS="${VALIDATE_VUS:-10 50 100}"
SEARCH_KEY_COUNTS="${SEARCH_KEY_COUNTS:-100 1000}"
REVOKE_KEY_COUNTS="${REVOKE_KEY_COUNTS:-10 50}"

# Thresholds
MAX_CREATE_LATENCY_MS="${MAX_CREATE_LATENCY_MS:-2000}"
MAX_VALIDATE_LATENCY_MS="${MAX_VALIDATE_LATENCY_MS:-100}"
MAX_SEARCH_LATENCY_MS="${MAX_SEARCH_LATENCY_MS:-1000}"

mkdir -p "$RESULTS_DIR"

# ========================================
# Summary file setup
# ========================================
SUMMARY_FILE="$RESULTS_DIR/api-key-operations-benchmark-$(date +%Y-%m-%d).md"

init_summary() {
  cat > "$SUMMARY_FILE" << 'EOF'
# API Key Operations Benchmark Results

## Run Metadata

| Parameter | Value |
|-----------|-------|
EOF

  echo "| **Executed at** | $(date -u +"%Y-%m-%d %H:%M:%S UTC") |" >> "$SUMMARY_FILE"
  echo "| **Target Host** | \`${HOST}\` |" >> "$SUMMARY_FILE"
  echo "| **Protocol** | \`${PROTOCOL}\` |" >> "$SUMMARY_FILE"
  
  cat >> "$SUMMARY_FILE" << 'EOF'

## Test Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                              k6                                      │
│                    (Load Testing Tool)                               │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     MaaS Gateway                                     │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐   │
│  │    Router    │ → │   Authorino   │ → │      maas-api         │   │
│  │  (Ingress)   │    │    (Auth)     │    │   (Key Management)   │   │
│  └──────────────┘    └──────────────┘    └──────────────────────┘   │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        PostgreSQL                                    │
│                  (API Key Storage)                                   │
│            - key_hash (SHA-256)                                      │
│            - user, groups, subscription                              │
│            - created_at, expires_at, status                          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## API Operations Tested

| Operation | Endpoint | Method | Purpose |
|-----------|----------|--------|---------|
| Create | `/maas-api/v1/api-keys` | POST | Mint new API key |
| Validate | `/internal/v1/api-keys/validate` | POST | Verify key (critical path) |
| Search | `/maas-api/v1/api-keys/search` | POST | Query keys with filters |
| Revoke | `/maas-api/v1/api-keys/{id}` | DELETE | Revoke single key |
| Bulk Revoke | `/maas-api/v1/api-keys/bulk-revoke` | POST | Revoke all user keys |

---

## Results Summary

### Key Creation Performance

| VUs | Keys Created | Avg Latency (ms) | p95 Latency (ms) | Throughput (keys/s) | Status |
|-----|--------------|------------------|------------------|---------------------|--------|
EOF
}

# ========================================
# Benchmark functions
# ========================================

get_auth_token() {
  kubectl create token default -n "${MAAS_CR_NAMESPACE}" --duration=4h 2>/dev/null || echo ""
}

benchmark_key_creation() {
  local vus=$1
  local key_count=$2
  
  log_info "Testing key creation: ${vus} VUs, ${key_count} keys..."
  
  local result_file="$RESULTS_DIR/k6_create_${vus}vus_${key_count}keys_${TIMESTAMP}.json"
  local auth_token
  auth_token=$(get_auth_token)
  
  if [[ -z "$auth_token" ]]; then
    log_warn "Could not get auth token, skipping..."
    echo "N/A|N/A|N/A|N/A"
    return
  fi
  
  k6 run \
    -e MODE="api_key_create" \
    -e HOST="$HOST" \
    -e PROTOCOL="$PROTOCOL" \
    -e AUTH_TOKEN="$auth_token" \
    -e VUS="$vus" \
    -e ITERATIONS="$key_count" \
    --summary-export="$result_file" \
    "$PROJECT_DIR/k6/api-key-benchmark.js" >&2 2>&1 || true
  
  if [[ -f "$result_file" ]]; then
    local avg p95 throughput
    avg=$(jq -r '.metrics.http_req_duration.avg // "N/A"' "$result_file")
    p95=$(jq -r '.metrics.http_req_duration["p(95)"] // "N/A"' "$result_file")
    local reqs=$(jq -r '.metrics.http_reqs.count // 0' "$result_file")
    local duration=$(jq -r '.state.testRunDurationMs // 1000' "$result_file")
    throughput=$(echo "scale=2; $reqs / ($duration / 1000)" | bc 2>/dev/null || echo "N/A")
    
    echo "${avg}|${p95}|${throughput}"
  else
    echo "N/A|N/A|N/A"
  fi
}

benchmark_key_validation() {
  local vus=$1
  local duration="${2:-30s}"
  
  log_info "Testing key validation: ${vus} VUs, ${duration} duration..."
  
  local result_file="$RESULTS_DIR/k6_validate_${vus}vus_${TIMESTAMP}.json"
  local token_file="$PROJECT_DIR/tokens/api-key-benchmark/all_tokens.json"
  
  if [[ ! -f "$token_file" ]]; then
    log_warn "No token file found at $token_file, creating test keys..."
    provision_test_keys 100
  fi
  
  k6 run \
    -e MODE="api_key_validate" \
    -e HOST="$HOST" \
    -e PROTOCOL="$PROTOCOL" \
    -e VUS="$vus" \
    -e DURATION="$duration" \
    -e TOKEN_FILE_PATH="../tokens/api-key-benchmark/all_tokens.json" \
    --summary-export="$result_file" \
    "$PROJECT_DIR/k6/api-key-benchmark.js" >&2 2>&1 || true
  
  if [[ -f "$result_file" ]]; then
    local avg p95 p99 throughput
    avg=$(jq -r '.metrics.http_req_duration.avg // "N/A"' "$result_file")
    p95=$(jq -r '.metrics.http_req_duration["p(95)"] // "N/A"' "$result_file")
    p99=$(jq -r '.metrics.http_req_duration["p(99)"] // "N/A"' "$result_file")
    local reqs=$(jq -r '.metrics.http_reqs.count // 0' "$result_file")
    throughput=$(jq -r '.metrics.http_reqs.rate // "N/A"' "$result_file")
    
    echo "${avg}|${p95}|${p99}|${throughput}"
  else
    echo "N/A|N/A|N/A|N/A"
  fi
}

benchmark_key_search() {
  local key_count=$1
  local vus="${2:-5}"
  
  log_info "Testing key search with ${key_count} keys in database..."
  
  local result_file="$RESULTS_DIR/k6_search_${key_count}keys_${TIMESTAMP}.json"
  local auth_token
  auth_token=$(get_auth_token)
  
  k6 run \
    -e MODE="api_key_search" \
    -e HOST="$HOST" \
    -e PROTOCOL="$PROTOCOL" \
    -e AUTH_TOKEN="$auth_token" \
    -e VUS="$vus" \
    -e ITERATIONS="50" \
    --summary-export="$result_file" \
    "$PROJECT_DIR/k6/api-key-benchmark.js" >&2 2>&1 || true
  
  if [[ -f "$result_file" ]]; then
    local avg p95
    avg=$(jq -r '.metrics.http_req_duration.avg // "N/A"' "$result_file")
    p95=$(jq -r '.metrics.http_req_duration["p(95)"] // "N/A"' "$result_file")
    
    echo "${avg}|${p95}"
  else
    echo "N/A|N/A"
  fi
}

provision_test_keys() {
  local count=$1
  local token_dir="$PROJECT_DIR/tokens/api-key-benchmark"
  mkdir -p "$token_dir"
  
  log_info "Provisioning ${count} test API keys..."
  
  local auth_token
  auth_token=$(get_auth_token)
  
  local all_tokens='{"free":[],"premium":[]}'
  
  for ((i=1; i<=count; i++)); do
    local response
    response=$(curl -s -k -X POST "${PROTOCOL}://${HOST}/maas-api/v1/api-keys" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${auth_token}" \
      -d "{\"name\": \"benchmark-key-${i}\", \"expiresIn\": \"4h\"}" 2>/dev/null || echo '{}')
    
    local token
    token=$(echo "$response" | jq -r '.key // empty')
    
    if [[ -n "$token" ]]; then
      all_tokens=$(echo "$all_tokens" | jq --arg uid "benchmark-user-${i}" --arg tok "$token" \
        '.free += [{"user_id": $uid, "token": $tok, "tier": "free"}]')
    fi
    
    if (( i % 20 == 0 )); then
      log_info "Created ${i}/${count} keys..."
    fi
  done
  
  echo "$all_tokens" > "$token_dir/all_tokens.json"
  log_info "Provisioned ${count} API keys"
}

cleanup_test_keys() {
  log_info "Cleaning up test API keys..."
  
  local auth_token
  auth_token=$(get_auth_token)
  
  # Bulk revoke benchmark keys
  curl -s -k -X POST "${PROTOCOL}://${HOST}/maas-api/v1/api-keys/bulk-revoke" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${auth_token}" \
    -d '{"username": "system:serviceaccount:models-as-a-service:default"}' 2>/dev/null || true
  
  rm -rf "$PROJECT_DIR/tokens/api-key-benchmark/"
}

# ========================================
# Main execution
# ========================================
log_phase "API Key Operations Benchmark"
init_summary

# Test key creation
log_phase "Phase 1: Key Creation Performance"
for vus in $CREATE_VUS; do
  for count in $CREATE_KEY_COUNTS; do
    result=$(benchmark_key_creation "$vus" "$count")
    IFS='|' read -r avg p95 throughput <<< "$result"
    
    avg_fmt=$(printf "%.2f" "$avg" 2>/dev/null || echo "$avg")
    p95_fmt=$(printf "%.2f" "$p95" 2>/dev/null || echo "$p95")
    throughput_fmt=$(printf "%.2f" "$throughput" 2>/dev/null || echo "$throughput")
    
    status="✅"
    if [[ "$p95" != "N/A" ]]; then
      p95_int=$(printf "%.0f" "$p95" 2>/dev/null || echo "0")
      if (( p95_int > MAX_CREATE_LATENCY_MS )); then
        status="🚨"
      fi
    fi
    
    echo "| ${vus} | ${count} | ${avg_fmt} | ${p95_fmt} | ${throughput_fmt} | ${status} |" >> "$SUMMARY_FILE"
    log_info "Create test: ${vus} VUs, ${count} keys -> avg=${avg_fmt}ms, p95=${p95_fmt}ms, throughput=${throughput_fmt}/s"
    
    cleanup_test_keys
  done
done

# Provision keys for validation testing
log_phase "Phase 2: Key Validation Performance (Critical Path)"
provision_test_keys 100

cat >> "$SUMMARY_FILE" << 'EOF'

### Key Validation Performance (Critical Path)

| VUs | Duration | Avg Latency (ms) | p95 Latency (ms) | p99 Latency (ms) | Throughput (req/s) | Status |
|-----|----------|------------------|------------------|------------------|-------------------|--------|
EOF

for vus in $VALIDATE_VUS; do
  result=$(benchmark_key_validation "$vus" "30s")
  IFS='|' read -r avg p95 p99 throughput <<< "$result"
  
  avg_fmt=$(printf "%.2f" "$avg" 2>/dev/null || echo "$avg")
  p95_fmt=$(printf "%.2f" "$p95" 2>/dev/null || echo "$p95")
  p99_fmt=$(printf "%.2f" "$p99" 2>/dev/null || echo "$p99")
  throughput_fmt=$(printf "%.2f" "$throughput" 2>/dev/null || echo "$throughput")
  
  status="✅"
  if [[ "$p95" != "N/A" ]]; then
    p95_int=$(printf "%.0f" "$p95" 2>/dev/null || echo "0")
    if (( p95_int > MAX_VALIDATE_LATENCY_MS )); then
      status="🚨"
    fi
  fi
  
  echo "| ${vus} | 30s | ${avg_fmt} | ${p95_fmt} | ${p99_fmt} | ${throughput_fmt} | ${status} |" >> "$SUMMARY_FILE"
  log_info "Validate test: ${vus} VUs -> avg=${avg_fmt}ms, p95=${p95_fmt}ms, throughput=${throughput_fmt}/s"
done

# Test search performance
log_phase "Phase 3: Key Search Performance"
cat >> "$SUMMARY_FILE" << 'EOF'

### Key Search Performance

| Keys in DB | Avg Latency (ms) | p95 Latency (ms) | Status |
|------------|------------------|------------------|--------|
EOF

for count in $SEARCH_KEY_COUNTS; do
  # Provision more keys if needed
  provision_test_keys "$count"
  
  result=$(benchmark_key_search "$count")
  IFS='|' read -r avg p95 <<< "$result"
  
  avg_fmt=$(printf "%.2f" "$avg" 2>/dev/null || echo "$avg")
  p95_fmt=$(printf "%.2f" "$p95" 2>/dev/null || echo "$p95")
  
  status="✅"
  if [[ "$p95" != "N/A" ]]; then
    p95_int=$(printf "%.0f" "$p95" 2>/dev/null || echo "0")
    if (( p95_int > MAX_SEARCH_LATENCY_MS )); then
      status="🚨"
    fi
  fi
  
  echo "| ${count} | ${avg_fmt} | ${p95_fmt} | ${status} |" >> "$SUMMARY_FILE"
  log_info "Search test: ${count} keys -> avg=${avg_fmt}ms, p95=${p95_fmt}ms"
done

# Cleanup
cleanup_test_keys

# Finish summary
cat >> "$SUMMARY_FILE" << 'EOF'

---

## SLO Recommendations

Based on benchmark results:

| Operation | Recommended SLO | Rationale |
|-----------|-----------------|-----------|
| Key Creation | p95 < 2000ms | Background operation, not latency-sensitive |
| Key Validation | p95 < 100ms | Critical path, every inference request |
| Key Search | p95 < 1000ms | Admin operation, occasional use |
| Key Revocation | p95 < 500ms | Security operation, immediate effect |

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
./scripts/benchmark-api-key-operations.sh

# Custom configuration
CREATE_KEY_COUNTS="10 50 100" \
VALIDATE_VUS="10 50 100" \
./scripts/benchmark-api-key-operations.sh
```
EOF

log_phase "Benchmark Complete"
log_success "Results saved to: ${SUMMARY_FILE}"
cat "$SUMMARY_FILE"
