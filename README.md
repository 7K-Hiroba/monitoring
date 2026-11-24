# 7K-Hiroba monitoring

Full Kubernetes observability for Hiroba/Inari: **Mimir, Alertmanager, Grafana, Loki, Alloy, kube-state-metrics, node-exporter, and kubelet/control-plane collection**, packaged as a KRO-managed stack with canonical dashboards/rules and target-side readiness.

Mimir is the only metrics backend and rule evaluator. No Prometheus server or kube-prometheus-stack dependency is installed; Prometheus-compatible exposition, PromQL, remote-write, and rule formats are interfaces used by Mimir and tooling.

## Layout

- `charts/monitoring`: pinned central/local/client stack chart.
- `packages/monitoring-stack`: KRO RGD and exact-digest ArgoCD Application contract.
- `observability/`: canonical dashboards, central/local rules, and real Alloy fixtures.
- `packages/observability-pack` and `charts/monitoring/{templates/observability,inari}`: generated, fail-on-diff outputs.
- `contracts/post-alloy-labels`: versioned telemetry-label contract.
- `tests/`: unit, real Alloy/Mimir rule-delivery, ephemeral Grafana, shared stack-lifecycle, and read-only readiness references.

See `docs/architecture.md`, `docs/onboarding.md`, `docs/readiness.md`, `docs/runbook.md`, and `docs/rollout.md`. The inari-catalog fresh-import attribution is in `docs/migration/inari-catalog.md`.

## Development and gates

Use Conventional Commits and immutable workflow/action SHAs. Run unit tests, regeneration checks, real Alloy/promtool/Mimir rule-delivery tests, ephemeral Grafana tests, and the hosted stack/workflow lanes before review. The app-config-v2 `archetype: stack` requires complete `tests/stack` install+same-cluster-upgrade coverage and exact-head evidence. Never edit generated outputs directly. Install/upgrade is not functional production readiness.

The repository is private/pre-v1. Publication, release, companion/Workflow rendering, baseline writes, deployed stage/prod runs, and production sync require their separate approvals. No Grafana identity synchronization, team/principal mapping, folder ACLs, direct-write reconciler, raw observability OCI bundle, puller, PR bot, or embedded UI is included.
