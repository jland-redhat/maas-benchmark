#!/usr/bin/env bash
# setup-maas-crs-for-benchmark.sh - Create MaaSSubscription and MaaSAuthPolicy for benchmark users
#
# Uses the MaaS CRs from models-as-a-service (MaaSModel, MaaSAuthPolicy, MaaSSubscription).
# Reads benchmark users from tokens/all/all_tokens.json and creates CRs so each
# service account has access to the specified model(s) with the given token rate limits.
#
# Prerequisites:
#   - maas-controller installed (e.g. from models-as-a-service)
#   - MaaSModel(s) already exist for the model names you use
#   - Run create-sa-tokens.sh first (with MAAS_CR_MODE=true to use benchmark namespace)
#
# Usage:
#   ./scripts/setup-maas-crs-for-benchmark.sh
#
# Environment:
#   MAAS_CR_NAMESPACE     Namespace for MaaS CRs - MaaSModel, MaaSAuthPolicy, MaaSSubscription (default: opendatahub)
#   BENCH_SA_NAMESPACE   Namespace where benchmark SAs live (default: maas-benchmark)
#   BENCH_MODEL_NAMESPACE Namespace where LLMIS (simulator) is installed (default: maas-benchmarking)
#   MODEL_NAMES          Comma-separated MaaSModel names (default: facebook-opt-125m-simulated)
#   TOKEN_LIMIT          Token rate limit per user per model (default: 100000)
#   TOKEN_WINDOW         Rate limit window (default: 1m)
#   TOKEN_FILE           Path to all_tokens.json (default: tokens/all/all_tokens.json)
#   MAAS_REPO_PATH       Path to models-as-a-service repo for installing simulator (default: ../models-as-a-service)
#   SKIP_MODEL_INSTALL   If set, do not install LLMIS or MaaSModel if missing
#   SKIP_WAIT            If set, do not wait for CRs to reconcile
#   SKIP_VALIDATE        If set, do not run auth and rate-limit validation tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

MAAS_CR_NAMESPACE="${MAAS_CR_NAMESPACE:-opendatahub}"
BENCH_SA_NAMESPACE="${BENCH_SA_NAMESPACE:-maas-benchmark}"
BENCH_MODEL_NAMESPACE="${BENCH_MODEL_NAMESPACE:-maas-benchmarking}"
MODEL_NAMES="${MODEL_NAMES:-facebook-opt-125m-simulated}"
TOKEN_LIMIT="${TOKEN_LIMIT:-100000}"
TOKEN_WINDOW="${TOKEN_WINDOW:-1m}"
TOKEN_FILE="${TOKEN_FILE:-$PROJECT_DIR/tokens/all/all_tokens.json}"
MAAS_REPO_PATH="${MAAS_REPO_PATH:-$(dirname "$PROJECT_DIR")/models-as-a-service}"

BENCH_AUTH_POLICY_NAME="maas-benchmark-auth"
BENCH_SUBSCRIPTION_NAME="maas-benchmark-subscription"

if [[ ! -f "$TOKEN_FILE" ]]; then
  log_error "Token file not found: $TOKEN_FILE"
  log_info "Run create-sa-tokens.sh first (with MAAS_CR_MODE=true for MaaS CR mode)"
  exit 1
fi

# Ensure MaaS CR namespace exists (opendatahub is often created by operator; create if missing)
if ! kubectl get namespace "$MAAS_CR_NAMESPACE" &>/dev/null; then
  log_info "Creating namespace $MAAS_CR_NAMESPACE"
  kubectl create namespace "$MAAS_CR_NAMESPACE"
fi

# Install LLMIS in BENCH_MODEL_NAMESPACE (maas-benchmarking) and MaaSModel in MAAS_CR_NAMESPACE (opendatahub) if missing
ensure_model_and_maas_model() {
  local model_name="$1"
  if kubectl get maasmodel "$model_name" -n "$MAAS_CR_NAMESPACE" &>/dev/null; then
    log_info "MaaSModel $model_name already exists in $MAAS_CR_NAMESPACE"
    return 0
  fi
  if [[ -n "${SKIP_MODEL_INSTALL:-}" ]]; then
    log_warn "MaaSModel $model_name not found; SKIP_MODEL_INSTALL set. Create it manually."
    return 1
  fi
  if [[ "$model_name" != "facebook-opt-125m-simulated" ]]; then
    log_warn "Auto-install only supports facebook-opt-125m-simulated. Create MaaSModel $model_name manually."
    return 1
  fi
  if [[ ! -d "$MAAS_REPO_PATH" ]]; then
    log_error "MAAS_REPO_PATH not found: $MAAS_REPO_PATH. Set it or create MaaSModel manually."
    return 1
  fi
  local models_dir="${MAAS_REPO_PATH}/docs/samples/models/simulator"
  if [[ ! -d "$models_dir" ]]; then
    log_error "Simulator not found at $models_dir. Set MAAS_REPO_PATH or create MaaSModel manually."
    return 1
  fi
  log_info "Installing LLMInferenceService (simulator) in $BENCH_MODEL_NAMESPACE and MaaSModel in $MAAS_CR_NAMESPACE..."
  kubectl get namespace "$BENCH_MODEL_NAMESPACE" &>/dev/null || kubectl create namespace "$BENCH_MODEL_NAMESPACE"
  # Simulator kustomization uses namespace: llm; override to BENCH_MODEL_NAMESPACE so LLMIS is in maas-benchmarking
  (cd "$MAAS_REPO_PATH" && kustomize build "docs/samples/models/simulator") | \
    sed "s/namespace: llm/namespace: $BENCH_MODEL_NAMESPACE/g" | \
    kubectl apply -f -
  # MaaSModel lives in MAAS_CR_NAMESPACE (opendatahub) and points at LLMIS in BENCH_MODEL_NAMESPACE (maas-benchmarking)
  kubectl apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModel
metadata:
  name: $model_name
  namespace: $MAAS_CR_NAMESPACE
  labels:
    app.kubernetes.io/part-of: maas-benchmarking
spec:
  modelRef:
    kind: LLMInferenceService
    name: $model_name
    namespace: $BENCH_MODEL_NAMESPACE
EOF
  log_info "Installed LLMIS in $BENCH_MODEL_NAMESPACE and MaaSModel $model_name in $MAAS_CR_NAMESPACE"
}

for name in ${MODEL_NAMES//,/ }; do
  name=$(echo "$name" | tr -d ' ')
  ensure_model_and_maas_model "$name" || true
done

# Build list of users: system:serviceaccount:${BENCH_SA_NAMESPACE}:${user_id}
# Token JSON may have "namespace" (MaaS CR mode) or we use BENCH_SA_NAMESPACE
users=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  users+=("$line")
done < <(jq -r --arg ns "$BENCH_SA_NAMESPACE" '
  ([.free // [], .premium // []] | add[])
  | (if .namespace then .namespace else $ns end) as $n
  | "system:serviceaccount:\($n):\(.user_id)"
' "$TOKEN_FILE" 2>/dev/null)

if [[ ${#users[@]} -eq 0 ]]; then
  log_error "No users found in $TOKEN_FILE"
  exit 1
fi

log_info "Creating MaaS CRs for ${#users[@]} benchmark users in namespace $MAAS_CR_NAMESPACE"
log_info "Models: $MODEL_NAMES | Token limit: $TOKEN_LIMIT / $TOKEN_WINDOW"

# Build modelRefs for subscription (each model with token rate limits)
model_refs_yaml=""
for name in ${MODEL_NAMES//,/ }; do
  name=$(echo "$name" | tr -d ' ')
  model_refs_yaml="${model_refs_yaml}
    - name: ${name}
      tokenRateLimits:
        - limit: ${TOKEN_LIMIT}
          window: ${TOKEN_WINDOW}"
done

# Build users YAML block (each user quoted for colons)
users_yaml=""
for u in "${users[@]}"; do
  users_yaml="${users_yaml}
    - \"${u}\""
done

# Build modelRefs list for auth policy
model_refs_list=""
for name in ${MODEL_NAMES//,/ }; do
  name=$(echo "$name" | tr -d ' ')
  model_refs_list="${model_refs_list}
    - ${name}"
done

# MaaSAuthPolicy: subjects = benchmark users, modelRefs = models
auth_policy=$(cat <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: ${BENCH_AUTH_POLICY_NAME}
  namespace: ${MAAS_CR_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: maas-benchmarking
spec:
  modelRefs:${model_refs_list}
  subjects:
    users:${users_yaml}
    groups: []
EOF
)

# MaaSSubscription: owner = benchmark users, modelRefs with token rate limits
subscription=$(cat <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: ${BENCH_SUBSCRIPTION_NAME}
  namespace: ${MAAS_CR_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: maas-benchmarking
spec:
  owner:
    users:${users_yaml}
    groups: []
  modelRefs:${model_refs_yaml}
EOF
)

# Apply (use temporary files to avoid quoting issues)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
echo "$auth_policy" > "$tmpdir/auth-policy.yaml"
echo "$subscription" > "$tmpdir/subscription.yaml"

kubectl apply -f "$tmpdir/auth-policy.yaml"
kubectl apply -f "$tmpdir/subscription.yaml"

log_info "Applied MaaSAuthPolicy $BENCH_AUTH_POLICY_NAME and MaaSSubscription $BENCH_SUBSCRIPTION_NAME"

# Wait for reconciliation unless skipped
if [[ -z "${SKIP_WAIT:-}" ]]; then
  log_info "Waiting for MaaS CRs to reconcile..."
  for name in ${MODEL_NAMES//,/ }; do
    name=$(echo "$name" | tr -d ' ')
    for i in 1 2 3 4 5 6 7 8 9 10; do
      phase=$(kubectl get maasmodel "$name" -n "$MAAS_CR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      [[ "$phase" == "Ready" ]] && break
      log_info "  MaaSModel $name phase=$phase (attempt $i/10)"
      sleep 5
    done
    phase=$(kubectl get maasmodel "$name" -n "$MAAS_CR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "$phase" != "Ready" ]] && log_warn "MaaSModel $name did not become Ready (phase=$phase)"
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ap_phase=$(kubectl get maasauthpolicy "$BENCH_AUTH_POLICY_NAME" -n "$MAAS_CR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    sub_phase=$(kubectl get maassubscription "$BENCH_SUBSCRIPTION_NAME" -n "$MAAS_CR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "$ap_phase" == "Active" && "$sub_phase" == "Active" ]] && break
    log_info "  MaaSAuthPolicy phase=$ap_phase, MaaSSubscription phase=$sub_phase (attempt $i/10)"
    sleep 5
  done
  ap_phase=$(kubectl get maasauthpolicy "$BENCH_AUTH_POLICY_NAME" -n "$MAAS_CR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  sub_phase=$(kubectl get maassubscription "$BENCH_SUBSCRIPTION_NAME" -n "$MAAS_CR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$ap_phase" == "Active" && "$sub_phase" == "Active" ]]; then
    log_info "MaaSAuthPolicy and MaaSSubscription are Active."
  else
    log_warn "MaaSAuthPolicy phase=$ap_phase, MaaSSubscription phase=$sub_phase (may still be reconciling)"
  fi
  # Show generated Kuadrant resources (AuthPolicy and TokenRateLimitPolicy target HTTPRoutes)
  log_info "Generated resources (controller reconciles these):"
  kubectl get authpolicy -A -l app.kubernetes.io/managed-by=maas-controller 2>/dev/null | head -10 || true
  kubectl get tokenratelimitpolicy -A -l app.kubernetes.io/managed-by=maas-controller 2>/dev/null | head -10 || true
else
  log_info "SKIP_WAIT set; not waiting for reconciliation."
fi

# Run validation tests unless skipped
if [[ -z "${SKIP_VALIDATE:-}" ]]; then
  val_host="${HOST:-maas.$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)}"
  val_proto="${PROTOCOL:-https}"
  val_base_path="${MODEL_BASE_PATH:-maas-benchmarking}"
  first_model=$(echo "$MODEL_NAMES" | cut -d',' -f1 | tr -d ' ')
  val_url="${val_proto}://${val_host}/${val_base_path}/${first_model}/v1/completions"
  log_info "Running auth and rate-limit validation tests (URL: $val_url)..."
  if [[ -f "$SCRIPT_DIR/validate-benchmark-setup.sh" ]]; then
    HOST="$val_host" PROTOCOL="$val_proto" MODEL_BASE_PATH="$val_base_path" \
    MAAS_CR_NAMESPACE="$MAAS_CR_NAMESPACE" \
    TOKEN_FILE="$TOKEN_FILE" \
    MODEL_NAMES="$MODEL_NAMES" \
    "$SCRIPT_DIR/validate-benchmark-setup.sh" || log_warn "Validation failed — check URL: $val_url"
  else
    log_info "Run ./scripts/validate-benchmark-setup.sh to validate auth and rate limiting."
  fi
else
  log_info "SKIP_VALIDATE set. Run ./scripts/validate-benchmark-setup.sh to validate auth and rate limiting."
fi

log_info "Done. Verify: kubectl get maasmodel,maasauthpolicy,maassubscription -n $MAAS_CR_NAMESPACE -l app.kubernetes.io/part-of=maas-benchmarking"
