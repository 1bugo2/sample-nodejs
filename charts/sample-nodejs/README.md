# sample-nodejs

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.0.0](https://img.shields.io/badge/AppVersion-1.0.0-informational?style=flat-square)

Stateless Node.js web service with Prometheus metrics, deployed via ArgoCD

**Homepage:** <https://github.com/1bugo2/sample-nodejs>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Noam Yanai |  |  |

## Source Code

* <https://github.com/1bugo2/sample-nodejs>

## Requirements

Kubernetes: `>=1.25.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules. |
| autoscaling.behavior.scaleDown.stabilizationWindowSeconds | int | `300` | Scale-down stabilization. Deliberately 10x scale-up: shedding capacity early causes the outage autoscaling exists to prevent. |
| autoscaling.behavior.scaleUp.stabilizationWindowSeconds | int | `30` | Scale-up stabilization. Short, so load is answered quickly. |
| autoscaling.enabled | bool | `true` | Create an HPA. Safe to leave on: without metrics-server it reports `<unknown>` and does nothing rather than failing. |
| autoscaling.maxReplicas | int | `6` | Maximum replicas. |
| autoscaling.minReplicas | int | `2` | Minimum replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `70` | Target CPU as a percentage of the CPU *request*, not of a core. |
| config.NODE_ENV | string | `"production"` | Node environment. |
| config.PORT | string | `"8080"` | Port the container listens on. Must match `service.targetPort`. |
| containerSecurityContext.allowPrivilegeEscalation | bool | `false` | Forbid gaining more privileges than the parent process. |
| containerSecurityContext.capabilities.drop | list | `["ALL"]` | Linux capabilities to drop. |
| containerSecurityContext.readOnlyRootFilesystem | bool | `true` | Read-only root filesystem. Verified safe: `docker diff` on a running container is empty, so the app writes nothing. |
| image.digest | string | `""` | Image digest, e.g. `sha256:...`. Takes precedence over `tag`, and is what the pipeline writes, so the deployed image is provably the one that was scanned. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/1bugo2/sample-nodejs"` | Image repository. Override to deploy from your own registry. |
| image.tag | string | `""` | Image tag. Written by the release pipeline. Prefer `digest`. |
| imagePullSecrets | list | `[]` | Pull secrets for a private registry. Empty by default so a fresh install cannot fail on a Secret that does not exist yet. |
| ingress.annotations | object | `{}` | Extra Ingress annotations. |
| ingress.className | string | `"traefik"` | Ingress class. Override for a cluster not running Traefik. |
| ingress.enabled | bool | `true` | Create an Ingress. |
| ingress.host | string | `"my-app.192-168-56-101.nip.io"` | Hostname. A `nip.io` name for the lab; override for any other cluster. |
| ingress.paths | list | `[{"path":"/my-app","pathType":"Prefix"},{"path":"/about","pathType":"Prefix"}]` | Routed paths, as an allow-list. Anything absent - including `/classified` and `/metrics` - is refused at the edge and never reaches a pod. |
| ingress.tls.enabled | bool | `false` | Serve over TLS, using a `<release>-tls` Secret. |
| lifecycle.preStopSleepSeconds | int | `5` | Seconds to hold a terminating pod open before SIGTERM, so it is removed from Service endpoints before it stops accepting. Needs a shell in the image. |
| metrics.dashboard.enabled | bool | `false` | Ship the Grafana dashboard as a ConfigMap, so it lives in Git rather than in someone's browser. Enable in one environment only; the uid is fixed. |
| metrics.dashboard.label | string | `"grafana_dashboard"` | Label Grafana's sidecar watches for. |
| metrics.prometheusRule.enabled | bool | `false` | Create a PrometheusRule with the six app alerts. Off by default for the same CRD reason as the ServiceMonitor. |
| metrics.prometheusRule.eventLoopLagSeconds | float | `0.2` | Event loop lag that fires an alert. Node is single-threaded, so a blocked loop means alive-but-not-working, and a liveness probe will not notice. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a ServiceMonitor. Off by default: needs Prometheus Operator CRDs, and the chart must install before the monitoring stack exists. |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.path | string | `"/metrics"` | Metrics path. |
| networkPolicy.enabled | bool | `false` | Create a default-deny NetworkPolicy. Off by default: enforcement is CNI-dependent, and on a CNI that filters kubelet traffic it blocks probes and kills every pod. |
| networkPolicy.extraIngressCIDRs | list | `[]` | Extra CIDRs allowed in. Only needed where the CNI filters kubelet probes, and must be the node CIDR - `0.0.0.0/0` would allow everything and void the policy. |
| networkPolicy.ingressControllerNamespace | string | `"kube-system"` | Namespace of the ingress controller, allowed to reach the pods. |
| networkPolicy.monitoringNamespace | string | `"monitoring"` | Namespace of Prometheus, allowed to scrape `/metrics`. |
| nodeSelector | object | `{}` | Node selector for pod placement. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podDisruptionBudget.enabled | bool | `true` | Create a PodDisruptionBudget. |
| podDisruptionBudget.maxUnavailable | int | `1` | Voluntary disruptions allowed at once. `maxUnavailable`, not `minAvailable`: the latter forbids every eviction at one replica and deadlocks node drains. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext.fsGroup | int | `1000` | Supplemental group applied to mounted volumes. |
| podSecurityContext.runAsGroup | int | `1000` | GID. |
| podSecurityContext.runAsNonRoot | bool | `true` | Refuse to start as root. |
| podSecurityContext.runAsUser | int | `1000` | UID. Numeric because Kubernetes cannot resolve a username from an image, so `runAsNonRoot` would otherwise be unenforceable. |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` | Seccomp profile. |
| probes.liveness.failureThreshold | int | `3` | Liveness failures before a restart. 3 x 10s means ~30s genuinely wedged. |
| probes.liveness.path | string | `"/live"` | Liveness probe path. Deliberately checks nothing downstream: a liveness probe that fails during a dependency outage restarts every replica. |
| probes.liveness.periodSeconds | int | `10` | Liveness probe interval. |
| probes.liveness.timeoutSeconds | int | `2` | Liveness probe timeout. |
| probes.readiness.failureThreshold | int | `3` | Readiness failures before the pod leaves the Service. |
| probes.readiness.path | string | `"/ready"` | Readiness probe path. Controls Service membership only. |
| probes.readiness.periodSeconds | int | `5` | Readiness probe interval. |
| probes.readiness.timeoutSeconds | int | `2` | Readiness probe timeout. |
| probes.startup.failureThreshold | int | `30` | Startup failures tolerated. 30 x 2s allows a 60s cold start. |
| probes.startup.path | string | `"/live"` | Startup probe path. Gates liveness, so a slow boot is never mistaken for a hang. |
| probes.startup.periodSeconds | int | `2` | Startup probe interval. |
| replicaCount | int | `2` | Replica count. Ignored while `autoscaling.enabled` is true, since the HPA owns it. |
| resources.limits.cpu | string | `"500m"` | CPU limit. High enough never to throttle normal traffic, low enough to cap a runaway loop. |
| resources.limits.memory | string | `"192Mi"` | Memory limit, ~5x measured peak: bounds a leak without OOM-killing normal use. |
| resources.requests.cpu | string | `"100m"` | CPU request. Also the HPA's denominator, so it must be realistic or the target percentage becomes meaningless. |
| resources.requests.memory | string | `"64Mi"` | Memory request. Measured ~20MiB idle, ~35MiB under load. |
| revisionHistoryLimit | int | `2` | ReplicaSets kept for rollback. Two is enough without accumulating dozens. |
| secretEnv | object | `{}` | Sensitive env vars, rendered into a Secret. Empty: this app has no secrets, so the mechanism is wired rather than demonstrated with an invented credential. |
| service.port | int | `80` | Port the Service listens on. |
| service.targetPort | string | `"http"` | Target container port, by name so the container port can move independently. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.automountServiceAccountToken | bool | `false` | Mount the API token into pods. Off: the app never calls the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount for the pods. |
| serviceAccount.name | string | `""` | Override the generated ServiceAccount name. |
| terminationGracePeriodSeconds | int | `30` | Grace period. Must exceed `lifecycle.preStopSleepSeconds` plus in-flight work. |
| tolerations | list | `[]` | Tolerations. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
