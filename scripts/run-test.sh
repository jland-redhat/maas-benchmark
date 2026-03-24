#!/bin/bash

# run-test.sh - Run k6 performance tests with predefined configurations
# Usage: ./run-test.sh [config_name] [additional_k6_options]

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
K6_SCRIPT="${PROJECT_DIR}/k6/maas-performance-test.js"
CONFIG_FILE="${PROJECT_DIR}/config/test-configs.yaml"
RESULTS_DIR="${PROJECT_DIR}/results"
TOKEN_DIR="${PROJECT_DIR}/tokens"

# Default configuration
DEFAULT_CONFIG="burst_basic"

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
    echo "Usage: $0 [config_name] [additional_k6_options]"
    echo ""
    echo "Available configurations:"
    if [ -f "$CONFIG_FILE" ]; then
        grep "^[a-zA-Z].*:$" "$CONFIG_FILE" | sed 's/:$//' | sed 's/^/  - /'
    else
        echo "  No configuration file found at $CONFIG_FILE"
    fi
    echo ""
    echo "Examples:"
    echo "  $0 burst_basic"
    echo "  $0 soak_standard --summary-export=results.json"
    echo "  $0 rate_limit_validation -e HOST=maas.example.com"
    echo ""
    echo "Environment variables:"
    echo "  HOST                - MaaS gateway host (e.g., maas.cluster.domain)"
    echo "  CLUSTER_DOMAIN      - OpenShift cluster domain"
    echo "  PROTOCOL            - http or https (default: https)"
    echo "  MODEL_NAME          - Model to test (auto-detected if empty)"
    echo "  TOKEN_FILE_PATH     - Path to token file (default: ../tokens/all/all_tokens.json)"
    echo "  USE_SAMPLE_TOKENS   - Use sample tokens for testing (default: false)"
}

# Check prerequisites
check_prerequisites() {
    local missing_tools=()

    if ! command -v k6 &> /dev/null; then
        missing_tools+=("k6")
    fi

    if ! command -v yq &> /dev/null && ! command -v python3 &> /dev/null; then
        missing_tools+=("yq or python3 (for YAML parsing)")
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        echo ""
        echo "To install k6: https://grafana.com/docs/k6/latest/set-up/install-k6/"
        echo "To install yq: https://github.com/mikefarah/yq"
        exit 1
    fi
}

# Parse YAML configuration
parse_config() {
    local config_name="$1"

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    # Try yq first, fallback to python
    if command -v yq &> /dev/null; then
        if ! yq eval ".${config_name}" "$CONFIG_FILE" | grep -q "null"; then
            yq eval ".${config_name}" "$CONFIG_FILE"
        else
            log_error "Configuration '$config_name' not found in $CONFIG_FILE"
            exit 1
        fi
    else
        # Python fallback for YAML parsing
        python3 -c "
import yaml, sys
try:
    with open('$CONFIG_FILE', 'r') as f:
        config = yaml.safe_load(f)
    if '$config_name' in config:
        for key, value in config['$config_name'].items():
            print(f'{key}: {value}')
    else:
        print('Configuration not found', file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f'Error parsing YAML: {e}', file=sys.stderr)
    sys.exit(1)
        "
    fi
}

# Convert config to environment variables
config_to_env() {
    local config_output="$1"
    local env_vars=""

    while IFS=': ' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            # Convert key to uppercase and replace underscores
            local env_key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
            env_vars="$env_vars -e ${env_key}=${value}"
        fi
    done <<< "$config_output"

    echo "$env_vars"
}

# Setup results directory
setup_results_dir() {
    mkdir -p "$RESULTS_DIR"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    echo "${RESULTS_DIR}/test_${1}_${timestamp}"
}

# Setup environment variables
setup_environment() {
    # Auto-detect CLUSTER_DOMAIN if not set
    if [ -z "${CLUSTER_DOMAIN:-}" ]; then
        log_info "Auto-detecting cluster domain..."
        if command -v kubectl &> /dev/null; then
            export CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
            if [ -n "$CLUSTER_DOMAIN" ]; then
                log_info "Detected cluster domain: $CLUSTER_DOMAIN"
            else
                log_warn "Could not auto-detect cluster domain. Please set CLUSTER_DOMAIN environment variable."
            fi
        else
            log_warn "kubectl not found. Please set CLUSTER_DOMAIN environment variable."
        fi
    fi

    # Auto-set HOST if not set
    if [ -z "${HOST:-}" ]; then
        if [ -n "${CLUSTER_DOMAIN:-}" ]; then
            export HOST="maas.${CLUSTER_DOMAIN}"
            log_info "Set HOST to: $HOST"
        else
            log_warn "HOST not set and CLUSTER_DOMAIN unavailable. Please set HOST environment variable."
        fi
    fi

    # Set default protocol if not set
    if [ -z "${PROTOCOL:-}" ]; then
        export PROTOCOL="https"
    fi

    log_info "Environment variables:"
    log_info "  HOST: ${HOST:-'not set'}"
    log_info "  CLUSTER_DOMAIN: ${CLUSTER_DOMAIN:-'not set'}"
    log_info "  PROTOCOL: ${PROTOCOL:-'not set'}"
    log_info "  MODEL_NAME: ${MODEL_NAME:-'not set'}"
}

# Check token availability
check_tokens() {
    local token_file="${TOKEN_DIR}/all/all_tokens.json"

    if [ ! -f "$token_file" ]; then
        log_warn "Token file not found: $token_file"
        log_info "You can:"
        echo "  1. Run '../scripts/provision-api-keys.sh' to generate API keys"
        echo "  2. Set USE_SAMPLE_TOKENS=true to use sample tokens for testing"
        echo ""
        read -p "Use sample tokens for this test? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            export USE_SAMPLE_TOKENS=true
            log_info "Using sample tokens for testing"
        else
            log_error "Cannot proceed without tokens"
            exit 1
        fi
    else
        local free_count=$(jq '.free | length' "$token_file" 2>/dev/null || echo "0")
        local premium_count=$(jq '.premium | length' "$token_file" 2>/dev/null || echo "0")
        log_info "Found $free_count free tokens and $premium_count premium tokens"
    fi
}

# Main execution
main() {
    local config_name="${1:-$DEFAULT_CONFIG}"
    shift || true
    local additional_args="$*"

    log_info "Starting MaaS performance test with configuration: $config_name"

    # Debug: Show initial environment variables
    log_info "=== INITIAL ENVIRONMENT VARIABLES ==="
    log_info "  HOST: ${HOST:-'not set'}"
    log_info "  CLUSTER_DOMAIN: ${CLUSTER_DOMAIN:-'not set'}"
    log_info "  PROTOCOL: ${PROTOCOL:-'not set'}"
    log_info "  MODEL_NAME: ${MODEL_NAME:-'not set'}"
    log_info "====================================="

    check_prerequisites
    setup_environment
    check_tokens

    # Parse configuration
    log_info "Loading configuration..."
    local config_output
    if ! config_output=$(parse_config "$config_name"); then
        log_error "Failed to parse configuration"
        exit 1
    fi

    # Extract description if available
    local description=$(echo "$config_output" | grep "description:" | cut -d' ' -f2- || echo "No description")
    log_info "Test description: $description"

    # Convert config to environment variables
    local env_vars
    env_vars=$(config_to_env "$config_output")

    # Setup results directory
    local results_prefix
    results_prefix=$(setup_results_dir "$config_name")

    # Build k6 command
    local k6_cmd="k6 run"
    k6_cmd="$k6_cmd $env_vars"

    # Add required environment variables
    if [ -n "${HOST:-}" ]; then
        k6_cmd="$k6_cmd -e HOST=${HOST}"
    fi
    if [ -n "${CLUSTER_DOMAIN:-}" ]; then
        k6_cmd="$k6_cmd -e CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
    fi
    if [ -n "${PROTOCOL:-}" ]; then
        k6_cmd="$k6_cmd -e PROTOCOL=${PROTOCOL}"
    fi
    if [ -n "${MODEL_NAME:-}" ]; then
        k6_cmd="$k6_cmd -e MODEL_NAME=${MODEL_NAME}"
    fi

    k6_cmd="$k6_cmd --summary-export=${results_prefix}_summary.json"
    k6_cmd="$k6_cmd --out json=${results_prefix}_results.json"
    k6_cmd="$k6_cmd $additional_args"
    k6_cmd="$k6_cmd $K6_SCRIPT"

    log_info "Running k6 test..."
    log_info "Command: $k6_cmd"
    echo ""

    # Execute k6 test
    if eval "$k6_cmd"; then
        log_success "Test completed successfully"
        echo ""
        echo "Results saved to:"
        echo "  Summary: ${results_prefix}_summary.json"
        echo "  Detailed: ${results_prefix}_results.json"
    else
        log_error "Test failed"
        exit 1
    fi
}

# Handle help flag
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
fi

# Run main function
main "$@"