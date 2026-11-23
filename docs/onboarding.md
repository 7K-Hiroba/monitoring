# Target onboarding

1. Create the stack through the KRO RGD and reviewed ArgoCD GitOps path using an exact chart version/digest. Select `central`, `local`, or `client`; never use a mutable channel.
2. Verify Mimir, Alertmanager, Grafana, Loki, and client collectors required by that topology are healthy. Client targets need explicit central Mimir/Loki endpoints and platform-approved network policy.
3. Register or adopt `monitoring.grafana` through the existing resource-target API. Use either the existing concrete Helm-addon evidence or `instanceId` plus the expected source-qualified catalog item for a running, synced, digest-bound KRO instance.
4. Configure HTTPS base URL, central/local evaluation, folder prefixes, datasource allowlists, approval teams, and one provider default only when policy allows. Existing Inari `view` and `provision` grants control visibility and submission and are rechecked at submit time.
5. Import the exact signed readiness suite and create the environment's exact digest+profile grant with preapproved ServiceAccount, RBAC, credentials, and egress. Actual profiles are `ci`, `stage`, or `prod`.

No Keycloak group is created for Grafana folder access, and no Grafana team sync, principal/team/ID mapping, or folder ACL is provisioned. Existing platform identity and target RBAC are not a substitute for target-side folder/dashboard/datasource/rule evidence.

Sibling Phase 3 confirmation is required before companion/Workflow rendering, baseline writes, or deployed runs. Production sync requires separate explicit approval.
