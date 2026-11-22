# monitoring chart

Full Kubernetes observability chart using exactly pinned upstream dependencies:

- Mimir (`mimir-distributed` 6.2.2) is the only metrics storage and rule-evaluation backend; its managed Alertmanager provides alert routing.
- Grafana 14.5.0 and Loki 7.7.0 provide visualization and logs.
- Alloy 1.6.0 (runtime v1.13.0), kube-state-metrics 9.0.1, and node-exporter 5.2.0 provide client telemetry, with kubelet and explicitly configured control-plane coverage.

No Prometheus server or `kube-prometheus-stack` dependency is deployed. Prometheus-compatible exposition, PromQL, remote-write, and rule formats are interfaces only.

`topology` and `global.topology` must both be `central`, `local`, or `client`. Client targets disable central/local services and require `global.telemetry.remoteWriteUrl` and `global.telemetry.lokiPushUrl`. Production Mimir/Loki object storage, retention, credentials, ingress, and resource limits are environment-owned. The `ci/*-values.yaml` filesystem/MinIO settings are isolated test fixtures, not production defaults.

Inari-managed chart-native observability remains disabled by default; the signed companion pack provisions the selected dashboards/rules. Standalone Helm users can opt into generated `observability/` resources explicitly.
