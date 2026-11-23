#!/usr/bin/env python3
"""Render CI-only local-registry inputs without changing the signed RGD."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import yaml


def merge_values(target: dict, overlay: dict) -> None:
    """Recursively apply CI values without discarding signed RGD expressions."""
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            merge_values(target[key], value)
        else:
            target[key] = value


def render(root: Path, work: Path, registry: str, digest: str, control_plane: str, chart_version: str | None = None) -> None:
    if not re.fullmatch(r"[a-z0-9.-]+:[0-9]+", registry):
        raise ValueError("registry must be an in-cluster DNS host and port")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("an exact chart digest is required")
    if not control_plane:
        raise ValueError("a kind control-plane address is required")

    rgd_path = root / "packages/monitoring-stack/rgd.yaml"
    rgd = yaml.safe_load(rgd_path.read_text())
    application = rgd["spec"]["resources"][0]["template"]
    application["spec"]["source"]["repoURL"] = f"oci://{registry}/charts/monitoring"
    values = application["spec"]["source"]["helm"]["valuesObject"]
    values["global"]["collectors"]["kubelet"]["insecureSkipVerify"] = True
    values["global"]["collectors"]["controlPlane"]["insecureSkipVerify"] = True
    kind_values = yaml.safe_load((root / "charts/monitoring/ci/kind-values.yaml").read_text())
    for component in ("mimir-distributed", "loki", "prometheus-node-exporter"):
        merge_values(values.setdefault(component, {}), kind_values[component])
    # Anonymous admin is confined to this disposable kind fixture. The signed
    # chart/RGD never enables it for a real target.
    values["grafana"] = {
        "persistence": {"enabled": False},
        "grafana.ini": {"auth.anonymous": {"enabled": True, "org_role": "Admin"}},
    }
    (work / "rgd.yaml").write_text(yaml.safe_dump(rgd, sort_keys=False))

    for topology in ("central", "local", "client"):
        source = root / f"packages/monitoring-stack/tests/{topology}.yaml"
        fixture = yaml.safe_load(source.read_text())
        spec = fixture["spec"]
        spec["namespace"] = f"monitoring-{topology}" if topology != "central" else "monitoring"
        spec["chartDigest"] = digest
        if chart_version is not None:
            spec["chartVersion"] = chart_version
        spec["controlPlaneTargets"] = control_plane
        if topology == "client":
            spec["remoteWriteUrl"] = "http://monitoring-mimir-gateway.monitoring.svc:80/api/v1/push"
            spec["lokiPushUrl"] = "http://monitoring-loki-gateway.monitoring.svc:80/loki/api/v1/push"
        (work / f"{topology}.yaml").write_text(yaml.safe_dump(fixture, sort_keys=False))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--registry", required=True)
    parser.add_argument("--digest", required=True)
    parser.add_argument("--control-plane", required=True)
    parser.add_argument("--chart-version")
    args = parser.parse_args()
    render(args.root, args.work, args.registry, args.digest, args.control_plane, chart_version=args.chart_version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
