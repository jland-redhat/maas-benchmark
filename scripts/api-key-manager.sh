#!/bin/bash

# api-key-manager.sh - Manage API keys for MaaS benchmarking
# Provides utilities for token validation, refresh, and cleanup

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TOKEN_DIR="${PROJECT_DIR}/tokens"
CLUSTER_DOMAIN=${CLUSTER_DOMAIN:-$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}
HOST=${HOST:-"maas.${CLUSTER_DOMAIN}"}

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

# Show usage information
show_usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
  status              Show token status and counts
  validate            Validate tokens by making test requests
  refresh             Refresh expired tokens
  cleanup             Remove expired or invalid token files
  clean               Remove ALL token files (complete reset)
  export-env          Export tokens as environment variables
  sample              Generate sample tokens for testing

Options:
  -h, --help          Show this help message
  --tier <tier>       Operate on specific tier (free|premium)
  --max-tokens <n>    Maximum tokens to process (default: 10)
  --protocol <p>      Protocol to use (http|https)

Examples:
  $0 status
  $0 validate --tier free --max-tokens 5
  $0 refresh
  $0 clean
  $0 export-env --tier premium > premium_tokens.env

Environment Variables:
  HOST               - MaaS gateway host
  CLUSTER_DOMAIN     - OpenShift cluster domain
  TOKEN_DIR          - Token storage directory
EOF
}

# Check token status
token_status() {
    log_info "Token Status Report"
    echo "=================="

    if [ ! -d "$TOKEN_DIR" ]; then
        log_warn "Token directory does not exist: $TOKEN_DIR"
        return 1
    fi

    local all_tokens_file="${TOKEN_DIR}/all/all_tokens.json"

    if [ ! -f "$all_tokens_file" ]; then
        log_warn "Consolidated token file not found: $all_tokens_file"
        echo ""
        echo "Individual token files:"

        local free_count=0
        local premium_count=0

        if [ -d "${TOKEN_DIR}/free" ]; then
            free_count=$(find "${TOKEN_DIR}/free" -name "*.json" 2>/dev/null | wc -l)
        fi

        if [ -d "${TOKEN_DIR}/premium" ]; then
            premium_count=$(find "${TOKEN_DIR}/premium" -name "*.json" 2>/dev/null | wc -l)
        fi

        echo "  Free tokens:    $free_count"
        echo "  Premium tokens: $premium_count"
        echo "  Total tokens:   $((free_count + premium_count))"
    else
        local free_count=$(jq '.free | length' "$all_tokens_file" 2>/dev/null || echo "0")
        local premium_count=$(jq '.premium | length' "$all_tokens_file" 2>/dev/null || echo "0")

        echo "Consolidated tokens:"
        echo "  Free tokens:    $free_count"
        echo "  Premium tokens: $premium_count"
        echo "  Total tokens:   $((free_count + premium_count))"
        echo ""
        echo "File locations:"
        echo "  All tokens:     $all_tokens_file"
        echo "  Free tokens:    ${TOKEN_DIR}/all/free_tokens.json"
        echo "  Premium tokens: ${TOKEN_DIR}/all/premium_tokens.json"
        echo "  Token list:     ${TOKEN_DIR}/all/token_list.txt"
    fi

    echo ""
    echo "Last updated: $(stat -c %y "$all_tokens_file" 2>/dev/null || echo "Unknown")"
}

# Validate tokens by making test requests
validate_tokens() {
    local tier="$1"
    local max_tokens="$2"
    local protocol="${3:-https}"

    log_info "Validating ${tier} tier tokens (max: $max_tokens)..."

    local all_tokens_file="${TOKEN_DIR}/all/all_tokens.json"
    if [ ! -f "$all_tokens_file" ]; then
        log_error "Token file not found: $all_tokens_file"
        return 1
    fi

    local valid_count=0
    local invalid_count=0
    local test_count=0

    # Get tokens for the specified tier
    local tokens
    if ! tokens=$(jq -r ".${tier}[] | @base64" "$all_tokens_file" 2>/dev/null); then
        log_error "Cannot read ${tier} tokens from file"
        return 1
    fi

    while IFS= read -r token_data && [ $test_count -lt $max_tokens ]; do
        local token_json
        token_json=$(echo "$token_data" | base64 --decode)

        local user_id
        local token

        user_id=$(echo "$token_json" | jq -r '.user_id')
        token=$(echo "$token_json" | jq -r '.token')

        if [ "$user_id" = "null" ] || [ "$token" = "null" ]; then
            log_warn "Invalid token data for entry $((test_count + 1))"
            ((invalid_count++))
            ((test_count++))
            continue
        fi

        # Make a test request
        local test_url="${protocol}://${HOST}/v1/models"
        local http_code

        http_code=$(curl -sSk \
            -o /dev/null \
            -w "%{http_code}" \
            --max-time 10 \
            -H "Authorization: Bearer $token" \
            "$test_url" 2>/dev/null || echo "000")

        if [[ "$http_code" -ge 200 && "$http_code" -lt 400 ]]; then
            log_success "✓ $user_id: Valid (HTTP $http_code)"
            ((valid_count++))
        else
            log_error "✗ $user_id: Invalid (HTTP $http_code)"
            ((invalid_count++))
        fi

        ((test_count++))

        # Small delay to avoid overwhelming the server
        sleep 0.1
    done <<< "$tokens"

    echo ""
    log_info "Validation Summary:"
    echo "  Valid tokens:   $valid_count"
    echo "  Invalid tokens: $invalid_count"
    echo "  Total tested:   $test_count"
}

# Refresh expired tokens
refresh_tokens() {
    log_info "Token refresh functionality"
    log_warn "Token refresh requires re-running the provision-api-keys.sh script"
    echo ""
    echo "To refresh tokens:"
    echo "  1. Run: ./provision-api-keys.sh"
    echo "  2. This will generate new tokens for all users"
    echo ""
    echo "Note: In the service account architecture, tokens are automatically"
    echo "managed by Kubernetes and expire based on their TTL setting."
}

# Clean up expired or invalid tokens
cleanup_tokens() {
    log_info "Cleaning up token files..."

    # Remove empty directories
    find "$TOKEN_DIR" -type d -empty -delete 2>/dev/null || true

    # Remove any temporary files
    find "$TOKEN_DIR" -name "*.tmp" -delete 2>/dev/null || true

    log_success "Cleanup completed"
}

# Remove all token files
clean_all_tokens() {
    log_warn "This will remove ALL token files!"
    echo "Directories that will be cleaned:"
    echo "  - ${TOKEN_DIR}/free/"
    echo "  - ${TOKEN_DIR}/premium/"
    echo "  - ${TOKEN_DIR}/all/"
    echo ""
    read -p "Are you sure you want to delete all tokens? (y/N): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing all token files..."

        # Remove all individual token files
        rm -f "${TOKEN_DIR}/free"/*.json 2>/dev/null || true
        rm -f "${TOKEN_DIR}/premium"/*.json 2>/dev/null || true

        # Remove all consolidated token files
        rm -f "${TOKEN_DIR}/all"/*.json 2>/dev/null || true
        rm -f "${TOKEN_DIR}/all"/*.txt 2>/dev/null || true

        log_success "All token files removed"
        log_info "Run './scripts/provision-api-keys.sh' to generate new API keys"
    else
        log_info "Operation cancelled"
    fi
}

# Export tokens as environment variables
export_tokens_env() {
    local tier="$1"

    local all_tokens_file="${TOKEN_DIR}/all/all_tokens.json"
    if [ ! -f "$all_tokens_file" ]; then
        log_error "Token file not found: $all_tokens_file"
        return 1
    fi

    echo "# ${tier^} tier tokens for MaaS benchmarking"
    echo "# Generated on $(date)"
    echo ""

    local tokens
    if tokens=$(jq -r ".${tier}[]" "$all_tokens_file" 2>/dev/null); then
        echo "$tokens" | jq -r '"export " + .user_id + "_TOKEN=\"" + .token + "\""'
    else
        log_error "Cannot read ${tier} tokens from file"
        return 1
    fi
}

# Generate sample tokens for testing
generate_sample_tokens() {
    log_info "Generating sample tokens for testing..."

    local sample_dir="${TOKEN_DIR}/sample"
    mkdir -p "$sample_dir"

    # Generate sample free tokens
    local free_tokens='[]'
    for i in {1..10}; do
        local user_token=$(jq -n \
            --arg user "freeuser${i}" \
            --arg token "sample_free_token_${i}" \
            --arg tier "free" \
            '{user_id: $user, token: $token, tier: $tier, expiration: "1h", expiresAt: (now + 3600)}')
        free_tokens=$(echo "$free_tokens" | jq ". + [$user_token]")
    done

    # Generate sample premium tokens
    local premium_tokens='[]'
    for i in {1..10}; do
        local user_token=$(jq -n \
            --arg user "premiumuser${i}" \
            --arg token "sample_premium_token_${i}" \
            --arg tier "premium" \
            '{user_id: $user, token: $token, tier: $tier, expiration: "1h", expiresAt: (now + 3600)}')
        premium_tokens=$(echo "$premium_tokens" | jq ". + [$user_token]")
    done

    # Create consolidated file
    jq -n \
        --argjson free "$free_tokens" \
        --argjson premium "$premium_tokens" \
        '{free: $free, premium: $premium}' > "${sample_dir}/sample_tokens.json"

    log_success "Sample tokens generated: ${sample_dir}/sample_tokens.json"
    echo ""
    echo "To use sample tokens with k6 tests:"
    echo "  export TOKEN_FILE_PATH=${sample_dir}/sample_tokens.json"
    echo "  export USE_SAMPLE_TOKENS=true"
}

# Main command processing
main() {
    local command="${1:-status}"
    local tier="all"
    local max_tokens=10
    local protocol="https"

    # Parse options
    shift || true
    while [[ $# -gt 0 ]]; do
        case $1 in
            --tier)
                tier="$2"
                shift 2
                ;;
            --max-tokens)
                max_tokens="$2"
                shift 2
                ;;
            --protocol)
                protocol="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Execute command
    case $command in
        status)
            token_status
            ;;
        validate)
            if [ "$tier" = "all" ]; then
                validate_tokens "free" "$max_tokens" "$protocol"
                echo ""
                validate_tokens "premium" "$max_tokens" "$protocol"
            else
                validate_tokens "$tier" "$max_tokens" "$protocol"
            fi
            ;;
        refresh)
            refresh_tokens
            ;;
        cleanup)
            cleanup_tokens
            ;;
        clean)
            clean_all_tokens
            ;;
        export-env)
            if [ "$tier" = "all" ]; then
                log_error "Please specify a tier with --tier (free|premium)"
                exit 1
            fi
            export_tokens_env "$tier"
            ;;
        sample)
            generate_sample_tokens
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"