#!/usr/bin/env bash
# validate-benchmark-setup.sh - Validate auth and rate limiting before running benchmarks
#
# 1. Auth validation: no token -> 401, invalid token -> 401, valid token -> 2xx
# 2. Rate-limit validation: temporarily lower token limit, make requests until 429, restore limit
#
# Environment: HOST, PROTOCOL (http/https), MODEL_BASE_PATH (default: maas-benchmarking), MAAS_CR_NAMESPACE, TOKEN_FILE, MODEL_NAMES (first used for URL)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}"
HOST="${HOST:-maas.${CLUSTER_DOMAIN}}"
PROTOCOL="${PROTOCOL:-https}"
MAAS_CR_NAMESPACE="${MAAS_CR_NAMESPACE:-opendatahub}"
TOKEN_FILE="${TOKEN_FILE:-$PROJECT_DIR/tokens/all/all_tokens.json}"
MODEL_NAMES="${MODEL_NAMES:-facebook-opt-125m-simulated}"
MODEL_PAYLOAD_ID="${MODEL_PAYLOAD_ID:-facebook/opt-125m}"
# Base path before model name in URL (default: maas-benchmarking). Override if your gateway uses e.g. /llm
MODEL_BASE_PATH="${MODEL_BASE_PATH:-maas-benchmarking}"
FIRST_MODEL=$(echo "$MODEL_NAMES" | cut -d',' -f1 | tr -d ' ')
BENCH_SUBSCRIPTION_NAME="maas-benchmark-subscription"
# Header required by MaaS gateway for subscription-based auth
MAAS_SUBSCRIPTION_HEADER="${MAAS_SUBSCRIPTION_HEADER:-maas-benchmark-subscription}"

if [[ -z "$HOST" || "$HOST" == "maas." ]]; then
  log_error "HOST not set and could not get cluster domain. Set HOST or CLUSTER_DOMAIN."
  exit 1
fi

BASE_URL="${PROTOCOL}://${HOST}/${MODEL_BASE_PATH}/${FIRST_MODEL}/v1/completions"
AUTH_FAILED=0
RATELIMIT_FAILED=0

log_info "Validation URL: $BASE_URL"

# --- Auth: no token -> 401 ---
log_info "Auth test 1/3: request with no token (expect 401)"
code=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "$BASE_URL" \
  -H "Content-Type: application/json" \
  -H "x-maas-subscription: $MAAS_SUBSCRIPTION_HEADER" \
  -d "{\"model\":\"$MODEL_PAYLOAD_ID\",\"prompt\":\"hi\",\"max_tokens\":2}")
if [[ "$code" == "401" ]]; then
  log_info "  Got 401 as expected."
else
  log_error "  Expected 401, got $code — URL: $BASE_URL"
  AUTH_FAILED=1
fi

# --- Auth: invalid token -> 401 ---
log_info "Auth test 2/3: request with invalid token (expect 401)"
code=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "$BASE_URL" \
  -H "Authorization: Bearer invalid-token" \
  -H "Content-Type: application/json" \
  -H "x-maas-subscription: $MAAS_SUBSCRIPTION_HEADER" \
  -d "{\"model\":\"$MODEL_PAYLOAD_ID\",\"prompt\":\"hi\",\"max_tokens\":2}")
if [[ "$code" == "401" ]]; then
  log_info "  Got 401 as expected."
else
  log_error "  Expected 401, got $code — URL: $BASE_URL"
  AUTH_FAILED=1
fi

# --- Auth: valid token -> 2xx ---
if [[ ! -f "$TOKEN_FILE" ]]; then
  log_warn "TOKEN_FILE not found; skipping valid-token auth test."
  AUTH_FAILED=1
else
  log_info "Auth test 3/3: request with valid token (expect 2xx)"
  token=$(jq -r '(.free // [])[0].token // (.premium // [])[0].token // empty' "$TOKEN_FILE")
  if [[ -z "$token" ]]; then
    log_error "  No token found in $TOKEN_FILE"
    AUTH_FAILED=1
  else
    code=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "$BASE_URL" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -H "x-maas-subscription: $MAAS_SUBSCRIPTION_HEADER" \
      -d "{\"model\":\"$MODEL_PAYLOAD_ID\",\"prompt\":\"hi\",\"max_tokens\":2}")
    if [[ "$code" =~ ^2 ]]; then
      log_info "  Got $code as expected."
    else
      log_error "  Expected 2xx, got $code — URL: $BASE_URL"
      AUTH_FAILED=1
    fi
  fi
fi

# --- Rate limit: temporarily set low limit, make requests until 429, restore ---
log_info "Rate-limit test: verify token rate limiting is enforced (expect 429 after limit)"
if [[ ! -f "$TOKEN_FILE" ]]; then
  log_warn "TOKEN_FILE not found; skipping rate-limit test."
  RATELIMIT_FAILED=1
else
  token=$(jq -r '(.free // [])[0].token // (.premium // [])[0].token // empty' "$TOKEN_FILE")
  if [[ -z "$token" ]]; then
    RATELIMIT_FAILED=1
  else
    # Get current subscription spec and patch first model to limit 5 tokens per 1m
    if ! kubectl get maassubscription "$BENCH_SUBSCRIPTION_NAME" -n "$MAAS_CR_NAMESPACE" &>/dev/null; then
      log_warn "MaaSSubscription $BENCH_SUBSCRIPTION_NAME not found; skipping rate-limit test."
      RATELIMIT_FAILED=1
    else
      # Save full resource for restore
      restore_file=$(mktemp)
      trap "rm -f '$restore_file'" EXIT
      kubectl get maassubscription "$BENCH_SUBSCRIPTION_NAME" -n "$MAAS_CR_NAMESPACE" -o json > "$restore_file"
      # Patch: set first modelRef tokenRateLimits to limit 5, window 1m
      kubectl patch maassubscription "$BENCH_SUBSCRIPTION_NAME" -n "$MAAS_CR_NAMESPACE" --type=json -p='[
        {"op": "replace", "path": "/spec/modelRefs/0/tokenRateLimits", "value": [{"limit": 5, "window": "1m"}]}
      ]' 2>/dev/null || { log_warn "Could not patch subscription for rate-limit test"; RATELIMIT_FAILED=1; rm -f "$restore_file"; }
      if [[ $RATELIMIT_FAILED -eq 0 ]]; then
        log_info "  Patched subscription to 5 tokens/min; waiting 10s for reconciliation..."
        sleep 10
        got_429=0
        for i in $(seq 1 15); do
          code=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "$BASE_URL" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -H "x-maas-subscription: $MAAS_SUBSCRIPTION_HEADER" \
            -d "{\"model\":\"$MODEL_PAYLOAD_ID\",\"prompt\":\"req $i\",\"max_tokens\":2}")
          if [[ "$code" == "429" ]]; then
            got_429=1
            log_info "  Got 429 on request $i as expected (rate limit enforced)."
            break
          fi
          [[ $i -le 3 ]] && log_info "  Request $i: $code"
        done
        # Restore original spec
        spec=$(jq -c '.spec' "$restore_file")
        kubectl patch maassubscription "$BENCH_SUBSCRIPTION_NAME" -n "$MAAS_CR_NAMESPACE" --type=merge -p "{\"spec\": $spec}" 2>/dev/null || log_warn "Could not restore subscription spec"
        rm -f "$restore_file"
        if [[ $got_429 -eq 0 ]]; then
          log_error "  Did not receive 429 after 15 requests; rate limiting may not be active. URL: $BASE_URL"
          RATELIMIT_FAILED=1
        fi
      fi
    fi
  fi
fi

# --- Summary ---
echo ""
if [[ $AUTH_FAILED -eq 0 && $RATELIMIT_FAILED -eq 0 ]]; then
  log_info "All validation tests passed. Auth and rate limiting are working; safe to run benchmarks and report stats."
  exit 0
fi
[[ $AUTH_FAILED -ne 0 ]] && log_error "Auth validation failed."
[[ $RATELIMIT_FAILED -ne 0 ]] && log_error "Rate-limit validation failed."
exit 1
