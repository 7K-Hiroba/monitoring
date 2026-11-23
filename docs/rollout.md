# Rollout plan

1. Land reviewed chart/RGD/pack/contracts and the coordinated API/server consumers. Do not create tags, releases, stable channels, or GHCR artifacts from an ordinary Work/PR run.
2. After an explicitly approved release, verify exact OCI digests, cosign publisher identity, SLSA provenance, and signed test evidence. Record the chart, stack package, observability pack, and suite identities.
3. Use a non-production staged or canary target. Deploy central/local/client topology through the KRO/RGD → reviewed baseline PR → ArgoCD path, with platform CODEOWNERS, policy/resource limits, and target grants. The renderer/multi-repo Phase 3 gate must be independently confirmed first.
4. Verify Mimir, Alertmanager, Grafana, Loki, Alloy, kube-state-metrics, node-exporter, kubelet, and configured control-plane coverage. Confirm no Prometheus server is installed.
5. Run the approved read-only suite against the existing companion and confirm folder/dashboard/datasource/rule evidence, outbound reporting, and readiness-gated links. No install adapter or direct Grafana call is allowed.
6. Review canary evidence and operational limits before any further promotion. Production central-baseline changes and production sync require separate explicit owner/platform approval; this document does not grant it.

Rollback uses a reviewed GitOps revert to compatible exact pins. A failed verification never automatically rolls back or mutates the application. Report any not-run stage/prod or production evidence explicitly.
