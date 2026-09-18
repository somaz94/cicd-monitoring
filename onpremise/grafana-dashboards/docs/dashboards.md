# Grafana Dashboard Guide (on-prem)

Covers the custom and imported dashboards of the on-prem Grafana (<http://grafana.example.com>).

The 11 custom dashboards are rendered by this component (`grafana-dashboards`) as one ConfigMap per
file, and the kube-prometheus-stack Grafana sidecar **provisions** them into Grafana. The only way to
change a dashboard is therefore **edit the JSON → commit → ArgoCD sync**. A provisioned dashboard is
`provisioned=True` in Grafana, which **disables the UI Save button**.

<br/>

## Delivery flow (GitOps)

```text
edit dashboards/<file>.json
  → git commit / push (master)
  → ArgoCD Application `infra-grafana-dashboards` sync
  → ConfigMap `grafana-dashboards-<file>` (label grafana_dashboard=1)
  → the grafana-sc-dashboard sidecar of kube-prometheus-stack-grafana picks it up
  → pushed into Grafana over its API (updated by uid)
```

- **`autoSync: true`** (`argocd-local/grafana-dashboards.yaml`, flipped 2026-07-20). A commit to master
  lands without a manual sync — the appset attaches `automated{prune, selfHeal}`.
- **Grafana's UI Save is blocked.** All 11 are provisioned dashboards, so committing this JSON is the
  only edit path. (`selfHeal` reconciles the ConfigMap against the repo — it does not revert a
  dashboard inside Grafana. Provisioning itself is what blocks UI edits.)
- Keep the uid — bookmarked URLs and the provisioner's update key both depend on it. Changing a uid
  leaves the old dashboard in place and adds a new one alongside it.
- The folder is `General` (the sidecar's `folderAnnotation` is not in use).

<br/>

## Custom dashboards

Managed as JSON files under `dashboards/`. All 11 are provisioned.

| File | Covers |
|------|--------|
| `argocd-dashboard.json` | ArgoCD (app sync, git requests, cluster state) |
| `cilium-dashboard.json` | Cilium CNI (agent state, endpoints, BPF maps, policy) |
| `control-plane-health-dashboard.json` | Control Plane Health — etcd / apiserver latency + GitLab Runner CI correlation (built for incident analysis; came out of the 2026-05-08 incident) |
| `elasticsearch-dashboard.json` | Elasticsearch (cluster health, shards, nodes, doc count) |
| `fluentbit-fluentd-dashboard.json` | Fluent Bit + Fluentd logging pipeline |
| `gitlab-runner-dashboard.json` | GitLab Runner (manager up, running jobs, job start rate, error levels, concurrency) |
| `harbor-dashboard.json` | Harbor (projects, storage, HTTP requests) |
| `metallb-dashboard.json` | MetalLB (speaker/controller, BGP·L2 announcements, address pool usage) |
| `mysql-dashboard.json` | MySQL (connections, QPS, InnoDB, slow queries) |
| `nginx-gateway-dashboard.json` | NGINX Gateway Fabric — control plane (reconcile, work queue, NGF event batch, resources) + data plane (request rate, connection state, accept/handle rate, agent CPU/memory/network throughput; based on nginx-agent OTEL native export, so no latency histogram or status-code labels) |
| `redis-dashboard.json` | Redis (memory, commands, keys, hit rate) |

All 11 reference a single datasource, the `prometheus` uid — already provisioned by
kube-prometheus-stack, so no wiring is needed.

> Only JSON files directly under `dashboards/` are shipped (the template globs
> `Files.Glob "dashboards/*.json"`). Subdirectories such as `dashboards/_deprecated/` are excluded
> automatically, so move a dashboard there when you stop maintaining it.

> The former `ingress-nginx-dashboard.json` lives in `dashboards/_deprecated/`. It stopped being
> maintained after the ingress-nginx → NGF (NGINX Gateway Fabric) cutover completed on 2026-04-17.

<br/>

## Dashboard UID list

Each dashboard has a unique `uid`. The provisioner updates an existing dashboard by uid, so as long
as the uid is kept there are no duplicates.

| Dashboard | UID | Variables (dropdowns) |
|-----------|-----|-----------------------|
| ArgoCD Overview | `argocd-overview` | `job`, `namespace` |
| Cilium CNI | `cilium-cni` | `instance` |
| Control Plane Health | `control-plane-health` | — |
| Elasticsearch | `elasticsearch-overview` | `job` |
| GitLab Runner | `gitlab-runner` | `job`, `instance` |
| Harbor Registry | `harbor-registry` | `job`, `instance` |
| Logging Pipeline | `logging-pipeline-fluent` | `fb_job`, `fb_instance`, `fd_job`, `fd_instance` |
| MetalLB | `metallb` | `instance` |
| MySQL Overview | `mysql-overview` | `job`, `instance` |
| NGINX Gateway Fabric | `nginx-gateway-fabric` | `namespace`, `pod`, `controller` |
| Redis Overview | `redis-overview` | `job`, `instance` |
| (deprecated) Ingress-Nginx | `ingress-nginx-controller` | file: `dashboards/_deprecated/ingress-nginx-dashboard.json` |

> Read the UID off the Grafana URL: `http://grafana.example.com/d/<UID>/...`

<br/>

## Editing and adding dashboards

### Editing

Only saving is blocked — exploring and experimenting in the UI still works. To keep the result:

1. Edit the dashboard in the Grafana UI (saving is unavailable once provisioned).
2. Copy **Settings** → **JSON Model**, or export it over the API.

   ```bash
   PW=$(kubectl -n monitoring get secret grafana-auth \
          -o jsonpath='{.data.admin-password}' | base64 --decode)
   curl -s http://grafana.example.com/api/dashboards/uid/<UID> \
     -u "admin:$PW" | python3 -m json.tool > dashboards/<filename>.json
   ```

3. Overwrite `dashboards/<filename>.json`. Always keep the `uid`.
4. Commit → push → sync `infra-grafana-dashboards` in ArgoCD.

### Adding

Drop the JSON into `dashboards/` — that is all. The template globs the directory, so the chart needs
no change.

```bash
cd observability/monitoring/grafana-dashboards
helm template grafana-dashboards . -f values/dev.yaml -n monitoring   # check the render
```

### Verifying

```bash
# Confirm the ConfigMaps exist (11)
kubectl -n monitoring get cm -l grafana_dashboard=1

# Sidecar pickup logs
kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana \
  -c grafana-sc-dashboard --tail=20

# Check the provisioning state (provisioned should be True)
# Grafana API: GET /api/dashboards/uid/<UID> → meta.provisioned
```

<br/>

## import-dashboards.sh — a reduced role

`scripts/import-dashboards.sh` bulk-POSTs `dashboards/*.json` into the Grafana HTTP API. Moving it
into this component left its `DASHBOARDS_DIR` default (`$CHART_DIR/dashboards`) pointing at the same
11 JSONs, but **it is not the delivery path.**

> **A provisioned dashboard rejects Grafana API writes.** Pushing an already-provisioned dashboard
> with `--all` will fail. Do not use this script for routine changes — the GitOps flow above is the
> only path.

What it is still good for:

- **Development / experimentation**: pushing dashboards into a different Grafana (local, staging, …).
- **Rollback / recovery**: restoring a dashboard by hand when the ConfigMap is gone and provisioning
  has lapsed.

```bash
cd observability/monitoring/grafana-dashboards

# Import everything — password read from the in-cluster secret
./scripts/import-dashboards.sh --context onprem-dev --all --from-secret

# A single file (repeatable)
./scripts/import-dashboards.sh -f dashboards/mysql-dashboard.json -p <password>

# Exclude some — substring match on the name, comma-separated
./scripts/import-dashboards.sh --context onprem-dev --all --except metallb,cilium --from-secret

# Dry run — print the targets only
./scripts/import-dashboards.sh --all --dry-run
```

Main flags:

| Flag | Description |
|---|---|
| `-f, --file PATH` | A single file. Repeatable. |
| `--all` | Every `*.json` directly under `dashboards/` (the default when `-f` is absent). |
| `--except PAT[,...]` | With `--all`, skip files whose basename matches the substring. |
| `-p, --password PASS` | Password (or the `GRAFANA_PASSWORD` env var). |
| `--from-secret` | Read `admin-password` from `monitoring/grafana-auth` via `kubectl`. `values/dev.yaml` overrides `grafana.admin.existingSecret: grafana-auth`, so the chart's default secret is never created. |
| `-u, --url URL` | Grafana base URL (default: `http://grafana.example.com`). |
| `-U, --user USER` | Grafana user (default: `admin`). |
| `-n, --dry-run` | Print the targets, do not POST. |
| `-v, --verbose` | Print the full Grafana response body per file. |

See `./scripts/import-dashboards.sh --help` for every option.

<br/>

## Imported dashboards (Grafana.com)

Community dashboards are not under GitOps — import them directly in the UI.

Grafana → **Dashboards** → **New** → **Import** → enter the ID → Data source: **Prometheus** → Import

| Target | Dashboard ID | Name |
|--------|-------------|------|
| K8s nodes / bare metal / VMs | `1860` | [Node Exporter Full](https://grafana.com/grafana/dashboards/1860) |
| MySQL | `14057` | [MySQL Overview](https://grafana.com/grafana/dashboards/14057) |
| Redis | `11835` | [Redis Dashboard](https://grafana.com/grafana/dashboards/11835) |
| ArgoCD | `14584` | [ArgoCD](https://grafana.com/grafana/dashboards/14584) |
| Harbor | `14930` | [Harbor](https://grafana.com/grafana/dashboards/14930) |
| Ingress-Nginx (deprecated) | `9614` | [NGINX Ingress Controller](https://grafana.com/grafana/dashboards/9614) — retired after the 2026-04-17 NGF cutover |

> The default K8s dashboards (Pod, Namespace, Workload, …) are generated by kube-prometheus-stack.

<br/>

## Relationship to the AWS stack

The AWS prod guide [`../../grafana-dashboards-aws/docs/dashboards-en.md`](../../grafana-dashboards-aws/docs/dashboards.md)
is the sibling that proved this design first. The two components carry different dashboard sets —
each holds only what has a real scrape target on its own cluster.

- On-prem only: `cilium` / `control-plane-health` / `harbor` / `metallb` / `mysql` / `nginx-gateway` / `redis`
- AWS only: `karpenter` / `alb-request-health` / `aws-load-balancer-controller` / `external-dns` / `external-secrets` / `argo-rollouts` / `argocd-applications` / `example-app-game-operations` / `opentelemetry-apm-tracing`
- Filenames present on both sides: `argocd` / `elasticsearch` / `fluentbit-fluentd` / `gitlab-runner`

What those four overlapping filenames actually are (measured 2026-07-16):

| File | Relationship |
|---|---|
| `argocd-dashboard.json` | the two copies are **identical** (uid `argocd-overview`) |
| `elasticsearch-dashboard.json` | the two copies are **identical** (uid `elasticsearch-overview`) |
| `fluentbit-fluentd-dashboard.json` | the two copies are **identical** (uid `logging-pipeline-fluent`) |
| `gitlab-runner-dashboard.json` | **different dashboards that merely share a filename** — on-prem uid `gitlab-runner` (19 panels) vs AWS uid `gitlab-runner-overview` (11 panels) |

- The first three match today, but **two files means no automatic sync.** A change meant for both
  clusters has to be made in both files.
- `gitlab-runner` differs down to the uid — they are **two distinct dashboards**. Do not copy one
  side's contents over the other.
