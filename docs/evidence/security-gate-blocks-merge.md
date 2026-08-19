# Evidence: the security gates block a merge, they do not merely report

A gate that reports but cannot stop anything is documentation. This is a deliberate
demonstration that the gates have teeth, kept as
[PR #8](https://github.com/1bugo2/sample-nodejs/pull/8). Opened to fail, never merged.

## What was planted

```diff
   "dependencies": {
     "express": "^4.22.2",
     "prom-client": "^15.1.3",
+    "lodash": "4.17.20"
   }
```

A real, well-known, fixable HIGH advisory, not a synthetic marker file.

## What caught it

Two **independent** gates, at two different layers:

### 1. `Dependency scan`: the source

Trivy against the lockfile:

```
Total: 2 (HIGH: 2, CRITICAL: 0)

│ lodash │ CVE-2021-23337 │ HIGH │ fixed │ 4.17.20 │ 4.17.21 │ command injection via template
│        │ CVE-2026-4800  │      │       │         │ 4.18.0  │ arbitrary code execution via untrusted input
```

`npm audit` independently agreed with `1 high severity vulnerability`, which is the point of
running both: they draw on different advisory databases, and agreement raises confidence
while disagreement is itself signal.

### 2. `Image build, smoke test and scan`: the artifact

The same vulnerability was caught *again* by the Trivy **image** scan, because `lodash`
ends up inside `node_modules` in the built image. Defence in depth: even if a dependency
slipped past the source scan, it would not reach the registry.

## The merge was actually refused

Not just a red tick. Attempting the merge over the API, **as the repository owner**:

```
PUT /repos/1bugo2/sample-nodejs/pulls/8/merge
→ HTTP 405
   "All comments must be resolved. Required status check "PR gate" is failing."

GET /repos/1bugo2/sample-nodejs/pulls/8
→ mergeable_state: blocked
```

That refusal applies to the owner because branch protection sets `enforce_admins: true`.
A gate an administrator can walk past is a suggestion, not a control.

## Where a real deploy would have stopped

```
PR opened ──► Dependency scan  FAIL ──┐
              Image scan       FAIL ──┼──► PR gate FAIL ──► merge REFUSED
              Secret scan      ok     │                          │
              SAST             ok     │                    release workflow
              Chart            ok  ───┘                    never runs
                                                                 │
                                                    nothing pushed to the registry
                                                    nothing promoted to GitOps
                                                    cluster state unchanged
```

The vulnerable code never reached `main`, so the release pipeline never ran, so no image
was published and no digest was promoted. The cluster was never at risk, which is the
difference between blocking at the gate and detecting after deployment.
