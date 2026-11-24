from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.parse
from pathlib import Path
from unittest import mock

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
        for field in ("mimirS3Endpoint", "mimirS3Region", "mimirBlocksBucket", "mimirAlertmanagerBucket", "mimirCredentialsSecret"):
            self.assertIn(field, schema)
        self.assertNotIn("mimirS3ForcePathStyle", schema)
        mimir = rgd["spec"]["resources"][0]["template"]["spec"]["source"]["helm"]["valuesObject"]["mimir-distributed"]
        structured = mimir["mimir"]["structuredConfig"]
        blocks = structured["blocks_storage"]["s3"]
        alerts = structured["alertmanager_storage"]["s3"]
        self.assertNotIn("force_path_style", blocks)
        self.assertNotIn("force_path_style", alerts)
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
            self.assertEqual("10m", values["mimir-distributed"]["rollout_operator"]["resources"]["requests"]["cpu"])
            self.assertEqual("10m", values["kube-state-metrics"]["resources"]["requests"]["cpu"])
            self.assertEqual("50m", self.load("charts/monitoring/values.yaml")["kube-state-metrics"]["resources"]["requests"]["cpu"])
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
        self.assertNotIn("rollout status deployment --all", lifecycle)
        self.assertNotIn("rollout status statefulset --all", lifecycle)
        self.assertNotIn("rollout status daemonset --all", lifecycle)
        self.assertIn("for kind in deployment statefulset daemonset; do", lifecycle)
        self.assertIn('kubectl get "$kind" -n "$namespace" -o name', lifecycle)
        self.assertIn('kubectl rollout status "$resource" -n "$namespace" --timeout=300s', lifecycle)
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

    def test_application_wait_requires_applied_revision_and_successful_operation(self):
        expected = "sha256:" + "a" * 64
        previous = "sha256:" + "b" * 64
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            work = base / "work"
            fake_bin = base / "bin"
            work.mkdir()
            fake_bin.mkdir()
            (work / "registry.env").write_text("HIROBA_REGISTRY_HOST=registry.example:5000\nHIROBA_REGISTRY_LOCAL=127.0.0.1:5000\n")
            kubectl = fake_bin / "kubectl"
            kubectl.write_text("""#!/usr/bin/env bash
case "$*" in
  *status.health.status*) printf Healthy ;;
  *status.sync.status*) printf Synced ;;
  *status.sync.revision*) printf '%s' "$APPLIED_DIGEST" ;;
  *status.operationState.phase*) printf '%s' "$OPERATION_PHASE" ;;
  *spec.source.targetRevision*) printf '%s' "$EXPECTED_DIGEST" ;;
  *chart-version*) printf '0.1.0' ;;
  *) exit 1 ;;
esac
""")
            kubectl.chmod(0o755)

            def run_wait(applied, phase):
                env = os.environ.copy()
                env.update({
                    "PATH": str(fake_bin) + os.pathsep + env["PATH"],
                    "HIROBA_STACK_ROOT": str(ROOT),
                    "HIROBA_STACK_WORK": str(work),
                    "EXPECTED_DIGEST": expected,
                    "APPLIED_DIGEST": applied,
                    "OPERATION_PHASE": phase,
                })
                return subprocess.run(
                    ["timeout", "1", "bash", "-c", f'source "{ROOT}/tests/stack/lifecycle-lib.sh"; wait_for_application monitoring-central "$EXPECTED_DIGEST" 0.1.0'],
                    env=env,
                    text=True,
                    capture_output=True,
                    check=False,
                    timeout=5,
                )

            stale = run_wait(previous, "Succeeded")
            self.assertEqual(stale.returncode, 124, stale.stdout + stale.stderr)
            running = run_wait(expected, "Running")
            self.assertEqual(running.returncode, 124, running.stdout + running.stderr)
            converged = run_wait(expected, "Succeeded")
            self.assertEqual(converged.returncode, 0, converged.stdout + converged.stderr)

    def test_pr_evidence_distinguishes_head_and_merge_tree(self):
        integration = (ROOT / ".github/workflows/integration.yml").read_text()
        self.assertIn("merge tree", integration)
        readme = (ROOT / "tests/stack/README.md").read_text()
        self.assertIn("head_sha", readme)
        self.assertIn("sourceSha", readme)

    def test_workflow_callers_use_the_approved_immutable_release(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            text = path.read_text()
            for line in text.splitlines():
                if "7K-Hiroba/workflows/" in line and "uses:" in line:
                    self.assertIn("f092eab6bb07de64a2d6f2e35ac4c65fca794f76", line, f"{path}: mutable workflow pin")

    def test_edge_release_is_manual_only_and_pin_unchanged(self):
        edge = self.load(".github/workflows/edge.yml")
        triggers = edge.get("on") or edge.get(True) or {}
        self.assertNotIn("push", triggers, "merges must not trigger edge publication")
        self.assertIn("workflow_dispatch", triggers, "edge must remain manually dispatchable")
        text = (ROOT / ".github/workflows/edge.yml").read_text()
        self.assertIn(
            "7K-Hiroba/workflows/.github/workflows/edge.yml@f092eab6bb07de64a2d6f2e35ac4c65fca794f76 # v2.0.3",
            text,
        )
        self.assertIn("packages: write", text)

class ReleaseGateBehaviorTests(unittest.TestCase):
    repository = "7K-Hiroba/monitoring"
    release_branch = "release-please--branches--main"

    @classmethod
    def setUpClass(cls):
        workflow = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        cls.gate_source = next(
            step["run"] for step in workflow["jobs"]["gate"]["steps"] if step.get("id") == "gate"
        )

    def git(self, root, *args):
        return subprocess.run(
            ["git", "-C", str(root), *args],
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip()

    def history(
        self,
        root,
        *,
        form,
        branch,
        merge_subject,
        base_manifest,
        current_manifest,
        current_manifest_text,
        changelog_version,
        config,
        omit_manifest,
        omit_changelog,
        omit_extra,
        root_changelog_only,
        base_extra_overrides,
        current_extra_overrides,
    ):
        root.mkdir()
        self.git(root, "init", "-q", "-b", "main")
        self.git(root, "config", "user.name", "Release Gate Test")
        self.git(root, "config", "user.email", "release-gate@example.invalid")
        (root / "release-please-config.json").write_text(json.dumps(config))
        (root / ".release-please-manifest.json").write_text(json.dumps(base_manifest) + "\n")

        def component_file(path, relative, version):
            target = root / path / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f"version: {version}\nname: release-fixture\n")
            return target

        for path, package in config["packages"].items():
            changelog = root / path / package["changelog-path"]
            changelog.parent.mkdir(parents=True, exist_ok=True)
            changelog.write_text("# Changelog\n")
            for extra in package.get("extra-files", []):
                version = base_extra_overrides.get(path, base_manifest[path])
                component_file(path, extra, version)
        self.git(root, "add", "--", ".")
        self.git(root, "commit", "-qm", "chore: base")
        base_sha = self.git(root, "rev-parse", "HEAD")

        self.git(root, "switch", "-qc", branch)
        if omit_manifest:
            (root / ".release-please-manifest.json").unlink()
        elif current_manifest_text is not None:
            (root / ".release-please-manifest.json").write_text(current_manifest_text)
        else:
            (root / ".release-please-manifest.json").write_text(json.dumps(current_manifest) + "\n")

        deltas = [
            path for path in set(base_manifest) | set(current_manifest)
            if base_manifest.get(path) != current_manifest.get(path)
        ]
        for index, path in enumerate(config["packages"]):
            package = config["packages"][path]
            if path in deltas and not root_changelog_only:
                changelog = root / path / package["changelog-path"]
                if omit_changelog and index == 0:
                    changelog.unlink()
                else:
                    version = changelog_version if len(deltas) == 1 else current_manifest[path]
                    changelog.write_text(
                        f"# Changelog\n\n## [{version}](https://example.invalid/release) (2026-11-24)\n"
                    )
            for extra_index, extra in enumerate(package.get("extra-files", [])):
                if path not in deltas and path not in current_extra_overrides:
                    continue
                target = root / path / extra
                if omit_extra and index == 0 and extra_index == 0:
                    target.unlink()
                    continue
                version = current_extra_overrides.get(path, current_manifest.get(path, base_manifest[path]))
                component_file(path, extra, version)
        if root_changelog_only:
            (root / "CHANGELOG.md").write_text(
                f"# Changelog\n\n## [{changelog_version}](https://example.invalid/release)\n"
            )
        (root / "release-fixture.txt").write_text(f"{branch} {form}\n")
        self.git(root, "add", "--", ".")
        self.git(root, "commit", "-qm", "chore: release producer commit")
        head_sha = self.git(root, "rev-parse", "HEAD")

        self.git(root, "switch", "-q", "main")
        if form == "merge":
            self.git(root, "merge", "-q", "--no-ff", branch, "-m", merge_subject)
        elif form == "squash":
            self.git(root, "merge", "-q", "--squash", branch)
            self.git(root, "commit", "-qm", merge_subject)
        elif form == "rebase":
            self.git(root, "cherry-pick", branch)
        else:
            self.fail(f"unknown test merge form {form}")
        return self.git(root, "rev-parse", "HEAD"), base_sha, head_sha

    def run_gate(
        self,
        *,
        event="push",
        repair_tag="",
        form="merge",
        branch=release_branch,
        title="edited title",
        merge_subject="edited merge subject",
        base_manifest=None,
        current_manifest=None,
        current_manifest_text=None,
        changelog_version="0.2.0",
        config=None,
        omit_manifest=False,
        omit_changelog=False,
        omit_extra=False,
        root_changelog_only=False,
        base_extra_overrides=None,
        current_extra_overrides=None,
        associated=None,
        pr_transform=None,
        pr_files=None,
        existing_tags=(),
        api_error="",
    ):
        base_manifest = base_manifest or json.loads((ROOT / ".release-please-manifest.json").read_text())
        if current_manifest is None:
            current_manifest = dict(base_manifest)
            current_manifest["charts/monitoring"] = "0.2.0"
        config = config or json.loads((ROOT / "release-please-config.json").read_text())
        base_extra_overrides = base_extra_overrides or {}
        current_extra_overrides = current_extra_overrides or {}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "consumer"
            if event == "push":
                sha, base_sha, head_sha = self.history(
                    root,
                    form=form,
                    branch=branch,
                    merge_subject=merge_subject,
                    base_manifest=base_manifest,
                    current_manifest=current_manifest,
                    current_manifest_text=current_manifest_text,
                    changelog_version=changelog_version,
                    config=config,
                    omit_manifest=omit_manifest,
                    omit_changelog=omit_changelog,
                    omit_extra=omit_extra,
                    root_changelog_only=root_changelog_only,
                    base_extra_overrides=base_extra_overrides,
                    current_extra_overrides=current_extra_overrides,
                )
            else:
                root.mkdir()
                sha, base_sha, head_sha = "a" * 40, "b" * 40, "c" * 40

            if associated is None:
                associated = [{"number": 7, "merge_commit_sha": sha}]
            elif associated == "multiple":
                associated = [
                    {"number": 7, "merge_commit_sha": sha},
                    {"number": 8, "merge_commit_sha": sha},
                ]
            pr = {
                "number": 7,
                "state": "closed",
                "merged": True,
                "merged_at": "2026-11-24T12:00:00Z",
                "merge_commit_sha": sha,
                "title": title,
                "base": {
                    "ref": "main",
                    "sha": base_sha,
                    "repo": {"full_name": self.repository, "fork": False},
                },
                "head": {
                    "ref": branch,
                    "sha": head_sha,
                    "repo": {"full_name": self.repository, "fork": False},
                },
            }
            if pr_transform:
                pr_transform(pr)
            if pr_files is None:
                deltas = [
                    path for path in set(base_manifest) | set(current_manifest)
                    if base_manifest.get(path) != current_manifest.get(path)
                ]
                component_path = deltas[0] if deltas else "charts/monitoring"
                package = config["packages"][component_path]
                filenames = {".release-please-manifest.json"}
                if root_changelog_only:
                    filenames.add("CHANGELOG.md")
                else:
                    filenames.add(f"{component_path}/{package['changelog-path']}")
                filenames.update(
                    f"{component_path}/{extra}" for extra in package.get("extra-files", [])
                )
                pr_files = [{"filename": filename} for filename in sorted(filenames)]

            class Response:
                def __init__(self, payload):
                    self.payload = json.dumps(payload).encode()
                    self.headers = {}

                def __enter__(self):
                    return self

                def __exit__(self, *args):
                    return None

                def read(self):
                    return self.payload

            requests = []

            def fake_urlopen(request, timeout):
                self.assertEqual(timeout, 30)
                url = request.full_url
                requests.append(url)
                path = urllib.parse.urlsplit(url).path
                prefix = f"/repos/{self.repository}"
                association_path = f"{prefix}/commits/{sha}/pulls"
                detail_path = f"{prefix}/pulls/7"
                files_path = f"{detail_path}/files"

                def reply(payload, status=200):
                    if status != 200:
                        raise urllib.error.HTTPError(
                            url, status, "mock API response", None, io.BytesIO(b"{}")
                        )
                    return Response(payload)

                if path == association_path:
                    if api_error == "association":
                        return reply({}, 500)
                    return reply(associated)
                if path == detail_path:
                    if api_error == "detail":
                        return reply({}, 500)
                    return reply(pr)
                if path == files_path:
                    if api_error == "files":
                        return reply({}, 500)
                    return reply(pr_files)
                if path.startswith(f"{prefix}/git/ref/tags/"):
                    if api_error == "tag":
                        return reply({}, 500)
                    tag = urllib.parse.unquote(path.rsplit("/", 1)[-1])
                    if tag in existing_tags:
                        return reply({"ref": f"refs/tags/{tag}"})
                    return reply({}, 404)
                return reply({}, 500)

            output = Path(temporary) / "github-output"
            output.write_text("")
            namespace = {"__name__": "release_gate_test"}
            exec(compile(self.gate_source, ".github/workflows/release.yml", "exec"), namespace)
            env = {
                "CHECKOUT_ROOT": str(root),
                "GITHUB_API_URL": "https://api.github.test",
                "GITHUB_REPOSITORY": self.repository,
                "GITHUB_SHA": sha,
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_NAME": event,
                "GITHUB_OUTPUT": str(output),
                "GH_TOKEN": "unit-test-token",
                "REPAIR_TAG": repair_tag,
            }
            stdout, stderr = io.StringIO(), io.StringIO()
            exit_code = 0
            with mock.patch.dict(os.environ, env), mock.patch.dict(namespace, {"urlopen": fake_urlopen}):
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    try:
                        namespace["main"]()
                    except SystemExit as error:
                        exit_code = error.code or 0
            lines = output.read_text().splitlines()
            self.assertEqual(len(lines), 1, lines)
            should_release = lines[0] == "should_release=true"
            self.assertIn(lines[0], ("should_release=true", "should_release=false"))
            return {
                "should_release": should_release,
                "exit_code": exit_code,
                "logs": stdout.getvalue() + stderr.getvalue(),
                "requests": requests,
            }

    def test_only_genuine_release_pr_results_enable_release(self):
        for form in ("merge", "squash", "rebase"):
            with self.subTest(form=form):
                result = self.run_gate(
                    form=form,
                    title="an edited title is not an identity",
                    merge_subject="chore: release forged-looking subject",
                )
                self.assertTrue(result["should_release"], result)
                self.assertEqual(result["exit_code"], 0, result)

    def test_ordinary_and_forged_subjects_skip_stable_release(self):
        cases = {
            "no merged PR": {"associated": []},
            "ordinary merge with chore subject": {
                "branch": "feature/ordinary",
                "merge_subject": "chore: release not-a-release",
            },
            "forged title and subject": {
                "branch": "feature/forged",
                "title": "chore: release forged",
                "merge_subject": "chore: release forged",
            },
        }
        for name, kwargs in cases.items():
            with self.subTest(name=name):
                result = self.run_gate(**kwargs)
                self.assertFalse(result["should_release"], result)
                self.assertEqual(result["exit_code"], 0, result)

    def test_release_pr_identity_and_api_fail_closed(self):
        cases = {
            "wrong head repository": lambda pr: pr["head"]["repo"].update(full_name="fork/monitoring"),
            "fork head repository": lambda pr: pr["head"]["repo"].update(fork=True),
            "wrong base branch": lambda pr: pr["base"].update(ref="develop"),
            "wrong base repository": lambda pr: pr["base"]["repo"].update(full_name="fork/monitoring"),
            "wrong merged SHA": lambda pr: pr.update(merge_commit_sha="0" * 40),
            "not merged": lambda pr: pr.update(merged=False, merged_at=None),
        }
        for name, transform in cases.items():
            with self.subTest(name=name):
                result = self.run_gate(pr_transform=transform)
                self.assertFalse(result["should_release"], result)
                self.assertNotEqual(result["exit_code"], 0, result)
        for name, kwargs in {
            "ambiguous merged PRs": {"associated": "multiple"},
            "association API failure": {"api_error": "association"},
            "detail API failure": {"api_error": "detail"},
        }.items():
            with self.subTest(name=name):
                result = self.run_gate(**kwargs)
                self.assertFalse(result["should_release"], result)
                self.assertNotEqual(result["exit_code"], 0, result)

    def test_release_metadata_and_tags_fail_closed(self):
        base = json.loads((ROOT / ".release-please-manifest.json").read_text())
        invalid = dict(base, **{"charts/monitoring": "01.2.0"})
        unchanged = dict(base)
        downgrade = dict(base, **{"charts/monitoring": "0.0.9"})
        multiple = dict(base, **{
            "charts/monitoring": "0.2.0",
            "packages/monitoring-stack": "1.4.0",
        })
        cases = {
            "missing manifest": {"omit_manifest": True},
            "invalid manifest JSON": {"current_manifest_text": "{"},
            "invalid semver": {"current_manifest": invalid},
            "unchanged metadata": {"current_manifest": unchanged},
            "downgrade": {"current_manifest": downgrade, "changelog_version": "0.0.9"},
            "multiple deltas": {"current_manifest": multiple},
            "root changelog only": {"root_changelog_only": True},
            "missing component changelog": {"omit_changelog": True},
            "missing component extra-file": {"omit_extra": True},
            "new extra-file mismatch": {
                "current_extra_overrides": {"charts/monitoring": "0.3.0"}
            },
            "old extra-file mismatch": {
                "base_extra_overrides": {"charts/monitoring": "0.1.1"}
            },
            "unchanged component config drift": {
                "current_extra_overrides": {"packages/monitoring-stack": "1.3.1"}
            },
            "component changelog missing version": {"changelog_version": "9.9.9"},
            "manifest absent from PR": {
                "pr_files": [
                    {"filename": "charts/monitoring/CHANGELOG.md"},
                    {"filename": "charts/monitoring/Chart.yaml"},
                ]
            },
            "component changelog absent from PR": {
                "pr_files": [
                    {"filename": ".release-please-manifest.json"},
                    {"filename": "charts/monitoring/Chart.yaml"},
                ]
            },
            "extra-file absent from PR": {
                "pr_files": [
                    {"filename": ".release-please-manifest.json"},
                    {"filename": "charts/monitoring/CHANGELOG.md"},
                ]
            },
            "existing global tag": {"existing_tags": ("v0.2.0",)},
            "existing component tag": {"existing_tags": ("chart-monitoring-v0.2.0",)},
            "files API failure": {"api_error": "files"},
            "tag API failure": {"api_error": "tag"},
        }
        for name, kwargs in cases.items():
            with self.subTest(name=name):
                result = self.run_gate(**kwargs)
                self.assertFalse(result["should_release"], result)
                self.assertNotEqual(result["exit_code"], 0, result)

    def test_genuine_chart_and_package_layouts_pass_and_check_both_tags(self):
        base = json.loads((ROOT / ".release-please-manifest.json").read_text())
        cases = {
            "chart": ("charts/monitoring", "0.2.0", "chart-monitoring-v0.2.0"),
            "stack package": (
                "packages/monitoring-stack", "1.4.0", "package-monitoring-stack-v1.4.0"
            ),
            "observability package": (
                "packages/observability-pack", "0.2.0", "package-observability-pack-v0.2.0"
            ),
        }
        for name, (path, version, component_tag) in cases.items():
            with self.subTest(name=name):
                current = dict(base)
                current[path] = version
                result = self.run_gate(
                    current_manifest=current,
                    changelog_version=version,
                )
                self.assertTrue(result["should_release"], result)
                self.assertEqual(result["exit_code"], 0, result)
                self.assertTrue(any(url.endswith(f"/git/ref/tags/v{version}") for url in result["requests"]))
                self.assertTrue(any(url.endswith(f"/git/ref/tags/{component_tag}") for url in result["requests"]))

    def test_dispatch_is_repair_only(self):
        empty = self.run_gate(event="workflow_dispatch", repair_tag="")
        self.assertFalse(empty["should_release"], empty)
        self.assertEqual(empty["exit_code"], 0, empty)
        self.assertIn("repair_tag", empty["logs"])
        self.assertEqual(empty["requests"], [])

        repair = self.run_gate(event="workflow_dispatch", repair_tag="v1.1.0")
        self.assertTrue(repair["should_release"], repair)
        self.assertEqual(repair["exit_code"], 0, repair)
        self.assertEqual(repair["requests"], [])

    def test_release_please_credential_preflight_handles_each_missing_input(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/release-please.yml").read_text())
        jobs = workflow["jobs"]
        script = next(
            step["run"]
            for step in jobs["preflight"]["steps"]
            if step.get("id") == "credentials"
        )
        for app_id, private_key, configured in (
            ("", "", "false"),
            ("12345", "", "false"),
            ("", "private-key-material", "false"),
            ("12345", "private-key-material", "true"),
        ):
            with self.subTest(app_id=bool(app_id), private_key=bool(private_key)):
                with tempfile.TemporaryDirectory() as temporary:
                    output = Path(temporary) / "output"
                    env = os.environ.copy()
                    env.update(
                        RELEASE_APP_ID=app_id,
                        RELEASE_PRIVATE_KEY=private_key,
                        GITHUB_OUTPUT=str(output),
                    )
                    result = subprocess.run(
                        ["bash", "-c", script], env=env, text=True, capture_output=True, check=False
                    )
                    contents = output.read_text()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(contents, f"configured={configured}\n")
                    if private_key:
                        self.assertNotIn(private_key, result.stdout + result.stderr + contents)
        self.assertEqual(jobs["propose"]["needs"], "preflight")
        self.assertEqual(jobs["propose"]["if"], "needs.preflight.outputs.configured == 'true'")
        self.assertEqual(jobs["not-configured"]["if"], "needs.preflight.outputs.configured != 'true'")
        self.assertNotIn("secrets.", str(jobs["propose"]["if"]))


if __name__ == "__main__":
    unittest.main()
