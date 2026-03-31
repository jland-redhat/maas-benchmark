# Subscription Scale Testing

Test how many MaaSSubscriptions the system can handle before performance degrades. Tests up to **1000 subscriptions** with **automatic bottleneck detection**.

## Overview

Each `MaaSSubscription` creates load on:

| Component | Impact | Bottleneck Signal |
|-----------|--------|-------------------|
| **maas-controller** | Reconciliation loops, watches | CPU usage, reconcile queue depth |
| **Limitador** | Rate limit counters (user × model) | Memory, counter lookup latency |
| **etcd** | CR storage, watch streams | Write latency, storage size |
| **Authorino** | Auth policy subjects | Auth evaluation time |
| **TokenRateLimitPolicy** | Aggregated limits per model | Policy complexity |

## Quick Start

```bash
# Full test: 1 → 10 → 25 → 50 → 100 → 150 → 200 → 300 → 400 → 500 → 750 → 1000
# Automatically stops when bottleneck is detected
./scripts/benchmark-subscription-scale.sh

# Custom subscription counts
SUBSCRIPTION_COUNTS="1 50 100 250 500 750 1000" ./scripts/benchmark-subscription-scale.sh

# Continue testing even after bottleneck
STOP_ON_BOTTLENECK=false ./scripts/benchmark-subscription-scale.sh

# Skip k6 tests (only measure reconciliation time)
SKIP_K6=true ./scripts/benchmark-subscription-scale.sh
```

## Configuration

### Test Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `SUBSCRIPTION_COUNTS` | `"1 10 25 50 100 150 200 300 400 500 750 1000"` | Subscription counts to test |
| `USERS_PER_SUBSCRIPTION` | `3` | Users per subscription |
| `MODEL_NAME` | `facebook-opt-125m-simulated` | Model for testing |
| `TOKEN_LIMIT` | `100000` | Token limit per user |
| `TOKEN_WINDOW` | `1m` | Rate limit window |
| `BURST_VUS` | `5` | k6 virtual users |
| `BURST_ITERATIONS` | `50` | k6 iterations per test |
| `RESULTS_DIR` | `results/subscription-scale` | Output directory |
| `CLEANUP_AFTER` | `true` | Clean up between tests |
| `SKIP_K6` | (unset) | Skip load tests if set |

### Bottleneck Thresholds

| Variable | Default | Description |
|----------|---------|-------------|
| `STOP_ON_BOTTLENECK` | `true` | Stop testing when bottleneck detected |
| `MAX_RECONCILE_TIME` | `300` (5 min) | Max reconciliation time before bottleneck |
| `MIN_SUCCESS_RATE` | `0.90` (90%) | Min success rate threshold |
| `MAX_P95_LATENCY` | `10000` (10s) | Max p95 latency in milliseconds |

## Automatic Bottleneck Detection

The script automatically detects bottlenecks based on three criteria:

### 1. Reconciliation Time
If the time for all subscriptions to become `Active` exceeds `MAX_RECONCILE_TIME`:

```
🚨 BOTTLENECK DETECTED: Reconciliation time (312s) exceeded threshold (300s)
```

### 2. Success Rate
If the k6 test success rate drops below `MIN_SUCCESS_RATE`:

```
🚨 BOTTLENECK DETECTED: Success rate (85%) below threshold (90%)
```

### 3. p95 Latency
If the p95 request latency exceeds `MAX_P95_LATENCY`:

```
🚨 BOTTLENECK DETECTED: p95 latency (12500ms) exceeded threshold (10000ms)
```

## What Gets Measured

### 1. Controller Reconciliation Time

Time for all subscriptions to reach `Active` state:

```
Creating 500 subscriptions...
Waiting for reconciliation...
  Active: 125/500 (attempt 10/110)
  Active: 350/500 (attempt 20/110)
  Active: 500/500 (attempt 35/110)
All 500 subscriptions Active (reconcile time: 68.5s)
✅ No bottleneck detected at 500 subscriptions
```

### 2. Request Latency

k6 burst test against a random subscription:

- **p50/p95 latency** - Should remain stable
- **Success rate** - Should stay >90%
- **Errors** - Watch for 5xx or timeouts

### 3. Resource Consumption

During tests, monitor:

```bash
# Controller resources
kubectl top pod -n maas-system -l app=maas-controller

# Limitador resources  
kubectl top pod -n kuadrant-system -l app=limitador

# TokenRateLimitPolicies created
kubectl get tokenratelimitpolicy -A -l app.kubernetes.io/managed-by=maas-controller
```

## Test Scenarios

### Scenario 1: Find Subscription Limit (up to 1000)

Find maximum subscriptions before degradation:

```bash
# Default: tests 1, 10, 25, 50, 100, 150, 200, 300, 400, 500, 750, 1000
./scripts/benchmark-subscription-scale.sh
```

### Scenario 2: Custom Thresholds

Adjust bottleneck detection sensitivity:

```bash
# Stricter thresholds (find issues earlier)
MAX_RECONCILE_TIME=120 \
MIN_SUCCESS_RATE=0.95 \
MAX_P95_LATENCY=5000 \
./scripts/benchmark-subscription-scale.sh

# More lenient (allow more degradation)
MAX_RECONCILE_TIME=600 \
MIN_SUCCESS_RATE=0.80 \
MAX_P95_LATENCY=30000 \
./scripts/benchmark-subscription-scale.sh
```

### Scenario 3: Many Users per Subscription

Test subscription with many users (enterprise simulation):

```bash
SUBSCRIPTION_COUNTS="1 10 25 50 100" \
USERS_PER_SUBSCRIPTION=50 \
./scripts/benchmark-subscription-scale.sh
```

### Scenario 4: Controller-Only Stress Test

Focus on controller without load testing (faster):

```bash
SUBSCRIPTION_COUNTS="100 200 300 500 750 1000" \
SKIP_K6=true \
./scripts/benchmark-subscription-scale.sh

# Monitor controller during test in another terminal
watch -n 2 kubectl top pod -n maas-system -l app=maas-controller
```

### Scenario 5: Full Test Without Stopping

Test all counts even after bottleneck:

```bash
STOP_ON_BOTTLENECK=false \
./scripts/benchmark-subscription-scale.sh
```

### Scenario 6: Sustained Load at Scale

Create many subscriptions, then run extended soak test:

```bash
# Step 1: Create 500 subscriptions (no cleanup)
SUBSCRIPTION_COUNTS="500" \
CLEANUP_AFTER=false \
SKIP_K6=true \
./scripts/benchmark-subscription-scale.sh

# Step 2: Run soak test
k6 run \
  -e MODE=soak \
  -e SOAK_DURATION=10m \
  -e SOAK_RATE_FREE=10 \
  -e HOST="maas.${CLUSTER_DOMAIN}" \
  -e TOKEN_FILE_PATH="tokens/subscription-scale/all_tokens.json" \
  k6/maas-performance-test.js
```

## Sample Output

```markdown
# Subscription Scale Benchmark Results

| Subscriptions | Total Users | Reconcile Time (s) | p50 (ms) | p95 (ms) | Success Rate | Errors | Status |
|---------------|-------------|-------------------|----------|----------|--------------|--------|--------|
| 1             | 3           | 2.15              | 125.32   | 245.67   | 99.80%       | 0.0020 | ✅     |
| 10            | 30          | 8.45              | 132.18   | 267.89   | 99.50%       | 0.0050 | ✅     |
| 25            | 75          | 18.32             | 145.67   | 298.45   | 99.20%       | 0.0080 | ✅     |
| 50            | 150         | 35.21             | 156.89   | 312.34   | 98.90%       | 0.0110 | ✅     |
| 100           | 300         | 68.45             | 178.23   | 389.67   | 97.80%       | 0.0220 | ✅     |
| 150           | 450         | 98.67             | 203.45   | 489.12   | 96.50%       | 0.0350 | ✅     |
| 200           | 600         | 142.89            | 267.89   | 678.34   | 94.20%       | 0.0580 | ✅     |
| 300           | 900         | 218.34            | 345.67   | 892.45   | 91.30%       | 0.0870 | ✅     |
| 400           | 1200        | 312.56            | 456.78   | 1245.67  | 88.50%       | 0.1150 | 🚨     |

## Bottleneck Analysis

### 🚨 Bottleneck Detected

- **First bottleneck at**: 400 subscriptions
- **Last healthy count**: 300 subscriptions
- **Reason**: Reconciliation time (312.56s) exceeded threshold (300s); Success rate (88.50%) below threshold (90%)

### Recommendations

1. **Safe operating limit**: 300 subscriptions
2. **With buffer (80%)**: 240 subscriptions
3. **Consider scaling**: Controller replicas, Limitador resources
```

## Interpreting Results

### Status Indicators

| Status | Meaning |
|--------|---------|
| ✅ | All metrics within thresholds |
| 🚨 | One or more bottleneck thresholds exceeded |

### Scaling Patterns

1. **Reconcile Time Scaling**
   - Linear (good): 10 subs = 10s, 100 subs = 100s
   - Exponential (bottleneck): 10 subs = 10s, 100 subs = 500s

2. **Latency Impact**
   - <20% increase: System handling well
   - >50% increase: Approaching limits
   - >100% increase: Bottleneck reached

3. **Success Rate**
   - >95%: Healthy
   - 90-95%: Degraded
   - <90%: Breaking point

## Cleanup

```bash
# Remove all benchmark subscriptions
kubectl delete maassubscription -n opendatahub \
  -l app.kubernetes.io/part-of=subscription-scale-benchmark

kubectl delete maasauthpolicy -n opendatahub \
  -l app.kubernetes.io/part-of=subscription-scale-benchmark

# Remove generated tokens
rm -rf tokens/subscription-scale/
```

## Recommended Limits

Based on testing patterns (adjust for your cluster):

| Cluster Size | Safe Subscriptions | Safe Users/Sub | Max Reconcile Time |
|--------------|-------------------|----------------|-------------------|
| 2-node (dev) | <100 | <50 | <60s |
| 4-node (staging) | <300 | <100 | <120s |
| 8+ node (prod) | <1000 | <200 | <180s |

### Scaling Recommendations

**Controller Bottleneck** (slow reconciliation):
- Increase controller replicas
- Check etcd performance
- Review controller resource limits

**Latency Bottleneck** (high p95):
- Scale Limitador replicas
- Check rate limit counter count
- Review TokenRateLimitPolicy aggregation

**Success Rate Bottleneck** (high errors):
- Check Authorino logs for auth failures
- Verify API key validity
- Check model server capacity
