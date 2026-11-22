# observability-pack

Generated KRO companion for the monitoring app. Canonical assets live in `observability/`; edit them and run the pinned renderer rather than editing `rgd.yaml`.

The pack creates the selected Grafana folder/dashboards, the chosen central or local PrometheusRule, and a same-gated rule ConfigMap for Mimir's filesystem ruler. Dashboard ConfigMaps carry the selected folder annotation. It contains no Grafana identity, team-sync, principal mapping, folder ACL, or access-readiness resource.

Use exact pack versions/digests and `render: all` with only one of `rulesCentral` or `rulesLocal`. The generic DeploymentPlan owns that server-side selection and disables chart-native observability for managed deployments.
