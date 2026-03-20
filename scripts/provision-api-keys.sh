#!/bin/bash

# provision-api-keys.sh - Provision API keys for benchmarking
set -euo pipefail

# Configuration
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
HOST="maas.${CLUSTER_DOMAIN}"
PROTOCOL="https"
TOKEN_EXPIRATION=${TOKEN_EXPIRATION:-"4h"}
FREE_USERS=${FREE_USERS:-3}
PREMIUM_USERS=${PREMIUM_USERS:-3}

# No need to save context since we're using the current user

echo "Starting MaaS API key provisioning..."
echo "Host: $HOST"
echo "Free users: $FREE_USERS, Premium users: $PREMIUM_USERS"

# Create directories
mkdir -p tokens/{free,premium,all}
rm -f tokens/free/*.json tokens/premium/*.json tokens/all/*.json

# API key provisioning using current user

# Provision API keys for benchmarking
echo "Provisioning API keys for benchmarking..."
success_count=0
failure_count=0
TOTAL_TOKENS=$((FREE_USERS + PREMIUM_USERS))

echo "Current OpenShift user: $(oc whoami)"
echo "Creating $TOTAL_TOKENS API keys..."

# Get user's token once
USER_TOKEN=$(oc whoami -t)
if [[ -z "$USER_TOKEN" ]]; then
    echo "ERROR: No OpenShift token available. Please login with 'oc login'"
    exit 1
fi

i=1
while [ $i -le $TOTAL_TOKENS ]; do
    user_id="benchuser${i}"

    echo "API key $i/$TOTAL_TOKENS: $user_id"

    response=$(curl -sSk \
        -w "\n%{http_code}" \
        --max-time 30 \
        -H "Authorization: Bearer ${USER_TOKEN}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d '{"name": "'${user_id}'", "expiresIn": "'${TOKEN_EXPIRATION}'"}' \
        "${PROTOCOL}://${HOST}/maas-api/v1/api-keys")

    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        # Extract token and key_id
        token=$(echo "$response_body" | jq -r '.key')
        key_id=$(echo "$response_body" | jq -r '.id')
        
        # Save token to free directory (since we don't care about tiers for this test)
        output_file="tokens/free/${user_id}.json"
        cat > "$output_file" <<EOF
{
    "user_id": "$user_id",
    "token": "$token",
    "tier": "free",
    "key_id": "$key_id"
}
EOF
        echo "SUCCESS: $user_id"
        success_count=$((success_count + 1))
    else
        echo "ERROR: Failed $user_id (HTTP $http_code)"
        echo "Response: $response_body" >&2
        failure_count=$((failure_count + 1))
    fi

    i=$((i + 1))
done

echo "API key provisioning complete: $success_count successful, $failure_count failed"

# No context restoration needed

# Generate consolidated files
echo "Generating consolidated files..."

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

# Combined file
jq -s '{"free": .[0], "premium": .[1]}' \
    tokens/all/free_tokens.json \
    tokens/all/premium_tokens.json > tokens/all/all_tokens.json

# Simple list
{
    echo "# Free tokens"
    if [ -s tokens/all/free_tokens.json ]; then
        jq -r '.[] | .user_id + "=" + .token' tokens/all/free_tokens.json 2>/dev/null || true
    fi
    echo "# Premium tokens"
    if [ -s tokens/all/premium_tokens.json ]; then
        jq -r '.[] | .user_id + "=" + .token' tokens/all/premium_tokens.json 2>/dev/null || true
    fi
} > tokens/all/token_list.txt

# Summary
free_count=$(find tokens/free -name '*.json' | wc -l)
premium_count=$(find tokens/premium -name '*.json' | wc -l)

echo ""
echo "=== COMPLETE ==="
echo "Total successful: $success_count"
echo "Total failed: $failure_count"
echo "Free tokens: $free_count"
echo "Premium tokens: $premium_count"
echo "Files: tokens/all/all_tokens.json"
echo "Done!"