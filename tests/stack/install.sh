#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$HIROBA_STACK_ROOT/tests/stack/lifecycle-lib.sh"

CHART_VERSION=$(helm show chart "$ROOT/charts/monitoring" | awk '/^version:/ {print $2}')
[[ "$CHART_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
PREVIOUS_CHART_VERSION="${CHART_VERSION}-ci.0"
push_chart_version "$PREVIOUS_CHART_VERSION" "$WORK/previous"
PREVIOUS_CHART_DIGEST=$PUSHED_DIGEST
CONTROL_PLANE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${HIROBA_STACK_CLUSTER}-control-plane")
[[ -n "$CONTROL_PLANE_IP" ]]
${HIROBA_PYTHON:-python3} "$ROOT/tests/stack/render-local.py" --root "$ROOT" --work "$WORK" \
  --registry "$REGISTRY_HOST" --digest "$PREVIOUS_CHART_DIGEST" --chart-version "$PREVIOUS_CHART_VERSION" \
  --control-plane "${CONTROL_PLANE_IP}:6443"

cat > "$WORK/argocd-project.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  sourceRepos:
    - oci://$REGISTRY_HOST/charts/monitoring
  destinations:
    - {server: https://kubernetes.default.svc, namespace: monitoring}
    - {server: https://kubernetes.default.svc, namespace: monitoring-local}
    - {server: https://kubernetes.default.svc, namespace: monitoring-client}
  clusterResourceWhitelist:
    - {group: "*", kind: "*"}
EOF
kubectl apply -f "$WORK/argocd-project.yaml"
cat > "$WORK/argocd-repository.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: monitoring-kind-oci
  namespace: argocd
  labels: {argocd.argoproj.io/secret-type: repository}
stringData:
  type: oci
  name: monitoring-kind
  url: oci://$REGISTRY_HOST/charts/monitoring
  enableOCI: "true"
  insecureOCIForceHttp: "true"
EOF
kubectl apply -f "$WORK/argocd-repository.yaml"
kubectl apply -f "$WORK/rgd.yaml"
kubectl wait --for=condition=Ready rgd/monitoring-stack --timeout=120s
kubectl apply -f "$WORK/central.yaml" -f "$WORK/local.yaml" -f "$WORK/client.yaml"
for app in monitoring-central monitoring-local monitoring-client; do
  wait_for_application "$app" "$PREVIOUS_CHART_DIGEST" "$PREVIOUS_CHART_VERSION"
  wait_for_stack "${app#monitoring-}"
done
assert_stack_rollouts
kubectl get deployment/monitoring-client-kube-state-metrics -n monitoring-client >/dev/null
kubectl get daemonset/monitoring-client-prometheus-node-exporter -n monitoring-client >/dev/null
kubectl get daemonset/monitoring-client-alloy -n monitoring-client >/dev/null
if helm template monitoring "$ROOT/charts/monitoring" --values "$ROOT/charts/monitoring/ci/central-values.yaml" | grep -q '^kind: Prometheus$'; then
  echo "Prometheus server resource is forbidden" >&2
  exit 1
fi
if kubectl get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1; then
  echo "Prometheus operator/server CRD is not part of the Mimir stack" >&2
  exit 1
fi
assert_observability_pack

INGESTER_PVC=storage-monitoring-central-mimir-ingester-0
INGESTER_PVC_UID=$(kubectl get pvc "$INGESTER_PVC" -n monitoring -o jsonpath='{.metadata.uid}')
[[ -n "$INGESTER_PVC_UID" ]]
printf '%s' "$INGESTER_PVC_UID" > "$WORK/ingester-pvc-uid"
CLIENT_REMOTE_WRITE=$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.global.telemetry.remoteWriteUrl}')
CLIENT_LOKI_PUSH=$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.global.telemetry.lokiPushUrl}')
printf '%s' "$CLIENT_REMOTE_WRITE" > "$WORK/client-remote-write"
printf '%s' "$CLIENT_LOKI_PUSH" > "$WORK/client-loki-push"
write_phase_result install "$PREVIOUS_CHART_VERSION" "$PREVIOUS_CHART_DIGEST"
