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
MAAS_CR_MODE=${MAAS_CR_MODE:-false}
BENCH_SA_NAMESPACE=${BENCH_SA_NAMESPACE:-maas-benchmark}

log_info "Cleaning up service accounts and tokens..."

if [[ "$MAAS_CR_MODE" == "true" ]]; then
    # MaaS CR mode: all SAs in a single benchmark namespace
    if kubectl get namespace "$BENCH_SA_NAMESPACE" &>/dev/null; then
        log_info "Cleaning up service accounts in $BENCH_SA_NAMESPACE (MaaS CR mode)..."
        for i in $(seq 1 $FREE_USERS); do
            kubectl delete sa "benchuser-free-${i}" -n "$BENCH_SA_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
        done
        for i in $(seq 1 $PREMIUM_USERS); do
            kubectl delete sa "benchuser-premium-${i}" -n "$BENCH_SA_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
        done
    fi
else
    # Legacy tier namespaces
    FREE_NAMESPACE="maas-default-gateway-tier-free"
    if kubectl get namespace "$FREE_NAMESPACE" &>/dev/null; then
        log_info "Cleaning up service accounts in $FREE_NAMESPACE..."
        for i in $(seq 1 $FREE_USERS); do
            username="benchuser-free-${i}"
            log_info "Deleting SA: $FREE_NAMESPACE/$username"
            kubectl delete sa "$username" -n "$FREE_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
        done
    fi

    PREMIUM_NAMESPACE="maas-default-gateway-tier-premium"
    if kubectl get namespace "$PREMIUM_NAMESPACE" &>/dev/null; then
        log_info "Cleaning up service accounts in $PREMIUM_NAMESPACE..."
        for i in $(seq 1 $PREMIUM_USERS); do
            username="benchuser-premium-${i}"
            log_info "Deleting SA: $PREMIUM_NAMESPACE/$username"
            kubectl delete sa "$username" -n "$PREMIUM_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
        done
    fi
fi

# Clean up ClusterRoleBinding for premium tier (legacy mode only)
if [[ "$MAAS_CR_MODE" != "true" ]] && [[ $PREMIUM_USERS -gt 0 ]]; then
    log_info "Cleaning up premium tier group resources..."
    kubectl delete clusterrolebinding tier-premium-users --ignore-not-found=true 2>/dev/null || true
    kubectl delete clusterrole tier-premium-group --ignore-not-found=true 2>/dev/null || true
fi

# Clean up token files if requested
if [ "$CLEAN_TOKENS" == "true" ]; then
    log_info "Cleaning up token files..."
    rm -rf tokens/free/*.json tokens/premium/*.json tokens/all/*.json 2>/dev/null || true
fi

echo ""
log_info "Cleanup complete!"
echo "  - Removed $FREE_USERS free tier service accounts"
echo "  - Removed $PREMIUM_USERS premium tier service accounts"
if [ "$CLEAN_TOKENS" == "true" ]; then
    echo "  - Removed token files"
fi
