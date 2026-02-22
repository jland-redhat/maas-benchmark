# MaaS Benchmarking Quickstart

## Prerequisites
- Authenticated to OpenShift: `oc login`
- k6 installed
- MaaS deployment running
- etcd monitoring steps (Prometheus access + PromQL) are documented in `docs/ETCD-MONITORING.md`

## Service accounts and group-based auth

**Service accounts do not have IdP group membership.** When the gateway validates an SA token via Kubernetes TokenReview, the API returns:

- **User:** `system:serviceaccount:<namespace>:<name>`
- **Groups:** `system:serviceaccounts`, `system:serviceaccounts:<namespace>` (not `system:authenticated` or custom groups like `premium-user`)

So an MaaSAuthPolicy or MaaSSubscription that allows access only by **groups** (e.g. `system:authenticated` or `premium-user`) will **not** match SA tokens. Group-based policies are intended for human users whose tokens carry IdP groups.

**For benchmarking with service accounts** you must grant access by **user** (explicit SA identity), not by group. The **MaaS CR flow** below does exactly that: `setup-maas-crs-for-benchmark.sh` creates a MaaSAuthPolicy and MaaSSubscription whose `subjects.users` / `owner.users` list each benchmark SA as `system:serviceaccount:<namespace>:<name>`. That is the correct and only reliable way to run SA-based performance tests against the new MaaS CRs.

The legacy tier-namespace flow (SAs in `maas-default-gateway-tier-free`, etc.) may work on some clusters if a separate tier-by-namespace path exists, but it does not use the new MaaSSubscription/MaaSAuthPolicy model and is not guaranteed to work with group-only policies.

---

## Benchmarking with MaaS CRs (models-as-a-service)

To run benchmarks against the **new MaaS objects** (MaaSModel, MaaSAuthPolicy, MaaSSubscription) from the [models-as-a-service](https://github.com/opendatahub-io/models-as-a-service) repo (e.g. the `feature/maas-subscription-redesign` branch):

### 1. Install MaaS from a feature branch (optional)

From the `maas-benchmark` directory, point at your local clone and branch:

```bash
cd maas-benchmark

# Use the models-as-a-service repo (default: ../models-as-a-service) and a feature branch
MAAS_REPO_PATH=/path/to/models-as-a-service MAAS_BRANCH=feature/maas-subscription-redesign ./scripts/install-maas-from-branch.sh
```

This installs the maas-controller and, by default, the example MaaS CRs and simulator LLMInferenceServices. Set `SKIP_EXAMPLES=1` to skip examples if you already have models and CRs.

### 2. Create benchmark service accounts and tokens (MaaS CR mode)

Create SAs in a single namespace so they can be referenced by MaaSSubscription and MaaSAuthPolicy:

```bash
MAAS_CR_MODE=true FREE_USERS=10 PREMIUM_USERS=0 ./scripts/create-sa-tokens.sh
```

### 3. Create benchmark MaaS CRs

Create a MaaSAuthPolicy and MaaSSubscription that grant the benchmark **users** (each SA listed as `system:serviceaccount:...`) access to the model(s) with token rate limits. **MaaS CRs** (MaaSModel, MaaSAuthPolicy, MaaSSubscription) are created in the **opendatahub** namespace by default. The **LLMInferenceService** (simulator) is installed in **maas-benchmarking** by default, and the MaaSModel points at that LLMIS. If the MaaSModel (and LLMIS) for the default simulator do not exist, the script can install them from `MAAS_REPO_PATH` (default: `../models-as-a-service`). After apply, the script waits for MaaSModel(s) to be Ready and for MaaSAuthPolicy/MaaSSubscription to be Active, then runs **auth and rate-limit validation** to confirm auth works and token rate limiting is enforced before you run benchmarks.

```bash
./scripts/setup-maas-crs-for-benchmark.sh
```

Optional env: `MAAS_CR_NAMESPACE` (default: **opendatahub**), `BENCH_MODEL_NAMESPACE` (default: **maas-benchmarking**, where the LLMIS is deployed), `MODEL_NAMES`, `TOKEN_LIMIT`, `TOKEN_WINDOW`, `BENCH_SA_NAMESPACE`, `MAAS_REPO_PATH` (for auto-installing simulator), `SKIP_MODEL_INSTALL`, `SKIP_WAIT`, `SKIP_VALIDATE`.

**Validation:** The setup script runs `validate-benchmark-setup.sh`, which (1) checks that requests with no token or invalid token get 401 and valid token gets 2xx, and (2) temporarily lowers the subscription token limit, sends requests until a 429 is received, then restores the limit. You can run it manually: `./scripts/validate-benchmark-setup.sh`.

**Troubleshooting – Authorino shows `status.user` empty:** If `kubectl logs Deployment/authorino -n kuadrant-system` shows TokenReview responses with `"status":{"user":{}}`, the API server rejected the token (usually **audience mismatch**). The AuthPolicy uses `kubernetesTokenReview.audiences: [maas-default-gateway-sa, https://kubernetes.default.svc]`. Benchmark tokens are created with **both** audiences so they validate regardless of which audience Authorino sends. Re-create tokens with `create-sa-tokens.sh` (it now requests both audiences). If it still fails, confirm the AuthPolicy attached to your model’s HTTPRoute has those audiences: `kubectl get authpolicy -A -o yaml` and search for `kubernetesTokenReview`.

### 4. Run k6

Use the **MaaSModel name** for the URL: `MODEL_NAME=facebook-opt-125m-simulated`. The request URL is **`${PROTOCOL}://${HOST}/${MODEL_BASE_PATH}/${model}/v1/completions`**; **`MODEL_BASE_PATH`** defaults to **`maas-benchmarking`** (override with `MODEL_BASE_PATH=llm` if your gateway uses `/llm`). The script sends body `{ "model", "prompt", "max_tokens" }` and the **`x-maas-subscription`** header (default: `maas-benchmark-subscription`). If the inference backend expects a different model id in the body (e.g. simulator: `facebook/opt-125m`), set `MODEL_PAYLOAD_ID`:

```bash
export HOST="maas.$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
export MODEL_NAME="facebook-opt-125m-simulated"
export MODEL_PAYLOAD_ID="facebook/opt-125m"   # for simulator backend

HOST=$HOST MODEL_NAME=$MODEL_NAME MODEL_PAYLOAD_ID=$MODEL_PAYLOAD_ID PROTOCOL=https BURST_VUS=5 BURST_ITERATIONS=10 k6 run k6/maas-performance-test.js
```

Override base path: `MODEL_BASE_PATH=llm`. Override subscription header: `MAAS_SUBSCRIPTION_HEADER=your-subscription-name`.

### 5. Cleanup MaaS CRs and tokens

```bash
./scripts/cleanup-maas-crs.sh   # removes benchmark MaaS CRs from opendatahub namespace
MAAS_CR_MODE=true FREE_USERS=10 PREMIUM_USERS=0 ./scripts/cleanup-sa-tokens.sh
./scripts/token-manager.sh clean
```

---

## 0. Setup (legacy / tier-based)

### Upgrade Kuadrant to Latest (Optional)
```bash
# Bump Kuadrant operator to latest version
kubectl patch csv kuadrant-operator.v1.3.0 -n kuadrant-system --type='json' \
  -p='[{"op": "replace", "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/image", "value": "quay.io/kuadrant/kuadrant-operator:latest"}]'

# Verify the operator pod restarts with new image
kubectl get pods -n kuadrant-system -l control-plane=controller-manager -w
```

### Adjust Rate Limits for Scale Testing (Optional)

For scale/performance testing, increase rate limits to avoid hitting quotas during tests:

```bash
# Check current rate limit policies
kubectl get ratelimitpolicy -A
kubectl get tokenratelimitpolicy -A

# Increase RateLimitPolicy limits (requests per 2 minutes)
kubectl patch ratelimitpolicy gateway-rate-limits -n openshift-ingress --type='json' -p='[
  {"op": "replace", "path": "/spec/limits/free/rates/0/limit", "value": 10000},
  {"op": "replace", "path": "/spec/limits/premium/rates/0/limit", "value": 10000},
  {"op": "replace", "path": "/spec/limits/enterprise/rates/0/limit", "value": 10000}
]'

# Increase TokenRateLimitPolicy limits (tokens per 1 minute)
kubectl patch tokenratelimitpolicy gateway-token-rate-limits -n openshift-ingress --type='json' -p='[
  {"op": "replace", "path": "/spec/limits/free-user-tokens/rates/0/limit", "value": 10000000},
  {"op": "replace", "path": "/spec/limits/premium-user-tokens/rates/0/limit", "value": 10000000},
  {"op": "replace", "path": "/spec/limits/enterprise-user-tokens/rates/0/limit", "value": 10000000}
]'

# Verify the changes
kubectl get ratelimitpolicy gateway-rate-limits -n openshift-ingress -o jsonpath='{.spec.limits.free.rates[0].limit}'
# Should show: 10000

kubectl get tokenratelimitpolicy gateway-token-rate-limits -n openshift-ingress -o jsonpath='{.spec.limits.free-user-tokens.rates[0].limit}'
# Should show: 10000000
```

To restore original limits after testing:
```bash
# Restore RateLimitPolicy (5/20/50 per 2 min)
kubectl patch ratelimitpolicy gateway-rate-limits -n openshift-ingress --type='json' -p='[
  {"op": "replace", "path": "/spec/limits/free/rates/0/limit", "value": 5},
  {"op": "replace", "path": "/spec/limits/premium/rates/0/limit", "value": 20},
  {"op": "replace", "path": "/spec/limits/enterprise/rates/0/limit", "value": 50}
]'

# Restore TokenRateLimitPolicy (100/50000/100000 per 1 min)
kubectl patch tokenratelimitpolicy gateway-token-rate-limits -n openshift-ingress --type='json' -p='[
  {"op": "replace", "path": "/spec/limits/free-user-tokens/rates/0/limit", "value": 100},
  {"op": "replace", "path": "/spec/limits/premium-user-tokens/rates/0/limit", "value": 50000},
  {"op": "replace", "path": "/spec/limits/enterprise-user-tokens/rates/0/limit", "value": 100000}
]'
```

## 1. Create Service Account Tokens

Create multiple service accounts with unique tokens for multi-user benchmarking:

```bash
cd maas-benchmarking

# Create 10 free tier service accounts with tokens
FREE_USERS=10 PREMIUM_USERS=0 ./scripts/create-sa-tokens.sh

# Or with custom expiration (default is 2h)
TOKEN_EXPIRATION="4h" FREE_USERS=10 PREMIUM_USERS=0 ./scripts/create-sa-tokens.sh

# Verify tokens were created
./scripts/token-manager.sh status
```

This creates:
- Service accounts: `benchuser-free-1`, `benchuser-free-2`, etc.
- Kubernetes tokens with correct audience for MaaS gateway
- Each SA has a unique name for independent rate limiting

## 2. Run Benchmarks

Run k6 performance tests directly with environment variables:

```bash
# Set your MaaS host (replace with your actual host)
export HOST="your-maas-host.apps.example.com"
export MODEL_NAME="facebook/opt-125m"

# Basic test: 5 concurrent users, 10 requests each
HOST=$HOST MODEL_NAME=$MODEL_NAME BURST_VUS=5 BURST_ITERATIONS=10 k6 run k6/maas-performance-test.js

# Moderate load: 10 concurrent users, 20 requests each
HOST=$HOST MODEL_NAME=$MODEL_NAME BURST_VUS=10 BURST_ITERATIONS=20 k6 run k6/maas-performance-test.js

# High concurrency: 30 concurrent users, 30 requests each
HOST=$HOST MODEL_NAME=$MODEL_NAME BURST_VUS=30 BURST_ITERATIONS=30 k6 run k6/maas-performance-test.js

# Sustained load test (soak mode)
HOST=$HOST MODEL_NAME=$MODEL_NAME MODE=soak SOAK_DURATION=5m SOAK_RATE_FREE=2 k6 run k6/maas-performance-test.js
```

**Environment Variables:**
- `HOST` - MaaS hostname (without https://)
- `MODEL_NAME` - Model path/name for URL (e.g. `facebook-opt-125m-simulated` for MaaSModel name)
- `MODEL_BASE_PATH` - URL path segment before model name (default: `maas-benchmarking`). Full path: `/${MODEL_BASE_PATH}/${model}/v1/completions`. Set to `llm` if your gateway uses `/llm`.
- `MODEL_PAYLOAD_ID` - Model id sent in request body; set when the backend expects a different id (e.g. simulator: `facebook/opt-125m`)
- `MAAS_SUBSCRIPTION_HEADER` - Value for `x-maas-subscription` header (default: `maas-benchmark-subscription`)
- `PROTOCOL` - `http` or `https` (default: http)
- `BURST_VUS` - Number of concurrent virtual users
- `BURST_ITERATIONS` - Total iterations to run
- `MODE` - Test mode: `burst` (default), `soak`, or `rate-limit-test`

## 4. View Results

```bash
# Latest test results
ls -lth results/*.json | head -5

# View summary with better formatting
cat results/test_*_summary.json | jq
```

## 5. Cleanup

```bash
# Remove service accounts and tokens
FREE_USERS=10 PREMIUM_USERS=0 ./scripts/cleanup-sa-tokens.sh

# Keep tokens but clean service accounts
FREE_USERS=10 PREMIUM_USERS=0 CLEAN_TOKENS=false ./scripts/cleanup-sa-tokens.sh

# Or just remove token files
./scripts/token-manager.sh clean
```

## Quick Reference

**Common Test Patterns:**
```bash
export HOST="your-maas-host.apps.example.com"
export MODEL_NAME="facebook/opt-125m"

# Single user baseline
HOST=$HOST MODEL_NAME=$MODEL_NAME BURST_VUS=1 BURST_ITERATIONS=1 k6 run k6/maas-performance-test.js

# Safe concurrent load (recommended)
HOST=$HOST MODEL_NAME=$MODEL_NAME BURST_VUS=3 BURST_ITERATIONS=10 k6 run k6/maas-performance-test.js

# Breaking point test (will likely fail)
HOST=$HOST MODEL_NAME=$MODEL_NAME BURST_VUS=30 BURST_ITERATIONS=30 k6 run k6/maas-performance-test.js

# Sustained load (soak test)
HOST=$HOST MODEL_NAME=$MODEL_NAME MODE=soak SOAK_DURATION=2m SOAK_RATE_FREE=5 k6 run k6/maas-performance-test.js
```

**Scale to More Users:**
```bash
# Create 50 service accounts
FREE_USERS=50 PREMIUM_USERS=0 ./scripts/create-sa-tokens.sh
```
