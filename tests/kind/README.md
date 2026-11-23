# Hosted kind install/upgrade contract

`test-stack.sh` uses **one disposable kind cluster** to exercise the real KRO → ArgoCD → OCI-chart path. It intentionally follows the chart install/upgrade boundary rather than running a functional telemetry E2E matrix.

## Install

- Package a CI-only previous compatible fixture from the current chart with `-ci.0` prerelease metadata. The repository has no earlier released chart; this fixture is never published outside the disposable in-cluster registry.
- Reconcile central, local, and client `MonitoringStack` inputs through the real RGD and ArgoCD. Require the expected digest/version evidence, `Healthy`/`Synced` Applications, ready KRO instances, completed workload rollouts, and expected client collector resources.
- Verify the observability-pack's KRO resources and central/local isolation, and confirm that no Prometheus server is introduced.

## Upgrade

- Re-render the same three instances with the current chart's distinct exact OCI digest and compatible version. Reuse the cluster, ArgoCD, registry, and applications.
- Require health/sync and KRO readiness at the **current** digest/version, repeat rollout convergence, preserve the organization and client remote endpoints, and preserve the central ingester PVC identity.

## What this does not prove

Install/upgrade convergence is not functional production readiness. Alloy transformations/shipping, Mimir query/rule behavior, Loki queries, Alertmanager behavior, and Grafana provisioning/datasource/panel behavior belong to the kind-less unit, component, Docker, and fake-API suites (`scripts/test-alloy-pipeline.sh`, `tests/grafana/test-provisioning.sh`, and `tests/unit/`). The read-only WorkflowTemplate is separately validated by the runtime-smoke lane. Actual renderer-driven GitOps dogfood and deployed stage/prod verification remain Phase 3 and owner-approval gated.

The shared executor host's inotify limit still prevents local kind creation. Do not change host sysctls or shared clusters; run this scoped lane in hosted CI.
