#!/bin/bash

# validate-deployment.sh - Validate MaaS deployment for benchmarking
# Tests the complete flow: authentication, token generation, model access, and rate limiting

set -euo pipefail

# Configuration
CLUSTER_DOMAIN=${CLUSTER_DOMAIN:-$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}
HOST=${HOST:-"maas.${CLUSTER_DOMAIN}"}
TOKEN_EXPIRATION=${TOKEN_EXPIRATION:-"10m"}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Global variables
OPENSHIFT_TOKEN=""
PROTOCOL=""
MAAS_TOKEN=""
MODEL_NAME=""
MODEL_URL=""

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing_tools=()

    if ! command -v oc &> /dev/null; then
        missing_tools+=("oc (OpenShift CLI)")
    fi

    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi

    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi

    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi

    if [ -z "$CLUSTER_DOMAIN" ]; then
        log_error "Could not determine cluster domain. Set CLUSTER_DOMAIN environment variable."
        exit 1
    fi

    log_success "All prerequisites satisfied"
}

# Test cluster connectivity
test_cluster_connectivity() {
    log_info "Testing cluster connectivity..."

    if ! oc whoami &>/dev/null; then
        log_error "Not logged into OpenShift cluster. Run 'oc login' first."
        exit 1
    fi

    local user=$(oc whoami)
    local server=$(oc whoami --show-server)

    log_success "Connected to OpenShift as $user"
    log_info "Server: $server"
}

# Get OpenShift authentication token
get_openshift_token() {
    log_info "Getting OpenShift authentication token..."

    if ! OPENSHIFT_TOKEN=$(oc whoami -t 2>/dev/null); then
        log_error "Failed to get OpenShift token"
        exit 1
    fi

    if [ -z "$OPENSHIFT_TOKEN" ]; then
        log_error "OpenShift token is empty"
        exit 1
    fi

    log_success "OpenShift token obtained"
}

# Test MaaS API connectivity and determine protocol
test_maas_api_connectivity() {
    log_info "Testing MaaS API connectivity at ${HOST}..."

    # Try HTTPS first
    if curl -sSk --max-time 10 "https://${HOST}/maas-api/health" &>/dev/null; then
        PROTOCOL="https"
        log_success "MaaS API is accessible via HTTPS"
    elif curl -sSk --max-time 10 "http://${HOST}/maas-api/health" &>/dev/null; then
        PROTOCOL="http"
        log_warn "MaaS API is accessible via HTTP only (no HTTPS)"
    else
        log_error "Cannot connect to MaaS API at ${HOST}"
        log_error "Make sure the MaaS gateway is deployed and accessible"
        exit 1
    fi
}

# Test MaaS API health endpoint
test_maas_api_health() {
    log_info "Testing MaaS API health endpoint..."

    local health_response
    health_response=$(curl -sSk "${PROTOCOL}://${HOST}/maas-api/health" | jq -r .)

    if echo "$health_response" | jq -e '.status == "healthy"' &>/dev/null; then
        log_success "MaaS API health check passed"
    else
        log_error "MaaS API health check failed: $health_response"
        exit 1
    fi
}

# Test token generation
test_token_generation() {
    log_info "Testing service account token generation..."

    local api_url="${PROTOCOL}://${HOST}/maas-api/v1/tokens"
    local payload=$(jq -n --arg exp "$TOKEN_EXPIRATION" '{expiration: $exp}')

    local response
    response=$(curl -sSk \
        -H "Authorization: Bearer ${OPENSHIFT_TOKEN}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$payload" \
        "$api_url")

    if echo "$response" | jq -e '.token' &>/dev/null; then
        MAAS_TOKEN=$(echo "$response" | jq -r '.token')
        local expiration=$(echo "$response" | jq -r '.expiration')
        log_success "Service account token generated successfully"
        log_info "Token expiration: $expiration"
    else
        log_error "Token generation failed: $response"
        exit 1
    fi
}

# Discover available models
discover_models() {
    log_info "Discovering available models..."

    local models_response
    models_response=$(curl -sSk \
        -H "Authorization: Bearer $MAAS_TOKEN" \
        -H "Content-Type: application/json" \
        "${PROTOCOL}://${HOST}/v1/models")

    if echo "$models_response" | jq -e '.data | length > 0' &>/dev/null; then
        local model_count=$(echo "$models_response" | jq '.data | length')
        MODEL_NAME=$(echo "$models_response" | jq -r '.data[0].id')
        local model_url=$(echo "$models_response" | jq -r '.data[0].url // empty')

        log_success "Found $model_count available models"
        log_info "Using model: $MODEL_NAME"

        # Construct model URL based on the pattern from the user's example
        if [ -n "$model_url" ]; then
            MODEL_URL="${PROTOCOL}://${HOST}/llm/${MODEL_NAME}/v1/chat/completions"
        else
            # Fallback URL construction
            MODEL_URL="${PROTOCOL}://${HOST}/v1/chat/completions"
        fi

        log_info "Model URL: $MODEL_URL"
    else
        log_error "No models found or model discovery failed: $models_response"
        exit 1
    fi
}

# Test model inference
test_model_inference() {
    log_info "Testing model inference..."

    local inference_payload=$(jq -n \
        --arg model "$MODEL_NAME" \
        '{
            model: $model,
            messages: [{"role": "user", "content": "Hello, this is a test"}],
            max_tokens: 50
        }')

    local inference_response
    local http_code

    inference_response=$(curl -sSk \
        -w "\n%{http_code}" \
        -H "Authorization: Bearer $MAAS_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$inference_payload" \
        "$MODEL_URL")

    http_code=$(echo "$inference_response" | tail -n1)
    local response_body=$(echo "$inference_response" | head -n -1)

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        log_success "Model inference successful (HTTP $http_code)"

        # Try to extract usage information if available
        if echo "$response_body" | jq -e '.usage.total_tokens' &>/dev/null; then
            local total_tokens=$(echo "$response_body" | jq '.usage.total_tokens')
            log_info "Tokens consumed: $total_tokens"
        fi
    else
        log_error "Model inference failed (HTTP $http_code): $response_body"
        exit 1
    fi
}

# Test authorization (no token should fail)
test_authorization_failure() {
    log_info "Testing authorization failure (no token)..."

    local inference_payload=$(jq -n \
        --arg model "$MODEL_NAME" \
        '{
            model: $model,
            messages: [{"role": "user", "content": "This should fail"}],
            max_tokens: 10
        }')

    local http_code
    http_code=$(curl -sSk \
        -o /dev/null \
        -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$inference_payload" \
        "$MODEL_URL")

    if [[ "$http_code" == "401" ]]; then
        log_success "Authorization correctly blocked request without token (HTTP 401)"
    else
        log_warn "Expected HTTP 401 for unauthorized request, got HTTP $http_code"
    fi
}

# Test rate limiting
test_rate_limiting() {
    log_info "Testing rate limiting (making multiple rapid requests)..."

    local success_count=0
    local rate_limited_count=0
    local error_count=0

    for i in {1..10}; do
        local inference_payload=$(jq -n \
            --arg model "$MODEL_NAME" \
            --arg content "Rate limit test request $i" \
            '{
                model: $model,
                messages: [{"role": "user", "content": $content}],
                max_tokens: 10
            }')

        local http_code
        http_code=$(curl -sSk \
            -o /dev/null \
            -w "%{http_code}" \
            -H "Authorization: Bearer $MAAS_TOKEN" \
            -H "Content-Type: application/json" \
            -X POST \
            -d "$inference_payload" \
            "$MODEL_URL")

        case "$http_code" in
            2[0-9][0-9])
                ((success_count++))
                ;;
            429)
                ((rate_limited_count++))
                ;;
            *)
                ((error_count++))
                ;;
        esac

        # Small delay between requests
        sleep 0.1
    done

    log_info "Rate limiting test results:"
    echo "  Successful requests: $success_count"
    echo "  Rate limited (429): $rate_limited_count"
    echo "  Other errors: $error_count"

    if [ $rate_limited_count -gt 0 ]; then
        log_success "Rate limiting is working (received HTTP 429 responses)"
    elif [ $success_count -eq 10 ]; then
        log_warn "No rate limiting observed - all requests succeeded"
    else
        log_warn "Unexpected rate limiting behavior"
    fi
}

# Test token revocation
test_token_revocation() {
    log_info "Testing token revocation..."

    # Revoke the current token
    local revoke_response
    local http_code

    revoke_response=$(curl -sSk \
        -w "\n%{http_code}" \
        -H "Authorization: Bearer ${OPENSHIFT_TOKEN}" \
        -X DELETE \
        "${PROTOCOL}://${HOST}/maas-api/v1/tokens")

    http_code=$(echo "$revoke_response" | tail -n1)

    if [[ "$http_code" == "204" ]]; then
        log_success "Token revocation successful (HTTP 204)"
    else
        log_warn "Token revocation returned HTTP $http_code"
    fi

    # Try to use the revoked token (should fail)
    local inference_payload=$(jq -n \
        --arg model "$MODEL_NAME" \
        '{
            model: $model,
            messages: [{"role": "user", "content": "This should fail with revoked token"}],
            max_tokens: 10
        }')

    local test_http_code
    test_http_code=$(curl -sSk \
        -o /dev/null \
        -w "%{http_code}" \
        -H "Authorization: Bearer $MAAS_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$inference_payload" \
        "$MODEL_URL")

    if [[ "$test_http_code" == "401" ]]; then
        log_success "Revoked token correctly rejected (HTTP 401)"
    else
        log_warn "Revoked token test returned HTTP $test_http_code (expected 401)"
    fi
}

# Print deployment summary
print_summary() {
    echo ""
    log_info "=== MaaS Deployment Validation Summary ==="
    echo "  Cluster Domain: $CLUSTER_DOMAIN"
    echo "  MaaS Host: $HOST"
    echo "  Protocol: $PROTOCOL"
    echo "  Model Used: $MODEL_NAME"
    echo "  Model URL: $MODEL_URL"
    echo ""
    log_success "MaaS deployment validation completed successfully!"
    echo ""
    echo "The deployment is ready for benchmarking. You can now:"
    echo "  1. Run './provision-api-keys.sh' to generate 500 API keys"
    echo "  2. Execute k6 performance tests using the generated tokens"
}

# Main execution
main() {
    log_info "Starting MaaS deployment validation..."
    log_info "Target: $HOST"
    echo ""

    check_prerequisites
    test_cluster_connectivity
    get_openshift_token
    test_maas_api_connectivity
    test_maas_api_health
    test_token_generation
    discover_models
    test_model_inference
    test_authorization_failure
    test_rate_limiting
    test_token_revocation
    print_summary
}

# Handle script interruption
cleanup() {
    log_warn "Validation interrupted"
    exit 1
}

trap cleanup INT TERM

# Run main function
main "$@"