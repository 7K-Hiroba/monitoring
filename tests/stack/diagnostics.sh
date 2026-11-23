#!/usr/bin/env bash
set -euo pipefail
kubectl get monitoringstacks,applications,pvc -A -o yaml || true
helm list -A || true
