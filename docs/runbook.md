# Operations runbook

## Health and diagnostics

- Mimir: check gateway/distributor/ingester/querier/ruler readiness, object storage, ingestion, and `/prometheus/api/v1/rules` evaluation. Never install Prometheus to compensate for a Mimir fault.
- Alertmanager: check the Mimir-managed StatefulSet and `/alertmanager/api/v2/status`; review routing configuration through the approved chart change.
- Loki: check single-binary/gateway health, object/filesystem storage, retention, and `/loki/api/v1/labels` or an approved read-only log query.
- Grafana: inspect sidecar logs, ConfigMap folder annotation, dashboard UID/folder, Mimir/Loki datasource resolution, and panel query errors.
- Alloy/client collectors: inspect scrape/remote-write/Loki delivery, service discovery, and read-only RBAC for nodes, kubelet, kube-state-metrics, node-exporter, workloads, and configured control-plane targets.
- KRO/ArgoCD: inspect RGD conditions, generated Application source digest, policy denial, sync health, and resource limits. Application health alone is not observability readiness.

## Changes and recovery

Make upgrades, storage changes, rule changes, and recovery through reviewed GitOps pull requests with exact chart/package/suite pins. Roll back by reverting to a previously reviewed compatible desired state; there is no verification-driven automatic rollback. Preserve Mimir/Loki data and object-store retention before any destructive action, which needs a separate change approval.

For failed readiness, keep links disabled, collect the target-side run and component diagnostics, correct the cause through an approved change, and run fresh verification. Do not reuse expired or wrong-generation evidence.

The read-only verification suite has no authority to install, repair, or mutate the stack. No Grafana identity/team/folder ACL recovery is part of this repository.
