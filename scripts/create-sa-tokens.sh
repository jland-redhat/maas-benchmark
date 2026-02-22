#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
FREE_USERS=${FREE_USERS:-3}
PREMIUM_USERS=${PREMIUM_USERS:-0}
TOKEN_EXPIRATION=${TOKEN_EXPIRATION:-"2h"}
# MaaS CR mode: create SAs in a single namespace for use with MaaSSubscription/MaaSAuthPolicy
MAAS_CR_MODE=${MAAS_CR_MODE:-false}
BENCH_SA_NAMESPACE=${BENCH_SA_NAMESPACE:-maas-benchmark}

log_info "Creating service accounts and tokens for benchmarking..."
log_info "Free users: $FREE_USERS; Premium users: $PREMIUM_USERS"
if [[ "$MAAS_CR_MODE" == "true" ]]; then
  log_info "MaaS CR mode: SAs will be created in namespace $BENCH_SA_NAMESPACE"
fi

# Create token directories
mkdir -p tokens/{free,premium,all}
rm -f tokens/free/*.json tokens/premium/*.json tokens/all/*.json

# Function to create service account and extract token
create_sa_token() {
    local username="$1"
    local tier="$2"
    local output_file="$3"
    local namespace
    if [[ "$MAAS_CR_MODE" == "true" ]]; then
        namespace="$BENCH_SA_NAMESPACE"
    else
        namespace="maas-default-gateway-tier-${tier}"
    fi

    # Ensure namespace exists
    if ! kubectl get namespace "$namespace" &>/dev/null; then
        log_warn "Namespace $namespace doesn't exist, skipping $username"
        return 1
    fi

    # Create service account
    log_info "Creating SA: $namespace/$username"
    kubectl create sa "$username" -n "$namespace" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

    # Create token with audiences that match AuthPolicy's kubernetesTokenReview.audiences.
    # Including both ensures TokenReview succeeds even if Authorino sends only one audience
    # (empty status.user in logs usually means audience mismatch).
    # Token duration in seconds (2 hours = 7200 seconds)
    local duration_seconds=7200
    if [[ "$TOKEN_EXPIRATION" =~ ([0-9]+)h ]]; then
        duration_seconds=$((${BASH_REMATCH[1]} * 3600))
    fi

    token=$(kubectl create token "$username" -n "$namespace" \
        --audience=maas-default-gateway-sa \
        --audience=https://kubernetes.default.svc \
        --duration="${duration_seconds}s" 2>/dev/null)

    if [ -z "$token" ]; then
        log_error "Failed to create token for $username"
        return 1
    fi

    # Get token expiration
    exp=$(echo "$token" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq -r '.exp' 2>/dev/null || echo "")

    # Token file: include namespace for MaaS CR mode (setup-maas-crs-for-benchmark.sh reads it)
    if [[ "$MAAS_CR_MODE" == "true" ]]; then
        cat > "$output_file" <<TOKENJSON
{
  "token": "$token",
  "expiration": "${TOKEN_EXPIRATION}",
  "expiresAt": ${exp:-0},
  "user_id": "$username",
  "tier": "$tier",
  "namespace": "$namespace"
}
TOKENJSON
    else
        cat > "$output_file" <<TOKENJSON
{
  "token": "$token",
  "expiration": "${TOKEN_EXPIRATION}",
  "expiresAt": ${exp:-0},
  "user_id": "$username",
  "tier": "$tier"
}
TOKENJSON
    fi

    log_info "Created token for $username"
    return 0
}

if [[ "$MAAS_CR_MODE" == "true" ]]; then
    log_info "Ensuring benchmark namespace $BENCH_SA_NAMESPACE exists..."
    kubectl create namespace "$BENCH_SA_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null || true
else
    # Ensure tier namespaces exist by requesting a token through MaaS API first
    log_info "Setting up tier namespaces..."

    CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
    HOST="maas.${CLUSTER_DOMAIN}"
    USER_TOKEN=$(oc whoami -t)

    if [[ -z "$USER_TOKEN" ]]; then
        log_error "No OpenShift token available. Please login with 'oc login'"
        exit 1
    fi

    log_info "Creating initial token to establish tier namespace..."

    if response=$(timeout 10 curl -sSk \
        -w "\n%{http_code}" \
        -H "Authorization: Bearer ${USER_TOKEN}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d '{"expiration": "10m"}' \
        "http://${HOST}/maas-api/v1/tokens" 2>/dev/null); then

        http_code=$(echo "$response" | tail -n1)
        if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
            log_info "Successfully created initial token - tier namespace should now exist"
        else
            log_warn "MaaS API returned HTTP $http_code, creating namespace manually..."
            kubectl create namespace maas-default-gateway-tier-free --dry-run=client -o yaml | kubectl apply -f - &>/dev/null || true
        fi
    else
        log_warn "MaaS API call timed out or failed, creating namespace manually..."
        kubectl create namespace maas-default-gateway-tier-free --dry-run=client -o yaml | kubectl apply -f - &>/dev/null || true
    fi
fi

# Create free and premium tier tokens
success_count=0
failure_count=0

log_info "Creating free tier service accounts and tokens..."
for i in $(seq 1 $FREE_USERS); do
    username="benchuser-free-${i}"
    output_file="tokens/free/${username}.json"

    if create_sa_token "$username" "free" "$output_file"; then
        success_count=$((success_count + 1))
    else
        failure_count=$((failure_count + 1))
    fi
done

log_info "Creating premium tier service accounts and tokens..."
for i in $(seq 1 $PREMIUM_USERS); do
    username="benchuser-premium-${i}"
    output_file="tokens/premium/${username}.json"

    if create_sa_token "$username" "premium" "$output_file"; then
        success_count=$((success_count + 1))
    else
        failure_count=$((failure_count + 1))
    fi
done

# Generate consolidated files
log_info "Generating consolidated files..."

# Free tokens
if ls tokens/free/*.json 1> /dev/null 2>&1; then
    jq -s '.' tokens/free/*.json > tokens/all/free_tokens.json
else
    echo '[]' > tokens/all/free_tokens.json
fi

# Premium tokens
if ls tokens/premium/*.json 1> /dev/null 2>&1; then
    jq -s '.' tokens/premium/*.json > tokens/all/premium_tokens.json
else
    echo '[]' > tokens/all/premium_tokens.json
fi

# Combined file in the format expected by token-manager.sh
jq -s '{"free": .[0], "premium": .[1]}' \
    tokens/all/free_tokens.json \
    tokens/all/premium_tokens.json > tokens/all/all_tokens.json

# Summary
free_count=$(find tokens/free -name '*.json' 2>/dev/null | wc -l)
premium_count=$(find tokens/premium -name '*.json' 2>/dev/null | wc -l)

echo ""
log_info "=== COMPLETE ==="
echo "Total successful: $success_count"
echo "Total failed: $failure_count"
echo "Free tokens: $free_count"
echo "Premium tokens: $premium_count"
echo "Files: tokens/all/all_tokens.json"
echo ""
if [[ "$MAAS_CR_MODE" == "true" ]]; then
  log_info "Next: run ./scripts/setup-maas-crs-for-benchmark.sh to create MaaSSubscription and MaaSAuthPolicy for these users"
else
  log_info "Service accounts created with unique names for independent rate limiting"
fi
