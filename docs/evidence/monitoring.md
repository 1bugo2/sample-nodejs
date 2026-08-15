# Evidence: monitoring

`kube-prometheus-stack` 88.3.0 (Prometheus Operator v0.93.0), installed by
[`scripts/bootstrap-vm.sh`](https://github.com/1bugo2/sample-nodejs-gitops/blob/main/scripts/bootstrap-vm.sh)
so it is reproducible rather than clicked together once.

## The starting problem: the app instruments almost nothing

`prom-client` gives the Node runtime defaults plus one custom counter. It does **not**
instrument HTTP request duration or status codes. So of Rate / Errors / Duration, the
application alone provides a partial Rate and nothing else.

A dashboard built purely on app metrics would look thorough and tell you nothing when
something broke.

## So the RED metrics come from Traefik

Traefik sits in front of every request and already exposes per-service request counts by
status code and duration histograms. k3s starts it with `--metrics.prometheus=true` and a
named `metrics` port, so a `PodMonitor` is enough — no change to the Traefik deployment,
which matters because k3s manages it through a `HelmChart` CR that would overwrite a manual
edit.

Verified with real traffic:

```
traefik_service_requests_total{code="200", service="sample-nodejs-...-dev-80@kubernetes"} = 45
histogram_quantile(0.95, ...traefik_service_request_duration_seconds_bucket...)      = 0.095
```

One nuance worth knowing: requests refused by the Ingress allow-list (`/classified`,
`/metrics`) never reach a Service, so they do **not** appear in
`traefik_service_requests_total`. They land in `traefik_entrypoint_requests_total` instead.
Service-level metrics therefore measure what the *app* served, which is what you want for an
error-rate alert.

## Application metrics being scraped

```
root_access_total{pod="sample-nodejs-dev-568b5744fb-hrzfh"}          = 15
nodejs_eventloop_lag_seconds{pod="sample-nodejs-dev-568b5744fb-..."} = 0.0107
```

## Six alerts, each mapped to a failure mode

| Alert | Fires when | Why it matters |
|---|---|---|
| `SampleNodejsCrashLooping` | >2 restarts in 15m | crash loop, not a rollout |
| **`SampleNodejsEventLoopBlocked`** | lag > 200ms for 5m | **see below** |
| `SampleNodejsMemoryNearLimit` | >80% of limit for 10m | fires *before* the OOMKill |
| `SampleNodejsHighErrorRate` | >1% 5xx for 5m | measured at the ingress |
| `SampleNodejsAutoscalerAtCeiling` | at `maxReplicas` for 10m | the ceiling is now the bottleneck |
| `SampleNodejsNoReadyReplicas` | 0 available for 2m | Service has no endpoints |

**Event loop lag is the one worth arguing for.** Node is single-threaded: if the loop is
blocked, the process is alive but doing no work — and it will still answer a liveness probe
if the probe's timeout is generous. `/live` returning 200 proves nothing in that state. Lag
is the only metric that catches it. Measured idle at ~11ms, so the 200ms threshold is well
clear of normal operation.

Confirmed loaded in Prometheus:

```
SampleNodejsCrashLooping        SampleNodejsHighErrorRate
SampleNodejsEventLoopBlocked    SampleNodejsAutoscalerAtCeiling
SampleNodejsMemoryNearLimit     SampleNodejsNoReadyReplicas
```

All `inactive` — the application is healthy.

## The dashboard is a ConfigMap, not a UI artifact

Grafana's sidecar imports any ConfigMap labelled `grafana_dashboard`, so the dashboard ships
**with the chart** and is versioned alongside the thing it describes. A dashboard built in
the browser is lost the next time Grafana is reinstalled.

```
grafana-sc-dashboard: Writing /tmp/dashboards/sample-nodejs.json
```

Ten panels in three rows: traffic and errors from Traefik, Node runtime internals (event
loop lag, heap, `root_access_total`), and Kubernetes (replicas vs HPA ceiling, memory vs
limit).

## Two things that had to be fixed to make the alerting trustworthy

**1. The default rules assume a kubeadm cluster.** k3s runs the scheduler,
controller-manager, etcd and kube-proxy inside a single process, so those default
`ServiceMonitor`s have nothing to scrape and sit permanently down. They are disabled in the
values — a wall of red trains people to ignore the alerting you just built.

**2. Prometheus was scraping the kubelet over IPv6 and failing.** The node carries a ULA
IPv6 address that k3s's kubelet does not listen on, so the operator generated three IPv6
targets that could never succeed, firing `TargetDown` and `KubeletInstanceUnreachable`
permanently. Fixed with a `keep` relabel on IPv4 addresses:

```
before:  kubelet targets 6, down 3   → TargetDown + KubeletInstanceUnreachable firing
after:   kubelet targets 3, down 0   → clean
```

## Final state

```
firing: Watchdog        ← by design; a dead-man's switch proving the pipeline works.
                          If Watchdog ever stops firing, the alerting itself is broken.
SampleNodejs alerts active: 0
```

Grafana: `http://grafana.192-168-56-101.nip.io` — reachable from the host, returns 200.
