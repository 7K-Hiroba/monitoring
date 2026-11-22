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
MIMIR_IMAGE='grafana/mimir@sha256:0ed56db7d7713707eff00224ddd4c3096afa6cf1cbe43a6f9391c537f1416099'
ALLOY_IMAGE='grafana/alloy@sha256:6616111d70b3c75d5aa177e0584a523403eaba0eb3b177cb387302c2206d5221'

finish() {
  docker rm -f "${PREFIX}-alloy" "${PREFIX}-mimir" "${PREFIX}-metrics" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap finish EXIT

cp "$FIXTURE_DIR/input.prom" "$WORK/input.prom"
sed -e 's|__TARGET__|metrics:8000|g' \
  -e 's|__REMOTE_WRITE_URL__|http://mimir:9090/api/v1/push|g' \
  "$FIXTURE_DIR/config.river" > "$WORK/config.river"
cat > "$WORK/mimir.yaml" <<'EOF'
multitenancy_enabled: false
ingester:
  ring:
    replication_factor: 1
server:
  http_listen_port: 9090
  log_level: warn
common:
  storage:
    backend: filesystem
    filesystem:
      dir: /tmp/mimir
blocks_storage:
  backend: filesystem
  filesystem:
    dir: /tmp/mimir/blocks
  bucket_store:
    sync_dir: /tmp/mimir/tsdb-sync
  tsdb:
    dir: /tmp/mimir/tsdb
EOF

docker network create "$NETWORK" >/dev/null
docker create --name "${PREFIX}-metrics" --network "$NETWORK" --network-alias metrics \
  "$PYTHON_IMAGE" python -m http.server 8000 --directory /tmp >/dev/null
docker cp "$WORK/input.prom" "${PREFIX}-metrics:/tmp/input.prom"
docker start "${PREFIX}-metrics" >/dev/null
docker create --name "${PREFIX}-mimir" --network "$NETWORK" --network-alias mimir \
  --publish 127.0.0.1::9090 \
  "$MIMIR_IMAGE" -config.file=/tmp/mimir.yaml >/dev/null
docker cp "$WORK/mimir.yaml" "${PREFIX}-mimir:/tmp/mimir.yaml"
docker start "${PREFIX}-mimir" >/dev/null
MIMIR_PORT=$(docker port "${PREFIX}-mimir" 9090/tcp | head -1 | awk -F: '{print $NF}')
[[ "$MIMIR_PORT" =~ ^[0-9]+$ ]]
docker create --name "${PREFIX}-alloy" --network "$NETWORK" \
  "$ALLOY_IMAGE" run --stability.level generally-available \
  --feature.community-components.enabled=false /tmp/config.river >/dev/null
docker cp "$WORK/config.river" "${PREFIX}-alloy:/tmp/config.river"
docker start "${PREFIX}-alloy" >/dev/null

ACTUAL_METRIC=""
for _ in $(seq 1 90); do
  RESPONSE=$(curl -fsS --get --data-urlencode 'query=up' "http://127.0.0.1:${MIMIR_PORT}/prometheus/api/v1/query" 2>/dev/null || true)
  if [[ -n "$RESPONSE" ]] && jq -e '.status == "success" and .data.resultType == "vector" and (.data.result | length) == 1' >/dev/null 2>&1 <<<"$RESPONSE"; then
    ACTUAL_METRIC=$(jq -c '.data.result[0].metric' <<<"$RESPONSE")
    break
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "${PREFIX}-alloy" 2>/dev/null || true)" != true ]]; then
    docker logs "${PREFIX}-alloy" >&2 || true
    echo "Alloy exited before producing the expected series" >&2
    exit 1
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "${PREFIX}-mimir" 2>/dev/null || true)" != true ]]; then
    docker logs "${PREFIX}-mimir" >&2 || true
    echo "Mimir exited before receiving the expected series" >&2
    exit 1
  fi
  sleep 1
done
if [[ -z "$ACTUAL_METRIC" ]]; then
  docker logs "${PREFIX}-alloy" >&2 || true
  docker logs "${PREFIX}-mimir" >&2 || true
  echo "post-Alloy series did not arrive" >&2
  exit 1
fi

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

echo "real Alloy to Mimir fixture and promtool central/local logic: OK"
