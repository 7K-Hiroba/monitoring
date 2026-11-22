#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CLUSTER=monitoring-kind-$$
ARGOCD_COMMIT=03c4ad854c1e6d922a121cd40f505d9bc6e402da
KIND_IMAGE='kindest/node:v1.31.2@sha256:0526eb5cd8d892ed79b56feb48d17eeee1f719f55d5c35cef468f053caffad32'
PF_PIDS=()
export KUBECONFIG="/tmp/${CLUSTER}.kubeconfig"
DIAGNOSTICS="$ROOT/diagnostics/${CLUSTER}.txt"

finish() {
  if [[ ${#PF_PIDS[@]} -gt 0 ]]; then kill "${PF_PIDS[@]}" >/dev/null 2>&1 || true; fi
  if [[ "${KEEP_KIND:-false}" != true ]]; then
    mkdir -p "$ROOT/diagnostics"
    kubectl get all -A -o wide > "$DIAGNOSTICS" 2>&1 || true
    kubectl get rgd -A -o yaml >> "$DIAGNOSTICS" 2>&1 || true
    kubectl get events -A --sort-by=.lastTimestamp >> "$DIAGNOSTICS" 2>&1 || true
    kubectl logs -n kro-system deploy/kro --tail=200 >> "$DIAGNOSTICS" 2>&1 || true
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
}
trap finish EXIT

kind create cluster --name "$CLUSTER" --image "$KIND_IMAGE" --wait 120s
helm upgrade --install kro oci://registry.k8s.io/kro/charts/kro \
  --namespace kro-system --create-namespace --version 0.6.1 --wait --timeout 180s
kubectl apply -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_COMMIT}/manifests/crds/application-crd.yaml"
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=60s
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$ROOT/packages/monitoring-stack/rgd.yaml"
kubectl wait --for=condition=Ready rgd/monitoring-stack --timeout=120s
kubectl apply -f "$ROOT/packages/monitoring-stack/tests/central.yaml" \
  -f "$ROOT/packages/monitoring-stack/tests/local.yaml" -f "$ROOT/packages/monitoring-stack/tests/client.yaml"
for app in monitoring-central monitoring-local monitoring-client; do
  for _ in $(seq 1 60); do
    if kubectl get application "$app" -n argocd >/dev/null 2>&1; then break; fi
    sleep 2
  done
  kubectl get application "$app" -n argocd >/dev/null
done

CONTROL_PLANE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER}-control-plane")
[[ -n "$CONTROL_PLANE_IP" ]]
for topology in central local; do
  release=monitoring
  namespace=monitoring
  if [[ "$topology" == local ]]; then release=monitoring-local; namespace=monitoring-local; fi
  helm upgrade --install "$release" "$ROOT/charts/monitoring" \
    --namespace "$namespace" --create-namespace \
    --values "$ROOT/charts/monitoring/ci/${topology}-values.yaml" \
    --set "global.collectors.controlPlane.targets[0]=${CONTROL_PLANE_IP}:6443" \
    --wait --timeout 12m
  kubectl rollout status deployment --all -n "$namespace" --timeout=300s
  kubectl rollout status statefulset --all -n "$namespace" --timeout=300s
  kubectl rollout status daemonset --all -n "$namespace" --timeout=300s
done

if helm template monitoring "$ROOT/charts/monitoring" --values "$ROOT/charts/monitoring/ci/central-values.yaml" | grep -q '^kind: Prometheus$'; then
  echo "Prometheus server resource is forbidden" >&2
  exit 1
fi
if kubectl get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1; then
  echo "Prometheus operator/server CRD is not part of the Mimir stack" >&2
  exit 1
fi

kubectl apply -f "$ROOT/packages/observability-pack/tests/deps/prometheusrule-crd.yaml"
kubectl apply -f "$ROOT/packages/observability-pack/rgd.yaml"
kubectl wait --for=condition=Ready rgd/monitoring-observability --timeout=120s
kubectl apply -f "$ROOT/tests/kind/pack-central.yaml" -f "$ROOT/tests/kind/pack-local.yaml"
for resource in configmap/monitoring-overview configmap/monitoring-folder configmap/monitoring-central-rules prometheusrule/monitoring-central; do
  for _ in $(seq 1 60); do
    if kubectl get "$resource" -n monitoring >/dev/null 2>&1; then break; fi
    sleep 2
  done
  kubectl get "$resource" -n monitoring >/dev/null
done
for resource in configmap/monitoring-overview configmap/monitoring-folder configmap/monitoring-local-rules prometheusrule/monitoring-local; do
  for _ in $(seq 1 60); do
    if kubectl get "$resource" -n monitoring-local >/dev/null 2>&1; then break; fi
    sleep 2
  done
  kubectl get "$resource" -n monitoring-local >/dev/null
done
if kubectl get configmap/monitoring-local-rules -n monitoring >/dev/null 2>&1; then
  echo "central companion leaked local rules" >&2
  exit 1
fi
if kubectl get configmap/monitoring-central-rules -n monitoring-local >/dev/null 2>&1; then
  echo "local companion leaked central rules" >&2
  exit 1
fi

kubectl port-forward svc/monitoring-mimir-gateway -n monitoring 18080:80 >/tmp/${CLUSTER}-mimir-pf.log 2>&1 & PF_PIDS+=("$!")
kubectl port-forward svc/monitoring-local-mimir-gateway -n monitoring-local 18081:80 >/tmp/${CLUSTER}-local-mimir-pf.log 2>&1 & PF_PIDS+=("$!")
kubectl port-forward svc/monitoring-loki-gateway -n monitoring 18082:80 >/tmp/${CLUSTER}-loki-pf.log 2>&1 & PF_PIDS+=("$!")
kubectl port-forward svc/monitoring-local-loki-gateway -n monitoring-local 18083:80 >/tmp/${CLUSTER}-local-loki-pf.log 2>&1 & PF_PIDS+=("$!")
kubectl port-forward svc/monitoring-mimir-alertmanager -n monitoring 18084:8080 >/tmp/${CLUSTER}-alertmanager-pf.log 2>&1 & PF_PIDS+=("$!")
kubectl port-forward svc/monitoring-local-mimir-alertmanager -n monitoring-local 18085:8080 >/tmp/${CLUSTER}-local-alertmanager-pf.log 2>&1 & PF_PIDS+=("$!")
kubectl port-forward svc/monitoring-grafana -n monitoring 18086:80 >/tmp/${CLUSTER}-grafana-pf.log 2>&1 & PF_PIDS+=("$!")
kubectl port-forward svc/monitoring-local-grafana -n monitoring-local 18087:80 >/tmp/${CLUSTER}-local-grafana-pf.log 2>&1 & PF_PIDS+=("$!")
sleep 3

for port in 18080 18081; do
  group=monitoring-central
  if [[ "$port" == 18081 ]]; then group=monitoring-client; fi
  RULES=""
  for _ in $(seq 1 120); do
    RULES=$(curl -fsS "http://127.0.0.1:${port}/prometheus/api/v1/rules" 2>/dev/null || true)
    if jq -e --arg group "$group" '.data.groups[] | select(.name == $group) and (.rules | length > 0) and (.rules[0].lastEvaluation | length > 0)' >/dev/null 2>&1 <<<"$RULES"; then break; fi
    sleep 2
  done
  jq -e --arg group "$group" '.data.groups[] | select(.name == $group) and (.rules | length > 0) and (.rules[0].lastEvaluation | length > 0)' <<<"$RULES" >/dev/null
  curl -fsS --get --data-urlencode 'query=up' "http://127.0.0.1:${port}/prometheus/api/v1/query" | jq -e '.status == "success" and (.data.result | length > 0)' >/dev/null
done
for port in 18082 18083; do
  curl -fsS "http://127.0.0.1:${port}/loki/api/v1/labels" | jq -e '.status == "success"' >/dev/null
done
for port in 18084 18085; do
  curl -fsS "http://127.0.0.1:${port}/alertmanager/api/v2/status" | jq -e '.cluster' >/dev/null
done
for port in 18086 18087; do
  curl -fsS "http://127.0.0.1:${port}/api/dashboards/uid/monitoring-overview" | \
    jq -e '.dashboard.uid == "monitoring-overview" and .meta.folderTitle == "monitoring" and (.meta.folderUid | length > 0)' >/dev/null
done

echo "KRO central/local/client resources, Mimir rules, Alertmanager, Loki, Grafana, Alloy, and client collectors: OK"
