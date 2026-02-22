#!/usr/bin/env bash
# install-maas-from-branch.sh - Install MaaS controller and examples from a feature branch
#
# Use this to run benchmarks against the new MaaS CRs (MaaSModel, MaaSAuthPolicy,
# MaaSSubscription) from a specific branch of the models-as-a-service repo (e.g.
# feature/maas-subscription-redesign).
#
# Prerequisites: oc/kubectl, cluster with Gateway API and Kuadrant. The shared
# gateway-auth-policy in openshift-ingress should be disabled before using
# MaaSAuthPolicy (see models-as-a-service/maas-controller/hack/disable-gateway-auth-policy.sh).
#
# Usage:
#   MAAS_REPO_PATH=/path/to/models-as-a-service MAAS_BRANCH=feature/maas-subscription-redesign ./scripts/install-maas-from-branch.sh
#
# Environment:
#   MAAS_REPO_PATH   Path to models-as-a-service repo (default: ../models-as-a-service from maas-benchmark)
#   MAAS_BRANCH      Branch to use (default: main). Use feature/maas-subscription-redesign for subscription redesign.
#   MAAS_NAMESPACE   Namespace for controller and CRs (default: opendatahub)
#   SKIP_EXAMPLES    If set, do not install example MaaS CRs and simulator LLMInferenceServices

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_DIR="$(dirname "$SCRIPT_DIR")"
MAAS_REPO_PATH="${MAAS_REPO_PATH:-$(dirname "$BENCHMARK_DIR")/models-as-a-service}"
MAAS_BRANCH="${MAAS_BRANCH:-main}"
MAAS_NAMESPACE="${MAAS_NAMESPACE:-opendatahub}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ ! -d "$MAAS_REPO_PATH" ]]; then
  log_error "MaaS repo not found: $MAAS_REPO_PATH"
  log_info "Set MAAS_REPO_PATH to the path of the models-as-a-service repo, or clone it:"
  log_info "  git clone https://github.com/opendatahub-io/models-as-a-service.git"
  exit 1
fi

CONTROLLER_DIR="${MAAS_REPO_PATH}/maas-controller"
if [[ ! -d "$CONTROLLER_DIR" ]]; then
  log_error "maas-controller not found at $CONTROLLER_DIR"
  exit 1
fi

log_info "Using MaaS repo: $MAAS_REPO_PATH"
log_info "Branch: $MAAS_BRANCH"
log_info "Namespace: $MAAS_NAMESPACE"

# Optional: checkout branch (if repo is a git clone and branch differs)
if [[ -d "${MAAS_REPO_PATH}/.git" ]]; then
  current=$(cd "$MAAS_REPO_PATH" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [[ -n "$current" && "$current" != "$MAAS_BRANCH" ]]; then
    log_info "Checking out branch $MAAS_BRANCH (current: $current)..."
    (cd "$MAAS_REPO_PATH" && git fetch -q origin "$MAAS_BRANCH" 2>/dev/null || true; git checkout "$MAAS_BRANCH" 2>/dev/null || git checkout -b "$MAAS_BRANCH" origin/"$MAAS_BRANCH" 2>/dev/null) || {
      log_warn "Could not checkout $MAAS_BRANCH; continuing with current branch $current"
    }
  fi
else
  log_warn "Not a git repo; using current contents (no branch checkout)"
fi

# Install controller
log_info "Installing maas-controller..."
"${CONTROLLER_DIR}/scripts/install-maas-controller.sh" "$MAAS_NAMESPACE"

# Wait for controller to be ready
log_info "Waiting for maas-controller to be ready..."
if ! kubectl rollout status deployment/maas-controller -n "$MAAS_NAMESPACE" --timeout=120s 2>/dev/null; then
  log_warn "maas-controller may not be ready yet; check: kubectl get pods -n $MAAS_NAMESPACE -l app=maas-controller"
fi

if [[ -n "${SKIP_EXAMPLES:-}" ]]; then
  log_info "SKIP_EXAMPLES set; skipping example MaaS CRs and simulator models"
else
  log_info "Installing example MaaS CRs and simulator LLMInferenceServices..."
  REPO_PARENT="$MAAS_REPO_PATH" "${CONTROLLER_DIR}/scripts/install-examples.sh" || {
    log_warn "install-examples.sh failed; you may need to create MaaSModel/MaaSAuthPolicy/MaaSSubscription and models manually"
  }
fi

log_info "Done. Next steps:"
log_info "  1. Create benchmark SAs and tokens: MAAS_CR_MODE=true FREE_USERS=10 ./scripts/create-sa-tokens.sh"
log_info "  2. Create benchmark MaaS CRs:      ./scripts/setup-maas-crs-for-benchmark.sh"
log_info "  3. Run k6: HOST=maas.<cluster-domain> MODEL_NAME=facebook-opt-125m-simulated k6 run k6/maas-performance-test.js"
