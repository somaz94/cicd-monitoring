# Disaster Recovery Procedures

Recovery procedures for each major component in the CI/CD and monitoring stack.

<br/>

## General Principles

- All Helm releases use Helmfile with versioned `Chart.yaml` — redeployment is repeatable.
- Each component has an `upgrade.sh --rollback` option for reverting to the previous Helm values.
- Persistent data (metrics, logs, artifacts) requires separate backup strategies listed below.
- Target RTO (Recovery Time Objective): **< 30 minutes** for stateless components, **< 2 hours** for stateful components.

<br/>

## Component Recovery Procedures

<br/>

### Prometheus + Alertmanager (Kube-Prometheus-Stack)

**Data loss impact:** Metrics history lost; alerting rules and dashboards remain in Git.

**Recovery steps:**

```bash
# 1. Redeploy the Helm release
cd aws/kube-prometheus-stack   # or gcp/ or onpremise/
helmfile apply

# 2. Verify Prometheus is scraping targets
kubectl port-forward svc/prometheus-operated 9090 -n monitoring
# Open http://localhost:9090/targets

# 3. Restore alerting rules from Git (applied automatically via Helmfile)
helmfile diff
helmfile apply
```

**Backup strategy:**
- Prometheus TSDB snapshots (manual): `curl -X POST http://localhost:9090/api/v1/admin/tsdb/snapshot`
- For on-premise long-term storage, Thanos handles persistence — see [Thanos section](#thanos-on-premise).

<br/>

### Grafana

**Data loss impact:** Dashboards and data source configs lost if not backed up.

**Recovery steps:**

```bash
# 1. Redeploy
cd aws/grafana   # or gcp/ or onpremise/
helmfile apply

# 2. Restore dashboards from ConfigMaps (if provisioned via values)
kubectl get configmap -n monitoring | grep grafana-dashboard
kubectl apply -f backup/dashboard-configmaps/

# 3. Reconnect data sources (Prometheus, Loki)
# Done automatically if datasources are provisioned in values/mgmt.yaml
```

**Prevention:** Provision all dashboards and data sources via `grafana.sidecar.dashboards` in Helmfile values — avoids manual state.

<br/>

### Loki

**Data loss impact:** Log history lost for the retention period.

**Recovery steps:**

```bash
# 1. Redeploy
cd aws/loki   # or gcp/ or onpremise/
helmfile apply

# 2. Verify log ingestion
kubectl logs -n monitoring -l app=loki --tail=50

# 3. Verify Promtail/Fluent Bit is shipping logs
kubectl logs -n monitoring -l app=promtail --tail=50
# or
kubectl logs -n monitoring -l app=fluent-bit --tail=50
```

**Backup strategy:**
- AWS: Loki uses S3 backend — data is durable by default.
- GCP: Loki uses GCS backend — data is durable by default.
- On-Premise: Loki uses NFS PVC — back up NFS volume regularly.

<br/>

### Thanos (On-Premise)

**Data loss impact:** Long-term metrics unavailable; recent metrics (Prometheus retention window) remain.

**Recovery steps:**

```bash
# 1. Check object storage backend
kubectl logs -n monitoring -l app=thanos-store --tail=50

# 2. Redeploy Thanos components
cd onpremise/thanos
helmfile apply

# 3. Verify Thanos sidecar is connected to Prometheus
kubectl get pods -n monitoring | grep thanos
```

<br/>

### ArgoCD

**Data loss impact:** GitOps sync state lost; all application definitions remain in Git.

**Recovery steps:**

```bash
# 1. Redeploy ArgoCD
cd aws/argocd   # or gcp/ or onpremise/
helmfile apply

# 2. Wait for ArgoCD to be ready
kubectl rollout status deployment/argocd-server -n argocd

# 3. Re-apply Application CRDs from Git
kubectl apply -f path/to/argocd-apps/

# 4. Sync all applications
argocd app sync --all
# or via UI: Applications > Sync All
```

**On-Premise (Redis HA):** If Redis HA pods are unhealthy, ArgoCD will lose session state but application configs are in Git.

```bash
# Force Redis HA recovery
kubectl delete pods -n argocd -l app=argocd-redis-ha
```

<br/>

### Jenkins (On-Premise)

**Data loss impact:** Build history, job configurations, and plugins lost.

**Recovery steps:**

```bash
# 1. Check PVC status
kubectl get pvc -n jenkins

# 2. Redeploy Jenkins
cd onpremise/jenkins
helmfile apply

# 3. If PVC is corrupted, restore from NFS backup
kubectl scale deployment jenkins -n jenkins --replicas=0
# Restore NFS volume from backup snapshot
kubectl scale deployment jenkins -n jenkins --replicas=1
```

**Backup strategy:**
- Jenkins home is on NFS PVC (30Gi) — schedule NFS snapshots or use the ThinBackup plugin.
- Export job DSL configs to Git for reproducibility.

**Rollback Helm release:**

```bash
cd onpremise/jenkins
./upgrade.sh --rollback
```

<br/>

### Harbor (On-Premise)

**Data loss impact:** Container images and Helm charts in the registry are lost.

**Recovery steps:**

```bash
# 1. Check Harbor component status
kubectl get pods -n harbor

# 2. Redeploy
cd onpremise/harbor-helm
helmfile apply

# 3. Verify all Harbor services are healthy
kubectl get svc -n harbor

# 4. If database (PostgreSQL) is corrupted, restore from backup
kubectl exec -it harbor-database-0 -n harbor -- pg_restore -U postgres -d registry /backup/harbor-db.dump
```

**Backup strategy:**
- Harbor supports native backup via `harbor-jobservice`. Schedule periodic exports.
- PostgreSQL: use `pg_dump` to back up the `registry` and `notaryserver` databases.
- Image storage: Back up the NFS-backed PVC for `/storage`.

<br/>

### ELK Stack (On-Premise)

**Data loss impact:** Historical log data and APM traces lost.

**Recovery steps:**

```bash
# 1. Check Elasticsearch cluster health
kubectl exec -it elasticsearch-master-0 -n elk -- curl -s localhost:9200/_cluster/health | jq .

# 2. Redeploy
cd onpremise/elk-stack
helmfile apply

# 3. If index data is lost, restore from snapshot
kubectl exec -it elasticsearch-master-0 -n elk -- \
  curl -X POST "localhost:9200/_snapshot/backup_repo/snapshot_1/_restore"
```

**Backup strategy:**
- Use Elasticsearch Snapshot API to back up indices to an S3-compatible or NFS repository.
- Register a snapshot repository:
  ```bash
  curl -X PUT "localhost:9200/_snapshot/backup_repo" -H 'Content-Type: application/json' \
    -d '{"type": "fs", "settings": {"location": "/usr/share/elasticsearch/backup"}}'
  ```

<br/>

### GitLab Runner / GitHub Runner

**Data loss impact:** In-progress jobs are lost; queued jobs will be re-triggered by the CI platform.

**Recovery steps:**

```bash
# GitLab Runner
cd gitlab-runner
helmfile apply

# GitHub Runner (ARC)
cd github-runner/actions-runner-controller
helmfile apply
```

Runners are stateless — full recovery is a simple redeploy.

<br/>

## Checklist After Recovery

After recovering any component, verify the following:

- [ ] All pods are in `Running` state: `kubectl get pods -n <namespace>`
- [ ] Ingress is accessible from the expected domain
- [ ] Metrics appear in Grafana (within 1–2 scrape intervals)
- [ ] Logs appear in Grafana/Kibana (within 1–2 minutes)
- [ ] ArgoCD shows all applications as `Synced`
- [ ] CI/CD pipelines can trigger and complete a test build
- [ ] Alert rules are active in Alertmanager

<br/>

## Related

- [Architecture Overview](architecture.md)
- Component-specific README files in each subdirectory
