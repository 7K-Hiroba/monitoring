#!/usr/bin/env bash
set -euo pipefail
ROOT=$HIROBA_STACK_ROOT
WORK=$HIROBA_STACK_WORK
# shellcheck disable=SC1091
source "$WORK/registry.env"
export REGISTRY_HOST=$HIROBA_REGISTRY_HOST
export REGISTRY_LOCAL=$HIROBA_REGISTRY_LOCAL

wait_for_application() {
  local name=$1 expected_digest=$2 expected_version=$3 health sync digest version applied operation
  for _ in $(seq 1 360); do
    health=$(kubectl get application "$name" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    sync=$(kubectl get application "$name" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    digest=$(kubectl get application "$name" -n argocd -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || true)
    version=$(kubectl get application "$name" -n argocd -o jsonpath='{.metadata.annotations.inari\.dev/chart-version}' 2>/dev/null || true)
    applied=$(kubectl get application "$name" -n argocd -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)
    operation=$(kubectl get application "$name" -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)
    if [[ "$health" == Healthy && "$sync" == Synced && "$digest" == "$expected_digest" && "$version" == "$expected_version" && "$applied" == "$expected_digest" && "$operation" == Succeeded ]]; then return 0; fi
    sleep 2
  done
  kubectl get application "$name" -n argocd -o yaml || true
  return 1
}

wait_for_stack() {
  local topology=$1 ready
  for _ in $(seq 1 60); do
    ready=$(kubectl get monitoringstack "$topology" -n default -o jsonpath='{.status.ready}' 2>/dev/null || true)
    if [[ "$ready" == true ]]; then return 0; fi
    sleep 2
  done
  kubectl get monitoringstack "$topology" -n default -o yaml || true
  return 1
}

push_chart_version() {
  local version=$1 destination=$2 digest
  mkdir -p "$destination"
  helm package "$ROOT/charts/monitoring" --version "$version" --destination "$destination" >/dev/null
  helm push --plain-http "$destination/monitoring-${version}.tgz" "oci://$REGISTRY_LOCAL/charts" >/dev/null
  digest=$(curl -fsSI -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://$REGISTRY_LOCAL/v2/charts/monitoring/manifests/${version}" | \
    tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}')
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
  export PUSHED_DIGEST=$digest
}

assert_stack_rollouts() {
  for namespace in monitoring monitoring-local monitoring-client; do
    for kind in deployment statefulset daemonset; do
      for resource in $(kubectl get "$kind" -n "$namespace" -o name); do
        kubectl rollout status "$resource" -n "$namespace" --timeout=300s
      done
    done
  done
}

assert_observability_pack() {
  kubectl apply -f "$ROOT/packages/observability-pack/tests/deps/prometheusrule-crd.yaml"
  kubectl apply -f "$ROOT/packages/observability-pack/rgd.yaml"
  kubectl wait --for=condition=Ready rgd/monitoring-observability --timeout=120s
  kubectl apply -f "$ROOT/tests/stack/pack-central.yaml" -f "$ROOT/tests/stack/pack-local.yaml"
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
    return 1
  fi
  if kubectl get configmap/monitoring-central-rules -n monitoring-local >/dev/null 2>&1; then
    echo "local companion leaked central rules" >&2
    return 1
  fi
}

write_phase_result() {
  local phase=$1 version=$2 digest=$3
  jq -n --arg phase "$phase" --arg version "$version" --arg digest "$digest" \
    '{schema:"inari.stack-phase-result.v1",phase:$phase,version:$version,contentDigest:$digest,converged:true}' \
    > "$WORK/$phase-result.json"
}
