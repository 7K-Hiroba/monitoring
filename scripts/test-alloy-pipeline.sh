#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE=check
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --update) MODE=update; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done

FIXTURE_DIR="$ROOT/observability/tests/alloy"
EXPECTED="$FIXTURE_DIR/expected-central-series.json"
WORK=$(mktemp -d)
NETWORK="monitoring-alloy-$$"
PREFIX="monitoring-alloy-$$"
PYTHON_IMAGE='python@sha256:7fbad8e4652eae0186429a6f26cf5b23e27e8c6fd7ac4d0cfd7a6988cdeea1e1'
PROMETHEUS_IMAGE='prom/prometheus@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996'
ALLOY_IMAGE='grafana/alloy@sha256:6616111d70b3c75d5aa177e0584a523403eaba0eb3b177cb387302c2206d5221'

finish() {
  docker rm -f "${PREFIX}-alloy" "${PREFIX}-prometheus" "${PREFIX}-metrics" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap finish EXIT

cp "$FIXTURE_DIR/input.prom" "$WORK/input.prom"
sed -e 's|__TARGET__|metrics:8000|g' \
  -e 's|__REMOTE_WRITE_URL__|http://prometheus:9090/api/v1/write|g' \
  "$FIXTURE_DIR/config.river" > "$WORK/config.river"
printf 'global: {}\nscrape_configs: []\n' > "$WORK/prometheus.yml"

docker network create "$NETWORK" >/dev/null
docker create --name "${PREFIX}-metrics" --network "$NETWORK" --network-alias metrics \
  "$PYTHON_IMAGE" python -m http.server 8000 --directory /tmp >/dev/null
docker cp "$WORK/input.prom" "${PREFIX}-metrics:/tmp/input.prom"
docker start "${PREFIX}-metrics" >/dev/null
docker create --name "${PREFIX}-prometheus" --network "$NETWORK" --network-alias prometheus \
  --publish 127.0.0.1::9090 \
  "$PROMETHEUS_IMAGE" --config.file=/tmp/prometheus.yml \
  --web.enable-remote-write-receiver --storage.tsdb.path=/tmp/prometheus >/dev/null
docker cp "$WORK/prometheus.yml" "${PREFIX}-prometheus:/tmp/prometheus.yml"
docker start "${PREFIX}-prometheus" >/dev/null
PROMETHEUS_PORT=$(docker port "${PREFIX}-prometheus" 9090/tcp | head -1 | awk -F: '{print $NF}')
[[ "$PROMETHEUS_PORT" =~ ^[0-9]+$ ]]
docker create --name "${PREFIX}-alloy" --network "$NETWORK" \
  "$ALLOY_IMAGE" run --stability.level generally-available \
  --feature.community-components.enabled=false /tmp/config.river >/dev/null
docker cp "$WORK/config.river" "${PREFIX}-alloy:/tmp/config.river"
docker start "${PREFIX}-alloy" >/dev/null

ACTUAL_METRIC=""
for _ in $(seq 1 60); do
  RESPONSE=$(curl -fsS --get --data-urlencode 'query=up' "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/query" 2>/dev/null || true)
  if [[ -n "$RESPONSE" ]] && jq -e '.status == "success" and .data.resultType == "vector" and (.data.result | length) == 1' >/dev/null 2>&1 <<<"$RESPONSE"; then
    ACTUAL_METRIC=$(jq -c '.data.result[0].metric' <<<"$RESPONSE")
    break
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "${PREFIX}-alloy" 2>/dev/null || true)" != true ]]; then
    docker logs "${PREFIX}-alloy" >&2 || true
    echo "Alloy exited before producing the expected series" >&2
    exit 1
  fi
  sleep 1
done
[[ -n "$ACTUAL_METRIC" ]] || { echo "post-Alloy series did not arrive" >&2; exit 1; }

ACTUAL="$WORK/expected-central-series.json"
jq -n --argjson labels "$ACTUAL_METRIC" '{
  fixtureVersion: "alloy-v1.13.0",
  labelContract: "inari.monitoring.post-alloy-labels/v1",
  reviewRequired: true,
  sourceConfig: "config.river",
  metric: "up",
  labels: ($labels | {cluster, instance, job, org}),
  value: 1
}' > "$ACTUAL"
for label in cluster instance job org; do
  jq -e --arg name "$label" '.labels[$name] | type == "string" and length > 0' "$ACTUAL" >/dev/null
done

if [[ "$MODE" == update ]]; then
  cp "$ACTUAL" "$EXPECTED"
  echo "updated $EXPECTED from the real Alloy pipeline"
else
  diff -u "$EXPECTED" "$ACTUAL"
fi

for rules in "$ROOT"/observability/rules/*.yaml; do
  promtool check rules "$rules"
done
for test_file in "$ROOT"/observability/tests/rules/*.test.yaml; do
  promtool test rules "$test_file"
done
WORKFLOW_ROOT=${HIROBA_WORKFLOW_ROOT:-"$ROOT/.hiroba/workflows"}
DERIVE_SCRIPT="$WORKFLOW_ROOT/scripts/derive-central-rule-test.py"
[[ -f "$DERIVE_SCRIPT" ]] || { echo "missing pinned workflow script: $DERIVE_SCRIPT" >&2; exit 1; }
HIROBA_PYTHON=${HIROBA_PYTHON:-python3}
"$HIROBA_PYTHON" "$DERIVE_SCRIPT" \
  --base "$ROOT/observability/tests/rules/app.test.yaml" \
  --actual "$ACTUAL" \
  --rules "$ROOT/observability/rules/app.yaml" \
  --output "$WORK/central.test.yaml"
promtool test rules "$WORK/central.test.yaml"

echo "real Alloy fixture and promtool central/local logic: OK"
