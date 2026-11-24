# Hosted stack install/upgrade contract

The classified monitoring stack uses the shared `test-stack.yml` lifecycle and **one disposable kind cluster per job**. The workflow library owns the central kind/KRO/ArgoCD/tool pins, exact-content cache, disposable OCI registry, diagnostics, evidence, and cleanup. Consumer phases own only monitoring fixtures and assertions.

For pull requests, the check's `head_sha` remains associated with the reviewed PR head while the default checkout tests the exact merge tree. Evidence `sourceSha` records that merge tree; record both identities when citing hosted results. Push and release callers bind evidence to their exact pushed or released source.

## Install

- Package the current compatible chart with CI-only `-ci.0` prerelease metadata because no earlier released chart exists. Push it only to the disposable in-cluster registry and resolve its actual OCI digest.
- Reconcile central, local, and client `MonitoringStack` inputs through the real RGD and ArgoCD. Require the expected digest/version, Healthy/Synced Applications, ready KRO instances, completed rollouts, and expected client collectors.
- Verify observability-pack resources and central/local isolation, and confirm that no Prometheus server is introduced.
- Record the organization, client endpoints, and central ingester PVC identity for the upgrade.

## Upgrade

- Package and push the current chart with a distinct exact OCI digest. Re-render the same three instances and reuse the same cluster, registry, and Applications.
- Require health/sync and KRO readiness at the current digest/version, repeat rollout and pack convergence, and preserve the organization, client endpoints, and PVC UID.

## What this does not prove

Install/upgrade convergence is not functional production readiness. Alloy transformations/shipping, targeted Mimir rule delivery, Loki/Grafana behavior, and readiness-result validation belong to the kind-less unit/component/container suites. The read-only WorkflowTemplate remains a separate runtime-smoke lane. Actual renderer-driven GitOps dogfood and deployed stage/prod verification remain Phase 3 and owner-approval gated.

Do not run kind on the shared executor host or change host sysctls. Run this lane in GitHub-hosted CI.
