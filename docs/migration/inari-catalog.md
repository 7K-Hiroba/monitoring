# Fresh import attribution: inari-catalog monitoring-stack

- Source repository: `https://github.com/7K-Inari/inari-catalog`
- Source path: `packages/monitoring-stack`
- Source repository HEAD at import: `43e80dcd24de12ba7d22f6f0a91e452f40b39c58`
- Last source-path change observed before import: `dd52d95516c4456811b32bb796cc7ea5679d6dac`
- Imported source package version: `1.3.0`
- Import mode: fresh files with attribution; no `filter-repo`, history rewrite, or legacy Git mirror.

## Imported and adapted content

The source's Grafana persistence, Alertmanager, component resource defaults, and operator-oriented deployment documentation informed the new chart/RGD. The legacy Prometheus server and `kube-prometheus-stack` dependency are deliberately not part of the target architecture: **Mimir replaces Prometheus** for metrics storage and rule evaluation.

The target adds Mimir, Loki, Alloy, kube-state-metrics, node-exporter, kubelet/control-plane collection, canonical dashboards/rules, generated pack output, and target-side readiness. Source package removal and old-artifact deprecation belong to the later catalog-slimming wave, not this task.

Verification of this attribution is the source SHA/path plus the current repository commit containing this document and the adapted stack; no provenance claim is made for unexecuted deployed migration tests.
