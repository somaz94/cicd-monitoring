# Thanos

Manages [Thanos](https://thanos.io/) using Helmfile. Provides long-term storage and multi-cluster unified query for Prometheus.

> Currently **optional** — single cluster with 15-day retention is sufficient.

<br/>

## When to Use

| Scenario | Needed |
|----------|--------|
| Single cluster, 15-day retention | No (current) |
| Months/years of metric retention | Yes |
| 2+ clusters unified monitoring | Yes |
| Prometheus HA (deduplication) | Yes |

<br/>

## Two Release Structure

| Release | Values | Components |
|---------|--------|-----------|
| `thanos` | `mgmt.yaml` | Compactor, Store Gateway, Object Storage |
| `thanos-query` | `mgmt-query.yaml` | Query, Query Frontend |

<br/>

## Prerequisites

- kube-prometheus-stack installed with thanos sidecar enabled
- Object Storage (MinIO, S3, GCS)

<br/>

## Installation

```bash
# First install
helmfile sync

# Subsequent updates
helmfile apply
```

<br/>

## Reference

- [Thanos](https://thanos.io/)
- [Bitnami Thanos Chart](https://github.com/bitnami/charts/tree/main/bitnami/thanos)
