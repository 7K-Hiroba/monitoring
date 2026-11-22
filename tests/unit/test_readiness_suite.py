from __future__ import annotations

import json
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


class ReadinessSuiteTests(unittest.TestCase):
    def setUp(self):
        self.suite = yaml.safe_load((ROOT / "tests/smoke/suite.yaml").read_text())
        self.workflow = yaml.safe_load((ROOT / "tests/smoke/workflowtemplate.yaml").read_text())

    def test_suite_is_read_only_and_exactly_versioned(self):
        self.assertEqual("inari.smoke.v1", self.suite["suiteSchema"])
        self.assertEqual("monitoring", self.suite["target"]["id"])
        self.assertEqual("0.1.0", self.suite["target"]["version"])
        self.assertEqual("inari.observability.params.v1", self.suite["parameterContract"])
        self.assertEqual(["ci", "stage", "prod"], self.suite["executableProfiles"])
        for profile in self.suite["profiles"].values():
            self.assertEqual("readOnly", profile["sideEffects"])
            self.assertEqual("required", profile["cleanup"])

    def test_workflow_has_no_install_mutation_or_secret_escape(self):
        template = self.workflow["spec"]["templates"][0]
        self.assertEqual("verify", self.workflow["spec"]["entrypoint"])
        self.assertNotIn("resource", template)
        self.assertNotIn("suspend", template)
        container = template["container"]
        self.assertIn("@sha256:", container["image"])
        self.assertTrue(container["securityContext"]["runAsNonRoot"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        text = yaml.safe_dump(self.workflow)
        for forbidden in ("secretKeyRef", "secretRef", "configMapRef", "hostPath", "workflowTemplateRef", "clusterWorkflowTemplateRef", "templateRef", "serviceAccountName", "helm upgrade", "kubectl apply", "Keycloak", "team-sync"):
            self.assertNotIn(forbidden, text)
        compile(container["args"][0], "inline-observability-verifier", "exec")
        self.assertIn('method="GET"', container["args"][0])
        self.assertIn("RejectRedirects", container["args"][0])
        self.assertIn('parsed.scheme != "https" and not ALLOW_PLAINTEXT', container["args"][0])
        self.assertIn('"/api/v1/query?" + urllib.parse.urlencode', container["args"][0])
        self.assertNotIn('urllib.request.urlopen', container["args"][0])
        self.assertNotIn('/api/v1/query?query=" + urllib.parse', container["args"][0])

    def test_ci_context_is_explicit_local_and_fully_bound(self):
        context = json.loads((ROOT / "tests/smoke/fixtures/ci-context.json").read_text())
        self.assertEqual(self.suite["target"]["adapter"]["ciContext"], "fixtures/ci-context.json")
        self.assertEqual("ci", context["suite"]["profile"])
        self.assertEqual("ci-run", context["run"]["id"])
        self.assertEqual("monitoring-overview", context["dashboards"][0]["uid"])
        self.assertEqual(1, len(context["ruleGroups"]))
        for key in ("grafanaBaseUrl", "metricsBaseUrl", "logsBaseUrl"):
            self.assertTrue(context[key].startswith("http://monitoring-"))
            self.assertTrue(context[key].endswith(".default.svc"))
        self.assertNotIn("token", json.dumps(context).lower())

    def test_result_fixtures_use_generic_profiles_and_no_access_claim(self):
        for name in ("central", "local"):
            result = json.loads((ROOT / f"tests/smoke/fixtures/{name}.json").read_text())
            self.assertEqual("ObservabilityVerificationResult", result["kind"])
            self.assertIn(result["suite"]["profile"], ("ci", "stage", "prod"))
            self.assertNotIn("access", result["checks"])
            self.assertTrue(result["checks"]["folder"]["uid"])
            self.assertTrue(result["checks"]["dashboards"])
            self.assertTrue(result["checks"]["datasources"])
            self.assertTrue(result["checks"]["rules"])
            self.assertNotIn("url", json.dumps(result))
        invalid = json.loads((ROOT / "tests/smoke/fixtures/invalid-expired.json").read_text())
        self.assertLess(invalid["expiresAt"], invalid["run"]["finishedAt"])


if __name__ == "__main__":
    unittest.main()
