# Evidence: HorizontalPodAutoscaler

Cluster: single-node k3s, 4 vCPU / 16 GiB. Load applied from the host **through the
Ingress**, so the path exercised is the same one real traffic takes.

## Configuration

```yaml
autoscaling:
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70   # of requests.cpu, which is 100m
  behavior:
    scaleUp:   { stabilizationWindowSeconds: 30 }
    scaleDown: { stabilizationWindowSeconds: 300 }
```

The 70% target is a percentage of the **CPU request**, not of a core. With
`requests.cpu: 100m`, scaling begins once average usage passes ~70m per pod. This is why
the request had to be a realistic number rather than an arbitrarily small one — an
unrealistically low request makes the target meaningless.

## Baseline (idle)

```
NAME                REFERENCE                      TARGETS       MINPODS  MAXPODS  REPLICAS
sample-nodejs-dev   Deployment/sample-nodejs-dev   cpu: 7%/70%   2        6        2

NAME                                CPU(cores)   MEMORY(bytes)
sample-nodejs-dev-8bcc47b9d-4pb2n   8m           19Mi
sample-nodejs-dev-8bcc47b9d-mnnm7   7m           24Mi
```

Memory at idle (~20 MiB) matches the measurement the chart's `resources` were sized
from, which is why the 64Mi request and 192Mi limit are what they are.

## Under load

```
ab -c 60 -t 240 http://my-app.192-168-56-101.nip.io/my-app
```

```
Complete requests:      1077610
Failed requests:        0            <-- no errors at any point while scaling 2 -> 6
Requests per second:    4490.04 [#/sec] (mean)
Time per request:       13.363 [ms] (mean)

Deployment:             6/6 replicas   (maxReplicas reached)
```

**Zero failed requests across 1.08M requests** is the number that matters. It means the
`maxUnavailable: 0` rolling-update strategy and the readiness probe did their job: new
pods only received traffic once they were actually ready, and no request was dropped
while the replica count was changing underneath.

## Scale-down

CPU fell back to 5-8% immediately once load stopped, but the replica count **stayed at 6
for roughly four minutes** before dropping straight to 2:

```
t+20s   cpu: 6%/70%   replicas=6
t+60s   cpu: 6%/70%   replicas=6
t+120s  cpu: 8%/70%   replicas=6
t+180s  cpu: 6%/70%   replicas=6
t+200s  cpu: 6%/70%   replicas=6
t+220s  cpu: 6%/70%   replicas=2   <-- stabilization window expired
```

That delay is deliberate, not sluggishness. `scaleDown.stabilizationWindowSeconds: 300`
makes the HPA take the *highest* recommendation over the preceding five minutes, so a
brief lull in traffic cannot shed capacity that is about to be needed again. Scaling up
is fast (30s) and scaling down is slow (300s) because the two directions have very
different failure costs: scaling up late means latency, scaling down early means an
outage.

## Note on `ignoreDifferences`

The ArgoCD `Application` ignores `/spec/replicas` on the Deployment:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers: [/spec/replicas]
```

Without it, `selfHeal: true` would see 6 replicas in the cluster against the chart's
value and revert the HPA's decision on every sync — ArgoCD and the autoscaler fighting
each other. The chart also omits `spec.replicas` entirely when autoscaling is enabled,
for the same reason.
