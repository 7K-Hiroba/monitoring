#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKFLOW_ROOT=${HIROBA_WORKFLOW_ROOT:-$(cd "$ROOT" && cd ../7K-Hiroba-workflows && pwd)}
PYTHON=${HIROBA_PYTHON:-"$WORKFLOW_ROOT/.venv/bin/python"}
for script in render-observability.py build-indexes.py sync-release-please-config.py; do
  "$PYTHON" "$WORKFLOW_ROOT/scripts/$script" --root "$ROOT" --check
done
