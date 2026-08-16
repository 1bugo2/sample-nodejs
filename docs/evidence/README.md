# Evidence

The cluster is a single-node k3s VM on a host-only network, so it is not reachable from
the internet. The task allows *"access to your Kubernetes cluster **or** screenshots"* —
this is the screenshots route, plus captured command output where text is more useful than
a picture.

## Screenshots

| File | Shows |
|---|---|
| [01-ingress-my-app.png](screenshots/01-ingress-my-app.png) | `Hello, World!` served through the Ingress at `my-app.192-168-56-101.nip.io/my-app` |
| [02-ingress-about.png](screenshots/02-ingress-about.png) | `/about` — the second routed path |
| [03-ingress-classified-404.png](screenshots/03-ingress-classified-404.png) | **`/classified` returns 404 at the edge.** The app still serves it internally; the Ingress allow-list means the request never reaches a pod |
| [04-argocd-applications-synced.png](screenshots/04-argocd-applications-synced.png) | ArgoCD with **all three Applications Healthy/Synced** — `root`, `sample-nodejs-dev` and `sample-nodejs-prod`. Both environments track chart `1.2.0` from `ghcr.io/1bugo2/charts` and deploy to separate namespaces |
| [05-argocd-resource-tree.png](screenshots/05-argocd-resource-tree.png) | The dev resource tree, **11 objects Synced**: `cm`, the dashboard `cm`, `svc`, `sa`, `deploy`, `hpa`, `prometheusrule`, `servicemonitor`, `ing`, `netpol`, `pdb` — plus ReplicaSets and 2 running pods. The `PR`/`SM`/dashboard nodes are the monitoring templates the GitOps values enable |
| [06-argocd-application-manifest.png](screenshots/06-argocd-application-manifest.png) | The `Application` manifest: multi-source (OCI chart + `$values` from the GitOps repo), `prune`/`selfHeal`, and `/spec/replicas` ignored so ArgoCD does not fight the HPA |
| [07-release-pipeline-steps.png](screenshots/07-release-pipeline-steps.png) | **The release pipeline's step order.** `Smoke test` → `Block release on high or critical vulnerabilities` → `Push image`. The gate precedes the push, so a vulnerable image is never published |
| [08-ghcr-image-private.png](screenshots/08-ghcr-image-private.png) | The image package marked **Private**, with `v1.0.0` and the cosign `.sig` and SBOM `.att` artifacts alongside it |
| [09-github-release-v1.0.0.png](screenshots/09-github-release-v1.0.0.png) | Release `v1.0.0` cut by the pipeline, changelog generated from Conventional Commit subjects, `sbom.spdx.json` attached |
| [10-argocd-hpa-scaled-to-6.png](screenshots/10-argocd-hpa-scaled-to-6.png) | **The HPA scaled to 6 replicas under load.** Captured 2026-08-14 during the load test, when the chart was at `1.0.0` — hence the older version and smaller object count than shot 05. Five pods are 4 minutes old against one at an hour, and the Application stayed `Healthy`/`Sync OK` throughout, which is `ignoreDifferences: /spec/replicas` preventing `selfHeal` from reverting the autoscaler |
| [11-grafana-alert-rules.png](screenshots/11-grafana-alert-rules.png) | The six `SampleNodejs*` alert rules loaded and all **Normal**. They appear under Grafana's *Prometheus* rule source rather than *Grafana-managed*, because they ship as a `PrometheusRule` object in the Helm chart — versioned in Git rather than clicked into the UI |

## Captured output

| File | Shows |
|---|---|
| [promotion-gate-pending.txt](promotion-gate-pending.txt) | **The gate at rest.** prod `OutOfSync / Healthy` with `target=1.2.1  last-deployed=1.2.0`, different digests genuinely running in each namespace, and prod still serving 200. Also records why `status.history` is the field to read and `status.sync.revisions` is not — the latter is only the *target*, and reading it is how you wrongly conclude prod is already on the new version |
| [promotion-gate.txt](promotion-gate.txt) | Verbatim transcript: the **same digest** in both environment files, prod's `syncPolicy.automated` empty while dev's is populated, the identical image running in both namespaces, and both Ingress hosts serving. Reasoning is in the [README](../../README.md#environments-and-promotion) rather than repeated here |
| [digest-and-registry-proof.txt](digest-and-registry-proof.txt) | The deployed image digest matches the digest committed to the GitOps repo, and an anonymous client gets **403** on the image while the chart returns **200** |
| [hpa-autoscaling.md](hpa-autoscaling.md) | 1,077,610 requests, **0 failed**, scaled 2 → 6, then held before scaling back down |
| [security-gate-blocks-merge.md](security-gate-blocks-merge.md) | A planted HIGH CVE caught by two independent gates; merge refused with **HTTP 405** |
| [gitops-rollback.md](gitops-rollback.md) | `git revert` rolled the cluster back with no `kubectl`, serving `200` throughout |

## Live things a reviewer can check

- [PR #8](https://github.com/1bugo2/sample-nodejs/pull/8) — deliberately left open and failing. `PR gate` is red and GitHub refuses the merge
- [Actions history](https://github.com/1bugo2/sample-nodejs/actions) — every PR run and every release
- [GitOps repo commit log](https://github.com/1bugo2/sample-nodejs-gitops/commits/main) — the deploy history, including the revert

## What the screenshots deliberately do not show

No `kubectl get secret` output and no ArgoCD login screen. The only secret in this system is
the registry pull credential, and a Kubernetes Secret is base64-encoded rather than
encrypted — putting one in a screenshot would leak it.
