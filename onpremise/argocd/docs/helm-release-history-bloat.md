# Helm Release History Bloat Breaking helmfile diff / apply

On 2026-07-15, `helmfile diff` / `helmfile apply` failed to start any work at all in both `cicd/argo-cd` (onprem-dev) and `cicd/argo-cd-aws` (example-app-prod). The errors look like a network fault, but the real cause is **the response size of the query helm runs against its own release history**. This document records the cause, the permanent fix, and the recovery procedure.

<br/>

## Summary

- Helm stores each release revision whole, in a Secret named `sh.helm.release.v1.argocd.vN`. Argo CD renders a large manifest, so **a single revision is roughly 700 KB**.
- Helm's default `--history-max` is **10**, so up to ten of these Secrets pile up.
- `helm upgrade` / `helm diff upgrade` starts by listing the entire history with a label selector, which puts **roughly 7 MB into one response** and causes the kube-apiserver stream to abort.
- Fix: pin `historyMax: 3` on the argocd release in both helmfiles so helm prunes automatically on every upgrade.

<br/>

## Symptom

In `cicd/argo-cd/` or `cicd/argo-cd-aws/`, `helmfile diff` / `helmfile apply` fails before printing any diff. The error takes the form of helm being **unable to read its own release**.

AWS EKS (`example-app-prod` context):

```
Error: Failed to get release argocd in namespace argocd: query: failed to query with labels: stream error when reading response body, may be caused by closed connection. Please retry. Original error: stream error: stream ID 3; INTERNAL_ERROR; received from peer
```

On-prem (`onprem-dev` context):

```
Error: query: failed to query with labels: unexpected error when reading response body. Please retry. Original error: read tcp 198.51.100.3:56050->192.0.2.17:6443: read: operation timed out
```

Accompanying observations:

- `helm -n argocd list` and `helm -n argocd status argocd` fail in exactly the same way.
- The message advises `Please retry`, but **retrying does not help** — it failed three times consecutively on both clusters.
- Meanwhile `kubectl` works fine at the same moment. That contrast is the key to identifying the cause.

<br/>

## Root cause

Helm creates one Secret per release revision and stores the full rendered manifest in `.data.release`. For a chart with a large manifest like Argo CD, a single revision is about 700 KB. Multiply that by helm's default history retention of 10.

`helm upgrade` and `helm diff upgrade` immediately query the history with the `owner=helm,name=argocd` label selector, and that query **fetches every revision as a full object**. The single response therefore reaches about 7 MB, and the kube-apiserver stream cannot carry it (EKS surfaces this as `INTERNAL_ERROR`, on-prem as a read timeout — different symptoms, same cause).

Measured values:

| Item | onprem-dev | example-app-prod |
|---|---|---|
| Revision range | v40–v49 | v1–v10 |
| Revision count | 10 | 10 |
| `.data.release` size per Secret | 700,336 B | 698,320 B |
| Total history query response | ~7 MB | ~7 MB |

**It reproduced identically on both clusters.** This is not an environment quirk — it is a *structural consequence of helm's default meeting Argo CD's large manifest*.

### Evidence that it is size, not connectivity — why kubectl works

The decisive evidence is that `kubectl` stays healthy at the very same moment.

```bash
# A single release secret reads fine (698,320 bytes, exit 0)
kubectl -n argocd get secret sh.helm.release.v1.argocd.v10 -o jsonpath='{.data.release}' | wc -c

# Listing the same 10 secrets also works
kubectl -n argocd get secret -l owner=helm,name=argocd
```

- Reading **one** Secret as a full object: 700 KB → succeeds.
- **Listing** those same 10 with `kubectl`: succeeds. `kubectl` uses server-side Table output, so the response is small.
- Helm **listing those same 10 as full objects**: ~7 MB → fails.

So the link and the apiserver are both fine; only helm's 7 MB full-object list breaks.

<br/>

## Permanent fix (applied 2026-07-15)

Both helmfiles now set `historyMax: 3`. Helm prunes old revisions on every upgrade, keeping the history query around 2 MB.

- `cicd/argo-cd/helmfile.yaml`
- `cicd/argo-cd-aws/helmfile.yaml`

**The standard form is the top-level `helmDefaults`** (see "Repo-wide standardization" below). It was originally added per-release, but that form has a trap: a release added to the same helmfile later silently misses the cap. It was therefore converted to `helmDefaults`.

```yaml
helmDefaults:
  historyMax: 3

releases:
  - name: argocd
    namespace: argocd
    chart: argo/argo-cd
    version: 10.1.3
```

Notes:

- `historyMax` is a helmfile-supported field (verified on helmfile v1.1.0) and maps to helm's `--history-max`. Both the global `helmDefaults.historyMax` form and the per-release form work (precedence: helm default 10 → `helmDefaults` → per-release), but this repo **standardizes on `helmDefaults`.**
- Three revisions still leave room to roll back.

<br/>

## Repo-wide standardization (2026-07-15)

After the fix above, a sweep across the whole repo added a top-level block to **all 19 active helmfiles** (commit `03cfb37`).

```yaml
helmDefaults:
  historyMax: 3
```

This block replaces the earlier per-release form on `cicd/argo-cd/helmfile.yaml` and `cicd/argo-cd-aws/helmfile.yaml`.
With a per-release `historyMax`, a release added to that helmfile later would silently miss the cap.
`helmDefaults` applies to every release in the file, including releases added in the future.

The propagation path was verified in the helmfile v1.1.0 source, `pkg/state/state.go:2005-2018`.

```go
historyMax := 10                              // helm default
if st.HelmDefaults.HistoryMax != nil {
    historyMax = *st.HelmDefaults.HistoryMax  // helmDefaults applies to every release
}
if spec.HistoryMax != nil {
    historyMax = *spec.HistoryMax             // per-release overrides
}
```

Precedence: helm default 10 → `helmDefaults.historyMax` → per-release `historyMax`.

**`historyMax` only takes effect on the NEXT `helmfile apply` of each release.** Helm prunes down to the cap at upgrade time, so setting it does not shrink existing history on its own.

<br/>

## Sweep results (measured 2026-07-15)

Contexts swept: `onprem-dev`, `example-app-prod`. (`secondary-project-prod` / `secondary-project-test` are a separate workstream — out of scope.)

| Risk | Component (ns/release) | Context | Measured | Per revision | At 10 revisions | Status |
|---|---|---|---|---|---|---|
| broke | `argocd/argocd` | example-app-prod | — | 698 KB | ~7 MB | was broken; pruned + capped |
| broke | `argocd/argocd` | onprem-dev | — | 700 KB | ~7 MB | was broken; pruned + capped |
| high | `monitoring/prometheus-operator-crds` | onprem-dev | 4 rev / 3.1 MB | 802 KB | ~8.0 MB | capped (largest per-rev in the repo) |
| high | `kube-system/cilium` | onprem-dev | 4 rev / 2.3 MB | 593 KB | ~5.9 MB | **NOT capped — see Known gap below** |
| medium | `nginx-gateway/nginx-gateway-fabric` | onprem-dev | 7 rev / 2.8 MB | 417 KB | ~4.1 MB | capped |
| medium | `elastic-system/eck-operator` | onprem-dev | 5 rev / 1.4 MB | 279 KB | ~2.7 MB | no active helmfile (ArgoCD-managed; leftover release secret) |
| medium | `keycloak-system/keycloak-operator` | onprem-dev | 5 rev / 1.3 MB | 268 KB | ~2.6 MB | capped |
| low | `harbor/harbor` | onprem-dev | 10 rev / 1.5 MB | 149 KB | already at cap | capped; small enough to be safe |
| low | all others (metallb, vaultwarden, gitlab-runner build/deploy-image, static-file-server, ghost, unity-mcp-server, local-path-provisioner, sealed-secrets, keycloak, karpenter, karpenter-cr, aws-load-balancer-controller) | both | < 1 MB total | < 150 KB | < 1.5 MB | no risk |

Thresholds: **~7 MB = measured breaking point** (Argo CD, 10 × ~700 KB). **Approaching ~5 MB = at risk.**

<br/>

## Counterintuitive finding — ArgoCD-deployed components are immune

Start here next time.

`kube-prometheus-stack` is the obvious suspect because the chart is huge, but it is **not affected.** There are no `sh.helm.release.v1.kube-prometheus-stack.*` Secrets on either cluster.
It is deployed via an ArgoCD Application, and **ArgoCD renders with `helm template`, so it creates no helm release Secrets at all**.
Any component under `<component>/argocd/` or `<component>/argocd-aws/` with no active helmfile is therefore structurally immune to this problem.

Corollary: only components with an **active helmfile** can hit this. When triaging, enumerate helmfiles first — do not start from "which chart is biggest".

<br/>

## ArgoCD Application state is separately bounded (audited 2026-07-15, no action needed)

ArgoCD apps have their own state stores, and all of them are self-capping.

| Store | onprem-dev | example-app-prod | Cap | Verdict |
|---|---|---|---|---|
| `status.history` | max 10 | max 10 | `spec.revisionHistoryLimit` (default 10; some apps set 3) | bounded |
| `notified.notifications.argoproj.io` annotation | max 100 entries / 10.5 KB | max 78 entries / 7.8 KB | hardcoded 100 in notifications-engine (`notifiedHistoryMaxSize`) | bounded |
| Application CR total size | max 71 KB (`infra-kube-prometheus-stack`) | max 69.5 KB (`infra-kube-prometheus-stack`) | etcd 1.5 MB | ~20× headroom |

For scale: the largest ArgoCD Application CR is **71 KB**, while a **single** helm release revision for Argo CD is **~700 KB**. The two are an order of magnitude apart.

Note: the 2026-07-15 `oncePer` change (`operationState.finishedAt` → `summary.images`, see the notification playbook) also reduces churn in the `notified` annotation.
The old formula minted a new key on every sync (which is why some apps sat pinned at the 100-entry cap), whereas the new one only mints a key when the image set changes.

<br/>

## Recovery — a cluster whose history already bloated

Adding `historyMax` **does not shrink revisions that already accumulated.** Helm cannot query the history, so helm itself cannot be asked to do the pruning. Delete the old revision Secrets directly with `kubectl` to bring the size back to where helm can work again.

> **Caution:** the highest-numbered revision is the live release. **Never delete it.** Deleting older revisions only drops the rollback history for those revisions; the running release is untouched.

```bash
# 1) see what exists (note the highest N = current)
kubectl -n argocd get secret -l owner=helm,name=argocd --no-headers | awk '{print $1}' | sort -V

# 2) confirm which is live
kubectl -n argocd get secret -l owner=helm,name=argocd \
  -o custom-columns='NAME:.metadata.name,STATUS:.metadata.labels.status'

# 3) delete the oldest, keeping the last 3 (example: current is v10 -> delete v1..v7)
kubectl -n argocd delete secret \
  sh.helm.release.v1.argocd.v1 \
  sh.helm.release.v1.argocd.v2 \
  sh.helm.release.v1.argocd.v3 \
  sh.helm.release.v1.argocd.v4 \
  sh.helm.release.v1.argocd.v5 \
  sh.helm.release.v1.argocd.v6 \
  sh.helm.release.v1.argocd.v7

# 4) helmfile diff should now work
cd cicd/argo-cd-aws && helmfile diff
```

After pruning down to 3 revisions, both `helmfile diff` and `helmfile apply` were verified working on prod and dev.

<br/>

## Workaround — inspecting a pending change while helm is blocked

If you cannot prune the history right now but still need to see the change you are about to apply, you can compare just the notifications ConfigMap through a path that **never makes helm read the release**: render locally and diff against the live object.

```bash
cd cicd/argo-cd-aws
helm template argocd argo/argo-cd --version <pinned> -n argocd \
  -f values/prod.yaml -f values/prod-server.yaml -f values/prod-redis.yaml -f values/prod-notifications.yaml \
  | yq eval 'select(.metadata.name == "argocd-notifications-cm") | .data' - > /tmp/cm-new.yaml
kubectl -n argocd get cm argocd-notifications-cm -o yaml | yq eval '.data' - > /tmp/cm-live.yaml
diff -u /tmp/cm-live.yaml /tmp/cm-new.yaml
```

Match `<pinned>` to the `version` value in the corresponding helmfile.yaml.

Why this works:

- `helm template` does not touch the cluster at all (no release history query).
- `kubectl get cm` fetches a single small object, nowhere near the size that breaks the stream.

<br/>

## Known gap — cilium

`kube-system/cilium` on `onprem-dev` is **593 KB per revision and cannot be capped from this repo** — it has no helmfile here and is managed externally (e.g. kubespray).
It currently sits at 4 revisions / 2.3 MB, so it is safe today, but nothing stops it from growing toward the ~5.9 MB risk zone at 10 revisions.

If it ever approaches the threshold, do one of the following.

- Prune its history Secrets manually with the recovery procedure in this document.
- Set `historyMax` at whatever tool actually manages the cilium release.

Also flag: `elastic-system/eck-operator`, `blog/ghost`, and the `gitlab-runner` build/deploy-image releases carry `deployed` helm release Secrets but have no active helmfile in this repo (only `backup/` and/or `argocd/` directories).
These look like leftovers from a helmfile → ArgoCD migration. They are small and not a risk, but they are unmanaged by any current helmfile — worth confirming whether the release Secrets should just be cleaned up.

<br/>

## Prevention checklist

- [ ] Keep `historyMax: 3` on the argocd release in both helmfiles — do not remove it.
- [ ] If a new helm release with a large rendered manifest is added to this repo, set `historyMax` on it too.
- [ ] If `helmfile diff` suddenly fails with a stream / timeout error, **check the revision count before suspecting the network.**
- [ ] Every active helmfile carries `helmDefaults.historyMax: 3` — verify with `grep -rL "^helmDefaults:" --include="helmfile.yaml*" . | grep -v backup` (should return nothing).
- [ ] A NEW helmfile added to this repo must include the `helmDefaults.historyMax: 3` block.
- [ ] When triaging a stream / timeout error from `helmfile diff` / `apply`, check the release revision count and per-revision size FIRST — `kubectl` succeeding is NOT evidence of a healthy release history (kubectl uses small server-side Table output; helm fetches full objects).

```bash
# Revision count check — the first thing to run on a stream/timeout failure
kubectl -n argocd get secret -l owner=helm,name=argocd --no-headers | wc -l
```

<br/>

## Related documents

- Playbook for minimizing redelivery when changing notification rules (the main workflow that uses `helmfile diff` / `apply`): [notification-rule-change-playbook-en.md](notification-rule-change-playbook.md)
- Helm `--history-max` upstream docs: <https://helm.sh/docs/helm/helm_upgrade/>
</content>
</invoke>
