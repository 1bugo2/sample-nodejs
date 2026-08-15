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

---

## The container image

Two-stage build on `node:22-alpine`, pinned by digest. The first stage runs
`npm ci --omit=dev`; the second copies only `node_modules`, `package.json` and `app.js`.

### Four things in it are load-bearing

**1. The base image is not clean, and the fix is to delete things.**

`node:22-alpine` ships HIGH and CRITICAL CVEs — `tar` (CRITICAL), `brace-expansion`,
`ip-address`, `sigstore`, `picomatch`. All of them come from the dependency trees bundled
with the **`npm` and `corepack` CLIs**, not from Alpine and not from this app. Our own image
gate would have blocked our own image.

None of that is needed at runtime — dependencies were already resolved in the build stage —
so the runtime stage deletes `npm`, `corepack` and `yarn`. Trivy then exits 0 on
HIGH/CRITICAL. The CVEs are *gone*, not suppressed in a `.trivyignore`, and a package
manager is a useful thing for an attacker to find in a container.

**2. `tini` at PID 1, because `SIGTERM` was being silently discarded.**

PID 1 does not get default signal handling — the kernel only delivers a signal to it if the
process installed a handler. `app.js` installs none, so as PID 1 node **ignored `SIGTERM`
entirely**. Measured: `docker stop` took the full **10.1s** timeout and ended in `SIGKILL`.
In Kubernetes that means every pod deletion burns the whole grace period.

With `tini` as PID 1 forwarding the signal to node as an ordinary child process:
**0.15s**. Fixed in the image, so no application code changed.

**3. `USER 1000:1000`, numerically.**

Not `USER node`, though they are the same account. Kubernetes evaluates `runAsNonRoot`
against the numeric id and cannot resolve a username from an image — a named `USER` would
leave the pod failing to start under `runAsNonRoot: true` unless `runAsUser` were also set.

**4. Exec form throughout.**

`ENTRYPOINT ["/sbin/tini", "--"]` with `CMD ["node", "app.js"]`. Shell form would insert
`/bin/sh` between tini and node, and it does not forward signals either — undoing fix #2.

### Also

- **`.dockerignore` excludes `.git`**, which otherwise carries the entire history into the
  build context, including any secret ever committed and later "removed"
- **`HEALTHCHECK`** is present even though Kubernetes ignores it, because it makes
  `docker run` and the CI smoke test self-verifying
- **OCI labels** (`image.source`, `image.revision`) make a running container traceable to
  the commit that built it, and let GitHub link the package to this repo. Trade-off recorded
  in the Dockerfile: since `revision` changes every commit, two builds of identical code no
  longer share a digest. Traceability was judged worth more than digest stability

### Result

```
245MB · no package managers · runs as uid 1000 · read-only root filesystem
Trivy HIGH/CRITICAL: 0 · hadolint clean at info threshold · stops in 0.15s
```

---

## The Helm chart

`charts/sample-nodejs/`. The brief asked to *"maximize the use of Kubernetes manifest
features"* and, in the same breath, for a chart *"so we can easily deploy it"*. Those pull
against each other, so the chart is built on one rule:

> **Feature-rich, but `helm install` works first try on any conformant cluster.** Anything
> that depends on a specific CNI, on optional CRDs, or on credentials that exist in only one
> place ships **present but disabled**, with a comment explaining why. It is enabled
> per-cluster from the GitOps values.

| Template | Default | Notes |
|---|---|---|
| `deployment.yaml` | on | 3 probes, resources, securityContext, `preStop`, config checksum |
| `service.yaml` | on | targets a *named* port so the container port can move |
| `ingress.yaml` | on | path **allow-list** — see below |
| `configmap.yaml` | on | `PORT`, `NODE_ENV` via `envFrom` |
| `secret.yaml` | on, empty | wired to `envFrom`; empty because the app has no secrets |
| `serviceaccount.yaml` | on | `automountServiceAccountToken: false` |
| `hpa.yaml` | on | degrades to `<unknown>` without metrics-server, so safe to leave on |
| `pdb.yaml` | on | `maxUnavailable`, not `minAvailable` — see below |
| `networkpolicy.yaml` | **off** | enforcement is CNI-specific |
| `servicemonitor.yaml` | **off** | needs Prometheus Operator CRDs |
| `values.schema.json` | — | rejects bad values at install time |
| `tests/test-connection.yaml` | — | a real `helm test` hook |

### Three probes, three different jobs

People often wire all three to the same endpoint with the same timings, which wastes them.

```yaml
startupProbe:    /live   every 2s,  30 failures allowed
readinessProbe:  /ready  every 5s,  3 failures
livenessProbe:   /live   every 10s, 3 failures
```

`startupProbe` **gates liveness** — until it succeeds, liveness is not evaluated at all, so a
slow cold start can never be mistaken for a hung process and restart-looped.
`readinessProbe` controls Service membership only. `livenessProbe` is the destructive one and
deliberately checks nothing downstream: a liveness probe that fails during a database outage
restarts every replica and turns a partial outage into a total one.

### The Ingress is an allow-list, not a deny-list

The app serves `/classified` to anyone. It is a supplied fixture and was not modified — so
the path is simply **never routed**:

```yaml
paths:
  - { path: /my-app, pathType: Prefix }
  - { path: /about,  pathType: Prefix }
```

Anything else gets a 404 from the ingress controller and **never reaches a pod**. Verified:
`/classified`, `/metrics`, `/live`, `/ready` and `/` all return 404 from outside, while
`/my-app` returns `Hello, World!`.

`/metrics` is excluded for the same reason — it is scraped in-cluster, and publishing it
externally leaks request volumes and process internals for no benefit.

Plain Ingress paths rather than a Traefik `Middleware`, so this works on any ingress
controller. The cost is that exposing a new route needs a chart change, which for an
allow-list is the intended behaviour.

### `preStop`, and why it is needed *because* of `tini`

Fixing `SIGTERM` created a second, subtler problem. Node now exits almost instantly — but the
kubelet removes a pod from Service endpoints and signals it **at the same moment**, so
requests already in flight would be cut off.

```yaml
lifecycle:
  preStop:
    exec: { command: ["/bin/sh", "-c", "sleep 5"] }
terminationGracePeriodSeconds: 30
```

`preStop` runs **before** `SIGTERM`, holding the pod open while it is de-registered. This is
also why the base image is alpine rather than distroless: `preStop exec` needs a shell.

### `maxUnavailable`, not `minAvailable`

```yaml
podDisruptionBudget:
  maxUnavailable: 1
```

`minAvailable: 1` looks equivalent and is a trap: with a single replica it forbids *every*
voluntary eviction, silently blocking node drains and cluster upgrades forever.
`maxUnavailable: 1` always permits exactly one, whatever the replica count.

### Resources sized from measurement

```
idle:               ~20 MiB
after 1000 requests: ~35 MiB
→ requests: 64Mi / 100m CPU     limits: 192Mi / 500m CPU
```

The CPU request is not arbitrary — the HPA scales on *percentage of request*, so an
unrealistically low request makes the 70% target meaningless. The memory limit is ~5× the
measured peak: enough to bound a leak without OOM-killing normal operation. `docker diff` on
a running container is empty, which is what makes `readOnlyRootFilesystem: true` safe.
