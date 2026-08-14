# Evidence: rollback is `git revert`

No `kubectl`, no `helm rollback`, no clicking in a UI. The rollback is a commit, which
means it is reviewable, attributable and itself revertible.

## Before

```
deployed digest : sha256:1eadadcefe33566ab45c55680f12ecde3df58bbe9711ee0d6c9dd47ee0fdbd97   (v1.0.2)
chart tracked   : 1.0.2
```

## The rollback

```bash
git revert --no-edit 54d0b02     # the "deploy(dev): sample-nodejs v1.0.2" commit
git push
```

That is the entire operation. It restored both fields the release pipeline had advanced:

```
 argocd/applications/sample-nodejs-dev.yaml | 6 +++++-
 envs/dev/values.yaml                       | 4 ++--
```

## After

ArgoCD reconciled on the next poll:

```
argocd: Synced/Healthy
image:  ghcr.io/1bugo2/sample-nodejs@sha256:c7ff9100255dde1f96964e182901372848faa99dfe055f230242adf1c7f131ef
chart:  1.0.0
```

## It was zero-downtime

Mid-rollback, with old and new pods overlapping:

```
sample-nodejs-dev-5fd8ccb994-85ghr   1/1   Terminating
sample-nodejs-dev-75c69d87fc-m4s8b   1/1   Terminating
sample-nodejs-dev-8bcc47b9d-ntnxb    1/1   Running
sample-nodejs-dev-8bcc47b9d-x52xm    1/1   Running
```

Requests through the Ingress during and after:

```
200  200  200  200  200
```

Two chart settings produce that. `maxUnavailable: 0` means a replacement pod must pass its
readiness probe before an old one is removed. The `preStop` sleep of 5s holds a terminating
pod open while the endpoints controller de-registers it, so in-flight requests are not cut
off — necessary because `tini` makes node exit almost immediately on SIGTERM, leaving no
natural drain window.

## The deploy log

`git log` in the GitOps repo *is* the deployment history:

```
d5527b1  Revert "deploy(dev): sample-nodejs v1.0.2"
54d0b02  deploy(dev): sample-nodejs v1.0.2
1bdf622  deploy(dev): sample-nodejs v1.0.1
059fbe3  feat: add app-of-apps root application
93f2536  feat: add dev Application tracking chart 1.0.0
```

Every line is a state change to the cluster, with an author and a timestamp, obtained
without any audit tooling.

## A bug this exercise found

The first attempt at this demonstration could not proceed, and the reason was informative.

`v1.0.1` was released from a **docs-only** change, and its image digest came out
**byte-identical** to `v1.0.0` — `.dockerignore` excludes `*.md`, so nothing entering the
build had changed. Reproducible builds working correctly, but it left nothing to roll back
between.

Investigating that surfaced a real defect: the release pipeline promoted the **image
digest** but never the **chart version**. Chart `1.0.1` sat published in GHCR while the
Application still tracked `1.0.0`. A change to a probe timing, a resource limit or a
securityContext would have been built, scanned, signed, pushed — and then silently ignored
by the cluster, with a green pipeline the whole way. Fixed in
[PR #10](https://github.com/1bugo2/sample-nodejs/pull/10), which also added OCI provenance
labels so that a running container is traceable to the commit that built it.
