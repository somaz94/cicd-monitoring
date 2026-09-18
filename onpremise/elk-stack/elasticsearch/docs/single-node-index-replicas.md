# Index Replicas on a Single-Node Cluster

On a single-node Elasticsearch cluster, leaving index replicas at the default (`1`) pins the cluster to `yellow` forever, and that in turn **blocks ECK rolling upgrades indefinitely**. Bumping the chart version will not replace the pod. On a single-node cluster, replicas must be set to `0`.

This applies to the on-prem single-node cluster only. Clusters with several data nodes (AWS, for example) allocate replicas on other nodes and never hit this.

<br/>

## Why it blocks

The Elasticsearch default for `index.number_of_replicas` is `1`. With only one node there is nowhere to place a replica, so those shards stay `UNASSIGNED` permanently and cluster health sits at `yellow`.

Before restarting a node, ECK evaluates a set of predicates. One of them, `require_started_replica`, is defined as:

> If a cluster is yellow, allow deleting a node, but only if they do not contain the only replica of a shard since it would make the cluster go red.

A single node holds **the only copy of every shard by definition**, so while the cluster is yellow this condition can never be satisfied. Conversely, when the cluster is `green` the condition does not apply at all and the restart proceeds.

Setting replicas to `0` is therefore not a workaround — it is the correct configuration for a single node. A replica that can never be allocated provides no protection while blocking every upgrade.

<br/>

## Recognising the symptom

When a chart pin is bumped and pushed but the pod is never replaced, check the following.

The ArgoCD Application reports `Synced` / `Healthy`, and both the CR and the StatefulSet already carry the new spec. The StatefulSet revisions, however, stay split:

```bash
kubectl -n <namespace> get sts <cluster>-es-<nodeset> \
  -o custom-columns=CUR:.status.currentRevision,UPD:.status.updateRevision
```

`CUR` differing from `UPD` means a new spec is waiting to be applied. Confirm the cause in the ECK operator log:

```bash
kubectl -n elastic-system logs <eck-operator-pod> --tail=200 | grep "Cannot restart"
```

If `failed_predicates` names `require_started_replica`, this document applies.

<br/>

## Remediation

Two steps are required. The first repairs indices that already exist; the second stops the problem returning with indices created later.

<br/>

### 1. Backfill existing indices (one-off)

First list the indices holding unassigned replicas:

```bash
curl -sk -u "elastic:$PW" \
  "https://localhost:9200/_cat/shards?h=index,prirep,state" \
  | awk '$2=="r" && $3=="UNASSIGNED"{print $1}' | sort -u
```

Apply the change to those indices explicitly. **Do not use a `*` wildcard** — many system indices already handle a single node through `auto_expand_replicas` and must be left alone.

```bash
curl -sk -u "elastic:$PW" -X PUT \
  "https://localhost:9200/<index1>,<index2>,.../_settings?expand_wildcards=all" \
  -H 'Content-Type: application/json' \
  -d '{"index":{"auto_expand_replicas":"0-1"}}'
```

Prefer `auto_expand_replicas: "0-1"` over pinning `number_of_replicas: 0`. **Elasticsearch then sizes the replica count to the number of data nodes**: zero on a single node, so the cluster stays green, and a replica is restored automatically the moment a second node joins — no manual step. It is the same mechanism the built-in system indices use.

No data is deleted: the replicas were never allocated, and primary shards are untouched. Once the cluster turns `green`, ECK proceeds with the pod replacement immediately.

<br/>

### 2. Index template (prevents recurrence)

Step 1 only fixes existing indices. New ones pick up the default of `1` again, the cluster returns to `yellow`, and the next upgrade stalls the same way. Attach a template to the index patterns the applications write to:

```bash
curl -sk -u "elastic:$PW" -X PUT \
  "https://localhost:9200/_index_template/<name>" \
  -H 'Content-Type: application/json' -d '{
    "index_patterns": ["<env>-<project>-*"],
    "priority": 60,
    "template": { "settings": { "index": { "auto_expand_replicas": "0-1" } } }
  }'
```

**Keeping the priority low matters.** Elasticsearch rejects a template whose patterns overlap another template at the same priority, and the built-in `logs-*-*` / `metrics-*-*` / `synthetics-*-*` templates use `100`. Creating it at that value is refused outright, and forcing it through at a higher value would let this template outrank the built-in data stream templates for an index such as `logs-<project>-*`, breaking its mappings and ILM settings. Below `100`, the built-in template wins wherever the two overlap while this one still applies to indices nothing else matches.

<br/>

## Managing it through GitOps

Index templates can be declared with a `StackConfigPolicy` CR. ECK deliberately splits cluster topology and stack configuration across two CRDs:

| CRD | Scope |
|---|---|
| `elasticsearches` | Cluster topology (`nodeSets`, `version`, `updateStrategy`, …) |
| `stackconfigpolicies` | Stack configuration (`indexTemplates`, `clusterSettings`, `indexLifecyclePolicies`, …) |

The `elasticsearch-eck` chart renders only the `elasticsearches` CR. The absence of index settings from the chart values is therefore by design, and index replicas should not be looked for there. Indices are created dynamically by the applications at write time, so the chart has no way of knowing their names.

`spec.elasticsearch.indexTemplates.composableIndexTemplates` maps to `/_index_template`, so the template from step 2 can be moved into a manifest. The step 1 backfill is a one-off data-plane operation and is not a GitOps concern.

> ⚠️ **StackConfigPolicy is an Enterprise-licensed feature.** The Elastic documentation states "This requires a valid Enterprise license or Enterprise trial license", and on a Basic licence the operator emits `StackConfigPolicy is an enterprise feature. Enterprise features are disabled` and the policy is never applied. Check the operating licence level with:
>
> ```bash
> kubectl -n elastic-system get configmap elastic-licensing \
>   -o jsonpath='{.data.eck_license_level}'
> ```
>
> On `basic` this route is unavailable. The alternative is a manifest-managed **Job** — an ArgoCD PostSync hook or a Helm hook that issues the `PUT /_index_template` call above — which keeps the declaration in git on a Basic licence. Unlike StackConfigPolicy it does **not** reconcile continuously, so a template changed through the API afterwards is not reverted.

<br/>

## If the cluster is rebuilt

Index settings and templates are Elasticsearch-internal state and disappear with the PVC. Recreating the cluster means **registering the template below again**. That alone covers every index created afterwards, so step 1 (backfilling existing indices) is usually unnecessary.

No dedicated bootstrap script exists for this. On-prem does not otherwise manage index templates — retention is handled by `scripts/delete_old_indices.sh` — and with a single template to carry, maintaining a script costs more than it saves. The runnable form is kept here instead.

```bash
NS=logging; POD=elasticsearch-es-default-0
PW=$(kubectl -n $NS get secret elasticsearch-es-elastic-user \
      -o jsonpath='{.data.elastic}' | base64 -d)

kubectl -n $NS exec $POD -c elasticsearch -- \
  curl -sk -u "elastic:$PW" -X PUT \
  "https://localhost:9200/_index_template/example-project-single-node-replicas" \
  -H 'Content-Type: application/json' -d '{
    "index_patterns": ["*-example-project-*"],
    "priority": 60,
    "template": { "settings": { "index": { "auto_expand_replicas": "0-1" } } }
  }'
```

The call is idempotent, so re-running it is safe. Verify afterwards:

```bash
kubectl -n $NS exec $POD -c elasticsearch -- \
  curl -sk -u "elastic:$PW" -X POST \
  "https://localhost:9200/_index_template/_simulate_index/dev-example-project-newindex"
```

`settings.index.auto_expand_replicas` in the response should read `0-1`. On a licence that permits `StackConfigPolicy`, this manual step can be replaced by a manifest.

<br/>

## If data nodes are added

With `auto_expand_replicas: "0-1"` there is **nothing to do**. The moment a second node joins, Elasticsearch raises the replica count to 1 and the constraint in this document disappears with it. The template does not need removing and index settings do not need reverting.

Pinning `number_of_replicas: 0` behaves differently: indices keep being created without replicas however many nodes are added, so the template has to be removed and existing indices restored by hand. That is the reason `auto_expand_replicas` is the recommended form.

<br/>

## References

- [Elasticsearch upgrade predicates](https://www.elastic.co/docs/reference/cloud-on-k8s/upgrade-predicates)
- [One-node clusters with a yellow health cannot be upgraded (cloud-on-k8s#4625)](https://github.com/elastic/cloud-on-k8s/issues/4625)
