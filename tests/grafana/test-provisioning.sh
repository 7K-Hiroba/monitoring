#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
NETWORK="monitoring-grafana-$$"
PREFIX="monitoring-grafana-$$"
PYTHON_IMAGE='python@sha256:7fbad8e4652eae0186429a6f26cf5b23e27e8c6fd7ac4d0cfd7a6988cdeea1e1'
GRAFANA_IMAGE='grafana/grafana@sha256:0615ec4fbd4072004b7d86b46ded63013a74b7d6eb1119273dd89e8fa25c13cf'
HIROBA_PYTHON=${HIROBA_PYTHON:-python3}

finish() {
  docker rm -f "${PREFIX}-grafana" "${PREFIX}-mimir" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap finish EXIT

helm template monitoring "$ROOT/charts/monitoring" --namespace monitoring \
  --set observability.enabled=true --set observability.rules.enabled=true > "$WORK/rendered.yaml"
mkdir -p "$WORK/dashboards/monitoring" "$WORK/provisioning/datasources" "$WORK/provisioning/dashboards"
"$HIROBA_PYTHON" - "$WORK" <<'PY'
import sys,yaml
from pathlib import Path
work=Path(sys.argv[1])
docs=list(yaml.safe_load_all((work/'rendered.yaml').read_text()))
found=False
for doc in docs:
    if isinstance(doc,dict) and doc.get('kind')=='ConfigMap' and doc.get('metadata',{}).get('name')=='monitoring-overview':
        (work/'dashboards/monitoring/monitoring-overview.json').write_text(doc['data']['monitoring-overview.json'])
        found=True
if not found:
    raise SystemExit('rendered chart has no monitoring-overview dashboard ConfigMap')
PY
cat > "$WORK/provisioning/datasources/datasources.yaml" <<'YAML'
apiVersion: 1
datasources:
  - name: Mimir
    uid: mimir
    type: prometheus
    access: proxy
    isDefault: true
    editable: false
    url: http://mimir:8080
    jsonData:
      prometheusType: Mimir
YAML
cat > "$WORK/provisioning/dashboards/dashboards.yaml" <<'YAML'
apiVersion: 1
providers:
  - name: monitoring
    type: file
    updateIntervalSeconds: 1
    allowUiUpdates: false
    options:
      path: /tmp/dashboards
      foldersFromFilesStructure: true
YAML

docker network create "$NETWORK" >/dev/null
docker create --name "${PREFIX}-mimir" --network "$NETWORK" --network-alias mimir \
  "$PYTHON_IMAGE" python /tmp/mock_mimir.py >/dev/null
docker cp "$ROOT/tests/grafana/fixtures/mock_mimir.py" "${PREFIX}-mimir:/tmp/mock_mimir.py"
docker start "${PREFIX}-mimir" >/dev/null
docker create --name "${PREFIX}-grafana" --network "$NETWORK" \
  --publish 127.0.0.1::3000 \
  --env GF_PATHS_PROVISIONING=/tmp/provisioning \
  --env GF_AUTH_ANONYMOUS_ENABLED=true \
  --env GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
  "$GRAFANA_IMAGE" >/dev/null
docker cp "$WORK/provisioning/." "${PREFIX}-grafana:/tmp/provisioning/"
docker cp "$WORK/dashboards/." "${PREFIX}-grafana:/tmp/dashboards/"
docker start "${PREFIX}-grafana" >/dev/null
GRAFANA_PORT=$(docker port "${PREFIX}-grafana" 3000/tcp | head -1 | awk -F: '{print $NF}')
[[ "$GRAFANA_PORT" =~ ^[0-9]+$ ]]
BASE="http://127.0.0.1:${GRAFANA_PORT}"

for _ in $(seq 1 90); do
  if curl -fsS "$BASE/api/health" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/api/health" >/dev/null

DASHBOARD=""
for _ in $(seq 1 30); do
  DASHBOARD=$(curl -fsS "$BASE/api/dashboards/uid/monitoring-overview" 2>/dev/null || true)
  if jq -e '.dashboard.uid == "monitoring-overview" and .dashboard.title == "Monitoring stack overview" and .meta.folderTitle == "monitoring" and (.meta.folderUid | length > 0)' >/dev/null 2>&1 <<<"$DASHBOARD"; then
    break
  fi
  sleep 1
done
jq -e '.dashboard.uid == "monitoring-overview" and .dashboard.title == "Monitoring stack overview" and .meta.folderTitle == "monitoring" and (.meta.folderUid | length > 0)' <<<"$DASHBOARD" >/dev/null
curl -fsS "$BASE/api/datasources/uid/mimir" | jq -e '.uid == "mimir" and .type == "prometheus" and .url == "http://mimir:8080"' >/dev/null

while read -r expression; do
  [[ -n "$expression" ]] || continue
  curl -fsS --get --data-urlencode "query=$expression" \
    "$BASE/api/datasources/proxy/uid/mimir/api/v1/query" | \
    jq -e '.status == "success" and .data.result[0].value[1] == "1"' >/dev/null
done < <(jq -r '.dashboard.panels[].targets[].expr' <<<"$DASHBOARD")

[[ "$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/api/dashboards/uid/unknown-dashboard")" == 404 ]]
[[ "$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/api/datasources/uid/unknown")" == 404 ]]
[[ "$(curl -sS -o /dev/null -w '%{http_code}' --get --data-urlencode 'query=invalid' "$BASE/api/datasources/proxy/uid/mimir/api/v1/query")" == 400 ]]

echo "ephemeral Grafana folder/dashboard/datasource/panel resolution: OK"
