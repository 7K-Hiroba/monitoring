#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CLUSTER=monitoring-kind-$$
ARGOCD_COMMIT=03c4ad854c1e6d922a121cd40f505d9bc6e402da
KIND_IMAGE='kindest/node:v1.31.2@sha256:0526eb5cd8d892ed79b56feb48d17eeee1f719f55d5c35cef468f053caffad32'
REGISTRY_IMAGE='registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373'
REDIS_IMAGE='redis@sha256:ddd16a9b1575a774c7e62956be8daa1de5b32cfb5c25b7a216aefed8e0919f9b'
REGISTRY_HOST=monitoring-registry.monitoring-registry.svc:5000
PF_PIDS=()
WORK=$(mktemp -d)
export KUBECONFIG="/tmp/${CLUSTER}.kubeconfig"
DIAGNOSTICS="$ROOT/diagnostics/${CLUSTER}.txt"

finish() {
  if [[ ${#PF_PIDS[@]} -gt 0 ]]; then kill "${PF_PIDS[@]}" >/dev/null 2>&1 || true; fi
  if [[ "${KEEP_KIND:-false}" != true ]]; then
    mkdir -p "$ROOT/diagnostics"
    kubectl get all -A -o wide > "$DIAGNOSTICS" 2>&1 || true
    kubectl get applications,monitoringstacks -A -o yaml >> "$DIAGNOSTICS" 2>&1 || true
    kubectl get rgd -A -o yaml >> "$DIAGNOSTICS" 2>&1 || true
    kubectl get events -A --sort-by=.lastTimestamp >> "$DIAGNOSTICS" 2>&1 || true
    kubectl logs -n kro-system deploy/kro --tail=200 >> "$DIAGNOSTICS" 2>&1 || true
    kubectl logs -n argocd deploy/argocd-repo-server --tail=200 >> "$DIAGNOSTICS" 2>&1 || true
    kubectl logs -n argocd statefulset/argocd-application-controller --tail=200 >> "$DIAGNOSTICS" 2>&1 || true
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
    rm -rf "$WORK"
  fi
}
trap finish EXIT

wait_for_application() {
  local name=$1 health sync
  for _ in $(seq 1 360); do
    health=$(kubectl get application "$name" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    sync=$(kubectl get application "$name" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    if [[ "$health" == Healthy && "$sync" == Synced ]]; then return 0; fi
    sleep 2
  done
  kubectl get application "$name" -n argocd -o yaml || true
  return 1
}

kind create cluster --name "$CLUSTER" --image "$KIND_IMAGE" --wait 120s

# A disposable in-cluster OCI registry lets ArgoCD resolve the real digest source
# without publishing or releasing task content.
kubectl create namespace monitoring-registry --dry-run=client -o yaml | kubectl apply -f -
cat > "$WORK/registry.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: monitoring-registry
  namespace: monitoring-registry
spec:
  replicas: 1
  selector:
    matchLabels: {app: monitoring-registry}
  template:
    metadata:
      labels: {app: monitoring-registry}
    spec:
      containers:
        - name: registry
          image: $REGISTRY_IMAGE
          ports: [{containerPort: 5000}]
          resources:
            requests: {cpu: 50m, memory: 64Mi}
            limits: {cpu: 200m, memory: 256Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: monitoring-registry
  namespace: monitoring-registry
spec:
  selector: {app: monitoring-registry}
  ports: [{port: 5000, targetPort: 5000}]
EOF
kubectl apply -f "$WORK/registry.yaml"
kubectl wait --for=condition=Available deployment/monitoring-registry -n monitoring-registry --timeout=180s
REGISTRY_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
kubectl port-forward svc/monitoring-registry -n monitoring-registry "$REGISTRY_PORT:5000" > "$WORK/registry-port-forward.log" 2>&1 & PF_PIDS+=("$!")
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "http://127.0.0.1:${REGISTRY_PORT}/v2/" >/dev/null

CHART_VERSION=$(helm show chart "$ROOT/charts/monitoring" | awk '/^version:/ {print $2}')
[[ "$CHART_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
helm package "$ROOT/charts/monitoring" --destination "$WORK"
helm push --plain-http "$WORK/monitoring-${CHART_VERSION}.tgz" "oci://127.0.0.1:${REGISTRY_PORT}/charts"
CHART_DIGEST=$(curl -fsSI -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "http://127.0.0.1:${REGISTRY_PORT}/v2/charts/monitoring/manifests/${CHART_VERSION}" | \
  tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}')
[[ "$CHART_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]
CONTROL_PLANE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER}-control-plane")
[[ -n "$CONTROL_PLANE_IP" ]]
${HIROBA_PYTHON:-python3} "$ROOT/tests/kind/render-local.py" --root "$ROOT" --work "$WORK" \
  --registry "$REGISTRY_HOST" --digest "$CHART_DIGEST" --control-plane "${CONTROL_PLANE_IP}:6443"

helm upgrade --install kro oci://registry.k8s.io/kro/charts/kro \
  --namespace kro-system --create-namespace --version 0.6.1 --wait --timeout 180s
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_COMMIT}/manifests/core-install.yaml"
# core-install leaves the secret empty. Give this disposable cluster a unique
# key so Application destination validation and reconciliation can proceed.
SERVER_SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
kubectl create secret generic argocd-secret --namespace argocd --dry-run=client -o yaml \
  --from-literal server.secretkey="$SERVER_SECRET_KEY" | kubectl apply -f -
unset SERVER_SECRET_KEY
# Pull the exact image from Docker Hub rather than relying on the manifest's
# public-ECR mirror, which is rate-limited in hosted CI.
kubectl set image deployment/argocd-redis redis="$REDIS_IMAGE" --namespace argocd
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=60s
kubectl wait --for=condition=Established crd/appprojects.argoproj.io --timeout=60s
kubectl wait --for=condition=Available deployment -n argocd --all --timeout=300s
# core-install deliberately has no default project. Create a narrowly scoped
# disposable project so the real application controller can reconcile KRO output.
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
    - server: https://kubernetes.default.svc
      namespace: monitoring
    - server: https://kubernetes.default.svc
      namespace: monitoring-local
    - server: https://kubernetes.default.svc
      namespace: monitoring-client
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
EOF
kubectl apply -f "$WORK/argocd-project.yaml"
cat > "$WORK/argocd-repository.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: monitoring-kind-oci
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: monitoring-kind
  url: $REGISTRY_HOST
  enableOCI: "true"
  insecureOCIForceHttp: "true"
EOF
kubectl apply -f "$WORK/argocd-repository.yaml"

kubectl apply -f "$WORK/rgd.yaml"
kubectl wait --for=condition=Ready rgd/monitoring-stack --timeout=120s
kubectl apply -f "$WORK/central.yaml" -f "$WORK/local.yaml" -f "$WORK/client.yaml"
for app in monitoring-central monitoring-local monitoring-client; do
  wait_for_application "$app"
  test "$(kubectl get application "$app" -n argocd -o jsonpath='{.spec.source.targetRevision}')" = "$CHART_DIGEST"
  test "$(kubectl get application "$app" -n argocd -o jsonpath='{.spec.source.repoURL}')" = "oci://${REGISTRY_HOST}/charts/monitoring"
done
for namespace in monitoring monitoring-local monitoring-client; do
  kubectl rollout status deployment --all -n "$namespace" --timeout=300s
  kubectl rollout status statefulset --all -n "$namespace" --timeout=300s
  kubectl rollout status daemonset --all -n "$namespace" --timeout=300s
done

# Client collectors are deployed by the same KRO/ArgoCD path, not by a second
# Helm installation or an unused Application fixture.
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
    if jq -e --arg group "$group" '.data.groups[] | select(.name == $group) and (.rules | length > 0) and (.lastEvaluation | length > 0) and all(.rules[]; .health == "ok" and ((.lastError // "") == ""))' >/dev/null 2>&1 <<<"$RULES"; then break; fi
    sleep 2
  done
  jq -e --arg group "$group" '.data.groups[] | select(.name == $group) and (.rules | length > 0) and (.lastEvaluation | length > 0) and all(.rules[]; .health == "ok" and ((.lastError // "") == ""))' <<<"$RULES" >/dev/null
  curl -fsS --get --data-urlencode 'query=up' "http://127.0.0.1:${port}/prometheus/api/v1/query" | jq -e '.status == "success" and (.data.result | length > 0)' >/dev/null
done
CLIENT_SERIES=""
for _ in $(seq 1 60); do
  CLIENT_SERIES=$(curl -fsS --get --data-urlencode 'query=up{cluster="monitoring-client"}' "http://127.0.0.1:18080/prometheus/api/v1/query" 2>/dev/null || true)
  if jq -e '.status == "success" and (.data.result | length > 0)' >/dev/null 2>&1 <<<"$CLIENT_SERIES"; then break; fi
  sleep 2
done
jq -e '.status == "success" and (.data.result | length > 0)' <<<"$CLIENT_SERIES" >/dev/null
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

echo "KRO/ArgoCD central/local/client stacks, client telemetry, Mimir rules, Alertmanager, Loki, and Grafana: OK"
