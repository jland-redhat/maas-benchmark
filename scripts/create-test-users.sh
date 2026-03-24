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
PREMIUM_USERS=${PREMIUM_USERS:-3}
HTPASSWD_FILE=$(mktemp)
PASSWORD="benchmarkuser123"  # Simple password for test users

log_info "Creating htpasswd file with $FREE_USERS free users and $PREMIUM_USERS premium users..."

# Create htpasswd file with test users
for i in $(seq 1 $FREE_USERS); do
    username="freeuser${i}"
    log_info "Adding user: $username"
    htpasswd -bB "$HTPASSWD_FILE" "$username" "$PASSWORD" 2>/dev/null
done

for i in $(seq 1 $PREMIUM_USERS); do
    username="premiumuser${i}"
    log_info "Adding user: $username"
    htpasswd -bB "$HTPASSWD_FILE" "$username" "$PASSWORD" 2>/dev/null
done

# Create or update htpasswd secret
log_info "Creating htpasswd secret in openshift-config namespace..."
if oc get secret htpasswd-secret -n openshift-config &>/dev/null; then
    log_warn "htpasswd-secret already exists, replacing it..."
    oc delete secret htpasswd-secret -n openshift-config
fi

oc create secret generic htpasswd-secret \
    --from-file=htpasswd="$HTPASSWD_FILE" \
    -n openshift-config

rm "$HTPASSWD_FILE"

# Configure OAuth to use htpasswd identity provider
log_info "Configuring OAuth identity provider..."
cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpasswd_provider
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpasswd-secret
EOF

log_info "Waiting for OAuth pods to restart (this may take 1-2 minutes)..."
sleep 10

# Wait for authentication operator to process the change
log_info "Waiting for authentication operator..."
oc wait --for=condition=Progressing=False clusteroperator/authentication --timeout=300s 2>/dev/null || true

# Get tier-to-group-mapping to find the correct group names
log_info "Getting tier group mappings..."
FREE_GROUP=$(kubectl get configmap tier-to-group-mapping -n maas-api -o jsonpath='{.data.free}' 2>/dev/null || echo "")
PREMIUM_GROUP=$(kubectl get configmap tier-to-group-mapping -n maas-api -o jsonpath='{.data.premium}' 2>/dev/null || echo "")

if [ -z "$FREE_GROUP" ]; then
    log_error "Could not find free tier group mapping"
    exit 1
fi

log_info "Free tier group: $FREE_GROUP"
log_info "Premium tier group: $PREMIUM_GROUP"

# Create groups and add users
log_info "Creating groups and adding users..."

# Add free users to free tier group
if [ $FREE_USERS -gt 0 ]; then
    for i in $(seq 1 $FREE_USERS); do
        username="freeuser${i}"
        log_info "Adding $username to $FREE_GROUP group"
        oc adm groups add-users "$FREE_GROUP" "$username" 2>/dev/null || \
            oc adm groups new "$FREE_GROUP" "$username" 2>/dev/null || true
    done
fi

# Add premium users to premium tier group
if [ $PREMIUM_USERS -gt 0 ] && [ -n "$PREMIUM_GROUP" ]; then
    for i in $(seq 1 $PREMIUM_USERS); do
        username="premiumuser${i}"
        log_info "Adding $username to $PREMIUM_GROUP group"
        oc adm groups add-users "$PREMIUM_GROUP" "$username" 2>/dev/null || \
            oc adm groups new "$PREMIUM_GROUP" "$username" 2>/dev/null || true
    done
fi

# Display created users
log_info "Created test users:"
echo ""
echo "Free tier users ($FREE_USERS):"
for i in $(seq 1 $FREE_USERS); do
    echo "  - freeuser${i} / $PASSWORD"
done

if [ $PREMIUM_USERS -gt 0 ]; then
    echo ""
    echo "Premium tier users ($PREMIUM_USERS):"
    for i in $(seq 1 $PREMIUM_USERS); do
        echo "  - premiumuser${i} / $PASSWORD"
    done
fi

echo ""
log_info "Test users created successfully!"
log_info "You can now provision API keys using: ./scripts/provision-api-keys.sh"
log_info ""
log_info "Note: It may take 1-2 minutes for the OAuth pods to fully restart."
log_info "      If token provisioning fails, wait a bit and try again."
