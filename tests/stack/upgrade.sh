#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$HIROBA_STACK_ROOT/tests/stack/lifecycle-lib.sh"

CHART_VERSION=$(helm show chart "$ROOT/charts/monitoring" | awk '/^version:/ {print $2}')
push_chart_version "$CHART_VERSION" "$WORK/current"
CHART_DIGEST=$PUSHED_DIGEST
[[ "$CHART_DIGEST" != "$(jq -r .contentDigest "$WORK/install-result.json")" ]]
CONTROL_PLANE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${HIROBA_STACK_CLUSTER}-control-plane")
[[ -n "$CONTROL_PLANE_IP" ]]
${HIROBA_PYTHON:-python3} "$ROOT/tests/stack/render-local.py" --root "$ROOT" --work "$WORK" \
  --registry "$REGISTRY_HOST" --digest "$CHART_DIGEST" --chart-version "$CHART_VERSION" \
  --control-plane "${CONTROL_PLANE_IP}:6443"
kubectl apply -f "$WORK/central.yaml" -f "$WORK/local.yaml" -f "$WORK/client.yaml"
for app in monitoring-central monitoring-local monitoring-client; do
  wait_for_application "$app" "$CHART_DIGEST" "$CHART_VERSION"
  test "$(kubectl get application "$app" -n argocd -o jsonpath='{.spec.source.helm.valuesObject.global.telemetry.org}')" = ci
  wait_for_stack "${app#monitoring-}"
done
assert_stack_rollouts
assert_observability_pack

INGESTER_PVC=storage-monitoring-central-mimir-ingester-0
CLIENT_REMOTE_WRITE=$(cat "$WORK/client-remote-write")
CLIENT_LOKI_PUSH=$(cat "$WORK/client-loki-push")
test "$(kubectl get pvc "$INGESTER_PVC" -n monitoring -o jsonpath='{.metadata.uid}')" = "$(cat "$WORK/ingester-pvc-uid")"
test "$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.global.telemetry.remoteWriteUrl}')" = "$CLIENT_REMOTE_WRITE"
test "$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.global.telemetry.lokiPushUrl}')" = "$CLIENT_LOKI_PUSH"
write_phase_result upgrade "$CHART_VERSION" "$CHART_DIGEST"
