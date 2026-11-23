# Post-Alloy label contract

`contracts/post-alloy-labels/v1.yaml` pins Alloy 1.13.0, the generally-available/non-community runtime flags, and required `org`, `cluster`, `job`, and `instance` labels. `namespace` and `app` are optional. Metric names are preserved. Central rules may rely only on this versioned contract.

## Regenerate and review

Run `scripts/test-alloy-pipeline.sh --update` after changing the representative input or Alloy config. The runner performs a real scrape, relabel, and remote write through pinned Alloy and a Prometheus-compatible receiver, then writes the observed fixture. Review the resulting label diff explicitly; the CI-only target/receiver identities are not production values.

Run `scripts/test-alloy-pipeline.sh --check` to require zero fixture drift, execute local and central promtool tests, and derive the central test from the actual post-Alloy labels. The pinned workflow's `derive-central-rule-test.py` is required for the derivation; do not hand-maintain a second central fixture.

The contract and fixture are CODEOWNERS-reviewed. A label addition/removal, runtime-version change, or changed rule meaning requires a reviewed contract change. A passing offline test does not replace target-side rule-evaluation evidence.
