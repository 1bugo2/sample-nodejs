## What

<!-- One or two sentences. What does this change do? -->

## Why

<!-- The reason this is worth doing. Link an issue if there is one. -->

## Notes for the reviewer

<!-- Tradeoffs considered, alternatives rejected, anything non-obvious in the diff. -->

## Checklist

- [ ] Commit messages follow Conventional Commits (drives the SemVer bump on merge)
- [ ] `PR gate` is green (secret scan, SAST, dependency scan)
- [ ] Kubernetes/Helm changes rendered locally with `helm template` before pushing
- [ ] No secrets, tokens, or kubeconfigs in the diff
