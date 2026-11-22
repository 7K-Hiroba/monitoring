#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(cd "$(dirname "$0")/.." && pwd)
ARGOCD_COMMIT=03c4ad854c1e6d922a121cd40f505d9bc6e402da

kubectl apply -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_COMMIT}/manifests/crds/application-crd.yaml"
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=60s
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$PACKAGE_DIR/rgd.yaml"
kubectl wait --for=condition=Ready rgd/monitoring-stack --timeout=120s
kubectl apply -f "$PACKAGE_DIR/tests/central.yaml" -f "$PACKAGE_DIR/tests/local.yaml" -f "$PACKAGE_DIR/tests/client.yaml" -f "$PACKAGE_DIR/tests/fixture.yaml"

for name in monitoring-central monitoring-local monitoring-client monitoring-fixture; do
  for _ in $(seq 1 60); do
    if kubectl get application "$name" -n argocd >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  kubectl get application "$name" -n argocd >/dev/null
  test "$(kubectl get application "$name" -n argocd -o jsonpath='{.spec.source.targetRevision}')" = "0.1.0"
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
