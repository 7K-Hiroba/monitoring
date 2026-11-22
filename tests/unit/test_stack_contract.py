from __future__ import annotations

import json
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


class StackContractTests(unittest.TestCase):
    def load(self, relative: str):
        path = ROOT / relative
        self.assertTrue(path.is_file(), f"missing required stack file: {relative}")
        return yaml.safe_load(path.read_text())

    def test_full_stack_dependencies_are_exact_and_prometheus_server_is_absent(self):
        chart = self.load("charts/monitoring/Chart.yaml")
        dependencies = {entry["name"]: entry for entry in chart.get("dependencies", [])}
        expected = {
            "mimir-distributed": "6.2.2",
            "grafana": "14.5.0",
            "loki": "7.7.0",
            "alloy": "1.6.0",
            "kube-state-metrics": "9.0.1",
            "prometheus-node-exporter": "5.2.0",
        }
        self.assertEqual(expected, {name: entry["version"] for name, entry in dependencies.items()})
        self.assertNotIn("kube-prometheus-stack", dependencies)
        for name, entry in dependencies.items():
            self.assertTrue(entry["repository"].startswith("https://"), name)
            self.assertTrue(entry["condition"].startswith("components."), name)
        self.assertEqual("1.13.0", self.load("contracts/post-alloy-labels/v1.yaml")["alloyVersion"])

    def test_central_local_and_client_topologies_have_explicit_components(self):
        for topology in ("central", "local", "client"):
            values = self.load(f"charts/monitoring/ci/{topology}-values.yaml")
            self.assertEqual(topology, values["topology"])
            components = values["components"]
            self.assertEqual(topology != "client", components["mimir"])
            self.assertEqual(topology != "client", components["alertmanager"])
            self.assertEqual(topology != "client", components["grafana"])
            self.assertEqual(topology != "client", components["loki"])
            self.assertTrue(components["alloy"])
            self.assertTrue(components["kubeStateMetrics"])
            self.assertTrue(components["nodeExporter"])
            self.assertTrue(values["global"]["collectors"]["kubelet"]["enabled"])
            self.assertTrue(values["global"]["collectors"]["controlPlane"]["enabled"])

    def test_kro_rgd_uses_only_digest_pinned_signed_chart_and_no_prometheus_server(self):
        rgd = self.load("packages/monitoring-stack/rgd.yaml")
        self.assertEqual("ResourceGraphDefinition", rgd["kind"])
        schema = rgd["spec"]["schema"]["spec"]
        for field in ("chartVersion", "chartDigest"):
            self.assertIn(field, schema)
        application = rgd["spec"]["resources"][0]["template"]
        self.assertEqual("Application", application["kind"])
        source = application["spec"]["source"]
        self.assertEqual("ghcr.io/7k-hiroba/monitoring/charts", source["repoURL"])
        self.assertEqual("monitoring", source["chart"])
        self.assertEqual("${schema.spec.chartDigest}", source["targetRevision"])
        rendered = yaml.dump(rgd)
        self.assertNotIn("kube-prometheus-stack", rendered)
        self.assertNotIn("kind: Prometheus\n", rendered)

    def test_workflow_callers_use_the_approved_immutable_release(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            text = path.read_text()
            for line in text.splitlines():
                if "7K-Hiroba/workflows/" in line and "uses:" in line:
                    self.assertIn("118baec9e2a12333a6930b85eb3ddb79e1c85079", line, f"{path}: mutable workflow pin")


if __name__ == "__main__":
    unittest.main()
