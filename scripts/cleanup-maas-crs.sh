#!/usr/bin/env bash
# cleanup-maas-crs.sh - Remove benchmark MaaSSubscription and MaaSAuthPolicy
#
# Deletes the MaaS CRs created by setup-maas-crs-for-benchmark.sh so you can
# re-run setup or tear down after benchmarking.
#
# Usage:
#   ./scripts/cleanup-maas-crs.sh
#
# Environment:
#   MAAS_CR_NAMESPACE   Namespace where MaaS CRs were created (default: opendatahub)

set -euo pipefail

MAAS_CR_NAMESPACE="${MAAS_CR_NAMESPACE:-opendatahub}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

log_info "Removing benchmark MaaS CRs from namespace $MAAS_CR_NAMESPACE..."

kubectl delete maasauthpolicy maas-benchmark-auth -n "$MAAS_CR_NAMESPACE" --ignore-not-found=true
kubectl delete maassubscription maas-benchmark-subscription -n "$MAAS_CR_NAMESPACE" --ignore-not-found=true

log_info "Done. Benchmark MaaSAuthPolicy and MaaSSubscription removed."
