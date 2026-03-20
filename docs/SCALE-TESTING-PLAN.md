# MaaS Scale Testing Plan

**Objective**: Quantify scale limits and answer concerns about etcd/TokenReview performance under load.

---

## Cluster Summary

### Infrastructure
| Component | Details |
|-----------|---------|
| **Platform** | ROSA (Red Hat OpenShift on AWS) - HyperShift |
| **OpenShift Version** | 4.19 (Kubernetes v1.32.9) |
| **Worker Nodes** | 2 nodes |
| **Current Utilization** | Node 1: 51% CPU, 30% Memory / Node 2: 7% CPU, 29% Memory |

### Key Components
| Component | Replicas | Resources | Location |
|-----------|----------|-----------|----------|
| **MaaS API** | 1 | 200m CPU, 128Mi Memory | ip-10-0-1-147 |
| **Router (Ingress)** | 2 | Default | Both nodes |
| **Authorino** | 1 | Default | ip-10-0-1-147 |
| **Limitador** | 1 | Default | ip-10-0-1-147 |
| **Model Server** | 1 | 1 CPU, 24Gi Memory | ip-10-0-1-147 |

### Current Rate Limits
| Tier | Request Limit | Token Limit |
|------|---------------|-------------|
| **Free** | 5 req / 2 min | 100 tokens / 1 min |
| **Premium** | 20 req / 2 min | 50,000 tokens / 1 min |
| **Enterprise** | 50 req / 2 min | 100,000 tokens / 1 min |

---

## Test Prerequisites

### 1. Adjust Rate Limits for Scale Testing
```bash
# Check current rate limit policies
kubectl get ratelimitpolicy -A
kubectl get tokenratelimitpolicy -A

# Increase RateLimitPolicy limits (10000 requests per 2 minutes)
kubectl patch ratelimitpolicy gateway-rate-limits -n openshift-ingress --type='json' -p='[
  {"op": "replace", "path": "/spec/limits/free/rates/0/limit", "value": 10000},
  {"op": "replace", "path": "/spec/limits/premium/rates/0/limit", "value": 10000},
  {"op": "replace", "path": "/spec/limits/enterprise/rates/0/limit", "value": 10000}
]'

# Increase TokenRateLimitPolicy limits (10M tokens per 1 minute)
kubectl patch tokenratelimitpolicy gateway-token-rate-limits -n openshift-ingress --type='json' -p='[
  {"op": "replace", "path": "/spec/limits/free-user-tokens/rates/0/limit", "value": 10000000},
  {"op": "replace", "path": "/spec/limits/premium-user-tokens/rates/0/limit", "value": 10000000},
  {"op": "replace", "path": "/spec/limits/enterprise-user-tokens/rates/0/limit", "value": 10000000}
]'

# Verify the changes
kubectl get ratelimitpolicy gateway-rate-limits -n openshift-ingress -o jsonpath='{.spec.limits.free.rates[0].limit}'
echo ""  # Should show: 10000
```

### 2. Navigate to Benchmarking Directory
```bash
cd ~/maas-bench/maas-benchmarking
```

---

## Test 1: Concurrent Users Scale Test

**Goal**: Determine maximum concurrent users before degradation

### Theory
- Each concurrent user (VU in k6) simulates a user making requests with API keys
- More VUs = more parallel API key validations at the gateway
- Looking for: increased latency, error rate, or timeouts

### Setup
```bash
# Create API keys for testing (start with 50, scale up as needed)
FREE_USERS=50 ./scripts/provision-api-keys.sh

# Verify tokens created
./scripts/api-key-manager.sh status
```

### Test Execution

#### Phase 1: Baseline (10 VUs)
```bash
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

k6 run \
  -e MODE="burst" \
  -e BURST_ITERATIONS=100 \
  -e BURST_VUS=10 \
  -e HOST="maas.${CLUSTER_DOMAIN}" \
  -e PROTOCOL="https" \
  -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/scale_10vus.json \
  k6/maas-performance-test.js

# Record: p95 latency, success rate, errors
```

#### Phase 2: Scale Up (25, 50, 75, 100 VUs)
```bash
# 25 VUs
k6 run -e MODE="burst" -e BURST_ITERATIONS=250 -e BURST_VUS=25 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/scale_25vus.json k6/maas-performance-test.js

# 50 VUs (need 50+ tokens)
k6 run -e MODE="burst" -e BURST_ITERATIONS=500 -e BURST_VUS=50 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/scale_50vus.json k6/maas-performance-test.js
```

#### Phase 3: High Scale (if cluster supports)
```bash
# Create more API keys if needed
FREE_USERS=100 ./scripts/cleanup-api-keys.sh
FREE_USERS=100 ./scripts/provision-api-keys.sh

# 100 VUs
k6 run -e MODE="burst" -e BURST_ITERATIONS=1000 -e BURST_VUS=100 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/scale_100vus.json k6/maas-performance-test.js
```

### Metrics to Record
| VUs | p50 Latency | p95 Latency | Success Rate | Errors | Notes |
|-----|-------------|-------------|--------------|--------|-------|
| 10  |             |             |              |        |       |
| 25  |             |             |              |        |       |
| 50  |             |             |              |        |       |
| 100 |             |             |              |        |       |

### Success Criteria
- **Healthy**: p95 < 1s, success rate > 99%
- **Degraded**: p95 1-5s, success rate 95-99%
- **Breaking**: p95 > 5s, success rate < 95%, or timeouts

---

## Test 2: Request Rate Breaking Point

**Goal**: Find maximum requests/second the system can handle

### Theory
- Sustained high request rate stresses all components
- API key validation, Authorino, Limitador, Model Server all under load
- Looking for: queue buildup, timeout errors, 5xx responses

### Setup
```bash
# Ensure API keys exist
FREE_USERS=20 ./scripts/provision-api-keys.sh
```

### Test Execution

#### Sustained Load Tests (5 minute each)
```bash
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

# ~10 req/sec (low baseline)
k6 run -e MODE="soak" -e SOAK_DURATION="2m" -e SOAK_RATE_FREE=10 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/rate_10rps.json k6/maas-performance-test.js

# ~25 req/sec
k6 run -e MODE="soak" -e SOAK_DURATION="2m" -e SOAK_RATE_FREE=25 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/rate_25rps.json k6/maas-performance-test.js

# ~50 req/sec
k6 run -e MODE="soak" -e SOAK_DURATION="2m" -e SOAK_RATE_FREE=50 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/rate_50rps.json k6/maas-performance-test.js

# ~100 req/sec (high load)
k6 run -e MODE="soak" -e SOAK_DURATION="2m" -e SOAK_RATE_FREE=100 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/rate_100rps.json k6/maas-performance-test.js
```

### Metrics to Record
| Target RPS | Actual RPS | p50 Latency | p95 Latency | Success Rate | Errors |
|------------|------------|-------------|-------------|--------------|--------|
| 10         |            |             |             |              |        |
| 25         |            |             |             |              |        |
| 50         |            |             |             |              |        |
| 100        |            |             |             |              |        |

### Success Criteria
- **Healthy**: Actual RPS matches target, p95 < 500ms
- **Saturated**: Actual RPS < target, latency increasing
- **Breaking**: Errors > 5%, timeouts, or 5xx responses

---

## Test 3: Token Volume Impact

**Goal**: Test if large numbers of active tokens degrade performance

### Theory
- More API keys = more entries in the database
- More tokens = potentially more validation pressure
- Looking for: degradation as token count increases

### Setup & Execution

#### Phase 1: Baseline with 10 Tokens
```bash
FREE_USERS=10 ./scripts/cleanup-api-keys.sh
FREE_USERS=10 ./scripts/provision-api-keys.sh

CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

k6 run -e MODE="burst" -e BURST_ITERATIONS=100 -e BURST_VUS=10 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/tokens_10.json k6/maas-performance-test.js
```

#### Phase 2: Scale Token Volume
```bash
# 50 tokens
FREE_USERS=50 ./scripts/cleanup-api-keys.sh
FREE_USERS=50 ./scripts/provision-api-keys.sh
k6 run -e MODE="burst" -e BURST_ITERATIONS=100 -e BURST_VUS=10 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/tokens_50.json k6/maas-performance-test.js

# 100 tokens
FREE_USERS=100 ./scripts/cleanup-api-keys.sh
FREE_USERS=100 ./scripts/provision-api-keys.sh
k6 run -e MODE="burst" -e BURST_ITERATIONS=100 -e BURST_VUS=10 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/tokens_100.json k6/maas-performance-test.js

# 250 tokens
FREE_USERS=250 ./scripts/cleanup-api-keys.sh
FREE_USERS=250 ./scripts/provision-api-keys.sh
k6 run -e MODE="burst" -e BURST_ITERATIONS=100 -e BURST_VUS=10 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/tokens_250.json k6/maas-performance-test.js

# 500 tokens
FREE_USERS=500 ./scripts/cleanup-api-keys.sh
FREE_USERS=500 ./scripts/provision-api-keys.sh
k6 run -e MODE="burst" -e BURST_ITERATIONS=100 -e BURST_VUS=10 \
  -e HOST="maas.${CLUSTER_DOMAIN}" -e PROTOCOL="https" -e MODEL_NAME="facebook/opt-125m" \
  --summary-export=results/tokens_500.json k6/maas-performance-test.js
```

### Metrics to Record
| Active Tokens | Key Creation Time | p50 Latency | p95 Latency | Success Rate |
|---------------|------------------|-------------|-------------|--------------|
| 10            |                  |             |             |              |
| 50            |                  |             |             |              |
| 100           |                  |             |             |              |
| 250           |                  |             |             |              |
| 500           |                  |             |             |              |

### Success Criteria
- **No Impact**: Latency consistent across all token volumes
- **Degradation**: Latency increases with token count
- **Breaking**: Significant degradation or API key creation failures

---

## Monitoring During Tests

### Watch Cluster Health
```bash
# Terminal 1: Watch node resources
watch -n 2 kubectl top nodes

# Terminal 2: Watch pod resources
watch -n 2 kubectl top pods -n maas-api

# Terminal 3: Watch for errors in logs
kubectl logs -f -n maas-api deployment/maas-api

# Terminal 4: Watch Authorino (auth component)
kubectl logs -f -n kuadrant-system deployment/authorino
```

### Key Indicators of Stress
- Node CPU > 80%
- MaaS API pod restarting
- Authorino errors in logs
- Increasing request timeouts

---

## Results Analysis

After running all tests, analyze results:

```bash
# View all results
ls -la results/scale_*.json results/rate_*.json results/tokens_*.json

# Extract key metrics from each
for f in results/scale_*.json results/rate_*.json results/tokens_*.json; do
  echo "=== $f ==="
  jq '{
    http_reqs: .metrics.http_reqs.values.count,
    http_req_duration_p95: .metrics.http_req_duration.values["p(95)"],
    success_rate: .metrics.success_rate.values.rate
  }' "$f"
done
```

---

## Cleanup

```bash
# Remove test API keys
FREE_USERS=500 ./scripts/cleanup-api-keys.sh

# Restore original rate limits
# RateLimitPolicy (5/20/50 requests per 2 min)
kubectl patch ratelimitpolicy gateway-rate-limits -n openshift-ingress --type='json' -p='[
  {"op": "replace", "path": "/spec/limits/free/rates/0/limit", "value": 5},
  {"op": "replace", "path": "/spec/limits/premium/rates/0/limit", "value": 20},
  {"op": "replace", "path": "/spec/limits/enterprise/rates/0/limit", "value": 50}
]'

# TokenRateLimitPolicy (100/50000/100000 tokens per 1 min)
kubectl patch tokenratelimitpolicy gateway-token-rate-limits -n openshift-ingress --type='json' -p='[
  {"op": "replace", "path": "/spec/limits/free-user-tokens/rates/0/limit", "value": 100},
  {"op": "replace", "path": "/spec/limits/premium-user-tokens/rates/0/limit", "value": 50000},
  {"op": "replace", "path": "/spec/limits/enterprise-user-tokens/rates/0/limit", "value": 100000}
]'

# Verify restored
kubectl get ratelimitpolicy gateway-rate-limits -n openshift-ingress -o jsonpath='{.spec.limits.free.rates[0].limit}'
# Should show: 5
```

---

## Expected Findings Template

### Concurrent Users
- **Baseline (10 VUs)**: p95 = ___ms, success = ___%
- **Degradation starts at**: ___ VUs
- **Breaking point**: ___ VUs
- **Recommended safe limit**: ___ concurrent users

### Request Rate
- **Sustainable rate**: ___ req/sec
- **Saturation point**: ___ req/sec
- **Breaking point**: ___ req/sec
- **Recommended safe limit**: ___ req/sec

### Token Volume
- **No impact up to**: ___ tokens
- **Degradation starts at**: ___ tokens
- **Recommended safe limit**: ___ active tokens

---

## Notes

- These tests are run on a 2-node cluster with limited resources
- Production clusters will have different limits based on:
  - Number of nodes
  - etcd configuration
  - API server resources
  - Network capacity
- Results should be scaled appropriately for production recommendations
