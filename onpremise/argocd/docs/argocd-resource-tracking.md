# ArgoCD Resource Tracking — annotation method (app-of-apps adoption prerequisite)

Background for the single line set under `configs.cm` in `cicd/argo-cd/values/dev.yaml`:

```yaml
configs:
  cm:
    application.resourceTrackingMethod: annotation
```

This setting is the **top-priority prerequisite for zero-downtime adoption of helmfile-deployed infra components into the ArgoCD app-of-apps structure**. The full migration context lives in a separate migration plan; this document covers only "why this one line is needed".

<br/>

## ArgoCD resource tracking methods

ArgoCD stamps every resource it manages with a marker identifying which Application owns it. Two methods exist:

- **label (default)** — tracks via the `app.kubernetes.io/instance: <app-name>` **label** on the resource.
- **annotation** — tracks via the `argocd.argoproj.io/tracking-id` **annotation** on the resource.

The default is `label`, so without explicit configuration ArgoCD uses label tracking.

<br/>

## The problem — immutable selector conflict during adoption

The trap with `label` tracking surfaces **when ArgoCD adopts already-running resources**.

1. Many Helm charts put `app.kubernetes.io/instance` into the Deployment/StatefulSet `.spec.selector.matchLabels`.
2. In Kubernetes a **selector is immutable** (cannot be changed after creation).
3. When ArgoCD adopts an existing resource under label tracking, it tries to overwrite that resource's `app.kubernetes.io/instance` label with its own Application name.
4. If that label is part of the selector → the API rejects the selector change → ArgoCD **recreates the whole resource** → **downtime**.

For stateful components (MySQL / Valkey / Elasticsearch / Ghost) this is the worst case, since PVC re-binding gets dragged in too.

<br/>

## The fix — annotation tracking

Switching to `resourceTrackingMethod: annotation` makes ArgoCD track via the `argocd.argoproj.io/tracking-id` annotation instead of a label. Annotations are not part of selectors, so:

- selectors are left untouched → **zero recreation → zero-downtime adoption**
- existing resource labels are not modified

<br/>

## When is it required — only for adoption

This setting is not unconditionally required. It depends on the scenario.

| Scenario | Is label tracking enough? | Note |
|---|---|---|
| **A. Greenfield** — ArgoCD deploys from scratch | ✅ Yes (not required) | ArgoCD creates the resources itself, so labels are consistent from the start → no selector conflict |
| **B. Adoption** — ArgoCD takes over already-running resources | ❌ Risky (annotation required) | Adopting helmfile-created resources (label already baked into the selector) → label overwrite → recreation |

This repo's migration is by definition **"deploy first via helmfile → adopt later via ArgoCD"** = the classic B (adoption) scenario, which is why annotation tracking is the top-priority prerequisite.

> Connecting a platform to ArgoCD does not by itself require annotation tracking. The immutable-selector problem only arises when **adopting existing resources with zero downtime**. That said, annotation tracking is also ArgoCD's recommended mode, so keeping it on as a baseline is correct even if some components are deployed greenfield.

<br/>

## Permanent setting — never toggle it off

This line is not a temporary migration scaffold but the **permanent baseline for this cluster's ArgoCD**.

- Once enabled, keep it enabled.
- **Reverting to label tracking after adoption re-introduces the exact same problem** — the moment you revert, ArgoCD re-writes the `app.kubernetes.io/instance` label on every resource → selector conflict → recreation/downtime. Turning it off is itself the dangerous act.
- Resources already tracked via annotation must continue to be managed by that annotation, so removing the setting breaks tracking consistency.

> What you might roll back is not this tracking setting but an **individual component adoption**. If moving a component to ArgoCD causes trouble, delete just that App (with prune disabled so the resources survive) and resume helmfile. Leave the tracking setting as is.

<br/>

## Apply impact (helmfile apply)

Changing `configs.cm` changes the argocd-cm ConfigMap, which auto-updates the `checksum/cm` annotation on the four ArgoCD core components that reference it (application-controller / dex-server / repo-server / server), triggering a **rolling restart**.

- The ArgoCD control plane pauses briefly for ~30–60s (UI / reconcile interruption).
- **Workload pods (example-project/secondary-project, etc.) are unaffected** — zero resource changes outside argocd-cm.
- Existing example-project/secondary-project Applications re-stamp the `argocd.argoproj.io/tracking-id` annotation on their next reconcile. During this window a **transient OutOfSync may appear, which is normal** and self-resolves on the next sync.

> ⚠️ Do **not** run an aggressive prune sync on example-project/secondary-project during the transition window. Pruning before the annotation re-stamp completes can mis-flag a not-yet-converted resource as a deletion candidate.

Verification commands:

```bash
# Before apply — confirm only the key is added to argocd-cm with no workload changes (read-only)
helmfile -f helmfile.yaml diff

# Apply
helmfile -f helmfile.yaml apply

# After apply — confirm the key landed + check app health
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.application\.resourceTrackingMethod}'
kubectl -n argocd get applications
```

<br/>

## AWS variant (argo-cd-aws)

on-prem (`cicd/argo-cd`) and AWS (`cicd/argo-cd-aws`) are **independent ArgoCD installs** (separate argocd-cm). There is no inheritance, so if the same behavior is needed on AWS later it must be added explicitly to `configs.cm` in `cicd/argo-cd-aws/values/prod.yaml`. The current app-of-apps migration targets **on-prem only**, so it is not applied to the AWS variant.
