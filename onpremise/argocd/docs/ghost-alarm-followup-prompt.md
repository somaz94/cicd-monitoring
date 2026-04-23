# Follow-up Inquiry Prompt — ArgoCD Ghost/Duplicate Alarm Investigation

<br/>

## Usage

When a symptom similar to the 2026-04-23 incident recurs (ArgoCD Slack alarms arriving in an unexpected way), copy the prompt below verbatim and paste it into Claude Code.

Supply the following together with the prompt (or make it readable by Claude):
- Raw Slack alarm text (include timestamp, application name, all visible fields)
- When helpful, point Claude to `~/gitlab-project/kuberntes-infra/cicd/argo-cd/docs/ghost-alarm-incident-2026-04-23-en.md` for full background.

<br/>

## Prompt (copy-paste)

```
An ArgoCD Slack alarm came through again and looks off. Please investigate.
The symptom is attached under [Symptom] below.

First, read `kuberntes-infra/cicd/argo-cd/docs/ghost-alarm-incident-2026-04-23-en.md`
to understand the 2026-04-23 analysis (root causes A/B/C, the fixes applied, and
the verification checklist). Follow the check order from that document and tell me
whether this recurrence matches the same pattern.

Checklist:
1. Interpret the "restart time" / "deploy time" fields in the alarm as UTC (the Z
   suffix is UTC; the template's "UTC+9=KST" label is misleading).
2. Verify whether the app was actually deployed or restarted via Pod AGE and RS history:
   - kubectl get pods -n <ns> -o wide
   - kubectl get rs -n <ns> --sort-by='.metadata.creationTimestamp'
3. Compare the ArgoCD Application's operationState (startedAt, finishedAt, phase)
   with reconciledAt:
   - kubectl get application <app> -n argocd -o json | jq '.status | {reconciledAt, operationState}'
4. Check argocd-application-controller logs for "comparison expired" or the reconcile
   cadence of this app.
   - A reconcile gap of 10+ minutes suggests root cause A has resurfaced.
5. Check recent argo-cd config commits (under cicd/argo-cd/).
   - If a change was just applied, root cause B (dedup key reshuffle) is possible.
6. Confirm the live trigger oncePer keys match the recommendation
   (operationState.finishedAt) by reading the live ConfigMap:
   - kubectl get cm argocd-notifications-cm -n argocd -o yaml | grep -A2 oncePer

Tell me whether:
- this alarm reflects a real event vs. a ghost/duplicate alarm
- it is the same pattern as the 2026-04-23 incident or a new pattern
- if it is a new pattern, what further investigation is needed
- anything in ghost-alarm-incident-2026-04-23-en.md should be updated

Constraints:
- kubectl get/describe/logs can be run freely, but
  kubectl apply/patch/delete, helmfile apply, and git push must wait for my approval.
- Commit messages are a single line, with no Co-Authored-By trailer (per global CLAUDE.md).

[Symptom]
<paste the raw Slack alarm text here>
```

<br/>

## Reference: Quick Check Command Set

Run these in order if you want to investigate without going through the prompt.

```bash
# 1) Pod / RS state for the affected app
APP=<app-name>
NS=<namespace>
kubectl get pods -n $NS -o wide
kubectl get rs -n $NS --sort-by='.metadata.creationTimestamp' | tail

# 2) ArgoCD Application state
kubectl get application $APP -n argocd -o json | jq '.status | {
  reconciledAt,
  sync: .sync.status,
  health: .health.status,
  operationState: {
    phase: .operationState.phase,
    startedAt: .operationState.startedAt,
    finishedAt: .operationState.finishedAt
  }
}'

# 3) Reconcile-gap overview across all apps
kubectl get applications -n argocd -o json | jq -r '
  .items[] | [.status.reconciledAt, .metadata.name,
              .status.operationState.finishedAt,
              .status.operationState.phase] | @tsv' | sort

# 4) Controller logs — look for recurrence
kubectl logs -n argocd argocd-application-controller-0 --since=24h | \
  grep -i "comparison expired" | head -20

# 5) Notifications trigger dedup annotation on the app
kubectl get application $APP -n argocd \
  -o jsonpath='{.metadata.annotations.notified\.notifications\.argoproj\.io}' | jq .

# 6) Verify that the live trigger config matches the recommended oncePer key
kubectl get cm argocd-notifications-cm -n argocd \
  -o jsonpath='{.data.trigger\.on-deployed}'
kubectl get cm argocd-notifications-cm -n argocd \
  -o jsonpath='{.data.trigger\.on-restarted}'
```

<br/>

## Related Documents

- [ghost-alarm-incident-2026-04-23-en.md](ghost-alarm-incident-2026-04-23-en.md) — original incident analysis
- `values/mgmt-notifications.yaml` — current trigger definitions
- `upgrade.sh` — script that applies changes
