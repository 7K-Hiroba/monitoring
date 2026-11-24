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
HIROBA_PYTHON=${HIROBA_PYTHON:-python3}

finish() {
  rc=$?
  if [[ $rc -ne 0 ]]; then
    docker logs "${PREFIX}-metrics" >&2 || true
    docker logs "${PREFIX}-alloy" >&2 || true
    docker logs "${PREFIX}-mimir" >&2 || true
  fi
  docker rm -f "${PREFIX}-alloy" "${PREFIX}-mimir" "${PREFIX}-metrics" >/dev/null 2>&1 || true
  docker volume rm "${PREFIX}-rules" "${PREFIX}-ruler" >/dev/null 2>&1 || true
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
ruler:
  rule_path: /data/ruler
ruler_storage:
  backend: local
  local:
    directory: /data/rules
EOF

# Exercise Hiroba-owned ConfigMap delivery through Mimir's real filesystem ruler.
for topology in central local; do
  helm template monitoring "$ROOT/charts/monitoring" --namespace monitoring \
    --values "$ROOT/charts/monitoring/ci/$topology-values.yaml" \
    --set observability.enabled=true --set observability.rules.enabled=true > "$WORK/$topology-full.yaml"
done
mkdir -p "$WORK/rules/anonymous"
"$HIROBA_PYTHON" - "$WORK" <<'PY'
import sys, yaml
from pathlib import Path
work = Path(sys.argv[1])
for topology in ("central", "local"):
    documents = list(yaml.safe_load_all((work / f"{topology}-full.yaml").read_text()))
    expected = f"monitoring-{topology}-rules"
    other = "local" if topology == "central" else "central"
    for document in documents:
        if not isinstance(document, dict) or document.get("kind") != "ConfigMap":
            continue
        name = document.get("metadata", {}).get("name")
        if name == f"monitoring-{other}-rules":
            raise SystemExit(f"{topology} rendering leaked {other} rules")
        if name == expected:
            data = document.get("data") or {}
            key = f"{topology}.yaml"
            if set(data) != {key}:
                raise SystemExit(f"unexpected {expected} keys: {sorted(data)}")
            if topology == "central":
                (work / "rules/anonymous/central.yaml").write_text(data[key])
PY
test -f "$WORK/rules/anonymous/central.yaml"

docker network create "$NETWORK" >/dev/null
docker create --name "${PREFIX}-metrics" --network "$NETWORK" --network-alias metrics \
  "$PYTHON_IMAGE" python -m http.server 8000 --directory /tmp >/dev/null
docker cp "$WORK/input.prom" "${PREFIX}-metrics:/tmp/input.prom"
docker start "${PREFIX}-metrics" >/dev/null
docker create --name "${PREFIX}-mimir" --network "$NETWORK" --network-alias mimir \
  --publish 127.0.0.1::9090 \
  --volume "${PREFIX}-rules:/data/rules" \
  --volume "${PREFIX}-ruler:/data/ruler" \
  "$MIMIR_IMAGE" -config.file=/tmp/mimir.yaml -target=all >/dev/null
docker cp "$WORK/mimir.yaml" "${PREFIX}-mimir:/tmp/mimir.yaml"
docker cp "$WORK/rules/." "${PREFIX}-mimir:/data/rules"
docker start "${PREFIX}-mimir" >/dev/null
MIMIR_PORT=$(docker port "${PREFIX}-mimir" 9090/tcp | head -1 | awk -F: '{print $NF}')
[[ "$MIMIR_PORT" =~ ^[0-9]+$ ]]
for _ in $(seq 1 180); do
  if curl -fsS "http://127.0.0.1:${MIMIR_PORT}/ready" >/dev/null 2>&1; then break; fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "${PREFIX}-mimir" 2>/dev/null || true)" != true ]]; then
    docker logs "${PREFIX}-mimir" >&2 || true
    echo "Mimir exited before becoming ready" >&2
    exit 1
  fi
  sleep 1
done
curl -fsS "http://127.0.0.1:${MIMIR_PORT}/ready" >/dev/null
docker create --name "${PREFIX}-alloy" --network "$NETWORK" \
  "$ALLOY_IMAGE" run --stability.level generally-available \
  --feature.community-components.enabled=false /tmp/config.river >/dev/null
docker cp "$WORK/config.river" "${PREFIX}-alloy:/tmp/config.river"
docker start "${PREFIX}-alloy" >/dev/null

ACTUAL_METRIC=""
ACTUAL_VALUE=""
for _ in $(seq 1 90); do
  RESPONSE=$(curl -fsS --get --data-urlencode 'query=up{instance="ci"}' "http://127.0.0.1:${MIMIR_PORT}/prometheus/api/v1/query" 2>/dev/null || true)
  if [[ -n "$RESPONSE" ]] && jq -e '.status == "success" and .data.resultType == "vector" and (.data.result | length) == 1' >/dev/null 2>&1 <<<"$RESPONSE"; then
    ACTUAL_METRIC=$(jq -c '.data.result[0].metric' <<<"$RESPONSE")
    ACTUAL_VALUE=$(jq -r '.data.result[0].value[1]' <<<"$RESPONSE")
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
if [[ -z "$ACTUAL_METRIC" || -z "$ACTUAL_VALUE" ]]; then
  printf 'last Mimir query response: %s\n' "$RESPONSE" >&2
  curl -fsS --get --data-urlencode 'query={__name__=~".+"}' "http://127.0.0.1:${MIMIR_PORT}/prometheus/api/v1/query" >&2 || true
  docker logs "${PREFIX}-alloy" >&2 || true
  docker logs "${PREFIX}-mimir" >&2 || true
  echo "post-Alloy series did not arrive" >&2
  exit 1
fi

ACTUAL="$WORK/expected-central-series.json"
jq -n --argjson labels "$ACTUAL_METRIC" --arg value "$ACTUAL_VALUE" '{
  fixtureVersion: "alloy-v1.13.0",
  labelContract: "inari.monitoring.post-alloy-labels/v1",
  reviewRequired: true,
  sourceConfig: "config.river",
  metric: "up",
  labels: ($labels | {cluster, instance, job, org}),
  value: ($value | tonumber)
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

RULE_VALUE=""
for _ in $(seq 1 90); do
  RULE_RESPONSE=$(curl -fsS --get --data-urlencode 'query=monitoring:up:sum' "http://127.0.0.1:${MIMIR_PORT}/prometheus/api/v1/query" 2>/dev/null || true)
  if [[ -n "$RULE_RESPONSE" ]] && jq -e '.status == "success" and (.data.result | length) == 1 and ((.data.result[0].value[1] | tonumber) > 0)' >/dev/null 2>&1 <<<"$RULE_RESPONSE"; then
    RULE_VALUE=$(jq -r '.data.result[0].value[1]' <<<"$RULE_RESPONSE")
    break
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "${PREFIX}-mimir" 2>/dev/null || true)" != true ]]; then
    docker logs "${PREFIX}-mimir" >&2 || true
    echo "Mimir exited before evaluating the delivered central rule" >&2
    exit 1
  fi
  sleep 2
done
if [[ -z "$RULE_VALUE" ]]; then
  printf 'last recording-rule response: %s\n' "$RULE_RESPONSE" >&2
  curl -fsS "http://127.0.0.1:${MIMIR_PORT}/prometheus/api/v1/rules" >&2 || true
  echo "Mimir did not evaluate monitoring:up:sum from the delivered ConfigMap" >&2
  exit 1
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

validate_chart_config() {
  local values=$2 rendered="$WORK/${1}-rendered.yaml" config="$WORK/${1}-config.river"
  helm template monitoring "$ROOT/charts/monitoring" --namespace default --values "$values" > "$rendered"
  "$HIROBA_PYTHON" - "$rendered" "$config" <<'PY'
import sys
import yaml
from pathlib import Path
rendered, output = Path(sys.argv[1]), Path(sys.argv[2])
for document in yaml.safe_load_all(rendered.read_text()):
    if not isinstance(document, dict) or document.get("kind") != "ConfigMap":
        continue
    for value in (document.get("data") or {}).values():
        if 'prometheus.remote_write "mimir"' in value:
            output.write_text(value)
            break
    else:
        continue
    break
else:
    raise SystemExit("rendered chart has no Alloy config")
PY
  alloy validate --stability.level generally-available --feature.community-components.enabled=false "$config"
}
validate_chart_config central "$ROOT/charts/monitoring/ci/central-values.yaml"
validate_chart_config client "$ROOT/charts/monitoring/ci/client-values.yaml"
"$HIROBA_PYTHON" - "$ROOT" "$WORK/quoted-values.yaml" <<'PY'
import sys
import yaml
from pathlib import Path
root, output = Path(sys.argv[1]), Path(sys.argv[2])
values = yaml.safe_load((root / "charts/monitoring/ci/client-values.yaml").read_text())
values["global"]["telemetry"]["remoteWriteUrl"] = 'http://mimir.example/api/v1/push"quoted'
values["global"]["telemetry"]["lokiPushUrl"] = 'http://loki.example/loki/api/v1/push"quoted'
values["global"]["collectors"]["kubelet"]["caFile"] = '/tmp/ca"quoted'
values["global"]["collectors"]["controlPlane"]["targets"] = ['192.0.2.10:6443"quoted']
output.write_text(yaml.safe_dump(values))
PY
validate_chart_config quoted "$WORK/quoted-values.yaml"

echo "real Alloy to Mimir fixture, promtool logic, and rendered chart Alloy validation: OK"
