from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


class FakeResponse:
    status = 200

    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return json.dumps(self.payload)


class FakeOpener:
    def __init__(self, handler):
        self.handler = handler

    def open(self, request, timeout):
        return FakeResponse(self.handler(request.full_url))


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
        self.assertNotIn("inputs", self.workflow["spec"])
        parameter = self.workflow["spec"]["arguments"]["parameters"][0]
        self.assertEqual("context", parameter["name"])
        self.assertEqual("", parameter["default"])
        self.assertEqual("context", template["inputs"]["parameters"][0]["name"])
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
        self.assertIn("except Exception as error:", container["args"][0])
        self.assertIn("readiness verification failed", container["args"][0])
        self.assertIn("file=sys.stderr", container["args"][0])

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

    def verifier(self):
        source = self.workflow["spec"]["templates"][0]["container"]["args"][0]
        namespace = {"__name__": "monitoring_readiness_test"}
        exec(compile(source, "inline-observability-verifier", "exec"), namespace)
        return namespace

    def ci_context(self):
        return json.loads((ROOT / "tests/smoke/fixtures/ci-context.json").read_text())

    def successful_payload(self, url):
        if url.endswith("/api/folders"):
            return [{"title": "monitoring", "uid": "folder-ci"}]
        if "/api/dashboards/uid/" in url:
            dashboard = json.loads((ROOT / "observability/dashboards/overview.json").read_text())
            return {"dashboard": dashboard, "meta": {"folderUid": "folder-ci", "url": "/d/monitoring-overview/monitoring-stack-overview"}}
        if url.endswith("/api/datasources"):
            return [{"uid": "mimir", "name": "Mimir", "type": "prometheus", "isDefault": True}]
        if "/api/datasources/proxy/" in url:
            return {"status": "success", "data": {"resultType": "vector", "result": []}}
        if url.endswith("/prometheus/api/v1/rules"):
            return {"status": "success", "data": {"groups": [{"name": "monitoring-central", "lastEvaluation": "2026-11-22T00:00:00Z", "rules": [{"health": "ok", "lastError": ""}]}]}}
        if url.endswith("/loki/api/v1/labels"):
            return {"status": "success", "data": []}
        self.fail(f"unexpected readiness URL: {url}")

    def verify_with(self, handler, context=None):
        verifier = self.verifier()
        verifier["OPENER"] = FakeOpener(handler)
        verifier["ALLOW_PLAINTEXT"] = True
        return verifier["verify"](context or self.ci_context(), "")

    def test_verifier_resolves_panel_datasource_and_accepts_healthy_rules(self):
        checks = self.verify_with(self.successful_payload)
        self.assertEqual("mimir", self.ci_context()["datasource"])
        self.assertEqual("monitoring-overview", checks["dashboards"][0]["uid"])
        self.assertEqual("central", checks["rules"][0]["evaluation"])

    def test_verifier_rejects_wrong_panel_datasource(self):
        def wrong_datasource(url):
            payload = copy.deepcopy(self.successful_payload(url))
            if "/api/dashboards/uid/" in url:
                payload["dashboard"]["panels"][0]["datasource"]["uid"] = "other"
            return payload
        with self.assertRaisesRegex(ValueError, "datasource"):
            self.verify_with(wrong_datasource)

    def test_verifier_rejects_unsuccessful_query_body(self):
        def failed_query(url):
            if "/api/datasources/proxy/" in url:
                return {"status": "error", "error": "invalid query"}
            return self.successful_payload(url)
        with self.assertRaisesRegex(ValueError, "panel query"):
            self.verify_with(failed_query)

    def test_verifier_rejects_failed_rule_evaluation(self):
        def failed_rule(url):
            payload = copy.deepcopy(self.successful_payload(url))
            if url.endswith("/prometheus/api/v1/rules"):
                payload["data"]["groups"][0]["rules"][0] = {"health": "error", "lastError": "query failed"}
            return payload
        with self.assertRaisesRegex(ValueError, "rule evaluation"):
            self.verify_with(failed_rule)


if __name__ == "__main__":
    unittest.main()
