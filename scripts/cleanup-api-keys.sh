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
CLEAN_TOKENS=${CLEAN_TOKENS:-true}
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
HOST="maas.${CLUSTER_DOMAIN}"
PROTOCOL="https"

log_info "Cleaning up API keys and tokens..."
echo "Host: $HOST"

if [ -z "$HOST" ] || [ "$HOST" = "maas." ]; then
    log_error "Could not determine HOST. Set CLUSTER_DOMAIN manually or provide HOST."
    exit 1
fi

# Get user's token for authentication
USER_TOKEN=$(oc whoami -t 2>/dev/null || echo "")
if [ -z "$USER_TOKEN" ]; then
    log_error "No OpenShift token available. Please login with 'oc login'"
    exit 1
fi

# Revoke API keys using key_id from token files
log_info "Revoking API keys..."
revoked_count=0
failed_count=0

for token_file in tokens/free/*.json tokens/premium/*.json; do
    if [ -f "$token_file" ]; then
        key_id=$(jq -r '.key_id // empty' "$token_file" 2>/dev/null || echo "")
        user_id=$(jq -r '.user_id // empty' "$token_file" 2>/dev/null || echo "")
        
        if [ -n "$key_id" ]; then
            log_info "Revoking API key for $user_id (ID: $key_id)"
            response=$(curl -sSk \
                -H "Authorization: Bearer $USER_TOKEN" \
                -X DELETE \
                -w "%{http_code}" \
                "${PROTOCOL}://${HOST}/maas-api/v1/api-keys/${key_id}" 2>/dev/null || echo "000")
                
            if [[ "$response" -ge 200 && "$response" -lt 300 ]]; then
                echo "  ✓ Revoked (HTTP $response)"
                revoked_count=$((revoked_count + 1))
            else
                echo "  ⚠ Failed (HTTP $response)"
                failed_count=$((failed_count + 1))
            fi
        else
            log_warn "No key_id found in $token_file"
        fi
    fi
done

# Clean up token files if requested
if [ "$CLEAN_TOKENS" == "true" ]; then
    log_info "Cleaning up token files..."
    rm -rf tokens/free/*.json tokens/premium/*.json tokens/all/*.json 2>/dev/null || true
fi

echo ""
log_info "Cleanup complete!"
echo "  - Revoked $revoked_count API keys successfully"
echo "  - Failed to revoke $failed_count API keys"
if [ "$CLEAN_TOKENS" == "true" ]; then
    echo "  - Removed token files"
fi