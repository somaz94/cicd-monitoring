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

## Architecture

```
                          ┌──────────────────┐
                          │  Thanos Query    │ ← unified query interface
                          │  (dev-query)    │
                          └───────┬──────────┘
                                  │
                    ┌─────────────┼─────────────┐
                    │             │             │
            ┌───────┴───┐  ┌─────┴─────┐  ┌───┴────────┐
            │ Prometheus │  │  Store    │  │ (Remote    │
            │ Sidecar    │  │  Gateway  │  │  Cluster)  │
            └───────┬───┘  └─────┬─────┘  └────────────┘
                    │            │
                    │     ┌──────┴──────┐
                    │     │  Object     │
                    └────►│  Storage    │◄── Compactor
                          │  (S3/MinIO) │
                          └─────────────┘
```

<br/>

## Two Release Structure

| Release | Values | Components |
|---------|--------|-----------|
| `thanos` | `dev.yaml` | Compactor, Store Gateway, Object Storage |
| `thanos-query` | `dev-query.yaml` | Query, Query Frontend |

<br/>

## Directory Structure

```
thanos/
├── Chart.yaml
├── helmfile.yaml            # 2 releases (thanos + thanos-query)
├── values/
│   ├── dev.yaml            # Compactor, Store Gateway config
│   └── dev-query.yaml      # Query config (stores connection)
├── upgrade.sh
├── backup/
├── .helmignore
├── README.md
└── README-en.md
```

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

## Upgrade

```bash
./upgrade.sh                      # latest version
./upgrade.sh --version <VERSION>  # specific version
./upgrade.sh --dry-run            # preview
```

<br/>

## Reference

- [Thanos](https://thanos.io/)
- [Bitnami Thanos Chart](https://github.com/bitnami/charts/tree/main/bitnami/thanos)
