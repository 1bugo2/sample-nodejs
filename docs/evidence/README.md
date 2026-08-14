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
| [04-argocd-applications-synced.png](screenshots/04-argocd-applications-synced.png) | ArgoCD: `root` and `sample-nodejs-dev` both **Healthy / Synced**. Note the child app's source is `ghcr.io/1bugo2/charts` at a pinned chart version |
| [05-argocd-resource-tree.png](screenshots/05-argocd-resource-tree.png) | All 8 chart objects reconciled — `cm`, `svc`, `sa`, `deploy`, `hpa`, `ing`, `netpol`, `pdb` — plus the ReplicaSet and 2 running pods |
| [06-argocd-application-manifest.png](screenshots/06-argocd-application-manifest.png) | The `Application` manifest: multi-source (OCI chart + `$values` from the GitOps repo), `prune`/`selfHeal`, and `/spec/replicas` ignored so ArgoCD does not fight the HPA |
| [07-release-pipeline-steps.png](screenshots/07-release-pipeline-steps.png) | **The release pipeline's step order.** `Smoke test` → `Block release on high or critical vulnerabilities` → `Push image`. The gate precedes the push, so a vulnerable image is never published |
| [08-ghcr-image-private.png](screenshots/08-ghcr-image-private.png) | The image package marked **Private**, with `v1.0.0` and the cosign `.sig` and SBOM `.att` artifacts alongside it |
| [09-github-release-v1.0.0.png](screenshots/09-github-release-v1.0.0.png) | Release `v1.0.0` cut by the pipeline, changelog generated from Conventional Commit subjects, `sbom.spdx.json` attached |

## Captured output

| File | Shows |
|---|---|
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
