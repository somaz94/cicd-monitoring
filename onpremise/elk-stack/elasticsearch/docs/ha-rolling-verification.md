# HA Rolling Upgrade Verification Summary

Summary of the zero-downtime rolling upgrade verification for the
`elasticsearch-eck` / `kibana-eck` OCI charts.

For the full procedure and evidence, see the chart maintainer repo:
**[somaz94/helm-charts — docs/ha-rolling-verification.md](https://github.com/somaz94/helm-charts/blob/main/docs/ha-rolling-verification.md)**

<br/>

## Overview

| Item | Value |
|---|---|
| Verified on | 2026-04-21 |
| Chart versions | elasticsearch-eck 0.1.1 / kibana-eck 0.1.1 |
| Stack version | 9.3.3 |
| Environment | kind (local), ECK operator public release |
| Load | in-cluster loadgen pod sampling every 0.5 s (indexing + cluster health + Kibana status) |

<br/>

## HA topology

| Component | Settings |
|---|---|
| Elasticsearch | 3 all-role nodes, `podDisruptionBudget.native: true`, `maxUnavailable: 1` |
| Kibana | 2 replicas, `podDisruptionBudget.enabled: true`, `maxUnavailable: 1` |
| Kibana memory | **1.5 GiB per replica** (less than 1 GiB triggers OOMKilled during startup) |

<br/>

## Results

All 3 scenarios **PASS** — across 1010 samples total, zero 5xx/timeout/red.

| Test | Trigger | Duration | Samples | ES indexing | ES health | Kibana |
|---|---|---|---|---|---|---|
| **T1: ES rolling** | ES resources change | 264 s | 470 | 470 × 201 | 303 green + 167 yellow, **0 red** | 470 × 200 |
| **T2: Kibana rolling** | Kibana resources change | 49 s | 82 | 82 × 201 | 82 × green | 82 × 200 |
| **T3: Cosmetic change** | CR annotation added | ~20 s | — | pod `startTime` unchanged → **no restart** | green | 200 |

**Aggregate**: 1010 samples → 100 % 201 on indexing, 100 % 200 on Kibana, zero red on ES health.

<br/>

## Applicability

| Condition | Result |
|---|---|
| HA topology (ES ≥3, Kibana ≥2, PDB configured) | Zero-downtime guaranteed ✅ |
| Single-node topology (current mgmt) | Not applicable — pod restart causes downtime; logging pipeline buffer absorbs |
| Cosmetic CR changes (annotations/labels) | No pod restart ✅ |

<br/>

## Contrast with current mgmt cluster

The mgmt cluster runs **single-node** topology, outside the HA guarantee. During
rolling upgrades, expect tens of seconds to a few minutes of downtime. Measured
during Phase 3 (2026-04-21): **ES 0 s, Kibana ~50 s**, absorbed by
Fluentd / Fluent-bit buffering.

If / when mgmt is promoted to HA, this verification confirms that the chart
itself supports zero-downtime rolling.

<br/>

## When to re-verify

- Before a chart major bump (0.x → 1.x)
- After an ECK operator major upgrade
- After changes to `podTemplate.spec` or StatefulSet / Deployment definitions

Not required for chart patch bumps or Stack version bumps alone.

<br/>

## Related docs

- [Full procedure + logs](https://github.com/somaz94/helm-charts/blob/main/docs/ha-rolling-verification.md) — chart maintainer repo
- [Elasticsearch README](../README-en.md) / [Kibana README](../../kibana/README-en.md)
- [Upgrade
