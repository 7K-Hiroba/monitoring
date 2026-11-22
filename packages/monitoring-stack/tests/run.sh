#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(cd "$(dirname "$0")/.." && pwd)
ARGOCD_COMMIT=03c4ad854c1e6d922a121cd40f505d9bc6e402da

# kubectl wait can fail immediately when a new resource has no conditions yet.
# Poll the condition value so both CRD establishment and KRO reconciliation are
# allowed to initialize without turning that transient state into a test error.
wait_for_condition() {
  local resource=$1 condition=$2 timeout=$3 status
  for _ in $(seq 1 "$timeout"); do
    status=$(kubectl get "$resource" -o "jsonpath={.status.conditions[?(@.type==\"${condition}\")].status}" 2>/dev/null || true)
    if [[ "$status" == True ]]; then return 0; fi
    sleep 1
  done
  echo "timed out waiting for $resource condition $condition" >&2
  kubectl get "$resource" -o yaml || true
  return 1
}

kubectl apply -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_COMMIT}/manifests/crds/application-crd.yaml"
wait_for_condition crd/applications.argoproj.io Established 60
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$PACKAGE_DIR/rgd.yaml"
wait_for_condition rgd/monitoring-stack Ready 120
kubectl apply -f "$PACKAGE_DIR/tests/central.yaml" -f "$PACKAGE_DIR/tests/local.yaml" -f "$PACKAGE_DIR/tests/client.yaml" -f "$PACKAGE_DIR/tests/fixture.yaml"

for name in monitoring-central monitoring-local monitoring-client monitoring-fixture; do
  for _ in $(seq 1 60); do
    if kubectl get application "$name" -n argocd >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  kubectl get application "$name" -n argocd >/dev/null
  test "$(kubectl get application "$name" -n argocd -o jsonpath='{.spec.source.repoURL}')" = "oci://ghcr.io/7k-hiroba/monitoring/charts/monitoring"
  test "$(kubectl get application "$name" -n argocd -o jsonpath='{.spec.source.targetRevision}')" = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  test "$(kubectl get application "$name" -n argocd -o jsonpath='{.spec.source.path}')" = "."
  test "$(kubectl get application "$name" -n argocd -o jsonpath='{.spec.source.chart}')" = ""
  test "$(kubectl get application "$name" -n argocd -o jsonpath='{.metadata.annotations.inari\.dev/chart-version}')" = "0.1.0"
  test "$(kubectl get application "$name" -n argocd -o jsonpath='{.metadata.annotations.inari\.dev/chart-digest}')" = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  test "$(kubectl get application "$name" -n argocd -o jsonpath='{.spec.source.helm.valuesObject.global.telemetry.org}')" = ci
done

test "$(kubectl get application monitoring-central -n argocd -o jsonpath='{.spec.source.helm.valuesObject.topology}')" = central
test "$(kubectl get application monitoring-local -n argocd -o jsonpath='{.spec.source.helm.valuesObject.topology}')" = local
for name in monitoring-central monitoring-local; do
  test "$(kubectl get application "$name" -n argocd -o jsonpath='{.spec.source.helm.valuesObject.loki.loki.storage.type}')" = filesystem
  test "$(kubectl get application "$name" -n argocd -o jsonpath='{.spec.source.helm.valuesObject.loki.loki.schemaConfig.configs[0].object_store}')" = filesystem
done
test "$(kubectl get application monitoring-fixture -n argocd -o jsonpath='{.spec.source.helm.valuesObject.loki.loki.storage.type}')" = s3
test "$(kubectl get application monitoring-fixture -n argocd -o jsonpath='{.spec.source.helm.valuesObject.loki.loki.storage.s3.endpoint}')" = s3.example.com
test "$(kubectl get application monitoring-fixture -n argocd -o jsonpath='{.spec.source.helm.valuesObject.loki.loki.storage.s3.region}')" = test-1
test "$(kubectl get application monitoring-fixture -n argocd -o jsonpath='{.spec.source.helm.valuesObject.loki.loki.storage.s3.s3ForcePathStyle}')" = true
test "$(kubectl get application monitoring-fixture -n argocd -o jsonpath='{.spec.source.helm.valuesObject.loki.singleBinary.extraEnvFrom[0].secretRef.name}')" = loki-credentials
test "$(kubectl get application monitoring-fixture -n argocd -o jsonpath='{.spec.source.helm.valuesObject.mimir-distributed.mimir.structuredConfig.blocks_storage.s3.bucket_name}')" = mimir-blocks-ci
test "$(kubectl get application monitoring-fixture -n argocd -o jsonpath='{.spec.source.helm.valuesObject.mimir-distributed.mimir.structuredConfig.blocks_storage.s3.endpoint}')" = s3.example.com
test "$(kubectl get application monitoring-fixture -n argocd -o jsonpath='{.spec.source.helm.valuesObject.mimir-distributed.mimir.structuredConfig.alertmanager_storage.s3.bucket_name}')" = mimir-alertmanager-ci
test "$(kubectl get application monitoring-fixture -n argocd -o jsonpath='{.spec.source.helm.valuesObject.mimir-distributed.global.extraEnvFrom[0].secretRef.name}')" = mimir-credentials
test "$(kubectl get application monitoring-central -n argocd -o jsonpath='{.spec.source.helm.valuesObject.mimir-distributed.mimir.structuredConfig.blocks_storage.s3.bucket_name}')" = mimir-tsdb
test "$(kubectl get application monitoring-central -n argocd -o jsonpath='{.spec.source.helm.valuesObject.mimir-distributed.mimir.structuredConfig.blocks_storage.s3.endpoint}')" = monitoring-central-minio.monitoring.svc:9000
test "$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.topology}')" = client
test "$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.components.mimir}')" = false
test "$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.components.alertmanager}')" = false
test "$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.components.grafana}')" = false
test "$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.components.loki}')" = false
test "$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.components.alloy}')" = true
test "$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.components.kubeStateMetrics}')" = true
test "$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.components.nodeExporter}')" = true
test "$(kubectl get application monitoring-client -n argocd -o jsonpath='{.spec.source.helm.valuesObject.global.collectors.controlPlane.targets[0]}')" = control-plane-1.example:6443

echo "monitoring-stack central/local/client KRO applications: OK"
