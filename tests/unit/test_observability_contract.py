from __future__ import annotations

import json
import unittest
from pathlib import Path

import jsonschema
import yaml

ROOT = Path(__file__).resolve().parents[2]


class ObservabilityContractTests(unittest.TestCase):
    def test_canonical_assets_use_registered_identity_and_current_rule_contract(self):
        manifest = yaml.safe_load((ROOT / "observability/observability.yaml").read_text())
        self.assertEqual("monitoring", manifest["app"])
        self.assertEqual("monitoring", manifest["folder"])
        self.assertEqual({"central", "local"}, {rule["evaluation"] for rule in manifest["rules"]})
        self.assertEqual("observability-pack", manifest["observabilityPack"]["package"])
        for dashboard in manifest["dashboards"]:
            self.assertTrue(dashboard["uid"].startswith("monitoring-"))
            document = json.loads((ROOT / "observability" / dashboard["file"]).read_text())
            self.assertEqual(dashboard["uid"], document["uid"])
            self.assertEqual("${DS_PROMETHEUS}", document["panels"][0]["datasource"]["uid"])
            self.assertNotIn("workflows_scaffold", json.dumps(document))
        contract = yaml.safe_load((ROOT / "contracts/post-alloy-labels/v1.yaml").read_text())
        self.assertEqual("inari.monitoring.post-alloy-labels/v1", contract["contractVersion"])
        self.assertEqual({"org", "cluster", "job", "instance"}, set(contract["requiredLabels"]))
        schema = json.loads((ROOT / "contracts/post-alloy-labels/v1.schema.json").read_text())
        jsonschema.validate(contract, schema)

    def test_real_alloy_fixture_is_bound_to_contract_and_representative_up_metric(self):
        fixture = json.loads((ROOT / "observability/tests/alloy/expected-central-series.json").read_text())
        self.assertEqual("alloy-v1.13.0", fixture["fixtureVersion"])
        self.assertEqual("inari.monitoring.post-alloy-labels/v1", fixture["labelContract"])
        self.assertEqual("up", fixture["metric"])
        self.assertEqual(1, fixture["value"])
        self.assertEqual({"org": "ci", "cluster": "kind-ci", "job": "mimir", "instance": "ci"}, fixture["labels"])
        self.assertTrue(fixture["reviewRequired"])
        config = (ROOT / "observability/tests/alloy/config.river").read_text()
        self.assertIn('metrics_path    = "/input.prom"', config)

    def test_generated_chart_and_pack_match_central_and_local_assets(self):
        for relative in (
            "packages/observability-pack/rgd.yaml",
            "charts/monitoring/templates/observability/rules.yaml",
        ):
            text = (ROOT / relative).read_text()
            self.assertIn("monitoring:up:sum", text)
            self.assertIn("MonitoringClientDown", text)
            self.assertNotIn("workflows_scaffold", text)
        dashboard = (ROOT / "charts/monitoring/templates/observability/dashboards.yaml").read_text()
        self.assertIn("inari.dev/folder: monitoring", dashboard)
        chart_rules = (ROOT / "charts/monitoring/templates/observability/rules.yaml").read_text()
        self.assertIn("kind: ConfigMap", chart_rules)
        for evaluation in ("central", "local"):
            self.assertIn(f"name: monitoring-{evaluation}-rules", chart_rules)
            self.assertIn(f"{evaluation}.yaml:", chart_rules)
        pack = yaml.safe_load((ROOT / "packages/observability-pack/rgd.yaml").read_text())
        self.assertEqual("inari.observability-pack/v2", pack["metadata"]["annotations"]["inari.dev/observability-render-contract"])
        self.assertNotIn("permissions", yaml.dump(pack))
        self.assertNotIn("GrafanaFolder", yaml.dump(pack))


if __name__ == "__main__":
    unittest.main()
