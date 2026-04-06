# Subscription Scale Benchmark Results - [DATE]

## Run Metadata

| Parameter | Value |
|-----------|-------|
| **Executed at** | `YYYY-MM-DD HH:MM:SS UTC` |
| **Repo** | `~/go/src/github.com/ai-engineering/maas-benchmark` |
| **Target Host** | `maas.apps.CLUSTER.DOMAIN` |
| **Protocol** | `https` |
| **Testing Focus** | MaaSSubscription scale limits and bottleneck detection |

## Test Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                              k6                                      │
│                    (Load Testing Tool)                               │
│         Simulates N virtual users with API keys                      │
└─────────────────────────────┬───────────────────────────────────────┘
                              │ HTTPS POST /v1/completions
                              │ Headers: Authorization, x-maas-subscription
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     MaaS Gateway (OpenShift)                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐   │
│  │    Router    │ → │   Authorino   │ → │      Limitador        │   │
│  │  (Ingress)   │    │    (Auth)     │    │   (Rate Limiting)    │   │
│  │              │    │              │    │                      │   │
│  │ TLS terminate│    │ API key      │    │ TokenRateLimitPolicy │   │
│  │ Route to svc │    │ validation   │    │ per subscription     │   │
│  └──────────────┘    └──────────────┘    └──────────────────────┘   │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        Model Server                                  │
│                  (LLM Simulator / KServe)                           │
│              facebook-opt-125m-simulated                            │
│                                                                     │
│              Returns: { choices: [...], usage: {...} }              │
└─────────────────────────────────────────────────────────────────────┘
```

### What Each Component Does

| Component | Role | Bottleneck Risk |
|-----------|------|-----------------|
| **k6** | Generates load, measures latency/success | N/A (client) |
| **Router** | TLS termination, routing | Low |
| **Authorino** | API key validation, user extraction | Medium (auth policies) |
| **Limitador** | Rate limit enforcement | High (counter lookups) |
| **MaaS Controller** | Reconciles subscriptions → policies | High (with many subs) |
| **Model Server** | Inference (simulated) | Low (simulator) |

## Test Environment

### Infrastructure

| Component | Details |
|-----------|---------|
| **Platform** | [ROSA / DevShift / etc.] |
| **OpenShift Version** | 4.x |
| **Worker Nodes** | X nodes |
| **MaaS Controller** | quay.io/opendatahub/maas-controller:latest |
| **MaaS API** | quay.io/opendatahub/maas-api:latest |
| **Database** | PostgreSQL (ephemeral/persistent) |
| **Policy Engine** | Kuadrant vX.X.X |
| **k6 Version** | vX.X.X |

### Test Configuration

| Parameter | Value |
|-----------|-------|
| **Subscription Counts Tested** | 1, 10, 25, 50, 100, 150, 200, 300, 400, 500, 750, 1000 |
| **Users per Subscription** | 3 |
| **Token Limit per User** | 100,000 |
| **Token Window** | 1 minute |
| **k6 Burst VUs** | 5 |
| **k6 Burst Iterations** | 50 |
| **Model** | facebook-opt-125m-simulated |

### Bottleneck Thresholds

| Threshold | Value |
|-----------|-------|
| **MAX_RECONCILE_TIME** | 300s (5 min) |
| **MIN_SUCCESS_RATE** | 90% |
| **MAX_P95_LATENCY** | 10,000ms (10s) |

---

## Results Summary

| Subscriptions | Total Users | Reconcile Time (s) | p50 (ms) | p95 (ms) | Success Rate | Errors | Status |
|---------------|-------------|-------------------|----------|----------|--------------|--------|--------|
| 1 | 3 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |
| 10 | 30 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |
| 25 | 75 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |
| 50 | 150 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |
| 100 | 300 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |
| 150 | 450 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |
| 200 | 600 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |
| 300 | 900 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |
| 400 | 1200 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |
| 500 | 1500 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |
| 750 | 2250 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |
| 1000 | 3000 | `___` | `___` | `___` | `___`% | `___` | ✅/🚨 |

---

## Bottleneck Analysis

### Bottleneck Detection Result

| Metric | Value |
|--------|-------|
| **Bottleneck Detected** | ✅ Yes / ❌ No |
| **First Bottleneck At** | `___` subscriptions |
| **Last Healthy Count** | `___` subscriptions |
| **Bottleneck Reason** | [Reconciliation time / Success rate / p95 latency] |

### Recommended Limits

| Limit Type | Value |
|------------|-------|
| **Safe Operating Limit** | `___` subscriptions |
| **With 80% Buffer** | `___` subscriptions |
| **With 50% Buffer** | `___` subscriptions |

---

## Detailed Metrics

### Reconciliation Time Trend

| Subscriptions | Reconcile Time (s) | Time per Subscription (ms) | Scaling Pattern |
|---------------|-------------------|---------------------------|-----------------|
| 1 | `___` | `___` | Baseline |
| 10 | `___` | `___` | `___` |
| 25 | `___` | `___` | `___` |
| 50 | `___` | `___` | `___` |
| 100 | `___` | `___` | `___` |
| 200 | `___` | `___` | `___` |
| 500 | `___` | `___` | `___` |
| 1000 | `___` | `___` | `___` |

**Scaling Analysis:**
- [ ] Linear scaling (healthy)
- [ ] Sub-linear scaling (very good)
- [ ] Super-linear scaling (bottleneck approaching)
- [ ] Exponential scaling (bottleneck)

### Latency Progression

| Subscriptions | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) |
|---------------|----------|----------|----------|----------|
| 1 | `___` | `___` | `___` | `___` |
| 10 | `___` | `___` | `___` | `___` |
| 50 | `___` | `___` | `___` | `___` |
| 100 | `___` | `___` | `___` | `___` |
| 200 | `___` | `___` | `___` | `___` |
| 500 | `___` | `___` | `___` | `___` |
| 1000 | `___` | `___` | `___` | `___` |

### Success Rate Progression

| Subscriptions | Success Rate | Auth Failures | Rate Limit Hits | Token Limit Hits |
|---------------|--------------|---------------|-----------------|------------------|
| 1 | `___`% | `___` | `___` | `___` |
| 10 | `___`% | `___` | `___` | `___` |
| 50 | `___`% | `___` | `___` | `___` |
| 100 | `___`% | `___` | `___` | `___` |
| 200 | `___`% | `___` | `___` | `___` |
| 500 | `___`% | `___` | `___` | `___` |
| 1000 | `___`% | `___` | `___` | `___` |

---

## Resource Utilization

### MaaS Controller

| Subscriptions | CPU (cores) | Memory (Mi) | Reconcile Queue Depth |
|---------------|-------------|-------------|----------------------|
| 1 | `___` | `___` | `___` |
| 50 | `___` | `___` | `___` |
| 100 | `___` | `___` | `___` |
| 200 | `___` | `___` | `___` |
| 500 | `___` | `___` | `___` |
| 1000 | `___` | `___` | `___` |

### Limitador

| Subscriptions | CPU (cores) | Memory (Mi) | Counter Count |
|---------------|-------------|-------------|---------------|
| 1 | `___` | `___` | `___` |
| 50 | `___` | `___` | `___` |
| 100 | `___` | `___` | `___` |
| 200 | `___` | `___` | `___` |
| 500 | `___` | `___` | `___` |
| 1000 | `___` | `___` | `___` |

### TokenRateLimitPolicies Generated

| Subscriptions | TRLP Count | Avg Limits per TRLP |
|---------------|------------|---------------------|
| 1 | `___` | `___` |
| 50 | `___` | `___` |
| 100 | `___` | `___` |
| 200 | `___` | `___` |
| 500 | `___` | `___` |
| 1000 | `___` | `___` |

---

## Component Health During Test

| Component | Status | Notes |
|-----------|--------|-------|
| maas-controller | ✅/⚠️/❌ | `___` |
| maas-api | ✅/⚠️/❌ | `___` |
| Authorino | ✅/⚠️/❌ | `___` |
| Limitador | ✅/⚠️/❌ | `___` |
| PostgreSQL | ✅/⚠️/❌ | `___` |
| Gateway/Router | ✅/⚠️/❌ | `___` |
| Model Server | ✅/⚠️/❌ | `___` |

---

## Analysis

### What Worked Well

1. `___`
2. `___`
3. `___`

### Bottleneck Root Cause

**Primary bottleneck:** [Controller reconciliation / Limitador / Auth / etcd]

**Evidence:**
- `___`
- `___`

### Comparison with Expected Limits

| Cluster Size | Expected Safe Limit | Actual Safe Limit | Difference |
|--------------|--------------------|--------------------|------------|
| This cluster (X nodes) | ~Y subscriptions | `___` subscriptions | `___` |

---

## Recommendations

### Immediate Actions

1. **Safe operating limit**: `___` subscriptions
2. **Production recommendation**: `___` subscriptions (with buffer)

### Scaling Recommendations

| If Bottleneck Is | Recommendation |
|------------------|----------------|
| **Controller** | Increase replicas, check resource limits |
| **Limitador** | Scale replicas, check memory |
| **etcd** | Check latency, consider dedicated etcd |
| **Auth** | Check Authorino logs, policy complexity |

### Configuration Changes

```bash
# If controller is bottleneck
kubectl scale deployment maas-controller -n maas-system --replicas=2

# If Limitador is bottleneck
kubectl scale deployment limitador -n kuadrant-system --replicas=2

# If rate limits too restrictive
kubectl patch tokenratelimitpolicy ... --type=json -p='...'
```

---

## Commands Used

### Run Benchmark

```bash
cd ~/go/src/github.com/ai-engineering/maas-benchmark

# Full subscription scale test
./scripts/benchmark-subscription-scale.sh

# Or with custom parameters
SUBSCRIPTION_COUNTS="1 50 100 250 500 750 1000" \
MAX_RECONCILE_TIME=600 \
MIN_SUCCESS_RATE=0.85 \
./scripts/benchmark-subscription-scale.sh
```

### Monitor During Test

```bash
# Terminal 1: Node resources
watch -n 5 kubectl top nodes

# Terminal 2: MaaS components
watch -n 5 'kubectl top pod -n maas-system; echo "---"; kubectl top pod -n kuadrant-system'

# Terminal 3: Controller logs
kubectl logs -f -n maas-system deployment/maas-controller

# Terminal 4: Subscription status
watch -n 2 'kubectl get maassubscription -A -o jsonpath="{range .items[*]}{.metadata.name}: {.status.phase}{\"\\n\"}{end}" | head -20'
```

### Cleanup

```bash
# Remove benchmark subscriptions
kubectl delete maassubscription -n opendatahub \
  -l app.kubernetes.io/part-of=subscription-scale-benchmark

kubectl delete maasauthpolicy -n opendatahub \
  -l app.kubernetes.io/part-of=subscription-scale-benchmark

# Remove generated tokens
rm -rf tokens/subscription-scale/
```

---

## Artifacts

| File | Description |
|------|-------------|
| `results/subscription-scale/summary_TIMESTAMP.md` | Auto-generated summary |
| `results/subscription-scale/k6_Xsubs_TIMESTAMP.json` | k6 results per subscription count |
| `scripts/benchmark-subscription-scale.sh` | Benchmark script used |
| `docs/SUBSCRIPTION-SCALE-TESTING.md` | Testing documentation |

---

## Related Documents

- [Subscription Scale Testing Guide](../docs/SUBSCRIPTION-SCALE-TESTING.md)
- [Load Testing Guide](../docs/LOAD-TESTING-GUIDE.md)
- [Scale Testing Plan](../docs/SCALE-TESTING-PLAN.md)
- [etcd Monitoring](../docs/etcd-monitoring.md)

---

## Conclusion

### Summary

- **Subscriptions tested**: 1 to `___`
- **Bottleneck found**: ✅ Yes at `___` / ❌ No
- **Safe operating limit**: `___` subscriptions
- **Primary constraint**: [Controller / Limitador / etcd / Auth]

### Key Findings

1. `___`
2. `___`
3. `___`

### Next Steps

1. [ ] `___`
2. [ ] `___`
3. [ ] `___`
