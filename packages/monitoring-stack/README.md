# monitoring-stack

KRO-managed full Kubernetes observability stack. The RGD creates an ArgoCD `Application` for the signed `monitoring` chart from the fixed `oci://ghcr.io/7k-hiroba/monitoring/charts/monitoring` repository. Every instance requires an exact chart version and SHA-256 OCI digest; the digest is the source `targetRevision`, so no channel or mutable tag is resolved.

## Topology

- `central`: Mimir, Alertmanager, Grafana, and Loki plus Alloy, kube-state-metrics, node-exporter, and kubelet/control-plane collection for the monitoring cluster.
- `local`: the same services on a tenant/local monitoring target, with local Mimir rule evaluation and client collectors.
- `client`: no central services; Alloy, kube-state-metrics, node-exporter, and kubelet/control-plane collection ship telemetry to explicitly configured central Mimir/Loki endpoints.

**Mimir is the only metrics backend and rule evaluator. No Prometheus server or `kube-prometheus-stack` dependency is deployed.** Prometheus-compatible metric exposition, PromQL, remote-write, and rule formats are interfaces used by Alloy, Mimir, and promtool.

Mimir and Loki require production object storage and retention configuration. `ephemeralObjectStorage` is only for isolated kind/CI fixtures and must not be enabled by production policy. For Loki, set the non-secret S3 endpoint/region/bucket fields and optionally name an existing namespace Secret containing `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`; credentials are never embedded in this package. The required `org` field is propagated to every post-Alloy metric series.

See `docs/architecture.md`, `docs/onboarding.md`, and `docs/runbook.md` for target registration and operational gates.
