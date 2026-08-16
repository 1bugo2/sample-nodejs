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

## Prerequisites — the stack this is built for

This is built for a specific stack rather than for every possible cluster. Real
infrastructure targets a known platform; a chart that tries to work everywhere is optimised
for nowhere, and every portability flag is a code path nobody exercises.

| Component | Requirement | Why |
|---|---|---|
| Kubernetes | **≥ 1.25** | `autoscaling/v2`, `policy/v1` |
| Ingress controller | **Traefik** | k3s default. Also the source of the RED metrics, since the app instruments no request duration or status codes |
| Metrics | **metrics-server** | the HPA scales on CPU as a percentage of request |
| Monitoring | **Prometheus Operator CRDs** | for `ServiceMonitor` and `PrometheusRule` |
| Registry | **OCI, private** | GHCR. The cluster needs an `imagePullSecret` |
| GitOps | **ArgoCD ≥ 2.6** | multi-source `Application`s (`$values` refs) |
| CNI | one that **enforces NetworkPolicy** | k3s does; not all do |

`scripts/bootstrap-vm.sh` in the [GitOps repo](https://github.com/1bugo2/sample-nodejs-gitops)
builds all of that from a bare Ubuntu host.

### Where that stack shows through

Two places the chart is genuinely Traefik-specific, worth knowing before deploying behind a
different controller:

- **`SampleNodejsHighErrorRate`** queries `traefik_service_requests_total`. Behind nginx that
  metric does not exist, so the alert never fires — silent rather than broken, which is
  worse. Swap it for the equivalent nginx metric.
- **Two dashboard panels** (request rate, latency percentiles) read the same Traefik
  histograms and would render empty.

### Why some templates ship disabled

`networkPolicy`, `metrics.serviceMonitor`, `metrics.prometheusRule` and `metrics.dashboard`
default to `false`. That is **not** about supporting unknown clusters — it is about
**bootstrap ordering**.

The app chart can legitimately be installed before the monitoring stack exists. If
`serviceMonitor` defaulted on, `helm install` would hard-fail with
`no matches for kind "ServiceMonitor"` on a cluster that is perfectly correct and simply not
finished being built. Same for `NetworkPolicy` before the CNI's policy controller is running.

They are switched on per-environment from the GitOps values, where the dependencies are known
to be present.

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
              │  envs/dev/values.yaml   ← digest    │
              │  envs/prod/values.yaml  ← SAME      │
              │  argocd/applications/   ← chart ver │
              └──────────────────┬──────────────────┘
                                 │  ArgoCD polls, outbound only
 ┌───────────────────────────────▼───────────────────────────────────────┐
 │  k3s on a VM (host-only network, 192.168.56.101)                      │
 │                                                                       │
 │   ArgoCD ──► helm render ──► Deployment · Service · Ingress · HPA      │
 │                              PDB · NetworkPolicy · ConfigMap · SA      │
 │                              ServiceMonitor · PrometheusRule           │
 │        │                                                               │
 │        ├─ dev   auto-sync    ──► my-app.192-168-56-101.nip.io          │
 │        │                                                               │
 │        └─ prod  MANUAL sync  ──► my-app-prod.192-168-56-101.nip.io     │
 │                 ▲                                                      │
 │                 └─ the gate: same digest, applied only when a human    │
 │                    syncs. Until then prod sits OutOfSync / Healthy.    │
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

`ENTRYPOINT ["/sbin/tini", "--"]` with `CMD ["node", "app.js"]`. Shell form wraps both in
`/bin/sh -c` and silently discards `CMD`, so an `args:` override from the chart would do nothing.

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

`charts/sample-nodejs/`. Built for the stack in [Prerequisites](#prerequisites--the-stack-this-is-built-for),
on one rule:

> **A default `helm install` must succeed before the cluster is finished being built.**
> Anything requiring CRDs, a policy-enforcing CNI, or a registry credential ships present but
> **disabled**, and is switched on per-environment from the GitOps values once those
> dependencies exist.

That is bootstrap ordering, not hedging about unknown clusters — the app chart legitimately
gets installed before the monitoring stack does.

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

### Chart reference, and changing it

[`charts/sample-nodejs/README.md`](charts/sample-nodejs/README.md) is a **generated**
reference for all 71 values, produced by helm-docs from the `# --` comments in `values.yaml`.
Do not edit it by hand.

CI regenerates it on every pull request and fails on any difference, so it cannot drift from
`values.yaml`.

### Regenerating it after changing `values.yaml`

Install helm-docs once:

```bash
go install github.com/norwoodj/helm-docs/cmd/helm-docs@latest
```

Or take a release binary from [the releases page](https://github.com/norwoodj/helm-docs/releases)
and put it on your `PATH` — `helm-docs_<version>_Windows_x86_64.zip` on Windows,
`helm-docs_<version>_Linux_x86_64.tar.gz` on Linux.

Then, from the repository root, **before committing**:

```bash
helm-docs --chart-search-root=charts
git add charts/sample-nodejs/README.md
```

If CI reports `charts/sample-nodejs/README.md is stale`, that is the fix.

To make it automatic, add a pre-commit hook — same result, and it needs no CI privilege:

```bash
cat > .git/hooks/pre-commit <<'EOF'
#!/usr/bin/env sh
helm-docs --chart-search-root=charts && git add charts/sample-nodejs/README.md
EOF
chmod +x .git/hooks/pre-commit
```

CI deliberately does **not** regenerate and commit this itself. That would need
`contents: write` on a pull-request workflow, and every workflow here runs `contents: read`
unless it has a specific reason not to.

### Comment conventions in `values.yaml`

| Prefix | Purpose |
|---|---|
| `#` | The reasoning — why the value is what it is. Stays in `values.yaml` |
| `# --` | One-line summary. This is what reaches the generated table |
| `# @ignore` | Omits the key from the table |

```yaml
# Without a memory limit one leaking pod can evict its neighbours. 192Mi is ~5x the
# measured peak: it bounds a runaway without OOM-killing normal operation.
# -- Memory limit, ~5x measured peak: bounds a leak without OOM-killing normal use.
memory: 192Mi
```

Only the `# --` line reaches the table, so keep it short and put anything needing a paragraph
above it.

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

---

## The pipelines

Two workflows, with clearly different jobs. **PR validation decides whether a change is
safe. Release publishes it.** The release workflow does not re-litigate safety, because
nothing reaches `main` without passing the gate.

### Git workflow

GitHub Flow: short-lived branch → PR → required checks → **rebase-merge** into protected
`main`.

Rebase rather than squash, deliberately: it preserves the individual commits so the reasoning
in each message survives on `main`, while keeping history linear. Squashing would collapse a
PR into one commit and paste the PR description into the commit body — which is how PR prose
ends up polluting `git log`.

`main` is protected with:

```
required status check : "PR gate"   (strict — branch must be current)
enforce_admins        : true        ← applies to the repository owner too
required_linear_history: true
allow_force_pushes    : false
```

`enforce_admins` matters. A gate an administrator can walk past is a suggestion. This one was
tested by trying to merge a vulnerable PR as the owner — see
[What the pipeline caught](#what-the-pipeline-caught).

### PR validation — 5 jobs, one required check

```
secret-scan  ──┐
sast         ──┤
dependency   ──┼──►  PR gate  ──►  merge allowed
image        ──┤
chart        ──┘
```

| Job | Tool | Blocks on |
|---|---|---|
| Secret scan | Gitleaks, `fetch-depth: 0` | **any** finding |
| SAST | Semgrep (`p/javascript`, `p/nodejs`, `p/owasp-top-ten`, `p/secrets`) | severity `ERROR` |
| Dependency scan | Trivy fs + `npm audit` | `HIGH`/`CRITICAL` |
| Image | hadolint → build → smoke test → Trivy image | `HIGH`/`CRITICAL` |
| Chart | `helm lint --strict` → kubeconform → Checkov | invalid manifests |

Three details that are choices rather than defaults:

**Reporting is separated from gating.** Every scan uploads SARIF to the Security tab with
`if: always()`, and a *separate* step decides pass/fail. A gate that exits before publishing
its own evidence is useless precisely when you need it — while triaging the failure.

**`PR gate` is a single aggregate check.** Adding a scan later is a `needs:` entry, not a
repository settings change. Branch protection references one context and never needs touching.

**Secrets scan the full history.** A credential committed and "removed" in a later commit is
still in the history, still leaked, and still needs rotating.

### Thresholds, and why they are not all the same

| Gate | Threshold | Reasoning |
|---|---|---|
| Secrets | any finding | there is no acceptable number of committed credentials |
| SAST | `ERROR` only | `WARNING`/`INFO` land in the Security tab for triage without blocking unrelated work |
| Dependencies | `HIGH`+, **`ignore-unfixed`** | an advisory with no released patch cannot be actioned by a version bump; blocking on it only teaches people to route around the gate |
| hadolint | advisory | style rules should not be indistinguishable from a critical CVE |
| Checkov | advisory | see below |

**Checkov is advisory on purpose.** Its OSS checks carry no severity, and it applies
Deployment rules to any Pod — it demanded readiness and liveness probes on the one-shot
`helm test` pod, which is meaningless. Gating on that pushes people to bulk-skip checks, which
is worse than triaging a report. Its two *genuine* findings were fixed, not suppressed: the
test pod was mounting a ServiceAccount token, and its image was pinned by tag rather than
digest.

### Release — on merge to `main`

```
1. version    from Conventional Commits since the last tag
2. build      into the local daemon — NOT pushed
3. smoke test /live /ready /my-app /metrics, plus stop-time under 5s
4. TRIVY GATE ◄────────── the whole point of the ordering
5. push       to private GHCR, by digest
6. SBOM       syft → SPDX, attached to the release
7. sign       cosign keyless + SBOM attestation
8. chart      packaged and pushed as an OCI artifact
9. tag        git tag + GitHub release with generated notes
10. promote   digest + chart version committed to the GitOps repo
```

**Steps 2–5 are the important sequence.** The image is built into the local daemon, scanned,
and only then pushed *from that same local image*. A HIGH or CRITICAL image is therefore never
published — as opposed to published and then flagged. It also means the bits that were scanned
are provably the bits that shipped.

Step 3 exists because **`docker build` succeeds even when the app is completely broken** —
building never runs it. Without a smoke test, a broken app produces a clean scan, a successful
push, and a `CrashLoopBackOff` in the cluster, with every pipeline step green. It also asserts
stop-time under 5s, which is a regression guard for the `tini` fix.

**Versions come from git tags, not `package.json`** — that file belongs to the upstream fixture
and is not ours to bump. `feat:` → minor, `!` or `BREAKING CHANGE` → major, anything else →
patch.

**Docs-only merges skip the release entirely** via `paths-ignore`. That is a deny-list rather
than an allow-list on purpose: with `paths:` you enumerate what triggers a release, so a file
you forget to list means a real change ships nothing and nobody notices. With `paths-ignore:`
the worst case is one redundant release. For a release gate, failing towards "published
something unnecessary" beats failing towards "silently published nothing". `charts/**` is
deliberately *not* ignored — a probe-timing change needs a new chart version even though the
image is unchanged.

**`concurrency: cancel-in-progress: false`.** Cancelling between "image pushed" and "digest
promoted" would leave the registry and the GitOps repo disagreeing about what is current.

**Every action is pinned to a commit SHA.** A tag is a mutable pointer; anyone who can push to
`actions/checkout` could repoint `v5` at code that reads our secrets. Dependabot is configured
for the `github-actions` ecosystem to bump the pins.

---

## Monitoring

`kube-prometheus-stack`, installed by the bootstrap script. The interesting part is where the
metrics come from, because the app does not provide most of them.

### The app instruments almost nothing

`prom-client` gives the Node runtime defaults plus one counter (`root_access_total`). It does
**not** instrument HTTP request duration or status codes. So of Rate / Errors / Duration, the
application alone provides a partial Rate.

A dashboard built purely on app metrics would look thorough and tell you nothing during an
incident.

### So RED comes from Traefik

Traefik sees every request and already exposes per-service counts by status code and duration
histograms. k3s starts it with `--metrics.prometheus=true` and a named `metrics` port, so a
`PodMonitor` is enough — no change to Traefik's deployment, which matters because k3s manages
it through a `HelmChart` CR that would overwrite a manual edit.

```
traefik_service_requests_total{code="200", service="sample-nodejs-dev-80@kubernetes"} = 45
histogram_quantile(0.95, …traefik_service_request_duration_seconds_bucket…)           = 0.095
```

Requests refused by the Ingress allow-list never reach a Service, so they appear in
`traefik_entrypoint_requests_total` rather than the service metric. Service-level metrics
therefore measure what the *app* served — which is what you want for an error-rate alert.

### Six alerts, and the one worth arguing for

| Alert | Fires when |
|---|---|
| `SampleNodejsCrashLooping` | >2 restarts in 15m |
| **`SampleNodejsEventLoopBlocked`** | **lag > 200ms for 5m** |
| `SampleNodejsMemoryNearLimit` | >80% of limit for 10m |
| `SampleNodejsHighErrorRate` | >1% 5xx for 5m |
| `SampleNodejsAutoscalerAtCeiling` | at `maxReplicas` for 10m |
| `SampleNodejsNoReadyReplicas` | 0 available for 2m |

**Event loop lag is the important one.** Node is single-threaded: if the loop is blocked the
process is alive but doing no work, and it will still answer a liveness probe. `/live`
returning 200 proves nothing in that state. Lag is the only signal that catches it. Measured
idle at ~11ms, so 200ms is well clear of normal.

Two of the six (`CrashLooping`, `AutoscalerAtCeiling`) overlap with kube-prometheus-stack's
own `KubePodCrashLooping` and `KubeHpaMaxedOut`. They are kept because they are scoped to this
app with tuned thresholds and app-specific annotations, so they read and route differently —
but they are not novel, and duplicate alerts do mean two pages for one incident.

### The dashboard is a ConfigMap

Grafana's sidecar imports any ConfigMap labelled `grafana_dashboard`, so the dashboard ships
**with the chart** and is versioned alongside what it describes. A dashboard built in the
browser is lost the next time Grafana is reinstalled.

### Two fixes needed to make the alerting trustworthy

Alerting that is red on day one is alerting people learn to ignore.

1. **The default rules assume kubeadm.** k3s runs the scheduler, controller-manager, etcd and
   kube-proxy inside one process, so four default rule groups had nothing to scrape and sat
   permanently down. Disabled in the values.
2. **Prometheus was scraping the kubelet over IPv6 and failing.** The node carries a ULA IPv6
   address the kubelet does not listen on, producing three targets that could never succeed
   and firing `TargetDown` forever. Fixed with a `keep` relabel on IPv4:
   `6 targets / 3 down → 3 targets / 0 down`.

Final state: only `Watchdog` firing, which is *supposed* to — it is a dead-man's switch
proving the pipeline works. If `Watchdog` ever stops firing, the alerting itself is broken.

No receivers are configured. There is nowhere sensible to page in a lab, and a fake Slack
webhook would be theatre.

---

## Environments and promotion

Two environments, `dev` and `prod`, each a namespace in the same cluster with its own values
file and ArgoCD `Application`.

### Read this before the rest of the section

**`prod` here is a namespace on the same single node as `dev`.** It demonstrates the
promotion *mechanism*; it is not production isolation, and calling it prod is a convenience.
Concretely, the two share a node with ArgoCD and the monitoring stack — so a load test in dev
can starve prod, which is the opposite of what production means. During the HPA
demonstration, `ab -c 60` scaled dev to six pods on a four-vCPU node.

What production would actually look like is in
[What production would do differently](#what-production-would-do-differently) below.

### What *is* real: prod receives the same artifact

The release pipeline writes one image digest to both environment files in a single commit:

```
envs/dev/values.yaml    digest: sha256:eda79dce…
envs/prod/values.yaml   digest: sha256:eda79dce…   ← identical
```

This is a **promotion, not a rebuild.** Prod is handed the exact artifact that was scanned,
signed and exercised in dev — not a fresh build from the same commit that is *assumed*
equivalent. Two builds of one commit can differ; a digest cannot.

### The gate

The two Applications differ in exactly one respect:

| | `syncPolicy.automated` | Behaviour |
|---|---|---|
| dev | `prune: true, selfHeal: true` | applies immediately |
| **prod** | **absent** | **waits for a human** |

So writing prod's desired state does not deploy it. Prod sits `OutOfSync / Healthy` —
running the previous version fine, with a pending change — until someone syncs it in the UI
or runs `argocd app sync sample-nodejs-prod`.

`OutOfSync + Healthy + no automated sync` is the idiomatic ArgoCD expression of "pending
promotion"; ArgoCD has no literal *Pending* status, and the enum cannot be extended. Because
that combination looks like a fault to anyone who does not read ArgoCD fluently, the prod
Application carries a `spec.info` block that states the policy on its own page.

### Why the gate is in ArgoCD rather than in CI

A GitHub Environment with a required reviewer was the alternative, and was rejected:

- **`environment:` protection is job-level**, so gating prod needs a second job — meaning
  either duplicated promotion logic or a shared script. More machinery for less.
- **The pipeline's job is to publish desired state.** Whether to apply it to production is a
  deployment decision, owned by the thing that performs deployments.
- **CI gains no privilege.** Production is gated without the pipeline holding a cluster
  credential of any kind.

The trade-off, stated plainly: Git records `v1.2.0` for prod while prod runs the previous
version. That is not a GitOps violation — Git holds *intent* and ArgoCD surfaces the gap
rather than hiding it — but "Git equals the cluster" is only strictly true for dev.

### Where the environments genuinely differ

| | dev | prod |
|---|---|---|
| Ingress host | `my-app.192-168-56-101.nip.io` | `my-app-prod.192-168-56-101.nip.io` |
| Replica floor | 2 | 2 |
| HPA ceiling | 6 | 4 — shares a node, and an unreachable ceiling only produces Pending pods |
| Scale-down window | 300s | **600s** — shedding prod capacity on a brief lull is the expensive mistake |
| Grafana dashboard | owned by dev | off — the ConfigMap is keyed on a fixed uid, so two releases would fight over it |

---

## What production would do differently

The gap between this and a real setup, since the honest version of that answer is more
useful than pretending there isn't one.

**Two ArgoCD instances, not one.** A single instance managing both environments holds prod
credentials, which makes the dev-facing GitOps controller a production-privileged system —
so every dev-side convenience becomes a prod risk. Separate instances mean prod credentials
exist only in prod's instance, a compromise of dev tooling cannot reach prod, and an ArgoCD
upgrade can be tested in dev first. "Who can sync prod" becomes "who can log into prod
ArgoCD" rather than a fine-grained `AppProject` RBAC exercise.

**Separate clusters, not namespaces.** Which is what makes the `server:` field in each
Application meaningful rather than aspirational, and gives prod its own control plane and
resource budget.

**Promotion as a pull request.** Rather than the pipeline committing prod's digest and a
human syncing afterwards, the pipeline opens a PR against the GitOps repo and prod stays
fully auto-sync. The approval becomes a reviewable, attributable record enforced by branch
protection and CODEOWNERS, in the same place all other change control lives — and Git equals
the cluster for prod too, with no deliberate drift. Combined with two instances, prod's
ArgoCD only ever *sees* approved state.

That requires a credential the current design deliberately avoids: a deploy key can push a
branch but cannot open a PR. The right answer is a **GitHub App** scoped to the GitOps repo
with `contents: write` and `pull_requests: write` — not a personal access token.

**Automated promotion gates above a certain deploy frequency.** A human reading a one-line
digest diff is meaningful review at a few deploys a week. At high frequency it degrades into
rubber-stamping — control in appearance only. The replacement is Argo Rollouts with an
`AnalysisTemplate` querying Prometheus for error rate and latency, so promotion is decided by
evidence and rolls back automatically. The alerts already defined here —
`SampleNodejsHighErrorRate` in particular — are the kind of query such an analysis step runs.
Human approval then applies to genuinely high-risk changes rather than to every deploy.

**Kargo** is the purpose-built tool once there are more than two stages, or multiple regions.

---

## Decisions, and why

### Deployment, not StatefulSet

The brief asks for this one explicitly.

**A `Deployment`.** The application holds no state:

- **It writes nothing to disk.** `docker diff` on a running container is empty — which is also
  what makes `readOnlyRootFilesystem: true` viable
- **No replica needs a stable identity.** Nothing addresses a specific pod; any replica can
  serve any request
- **No persistent volume.** There is nothing to attach

A `StatefulSet` would buy stable network identities (`app-0`, `app-1`), ordered
rollout and per-replica `PersistentVolumeClaim`s. None of those are used here, and each has a
cost: rollouts become sequential rather than surging, scaling down is ordered and slower, and
deleting the workload leaves PVCs behind on purpose.

Put plainly: a StatefulSet would make this deployment slower and more fragile in exchange for
guarantees the app does not need. If it grew a local cache it wanted to survive a restart, or
became a clustered database with peer discovery, that calculation would change.

### A separate GitOps repository

The brief offers a choice — a dedicated GitOps repo, or ArgoCD reading the app repo directly —
and asks which and why. **Separate repo.** Four reasons:

**1. CI never holds a cluster credential.** This is the big one. The pipeline's whole deploy
authority is a deploy key that can write to one repository. There is no kubeconfig in GitHub
Actions and no inbound path to the cluster. If the app repo's CI were compromised tomorrow, the
attacker could publish a bad image and propose a bad version — but they could not `kubectl` into
anything.

**2. No CI recursion.** If the pipeline committed the version bump back into the repo it builds
from, that commit retriggers the pipeline. Avoiding it needs `[skip ci]` markers or path filters,
both of which are easy to get subtly wrong and silently break.

**3. Deployment history is separate from code history.** `git log` in the GitOps repo *is* the
deploy log — who deployed what, when, with the digest. `git revert` is the rollback, and it does
not revert application source at the same time.

**4. Least privilege scales.** Adding a second environment or a second cluster is an access-control
change in the GitOps repo, not in the repository developers push to daily.

**The costs, honestly:** two repos to keep in step, and a deploy is not atomic with its merge —
there is a gap between merging and ArgoCD syncing. Both are acceptable. The credential separation
is not something a single repo can give you.

### Private image, public chart

The brief requires the *image* in a private registry. The **image is private** (an anonymous pull
gets `403`); the **chart is public** (`200`).

That split is deliberate. The artifact containing code is private. The artifact *describing how to
deploy it* is readable — which means ArgoCD needs no registry credential for the chart, and a
reviewer can inspect or install the chart against their own registry without being handed a
credential. It directly serves the brief's other request: *"so we can easily deploy it"*.

### Digest, not tag

The GitOps repo pins `image.digest`, and the chart's image helper prefers digest over tag. A tag
is a mutable pointer — `:v1.0.0` can be repushed with different content, so what Trivy scanned
would not provably be what runs. A digest cannot move. Signing and the SBOM reference the digest
too.

Verified in [digest-and-registry-proof.txt](docs/evidence/digest-and-registry-proof.txt): the
deployment spec, both running pods, and the GitOps commit all carry the same `sha256:…`.

### ArgoCD is installed by a script, not self-managed

ArgoCD could manage itself through the app-of-apps, and it is a common pattern. It is installed by
[`scripts/bootstrap-vm.sh`](https://github.com/1bugo2/sample-nodejs-gitops/blob/main/scripts/bootstrap-vm.sh)
in the GitOps repo instead.

Reason: if ArgoCD breaks itself, you can no longer use ArgoCD to fix it. A script is the more
robust recovery path. This is not theoretical — the ArgoCD instance that was on this VM
*before* this exercise was self-managed, and was sitting in `Unknown` sync state when I found
it. What the app-of-apps *does* manage is the `AppProject`, the chart repository registration
and the environment `Application`s.

### The app itself was left alone

`app.js` is byte-identical to upstream. The only change to `package.json` is the Express bump that
a HIGH CVE forced.

Where a problem *looked* like it needed an application change, it was solved at the layer that
actually owns it:

| Problem | Application fix I did not make | Infrastructure fix I made |
|---|---|---|
| `SIGTERM` discarded | add a signal handler | `tini` at PID 1 |
| Traffic to a terminating pod | readiness gating in code | `preStop` + `maxUnavailable: 0` |
| `/classified` is public | remove the route | Ingress path allow-list |
| Missing security headers | add `helmet` | *not fixed* — noted below |

That last row is the honest one. The app sends no security headers, and adding `helmet` would be a
one-line improvement — but it is application work, not infrastructure work, so it is recorded here
as a recommendation rather than done silently.

---

## What the pipeline caught

Seven real problems surfaced while building this. Three were in the supplied app or its base
image, three were in **my own** pipeline, and one was an external service. None were found by
reading the code — each came from running the thing and looking at what happened.

### 1. A HIGH CVE in the app's dependencies

The dependency gate failed on its **very first run**:

```
path-to-regexp  0.1.12  →  fixed in 0.1.13
CVE-2026-4867  HIGH
ReDoS via catastrophic backtracking from malformed URL parameters
```

Pulled in transitively by Express 4.21.2. Fixed by raising the Express floor to `^4.22.2` —
bumping the *range*, not just refreshing the lockfile, because the lockfile alone leaves the
manifest claiming 4.21.2 is acceptable and anyone regenerating it reintroduces the CVE.

### 2. My own workflow used mutable action tags

Semgrep flagged `github-actions-mutable-action-tag` **on the PR that introduced the SAST job**,
which is a reasonable advertisement for the gate. Every action is now pinned to a commit SHA.

### 3. My own Dependabot config had no cooldown

Also flagged by SAST. A bot that upgrades the moment a version appears turns someone else's
stolen publish token into our running container as fast as possible. Compromised npm packages are
usually yanked within days, so there is now a 7-day cooldown. Security advisories bypass it, so
real CVE fixes still arrive immediately.

### 4. `SIGTERM` was being silently discarded

The one I would not have predicted. PID 1 gets no default signal handling — the kernel only
delivers a signal to it if the process installed a handler, and `app.js` installs none.

```
before (node as PID 1):   docker stop → 10.1s, ended in SIGKILL
after  (tini as PID 1):   docker stop → 0.15s
```

Found by *timing* `docker stop` in the smoke test rather than assuming exec-form `CMD` was
sufficient. The CI smoke test now asserts stop-time under 5s so it cannot regress.

### 5. The base image ships CRITICAL CVEs

`node:22-alpine` carries HIGH and CRITICAL findings — all from the dependency trees bundled with
the `npm` and `corepack` CLIs, none from Alpine or this app. Our own image gate blocked our own
image. Resolved by deleting the package managers from the runtime stage, which clears the CVEs
legitimately rather than suppressing them.

### 6. The pipeline promoted the image but never the chart version

The worst of the seven, because it was **silent**.

The release published chart `1.0.1` to GHCR while the ArgoCD `Application` still tracked `1.0.0`.
A change to a probe timing, a resource limit or a `securityContext` would have been built,
scanned, signed, pushed — **and then ignored by the cluster, with a green pipeline the whole way.**

It only surfaced by accident. `v1.0.1` came from a docs-only change, and its image digest came out
**byte-identical** to `v1.0.0` — `.dockerignore` excludes `*.md`, so nothing entering the build had
changed. That is reproducible builds working correctly, but it left nothing to roll back between,
and chasing *why* exposed the missing chart promotion.

Fixed in [PR #10](https://github.com/1bugo2/sample-nodejs/pull/10); verified by watching chart
`1.0.4` propagate through the app-of-apps into the cluster.

### 7. Keyless signing has no retry, and Sigstore had a bad minute

A release failed with:

```
Post "https://fulcio.sigstore.dev/api/v1/signingCert": connection reset by peer
```

Nothing wrong on our side — but keyless signing puts two external public services (Fulcio for the
certificate, Rekor for the transparency log) directly in the release path with no retry, so a
network blip anywhere fails an otherwise good release. Now retries with exponential backoff, and
deliberately still **blocking** rather than best-effort: a release that claims to be signed should
be signed.

The failure mode was at least safe — the image was pushed but nothing was tagged, released or
promoted, so the cluster stayed on the previous digest rather than ending up half-updated.

### And one thing I got wrong about my own gate

The first version of the NetworkPolicy included `ipBlock: 0.0.0.0/0` to stop kubelet probes being
blocked. That would have allowed ingress from *anywhere*, reducing the policy to decoration. I
caught it before committing, removed it, and **tested instead of guessing** — on this k3s cluster
kubelet probes are not filtered, so no allowance is needed. Verified by enabling the policy and
confirming probes kept passing with 0 restarts while a pod in another namespace was refused.

---

## Requirement traceability

| Requirement | Where | Evidence |
|---|---|---|
| Fork the sample app | this repo | — |
| Helm chart for easy deployment | [`charts/sample-nodejs/`](charts/sample-nodejs/) | `helm lint --strict` clean, kubeconform valid, `helm test` exits 0 |
| Deployment or StatefulSet, **with reasoning** | [Decisions](#deployment-not-statefulset) | — |
| Readiness and liveness probes | `deployment.yaml` — plus a `startupProbe` | [05](docs/evidence/screenshots/05-argocd-resource-tree.png) |
| Service and Ingress | `service.yaml`, `ingress.yaml` | [01](docs/evidence/screenshots/01-ingress-my-app.png), [03](docs/evidence/screenshots/03-ingress-classified-404.png) |
| Resource limits and requests | sized from measurement | [hpa-autoscaling.md](docs/evidence/hpa-autoscaling.md) |
| Other configs (secrets, configmaps…) | ConfigMap, Secret, ServiceAccount, HPA, PDB, NetworkPolicy, ServiceMonitor, values schema, `helm test` | [05](docs/evidence/screenshots/05-argocd-resource-tree.png) |
| **Version bumping / git workflow** | SemVer from Conventional Commits → tag; GitHub Flow, protected `main` | [09](docs/evidence/screenshots/09-github-release-v1.0.0.png) |
| **SAST, fail on critical** | Semgrep, gates on `ERROR` | caught mutable action tags + missing cooldown |
| **Image scan, block on high** | Trivy **before** the push | [07](docs/evidence/screenshots/07-release-pipeline-steps.png), [security-gate-blocks-merge.md](docs/evidence/security-gate-blocks-merge.md) |
| Bonus tooling | Gitleaks, `npm audit`, hadolint, kubeconform, Checkov, Dependabot + cooldown, SBOM, cosign, SHA-pinned actions | — |
| Build and dockerize | multi-stage `Dockerfile`, buildx | [Container image](#the-container-image) |
| **Push to a private registry** | private GHCR | [08](docs/evidence/screenshots/08-ghcr-image-private.png), anonymous pull → `403` |
| **Deploy to Kubernetes via the pipeline** | pipeline commits the digest; ArgoCD reconciles | [04](docs/evidence/screenshots/04-argocd-applications-synced.png) |
| **ArgoCD + GitOps, with reasoning** | [Decisions](#a-separate-gitops-repository) | [06](docs/evidence/screenshots/06-argocd-application-manifest.png) |
| App deployed successfully | `Synced / Healthy` | [01](docs/evidence/screenshots/01-ingress-my-app.png) |
| Repo links + screenshots | [`docs/evidence/`](docs/evidence/) | — |

---

## Running it yourself

**The image is private**, as the task requires, so you cannot pull it — a credential cannot
be shipped in a public repo, and Kubernetes has no way to acquire one it was not given. Either
use [`docs/evidence/`](docs/evidence/), which is what the brief means by *"access to your
cluster **or** screenshots"*, or build the image and point the chart at your own registry:

```bash
docker build -t <your-registry>/sample-nodejs:1.0.0 .
docker push  <your-registry>/sample-nodejs:1.0.0

helm install app oci://ghcr.io/1bugo2/charts/sample-nodejs --version 1.1.0 \
  --namespace sample-nodejs --create-namespace \
  --set image.repository=<your-registry>/sample-nodejs \
  --set image.tag=1.0.0 \
  --set ingress.host=<your-hostname>

helm test app -n sample-nodejs
```

The chart itself is public, so no credential is needed to fetch it.

### Rebuilding the cluster from scratch

```bash
git clone https://github.com/1bugo2/sample-nodejs-gitops.git && cd sample-nodejs-gitops
./scripts/bootstrap-vm.sh          # k3s + Traefik + metrics-server + ArgoCD, idempotent

kubectl create namespace sample-nodejs
kubectl -n sample-nodejs create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<read:packages token>

kubectl apply -f bootstrap/root-app.yaml   # the only manual apply; everything else follows
```

That script exists because a host restore wiped this VM mid-exercise and none of the original setup
had been recorded. Rebuilding it by hand cost an afternoon; the script does it in about eight
minutes. Setup that only exists in someone's shell history is not reproducible.

### Rolling back

```bash
cd sample-nodejs-gitops
git revert <the deploy commit>
git push
```

ArgoCD syncs the previous digest. No `kubectl`, no `helm rollback`, and the rollback is itself a
reviewable commit. Verified zero-downtime — requests returned `200` throughout, captured in
[gitops-rollback.md](docs/evidence/gitops-rollback.md).

---

## Known gaps

Things a reviewer would reasonably ask about, stated rather than hidden.

**No test stage.** The app shipped npm's default `test` placeholder (`exit 1`) and no tests. The
brief does not require a test stage, and I chose not to author application tests for an
infrastructure exercise rather than add a stub that asserts nothing. The pipeline instead verifies
the *artifact* — the image is started and its endpoints are asserted before it can be published.

**No TLS.** The Ingress serves plain HTTP. The chart supports `ingress.tls.enabled`, but there is no
resolvable public DNS name for this VM, so cert-manager could not complete an ACME challenge. A
self-signed certificate would prove nothing.

**No security headers, and no WAF — deliberately, not as an oversight.** The app sends no
`X-Content-Type-Options`, `X-Frame-Options`, CSP or `Referrer-Policy`, and stock Express
advertises `X-Powered-By: Express`. A baseline DAST scan would flag all of that.

Those are **edge concerns, and this cluster is not the edge.** In production the chain is
CDN/WAF → load balancer → ingress → app, and response headers, TLS termination, rate
limiting, bot protection and OWASP rule sets belong at that first hop — owned by whoever owns
the edge, applied once for every service behind it.

Implementing them at the cluster ingress instead would put them at the wrong layer, duplicate
what the edge already owns, and couple the chart to one ingress controller. So the honest
position is that this layer is out of scope for this exercise rather than missing from it.

The consequence to be clear about: **as deployed, behind nothing, this app has no security
headers.** That is a property of an exercise with no edge tier, not a recommendation.

**No DAST.** All gates are static analysis. DAST tests a *deployed* application, and the
deployed application is meant to sit behind the edge tier above — so scanning the bare
container in CI would test a topology that never serves traffic, and report findings that the
edge layer is responsible for. CI also cannot reach the cluster, which is the point of the
GitOps isolation rather than a limitation to work around.

**Single node.** No real topology spread, no multi-node failure testing, and the PDB can only be
demonstrated rather than exercised against a genuine drain.

**"prod" is a namespace, not a production environment.** Two environments exist and promotion
between them works, but they share one node with ArgoCD and the monitoring stack — so a load
test in dev can starve prod. See [Environments and promotion](#environments-and-promotion) for
what is real about it and [What production would do differently](#what-production-would-do-differently)
for the gap.

**One ArgoCD instance manages both environments**, which means the dev-facing GitOps
controller holds prod credentials. Separate instances per environment is the correct answer
and is described above.

**The pull secret holds a broader token than it should.** It should be scoped to `read:packages`
only. It is a throwaway lab credential and will be revoked, but least privilege is the correct
answer and this is not it.

---

## Evidence

[`docs/evidence/`](docs/evidence/) — 9 screenshots and 4 captured-output documents, indexed with
what each one shows.

Live things that can be checked without any access to the cluster:

- [**PR #8**](https://github.com/1bugo2/sample-nodejs/pull/8) — deliberately left open and failing.
  `PR gate` is red and GitHub refuses the merge
- [**Actions history**](https://github.com/1bugo2/sample-nodejs/actions) — every PR run and release
- [**GitOps commit log**](https://github.com/1bugo2/sample-nodejs-gitops/commits/main) — the deploy
  history, including the revert
