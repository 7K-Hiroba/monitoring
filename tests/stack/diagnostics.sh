#!/usr/bin/env bash
set -euo pipefail
kubectl get monitoringstacks,applications,pvc -A -o yaml || true
helm list -A || true
for namespace in monitoring monitoring-local monitoring-client; do
  for pod in $(kubectl get pods -n "$namespace" -o name); do
    kubectl logs -n "$namespace" "$pod" --all-containers=true --tail=120 || true
  done
done
