#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(cd "$(dirname "$0")/.." && pwd)
kubectl apply -f "$PACKAGE_DIR/tests/deps/prometheusrule-crd.yaml"
kubectl apply -f "$PACKAGE_DIR/rgd.yaml"
kubectl wait --for=condition=Ready rgd/monitoring-observability --timeout=120s
kubectl apply -f "$PACKAGE_DIR/tests/fixture.yaml"
for _ in $(seq 1 60); do
  if kubectl get configmap monitoring-overview -n default >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl get configmap monitoring-overview -n default
kubectl get configmap monitoring-folder -n default
kubectl get prometheusrule monitoring-central -n default
kubectl get configmap monitoring-central-rules -n default
if kubectl get configmap monitoring-local-rules -n default >/dev/null 2>&1; then
  echo "central fixture must not create local rules" >&2
  exit 1
fi
test "$(kubectl get configmap monitoring-overview -n default -o jsonpath='{.metadata.annotations.inari\.dev/folder}')" = monitoring
