# sample-nodejs — DevOps / DevSecOps exercise

A fork of [EladAviczer/sample-nodejs](https://github.com/EladAviczer/sample-nodejs) with a
Helm chart, a CI/CD pipeline with security gates, and a GitOps deployment to Kubernetes via
ArgoCD.

There are two repositories:

| Repository | Holds |
|---|---|
| **this one** | application source, `Dockerfile`, the Helm chart, both pipelines |
| [**sample-nodejs-gitops**](https://github.com/1bugo2/sample-nodejs-gitops) | what is deployed, where — ArgoCD `Application`s and per-environment values |

Why they are separate is explained under [Decisions](#decisions-and-why).

Everything claimed here was verified against a running cluster, and the output is in
[`docs/evidence/`](docs/evidence/). Where something does not work, or works only under a
caveat, that is stated rather than omitted.

---

## The application

Unchanged from upstream apart from one forced dependency bump (see
[What the pipeline caught](#what-the-pipeline-caught)). It is a small Express server with
Prometheus metrics:

| Endpoint | Purpose |
|---|---|
| `/my-app` | returns `Hello, World!` — the main path |
| `/about` | description text |
| `/live` | liveness probe target |
| `/ready` | readiness probe target |
| `/metrics` | Prometheus exposition format, including a `root_access_total` counter |
| `/classified` | returns `You should not be here!!!` to anyone — see the Ingress section |

Port comes from `PORT`, defaulting to 8080.

---

## Architecture

```
 ┌─ developer ──────────────────────────────────────────────────────────┐
 │  branch → PR                                                          │
 └───────────────────────────────┬───────────────────────────────────────┘
                                 │
              ┌──────────────────▼──────────────────┐
              │  PR VALIDATION  (5 parallel jobs)   │
              │  secrets · SAST · deps · image ·    │
              │  chart                              │
              │  ── all behind one required check ──│
              └──────────────────┬──────────────────┘
                                 │  merge to protected main
              ┌──────────────────▼──────────────────┐
              │  RELEASE                            │
              │  1. version from commit messages    │
              │  2. build image (not pushed yet)    │
              │  3. smoke test it                   │
              │  4. Trivy gate  ◄── blocks here     │
              │  5. push to private GHCR            │
              │  6. SBOM + cosign signature         │
              │  7. chart → GHCR as OCI artifact    │
              │  8. git tag + GitHub release        │
              │  9. write digest to GitOps repo     │
              └──────────────────┬──────────────────┘
                                 │  a commit, nothing more
              ┌──────────────────▼──────────────────┐
              │  GITOPS REPO                        │
              │  envs/dev/values.yaml  ← the digest │
              │  argocd/applications/  ← chart ver  │
              └──────────────────┬──────────────────┘
                                 │  ArgoCD polls, outbound only
 ┌───────────────────────────────▼───────────────────────────────────────┐
 │  k3s on a VM (host-only network, 192.168.56.101)                      │
 │                                                                       │
 │   ArgoCD ──► helm render ──► Deployment · Service · Ingress · HPA      │
 │                              PDB · NetworkPolicy · ConfigMap · SA      │
 │                                        │                              │
 │   Traefik ──► my-app.192-168-56-101.nip.io/my-app                     │
 └───────────────────────────────────────────────────────────────────────┘
```

### The part that matters most

**Nothing in GitHub can reach the cluster.** The VM is on a VirtualBox host-only network,
so `192.168.56.101` is unroutable from the internet. There is no kubeconfig in GitHub
Actions and no inbound hole in the network.

The pipeline's entire deploy authority is *"write a version number into one file in one
repository"*, using an SSH deploy key scoped to the GitOps repo alone. ArgoCD, running
inside the cluster, polls that repository **outbound** and reconciles.

That is not an accident of the lab setup — it is the reason to use GitOps at all. The
alternative is handing CI a cluster-admin credential and opening a port, which is a much
larger blast radius for the same result.

### Direction of every arrow

```
GitHub Actions  ──push──►  GHCR                (outbound from CI)
GitHub Actions  ──commit─►  GitOps repo        (outbound from CI, one file)
ArgoCD          ──poll───►  GitOps repo        (outbound from cluster)
ArgoCD          ──pull───►  GHCR (chart)       (outbound from cluster)
kubelet         ──pull───►  GHCR (image)       (outbound from cluster)
```

Nothing points *into* the cluster.
