# Kibana Upgrade / Rollback Guide

Kibana and Elasticsearch share the same ECK operator/webhook and are managed by the same `local-cr-version` canonical template. The upgrade/rollback mechanisms are essentially identical, so **the full guide lives on the Elasticsearch side**.

**→ See [../../elasticsearch/docs/upgrade-rollback-en.md](../../elasticsearch/docs/upgrade-rollback-en.md)**

<br/>

## Kibana-specific notes

### Dependency CR constraint

Kibana's `upgrade.sh` is configured with:

```bash
DEPENDENCY_CR_KIND="elasticsearch"
DEPENDENCY_CR_NAME="elasticsearch"
```

→ Step 5 enforces **Kibana target version ≤ Elasticsearch CR version**. Aborts otherwise.

This means **Elasticsearch must be upgraded first** before Kibana can be upgraded.

### Upgrade order

1. In `observability/logging/elasticsearch/`: `./upgrade.sh && helmfile apply`
2. Wait for ES CR to become Ready on the new version
3. In `observability/logging/kibana/`: `./upgrade.sh && helmfile apply`

### Rollback order

No specific order required. Run `./upgrade.sh --rollback` independently in each component. The auto-handler (webhook, helm failed release, operator management) works identically for downgrades.

<br/>

## Related

- **Main guide**: [Elasticsearch/docs/upgrade-rollback-en.md](../../elasticsearch/docs/upgrade-rollback-en.md)
- [Kibana README](../README-en.md)
- [Elasticsearch README](../../elasticsearch/README-en.md)
- [helm-upgrade system guide](../../../../scripts/helm-upgrade/README-en.md)
