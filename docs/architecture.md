# Full-stack architecture

## Topology

| Topology | Services on the monitoring target | Client-cluster telemetry |
| --- | --- | --- |
| `central` | Mimir, Alertmanager, Grafana, Loki | Alloy, kube-state-metrics, node-exporter, kubelet and configured control-plane scraping for the central cluster |
| `local` | Mimir, Alertmanager, Grafana, Loki on the tenant/local target | The same collectors for the local target, with local Mimir rule evaluation |
| `client` | None | Alloy, kube-state-metrics, node-exporter, kubelet and reviewed control-plane targets ship to central Mimir/Loki endpoints |

Mimir is the **only** metrics backend and recording/alerting rule evaluator. No Prometheus server or kube-prometheus-stack dependency is deployed. Prometheus-compatible metric exposition, PromQL, remote-write, and rule YAML are interfaces used by Alloy, Mimir, and promtool.

Alertmanager runs as the pinned Mimir chart's managed component. Loki provides logs; Grafana provides provisioned folders/dashboards and Mimir/Loki datasources. Scrape topology lives only in the chart/RGD. Alloy carries telemetry, never dashboard or rule assets.

## Packaging and deployment

`packages/monitoring-stack/rgd.yaml` creates an ArgoCD Application for the fixed signed `monitoring` OCI chart. The source `targetRevision` is the exact OCI digest; the compatible chart version is retained as immutable evidence rather than used as a mutable deployment selector. KRO reports status from the actual Application. `observability/` is canonical for dashboards/rules; the pinned workflow generator produces chart and `observability-pack` outputs with fail-on-diff. Rule ConfigMaps use Mimir's filesystem ruler path; no API writer, puller, PR bot, or raw observability OCI bundle exists.

Inari-managed charts disable chart-native observability when using a companion. Existing catalog admission, resource-target resolver, DeploymentPlan, source-agnostic renderer, and generic verification services own their respective seams. No component in this repository implements a replacement renderer or hub-originated Grafana call.

## Testing boundary

Monitoring is explicitly `archetype: stack` under app config v2. The shared workflow owns central setup pins, exact-content caching, one fresh kind cluster, install+upgrade sequencing, diagnostics, cleanup, and source-bound evidence. `tests/stack` retains the real KRO/ArgoCD/OCI central/local/client and pack wiring, exact-digest upgrade, and preserved PVC/org/client endpoint assertions. Alloy/post-label, targeted Mimir filesystem-ruler delivery, Grafana provisioning, and readiness adapters remain kind-less suites. Install/upgrade evidence is neither upstream functional E2E nor deployed production readiness.

## Readiness and access boundary

The signed read-only Argo suite checks folder, dashboard, datasource, panel-query, and selected Mimir rule-group evidence. It does not install another copy, provision Grafana identities, synchronize teams, map principals, or assert folder ACLs. Existing Inari organization/target grants and generic verification RBAC/egress controls remain separate and authoritative. Links appear only after current, unexpired, fully bound evidence reaches the existing outbound verification path.

Sibling renderer/multi-repo Phase 3 remains the hard stop for companion/Workflow rendering, associated Git writes, and deployed runs. Release and production sync require their own approvals.
