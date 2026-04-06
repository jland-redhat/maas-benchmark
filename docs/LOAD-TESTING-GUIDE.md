# MaaS Load Testing Guide

Comprehensive guide for load testing Models-as-a-Service (MaaS) platform using `maas-benchmark`.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Test Modes](#test-modes)
4. [Load Testing Scenarios](#load-testing-scenarios)
5. [Subscription Scale Testing](#subscription-scale-testing)
6. [Monitoring During Tests](#monitoring-during-tests)
7. [Analyzing Results](#analyzing-results)
8. [Troubleshooting](#troubleshooting)

---

## Overview

The MaaS benchmark suite tests the complete request flow:

```
Client Request
     │
     ▼
┌─────────────────┐
│   Gateway       │  ← Rate limiting (RateLimitPolicy)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Authorino     │  ← API key validation, user extraction
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Limitador     │  ← Token rate limiting (TokenRateLimitPolicy)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Model Server  │  ← Inference
└─────────────────┘
```

### What Gets Tested

| Component | Test Focus |
|-----------|------------|
| **Gateway** | Request throughput, TLS termination |
| **Authorino** | API key validation latency, auth policy evaluation |
| **Limitador** | Rate limit counter operations, 429 responses |
| **MaaS Controller** | Subscription reconciliation, policy generation |
| **Model Server** | Inference latency (simulated or real) |

---

## Prerequisites

### Required Tools

```bash
# k6 load testing tool
brew install k6  # macOS
# or: https://k6.io/docs/getting-started/installation/

# jq for JSON processing
brew install jq

# yq for YAML processing (optional, for run-test.sh)
brew install yq
```

### Cluster Access

```bash
# Login to OpenShift
oc login --token=<token> --server=<server>

# Verify MaaS components are running
kubectl get pods -n maas-system
kubectl get pods -n kuadrant-system
```

### Set Environment Variables

```bash
export CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export HOST="maas.${CLUSTER_DOMAIN}"
export PROTOCOL="https"
export MODEL_NAME="facebook-opt-125m-simulated"
export MODEL_PAYLOAD_ID="facebook/opt-125m"
```

---

## Test Modes

### 1. Burst Mode

High-intensity short-duration load. Tests capacity and peak handling.

```bash
# Parameters
MODE=burst
BURST_VUS=10          # Concurrent virtual users
BURST_ITERATIONS=100  # Total requests to send

# Run
k6 run -e MODE=burst -e BURST_VUS=10 -e BURST_ITERATIONS=100 \
  -e HOST=$HOST -e MODEL_NAME=$MODEL_NAME \
  k6/maas-performance-test.js
```

**Use for**: Capacity testing, finding breaking points

### 2. Soak Mode

Sustained load over time. Tests stability and resource leaks.

```bash
# Parameters
MODE=soak
SOAK_DURATION=10m     # Test duration
SOAK_RATE_FREE=5      # Requests per second (free tier)
SOAK_RATE_PREMIUM=10  # Requests per second (premium tier)

# Run
k6 run -e MODE=soak -e SOAK_DURATION=10m -e SOAK_RATE_FREE=5 \
  -e HOST=$HOST -e MODEL_NAME=$MODEL_NAME \
  k6/maas-performance-test.js
```

**Use for**: Stability testing, memory leak detection, sustained load

### 3. Rate Limit Test Mode

Designed to hit rate limits and verify 429 responses.

```bash
# Parameters
MODE=rate-limit-test
RATE_LIMIT_DURATION=3m  # Test duration
RATE_LIMIT_VUS=30       # Concurrent users

# Run
k6 run -e MODE=rate-limit-test -e RATE_LIMIT_DURATION=3m -e RATE_LIMIT_VUS=30 \
  -e HOST=$HOST -e MODEL_NAME=$MODEL_NAME \
  k6/maas-performance-test.js
```

**Use for**: Validating rate limiting works correctly

---

## Load Testing Scenarios

### Scenario 1: Baseline Performance

Establish baseline metrics with minimal load.

```bash
# Single user, 10 requests
./scripts/run-test.sh performance_baseline

# Or manually:
k6 run -e MODE=burst -e BURST_VUS=1 -e BURST_ITERATIONS=10 \
  -e HOST=$HOST -e MODEL_NAME=$MODEL_NAME \
  k6/maas-performance-test.js
```

**Expected Results**:
- p95 latency: <500ms (simulated model)
- Success rate: >99%
- No auth failures

### Scenario 2: Concurrent Users Scale

Find maximum concurrent users before degradation.

```bash
# Provision API keys
FREE_USERS=100 ./scripts/provision-api-keys.sh
./scripts/setup-maas-crs-for-benchmark.sh

# Test increasing VUs
for vus in 5 10 25 50 75 100; do
  echo "Testing $vus VUs..."
  k6 run -e MODE=burst -e BURST_VUS=$vus -e BURST_ITERATIONS=$((vus * 10)) \
    -e HOST=$HOST -e MODEL_NAME=$MODEL_NAME \
    --summary-export="results/scale_${vus}vus.json" \
    k6/maas-performance-test.js
  sleep 10
done
```

**Analysis**:

| VUs | Expected p95 | Warning Signs |
|-----|--------------|---------------|
| 1-10 | <500ms | None expected |
| 10-25 | <1s | Minor increase OK |
| 25-50 | <2s | Watch for errors |
| 50-100 | <5s | May see 429s |
| >100 | Variable | Likely hitting limits |

### Scenario 3: Sustained Load (Soak Test)

Test system stability over extended period.

```bash
# Light load for 30 minutes
k6 run -e MODE=soak -e SOAK_DURATION=30m -e SOAK_RATE_FREE=2 \
  -e HOST=$HOST -e MODEL_NAME=$MODEL_NAME \
  --summary-export="results/soak_30m.json" \
  k6/maas-performance-test.js
```

**Monitor During Test**:
```bash
# Watch controller memory
watch -n 10 kubectl top pod -n maas-system

# Watch Limitador
watch -n 10 kubectl top pod -n kuadrant-system -l app=limitador
```

### Scenario 4: Request Rate Breaking Point

Find maximum sustainable requests per second.

```bash
for rate in 5 10 25 50 100; do
  echo "Testing $rate req/s..."
  k6 run -e MODE=soak -e SOAK_DURATION=2m -e SOAK_RATE_FREE=$rate \
    -e HOST=$HOST -e MODEL_NAME=$MODEL_NAME \
    --summary-export="results/rate_${rate}rps.json" \
    k6/maas-performance-test.js
  sleep 30
done

# Analyze results
for f in results/rate_*rps.json; do
  echo "=== $f ==="
  jq '{rate: .metrics.http_reqs.values.rate, p95: .metrics.http_req_duration.values["p(95)"], success: .metrics.success_rate.values.rate}' "$f"
done
```

### Scenario 5: Multi-Tier Load

Test free and premium tiers simultaneously.

```bash
# Provision both tier tokens
FREE_USERS=20 PREMIUM_USERS=10 ./scripts/provision-api-keys.sh
./scripts/setup-maas-crs-for-benchmark.sh

# Run test (automatically uses both tiers)
k6 run -e MODE=soak -e SOAK_DURATION=5m \
  -e SOAK_RATE_FREE=5 -e SOAK_RATE_PREMIUM=10 \
  -e MAX_TOKENS_FREE=50 -e MAX_TOKENS_PREMIUM=200 \
  -e HOST=$HOST -e MODEL_NAME=$MODEL_NAME \
  k6/maas-performance-test.js
```

---

## Subscription Scale Testing

Test how many MaaSSubscriptions the system can handle (up to 1000) with **automatic bottleneck detection**.

### Run Full Scale Test

```bash
# Full test: 1 → 10 → 25 → 50 → 100 → 150 → 200 → 300 → 400 → 500 → 750 → 1000
# Automatically stops when bottleneck is detected
./scripts/benchmark-subscription-scale.sh
```

### Custom Configuration

```bash
# Custom subscription counts
SUBSCRIPTION_COUNTS="1 50 100 250 500 750 1000" ./scripts/benchmark-subscription-scale.sh

# Continue past bottleneck (don't stop)
STOP_ON_BOTTLENECK=false ./scripts/benchmark-subscription-scale.sh

# Adjust thresholds
MAX_RECONCILE_TIME=600 MIN_SUCCESS_RATE=0.85 MAX_P95_LATENCY=15000 \
./scripts/benchmark-subscription-scale.sh

# Skip load tests (only measure reconciliation)
SKIP_K6=true ./scripts/benchmark-subscription-scale.sh
```

### Bottleneck Detection Thresholds

| Threshold | Default | Description |
|-----------|---------|-------------|
| `MAX_RECONCILE_TIME` | 300s (5 min) | Controller reconciliation limit |
| `MIN_SUCCESS_RATE` | 90% | Minimum acceptable success rate |
| `MAX_P95_LATENCY` | 10000ms (10s) | Maximum p95 request latency |

### What Gets Measured

| Metric | Description | Bottleneck Indicator |
|--------|-------------|---------------------|
| **Reconcile Time** | Time for all subscriptions to become Active | Controller scaling |
| **p50/p95 Latency** | Request latency at each subscription count | Limitador/auth overhead |
| **Success Rate** | Percentage of successful requests | System capacity |
| **Status** | ✅ healthy or 🚨 bottleneck | Automatic detection |

### Expected Results (varies by cluster)

| Cluster Size | Expected Safe Limit | Typical Bottleneck |
|--------------|--------------------|--------------------|
| 2-node (dev) | ~100-150 subs | Reconciliation time |
| 4-node (staging) | ~200-400 subs | Latency/success rate |
| 8+ node (prod) | ~500-1000 subs | May need tuning |

### Sample Output

```
| Subscriptions | Users | Reconcile (s) | p50 | p95 | Success | Status |
|---------------|-------|---------------|-----|-----|---------|--------|
| 100           | 300   | 68.45         | 178 | 389 | 97.8%   | ✅     |
| 200           | 600   | 142.89        | 267 | 678 | 94.2%   | ✅     |
| 300           | 900   | 218.34        | 345 | 892 | 91.3%   | ✅     |
| 400           | 1200  | 312.56        | 456 | 1245| 88.5%   | 🚨     |

🚨 BOTTLENECK DETECTED: Reconciliation time (312s) exceeded threshold (300s)
Recommended safe limit: 300 subscriptions
```

### Identifying Bottlenecks

**Controller Bottleneck** (reconciliation slow):
```bash
# Check controller logs
kubectl logs -n maas-system deployment/maas-controller --tail=100

# Check reconcile queue
kubectl get maassubscription -A -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase}{"\n"}{end}'
```

**Limitador Bottleneck** (high latency):
```bash
# Check Limitador resources
kubectl top pod -n kuadrant-system -l app=limitador

# Check counter count
kubectl exec -n kuadrant-system deployment/limitador -- limitador-cli counters list | wc -l
```

**etcd Bottleneck** (slow CR operations):
```bash
# Check etcd metrics (if accessible)
# See docs/etcd-monitoring.md
```

See [docs/SUBSCRIPTION-SCALE-TESTING.md](SUBSCRIPTION-SCALE-TESTING.md) for complete documentation.

---

## Monitoring During Tests

### Terminal 1: Node Resources

```bash
watch -n 5 kubectl top nodes
```

### Terminal 2: MaaS Components

```bash
watch -n 5 'kubectl top pod -n maas-system; echo "---"; kubectl top pod -n kuadrant-system'
```

### Terminal 3: Controller Logs

```bash
kubectl logs -f -n maas-system deployment/maas-controller
```

### Terminal 4: Error Monitoring

```bash
# Watch for 5xx errors in router logs
kubectl logs -f -n openshift-ingress deployment/router-default | grep -E '5[0-9]{2}'
```

### Prometheus Queries (if available)

```promql
# Request latency
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))

# Error rate
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

# Limitador counter operations
rate(limitador_counter_operations_total[5m])
```

---

## Analyzing Results

### Extract Key Metrics

```bash
# From k6 JSON output
jq '{
  total_requests: .metrics.http_reqs.values.count,
  requests_per_second: .metrics.http_reqs.values.rate,
  p50_latency_ms: .metrics.http_req_duration.values["p(50)"],
  p95_latency_ms: .metrics.http_req_duration.values["p(95)"],
  p99_latency_ms: .metrics.http_req_duration.values["p(99)"],
  success_rate: .metrics.success_rate.values.rate,
  auth_failures: .metrics.auth_failures.values.count,
  rate_limit_hits: .metrics.rate_limit_hits.values.count
}' results/test_*.json
```

### Compare Multiple Runs

```bash
# Create comparison table
echo "| Test | Requests | RPS | p95 (ms) | Success |"
echo "|------|----------|-----|----------|---------|"
for f in results/*.json; do
  name=$(basename "$f" .json)
  jq -r --arg name "$name" '"\($name) | \(.metrics.http_reqs.values.count) | \(.metrics.http_reqs.values.rate | floor) | \(.metrics.http_req_duration.values["p(95)"] | floor) | \(.metrics.success_rate.values.rate * 100 | floor)%"' "$f"
done
```

### Success Criteria

| Metric | Healthy | Degraded | Failed |
|--------|---------|----------|--------|
| p95 Latency | <1s | 1-5s | >5s |
| Success Rate | >99% | 95-99% | <95% |
| Error Rate | <1% | 1-5% | >5% |
| Auth Failures | 0 | <1% | >1% |

---

## Troubleshooting

### High Auth Failures (401/403)

```bash
# Check API key format
cat tokens/all/all_tokens.json | jq '.free[0].token'
# Should start with sk-oai-

# Check user in MaaSAuthPolicy
kubectl get maasauthpolicy -n opendatahub -o yaml | grep -A20 subjects

# Check Authorino logs
kubectl logs -n kuadrant-system deployment/authorino | grep -i error
```

### High Rate Limit Hits (429)

```bash
# Check current limits
kubectl get maassubscription -n opendatahub -o yaml | grep -A5 tokenRateLimits

# Temporarily increase limits for testing
kubectl patch maassubscription maas-benchmark-subscription -n opendatahub \
  --type=json -p='[{"op": "replace", "path": "/spec/modelRefs/0/tokenRateLimits/0/limit", "value": 1000000}]'
```

### Timeouts

```bash
# Increase k6 timeout
k6 run -e REQUEST_TIMEOUT=60s ...

# Check model server health
kubectl get pods -n maas-benchmarking
kubectl logs -n maas-benchmarking deployment/facebook-opt-125m-simulated
```

### Controller Not Reconciling

```bash
# Check controller status
kubectl get maassubscription -A -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase}{"\n"}{end}'

# Restart controller
kubectl rollout restart -n maas-system deployment/maas-controller
```

---

## Quick Reference

### Common Commands

```bash
# Setup
FREE_USERS=10 ./scripts/provision-api-keys.sh
./scripts/setup-maas-crs-for-benchmark.sh

# Run tests
./scripts/run-test.sh burst_basic
./scripts/run-test.sh soak_standard
./scripts/benchmark-subscription-scale.sh

# Cleanup
./scripts/cleanup-maas-crs.sh
FREE_USERS=10 ./scripts/cleanup-api-keys.sh
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `maas.${CLUSTER_DOMAIN}` | MaaS gateway host |
| `PROTOCOL` | `https` | http or https |
| `MODEL_NAME` | - | Model for URL path |
| `MODEL_PAYLOAD_ID` | `MODEL_NAME` | Model in request body |
| `MODE` | `burst` | burst, soak, rate-limit-test |
| `BURST_VUS` | `10` | Concurrent users (burst) |
| `BURST_ITERATIONS` | `100` | Total requests (burst) |
| `SOAK_DURATION` | `5m` | Duration (soak) |
| `SOAK_RATE_FREE` | `2` | Requests/sec free tier |
| `DEBUG` | `false` | Verbose logging |

### Pre-defined Test Configs

```bash
./scripts/run-test.sh burst_basic           # Quick burst
./scripts/run-test.sh burst_intensive       # Stress test
./scripts/run-test.sh soak_light            # Light sustained
./scripts/run-test.sh soak_standard         # Normal sustained
./scripts/run-test.sh soak_heavy            # Heavy sustained
./scripts/run-test.sh rate_limit_validation # Test 429s
./scripts/run-test.sh performance_baseline  # Single user baseline
./scripts/run-test.sh token_consumption     # High token usage
```
