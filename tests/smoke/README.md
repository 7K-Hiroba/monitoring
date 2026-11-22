# Observability readiness suite

This signed, versioned Argo WorkflowTemplate verifies an **existing** observability companion: Grafana folder and dashboards, the selected Mimir/Prometheus-compatible datasource, panel queries, selected Mimir rule-group evaluation, and optionally Loki label health. It emits `ObservabilityVerificationResult` through the existing `inari-verification-outcome` parameter and makes no identity, team-sync, or folder-access claim.

The `ci` chart adapter may install the chart only into an ephemeral CI cluster. Stage/prod runs never execute that adapter, install another copy, create resources/RBAC, or mutate desired state. The platform renderer binds `inari.observability.params.v1` context (exact companion/app/pack/target/suite/run identities, folder, dashboards, datasources, rule groups, and approved endpoints), the preapproved ServiceAccount, read-only credentials, and egress. The suite itself accepts no secret reference or arbitrary target binding.

Profiles are the generic verifier's actual `ci`, `stage`, and `prod` grant profiles. Evidence expires after one hour and must still pass every server-side identity/generation/revision check before links appear.

No deployed/stage/prod run is authorized by this repository while sibling Phase 3 is unconfirmed. Local kind execution is required in hosted CI; executor-local host limitations must be reported rather than skipped silently.
