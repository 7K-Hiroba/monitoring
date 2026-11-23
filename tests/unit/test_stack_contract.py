from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

import jsonschema
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

    def test_kro_rgd_uses_exact_version_and_retains_digest_evidence(self):
        rgd = self.load("packages/monitoring-stack/rgd.yaml")
        self.assertEqual("ResourceGraphDefinition", rgd["kind"])
        schema = rgd["spec"]["schema"]
        for field in ("chartVersion", "chartDigest"):
            self.assertIn(field, schema["spec"])
        self.assertEqual({"ready"}, set(schema["status"]))
        self.assertNotIn("schema.spec", schema["status"]["ready"])
        application = rgd["spec"]["resources"][0]["template"]
        self.assertEqual("Application", application["kind"])
        source = application["spec"]["source"]
        self.assertEqual("oci://ghcr.io/7k-hiroba/monitoring/charts/monitoring", source["repoURL"])
        self.assertEqual(".", source["path"])
        self.assertNotIn("chart", source)
        self.assertEqual("${schema.spec.chartDigest}", source["targetRevision"])
        self.assertEqual("${schema.spec.chartVersion}", application["metadata"]["annotations"]["inari.dev/chart-version"])
        self.assertEqual("${schema.spec.chartDigest}", application["metadata"]["annotations"]["inari.dev/chart-digest"])
        rendered = yaml.dump(rgd)
        self.assertNotIn("kube-prometheus-stack", rendered)
        self.assertNotIn("kind: Prometheus\n", rendered)

    def test_mimir_uses_read_only_local_rule_storage_and_writable_scratch(self):
        values = self.load("charts/monitoring/values.yaml")
        ruler = values["mimir-distributed"]["ruler"]
        config = values["mimir-distributed"]["mimir"]["structuredConfig"]
        self.assertFalse(config["ingest_storage"]["enabled"])
        self.assertTrue(config["ingester"]["push_grpc_method_enabled"])
        self.assertEqual(1, config["ingester"]["ring"]["replication_factor"])
        self.assertEqual("/data/ruler", config["ruler"]["rule_path"])
        self.assertEqual("local", config["ruler_storage"]["backend"])
        self.assertEqual("/data/rules", config["ruler_storage"]["local"]["directory"])
        self.assertEqual(1, len(ruler["extraVolumes"]))
        sources = ruler["extraVolumes"][0]["projected"]["sources"]
        self.assertEqual(2, len(sources))
        for evaluation, source in zip(("central", "local"), sources):
            volume = source["configMap"]
            self.assertEqual(f"monitoring-{evaluation}-rules", volume["name"])
            self.assertEqual(f"{evaluation}.yaml", volume["items"][0]["key"])
            self.assertEqual(f"anonymous/{evaluation}.yaml", volume["items"][0]["path"])
        self.assertEqual("/data/rules", ruler["extraVolumeMounts"][0]["mountPath"])
        self.assertTrue(ruler["extraVolumeMounts"][0]["readOnly"])

    def test_required_org_label_flows_through_chart_and_rgd(self):
        values = self.load("charts/monitoring/values.yaml")
        self.assertTrue(values["global"]["telemetry"]["org"])
        alloy = values["alloy"]["alloy"]["configMap"]["content"]
        self.assertIn('target_label = "org"', alloy)
        self.assertIn('replacement = {{ .Values.global.telemetry.org | quote }}', alloy)
        self.assertIn('headers = {"X-Scope-OrgID" = {{ .Values.global.telemetry.org | quote }}}', alloy)
        chart_schema = self.load("charts/monitoring/values.schema.json")
        self.assertEqual(1, chart_schema["properties"]["global"]["properties"]["telemetry"]["properties"]["org"]["minLength"])
        rgd = self.load("packages/monitoring-stack/rgd.yaml")
        self.assertEqual("string | required=true", rgd["spec"]["schema"]["spec"]["org"])
        telemetry = rgd["spec"]["resources"][0]["template"]["spec"]["source"]["helm"]["valuesObject"]["global"]["telemetry"]
        self.assertEqual("${schema.spec.org}", telemetry["org"])
        package_schema = self.load("packages/monitoring-stack/values.schema.json")
        self.assertIn("org", package_schema["required"])

    def test_grafana_mimir_datasource_includes_prometheus_api_base(self):
        template = (ROOT / "charts/monitoring/templates/datasources.yaml").read_text()
        self.assertIn("mimir-gateway.{{ .Release.Namespace }}.svc:80/prometheus", template)

    def test_loki_single_binary_uses_a_single_replica_ring(self):
        values = self.load("charts/monitoring/values.yaml")
        self.assertEqual("SingleBinary", values["loki"]["deploymentMode"])
        self.assertEqual(1, values["loki"]["singleBinary"]["replicas"])
        self.assertEqual(1, values["loki"]["loki"]["commonConfig"]["replication_factor"])

    def test_component_scrapes_follow_component_gates_and_label_pipeline(self):
        content = self.load("charts/monitoring/values.yaml")["alloy"]["alloy"]["configMap"]["content"]
        for component in ("mimir", "grafana", "loki", "alloy"):
            self.assertIn(f'prometheus.scrape "{component}"', content)
        self.assertEqual(3, content.count('if ne .Values.global.topology "client"'))
        self.assertNotIn('mimir-gateway.{{ .Release.Namespace }}.svc:8080", "job" = "mimir"', content)
        self.assertEqual("SingleBinary", self.load("charts/monitoring/values.yaml")["loki"]["deploymentMode"])
        self.assertGreaterEqual(content.count("forward_to = [prometheus.relabel.central.receiver]"), 8)
        self.assertIn("targets = discovery.kubernetes.pods.targets", content)
        rbac = (ROOT / "charts/monitoring/templates/collector-rbac.yaml").read_text()
        self.assertIn("pods/log", rbac)

    def test_rgd_loki_storage_supports_ephemeral_and_external_secret_reference(self):
        rgd = self.load("packages/monitoring-stack/rgd.yaml")
        schema = rgd["spec"]["schema"]["spec"]
        for field in ("lokiS3Endpoint", "lokiS3Region", "lokiChunksBucket", "lokiRulerBucket", "lokiCredentialsSecret", "lokiS3ForcePathStyle"):
            self.assertIn(field, schema)
        loki = rgd["spec"]["resources"][0]["template"]["spec"]["source"]["helm"]["valuesObject"]["loki"]
        expected = '${schema.spec.ephemeralObjectStorage ? "filesystem" : "s3"}'
        self.assertEqual(expected, loki["loki"]["storage"]["type"])
        self.assertEqual(expected, loki["loki"]["schemaConfig"]["configs"][0]["object_store"])
        secret = loki["singleBinary"]["extraEnvFrom"][0]["secretRef"]
        self.assertTrue(secret["optional"])
        self.assertIn("schema.spec.lokiCredentialsSecret", secret["name"])
        rendered = yaml.dump(rgd)
        self.assertNotIn("secretAccessKey", rendered)
        self.assertNotIn("accessKeyId", rendered)

    def test_rgd_mimir_and_alertmanager_support_external_storage(self):
        rgd = self.load("packages/monitoring-stack/rgd.yaml")
        schema = rgd["spec"]["schema"]["spec"]
        for field in ("mimirS3Endpoint", "mimirS3Region", "mimirBlocksBucket", "mimirAlertmanagerBucket", "mimirCredentialsSecret", "mimirS3ForcePathStyle"):
            self.assertIn(field, schema)
        mimir = rgd["spec"]["resources"][0]["template"]["spec"]["source"]["helm"]["valuesObject"]["mimir-distributed"]
        structured = mimir["mimir"]["structuredConfig"]
        blocks = structured["blocks_storage"]["s3"]
        alerts = structured["alertmanager_storage"]["s3"]
        self.assertIn("schema.spec.mimirBlocksBucket", blocks["bucket_name"])
        self.assertIn("schema.spec.mimirAlertmanagerBucket", alerts["bucket_name"])
        self.assertIn("schema.spec.mimirS3Endpoint", blocks["endpoint"])
        self.assertIn("schema.spec.mimirS3Endpoint", alerts["endpoint"])
        secret = mimir["global"]["extraEnvFrom"][0]["secretRef"]
        self.assertTrue(secret["optional"])
        self.assertIn("schema.spec.mimirCredentialsSecret", secret["name"])
        status = rgd["spec"]["schema"]["status"]["ready"]
        self.assertIn('application.?status.?health.?status.orValue("")', status)
        self.assertIn('application.?status.?sync.?status.orValue("")', status)
        rendered = yaml.dump(rgd)
        self.assertNotIn("secretAccessKey", rendered)
        self.assertNotIn("accessKeyId", rendered)

    def test_monitoring_stack_fixtures_match_package_schema(self):
        schema = self.load("packages/monitoring-stack/values.schema.json")
        for path in (ROOT / "packages/monitoring-stack/tests").glob("*.yaml"):
            with self.subTest(path=path.name):
                jsonschema.validate(self.load(path.relative_to(ROOT).as_posix())["spec"], schema)

    def test_chart_testing_reuses_prepared_locked_dependencies(self):
        self.assertTrue(self.load("ci/ct.yaml")["skip-helm-dependencies"])

    def test_ephemeral_ci_loki_is_writable_and_does_not_reserve_large_caches(self):
        paths = [
            "charts/monitoring/ci/central-values.yaml",
            "charts/monitoring/ci/local-values.yaml",
            "charts/monitoring/ci/kind-values.yaml",
            "tests/smoke/values.yaml",
        ]
        for relative in paths:
            values = self.load(relative)
            with self.subTest(path=relative):
                loki = values["loki"]
                self.assertFalse(loki["chunksCache"]["enabled"])
                self.assertFalse(loki["resultsCache"]["enabled"])
                single = loki["singleBinary"]
                self.assertFalse(single["persistence"]["enabled"])
                volumes = {volume["name"]: volume for volume in single["extraVolumes"]}
                self.assertEqual({}, volumes["loki-data"]["emptyDir"])
                mounts = {mount["name"]: mount for mount in single["extraVolumeMounts"]}
                self.assertEqual("/var/loki", mounts["loki-data"]["mountPath"])
                for component in ("ingester", "compactor", "store_gateway"):
                    resources = values["mimir-distributed"][component]["resources"]
                    self.assertEqual("10m", resources["requests"]["cpu"])

    def test_kro_tests_prepare_argocd_namespace_and_crd(self):
        text = (ROOT / "packages/monitoring-stack/tests/run.sh").read_text()
        self.assertIn("kubectl create namespace argocd", text)
        self.assertIn("wait_for_condition crd/applications.argoproj.io Established 60", text)
        self.assertIn("wait_for_condition rgd/monitoring-stack Ready 120", text)
        self.assertLess(text.index("crd/applications.argoproj.io"), text.index("rgd.yaml"))
        stack = (ROOT / "tests/stack/install.sh").read_text()
        self.assertNotIn("kubectl create namespace argocd", stack)
        self.assertNotIn("manifests/core-install.yaml", stack)
        self.assertIn("argocd", self.load("tests/stack/suite.yaml")["setupProfiles"])
        self.assertIn("kubectl apply -f \"$WORK/rgd.yaml\"", stack)

    def test_kind_local_renderer_binds_real_digest_and_all_topologies(self):
        spec = importlib.util.spec_from_file_location("monitoring_kind_render_local", ROOT / "tests/stack/render-local.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        digest = "sha256:" + "0" * 64
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            module.render(ROOT, work, "registry.registry.svc:5000", digest, "192.0.2.10:6443")
            rgd = self.load((work / "rgd.yaml").as_posix())
            source = rgd["spec"]["resources"][0]["template"]["spec"]["source"]
            self.assertEqual("oci://registry.registry.svc:5000/charts/monitoring", source["repoURL"])
            self.assertEqual("${schema.spec.chartDigest}", source["targetRevision"])
            values = source["helm"]["valuesObject"]
            self.assertFalse(values["prometheus-node-exporter"]["hostNetwork"])
            self.assertEqual("10m", values["prometheus-node-exporter"]["resources"]["requests"]["cpu"])
            self.assertTrue(values["global"]["collectors"]["kubelet"]["insecureSkipVerify"])
            self.assertTrue(values["global"]["collectors"]["controlPlane"]["insecureSkipVerify"])
            self.assertEqual("10m", values["mimir-distributed"]["ingester"]["resources"]["requests"]["cpu"])
            self.assertFalse(values["loki"]["chunksCache"]["enabled"])
            self.assertEqual("/var/loki", values["loki"]["singleBinary"]["extraVolumeMounts"][0]["mountPath"])
            self.assertIn("blocks_storage", values["mimir-distributed"]["mimir"]["structuredConfig"])
            for topology in ("central", "local", "client"):
                fixture = self.load((work / f"{topology}.yaml").as_posix())["spec"]
                self.assertEqual(digest, fixture["chartDigest"])
                self.assertEqual("0.1.0", fixture["chartVersion"])
                self.assertEqual("192.0.2.10:6443", fixture["controlPlaneTargets"])
                self.assertEqual("monitoring" if topology == "central" else f"monitoring-{topology}", fixture["namespace"])
            module.render(ROOT, work, "registry.registry.svc:5000", digest, "192.0.2.10:6443", chart_version="0.1.0-ci.0")
            for topology in ("central", "local", "client"):
                fixture = self.load((work / f"{topology}.yaml").as_posix())["spec"]
                self.assertEqual("0.1.0-ci.0", fixture["chartVersion"])
            client = self.load((work / "client.yaml").as_posix())["spec"]
            self.assertEqual("http://monitoring-mimir-gateway.monitoring.svc:80/api/v1/push", client["remoteWriteUrl"])
            self.assertEqual("http://monitoring-loki-gateway.monitoring.svc:80/loki/api/v1/push", client["lokiPushUrl"])
        canonical = self.load("packages/monitoring-stack/rgd.yaml")
        self.assertEqual("oci://ghcr.io/7k-hiroba/monitoring/charts/monitoring", canonical["spec"]["resources"][0]["template"]["spec"]["source"]["repoURL"])

    def test_shared_stack_suite_scopes_install_upgrade_without_functional_e2e(self):
        config = self.load(".hiroba.yaml")
        self.assertEqual("inari.hiroba.app.v2", config["schema"])
        self.assertEqual("stack", config["archetype"])
        self.assertEqual("tests/stack", config["stackTest"]["path"])
        suite = self.load("tests/stack/suite.yaml")
        self.assertEqual(["kro", "argocd", "oci-registry"], suite["setupProfiles"])
        self.assertEqual({"charts/monitoring", "packages/monitoring-stack", "packages/observability-pack"}, set(suite["covers"]))
        install = (ROOT / "tests/stack/install.sh").read_text()
        upgrade = (ROOT / "tests/stack/upgrade.sh").read_text()
        lifecycle = (ROOT / "tests/stack/lifecycle-lib.sh").read_text()
        for text in (install, upgrade, lifecycle):
            self.assertNotIn("kind create cluster", text)
            self.assertNotIn("kind delete cluster", text)
            self.assertNotIn("ARGOCD_COMMIT=", text)
            self.assertNotIn("KIND_IMAGE=", text)
            self.assertNotIn("REGISTRY_IMAGE=", text)
            self.assertNotIn("REDIS_IMAGE=", text)
            for functional in ("/prometheus/api/v1/query", "/prometheus/api/v1/rules", "/loki/api/v1/labels", "/alertmanager/api/v2/status", "/api/dashboards/uid"):
                self.assertNotIn(functional, text)
        self.assertIn("PREVIOUS_CHART_VERSION", install)
        self.assertIn("prepare-chart.py", install)
        for text in (install, upgrade):
            self.assertIn("for topology in central local client; do", text)
        self.assertIn("PREVIOUS_CHART_DIGEST", install)
        self.assertIn("INGESTER_PVC_UID", install)
        self.assertIn("CLIENT_REMOTE_WRITE", install)
        self.assertIn("kind: AppProject", install)
        self.assertIn('insecureOCIForceHttp: "true"', install)
        self.assertIn("CHART_DIGEST", upgrade)
        self.assertIn("CLIENT_LOKI_PUSH", upgrade)
        self.assertIn('test "$(kubectl get pvc "$INGESTER_PVC"', upgrade)
        self.assertIn("wait_for_application", lifecycle)
        self.assertIn("wait_for_stack", lifecycle)
        self.assertIn("deployment/monitoring-client-kube-state-metrics", install)
        self.assertIn("daemonset/monitoring-client-alloy", install)
        self.assertNotIn('helm upgrade --install "$release"', install + upgrade)

    def test_workflow_callers_use_the_approved_immutable_release(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            text = path.read_text()
            for line in text.splitlines():
                if "7K-Hiroba/workflows/" in line and "uses:" in line:
                    self.assertIn("dd42626e804aa4540351d4e7fcc1d2ea30101986", line, f"{path}: mutable workflow pin")


if __name__ == "__main__":
    unittest.main()
