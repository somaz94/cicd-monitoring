# Kibana Upgrade / Rollback Guide

Kibana and Elasticsearch share the same ECK operator/webhook and are managed by the same `external-oci-cr-version` canonical template. The upgrade/rollback mechanisms are essentially identical, so **the full guide lives on the Elasticsearch side**. The OCI chart pin bump procedure is also documented there.

**→ See [../../elasticsearch/docs/upgrade-rollback-en.md](../../elasticsearch/docs/upgrade-rollback.md)**

<br/>

> 🔴 **Read this first — ES / Kibana / eck-operator are ArgoCD pull-managed.**
>
> None of the three has a `helmfile.yaml`. The version SSOT is each `argocd/<release>.yaml`, and the Applications run `autoSync: true` with selfHeal. So `helmfile apply` has nothing to apply, and `./upgrade.py --rollback` rewrites local files only — **the cluster never sees it.** The only real rollback path is a revert commit landing on master, and an ES downgrade is still blocked by the admission webhook; the main guide above carries the full version of this note.
>
> The dependency and ordering constraints in "Kibana-specific notes" below are unaffected by the migration and still hold — only the commands were updated for ArgoCD.

<br/>

## Kibana-specific notes

### Dependency CR constraint

Kibana's `upgrade.py` is configured with:

```bash
DEPENDENCY_CR_KIND="elasticsearch"
DEPENDENCY_CR_NAME="elasticsearch"
```

→ Step 5 enforces **Kibana target version ≤ Elasticsearch CR version**. Aborts otherwise.

This means **Elasticsearch must be upgraded first** before Kibana can be upgraded.

### Upgrade order

1. In `observability/logging/elasticsearch/`: `./upgrade.py`, then commit the change to master (autoSync applies it; `argocd app sync infra-elasticsearch` if it has to happen now)
2. Wait for ES CR to become Ready on the new version
3. In `observability/logging/kibana/`: `./upgrade.py`, then commit the same way (`argocd app sync infra-kibana`)

### Rollback order

No specific order is required, but **`./upgrade.py --rollback` alone does not roll anything back** — it rewrites local files only, so each component's result has to land on master as a revert commit before the cluster follows. For downgrades, the role of the auto-handlers (webhook release and so on) is described in the main guide's rollback section.

<br/>

## Related

- **Main guide**: [Elasticsearch/docs/upgrade-rollback-en.md](../../elasticsearch/docs/upgrade-rollback.md)
- [Kibana README](../README.md)
- [Elasticsearch README](../../elasticsearch/README.md)
- [upgrade-sync system guide](../../../../scripts/upgrade-sync/README.md)
