WORKFLOW_ROOT ?= ../7K-Hiroba-workflows
PYTHON ?= $(WORKFLOW_ROOT)/.venv/bin/python
REGISTRY ?= ../7K-Hiroba-community/registry/apps.json

.PHONY: unit validate check-generated test-alloy test-grafana test-stack verify

unit:
	$(PYTHON) -m unittest discover -s tests/unit -p 'test_*.py'

validate:
	$(PYTHON) $(WORKFLOW_ROOT)/scripts/validate-repository.py --root . --registry $(REGISTRY)

check-generated:
	$(PYTHON) $(WORKFLOW_ROOT)/scripts/render-observability.py --root . --check
	$(PYTHON) $(WORKFLOW_ROOT)/scripts/build-indexes.py --root . --check
	$(PYTHON) $(WORKFLOW_ROOT)/scripts/sync-release-please-config.py --root . --check

test-alloy:
	./scripts/test-alloy-pipeline.sh --check

test-grafana:
	./tests/grafana/test-provisioning.sh

test-stack:
	HIROBA_WORKFLOW_ROOT="$(WORKFLOW_ROOT)" WORKFLOW_SHA="$(shell git -C $(WORKFLOW_ROOT) rev-parse HEAD)" $(WORKFLOW_ROOT)/scripts/run-stack-lifecycle.sh --root .

verify: unit validate check-generated test-alloy test-grafana
