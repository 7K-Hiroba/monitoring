# Readiness contract

The monitoring suite verifies the folder, every declared dashboard and panel query, each panel's resolved datasource against the selected UID, and each selected Mimir rule group against an existing companion. Rule evidence requires a successful query, healthy rule state, and no evaluation error. Optional Loki label health proves log-query connectivity. It produces folder/dashboard/datasource/rule evidence only; there is no access-readiness field or identity/ACL claim.

The result binds companion ID/generation, target ID/revision/cluster, plan and app instance/revision/digest, pack item/version/digest, capability digest, suite digest and actual generic `ci`/`stage`/`prod` profile, run ID/attempt/finish time, and expiry. The generic verifier authenticates the existing outbound agent stream and checks its run, environment grant, policy, and target before calling the deployment-plan consumer. The consumer repeats the subject-specific checks and applies the existing readiness state machine.

Pending, failed, stale, expired, revoked, or cancelled evidence never produces links. KRO or ArgoCD health alone never produces links. The suite has no public result endpoint, new agent stream, suite-created RBAC, install adapter in a real environment, or hub-originated Grafana call.

The workflow artifact is packaged and signed only through the approved release process. Exact suite digest+profile grants, platform-owned ServiceAccount/credentials/egress, resource limits, and staged/canary review are required before any deployed execution.
