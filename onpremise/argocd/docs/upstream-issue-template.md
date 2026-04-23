# Upstream Issue Template — argoproj/argo-cd

<br/>

## Purpose

Template for filing a new bug report at <https://github.com/argoproj/argo-cd/issues/new/choose> (**Bug Report**) for the **application-controller goroutine leak + silent reconcile freeze** observed on Argo CD v3.3.7. This file is English-only by design (the upstream project is English).

See the detailed Korean analysis in [ghost-alarm-incident-2026-04-23.md](ghost-alarm-incident-2026-04-23.md).

<br/>

## Pre-submission checklist

Fill out as many as possible before submitting. The more concrete data, the faster upstream can triage.

- [ ] Confirm the **Argo CD version** (`argocd version --short` on the server, or `kubectl get pod argocd-application-controller-0 -n argocd -o jsonpath='{.spec.containers[0].image}'`)
- [ ] Confirm the **helm chart version** used (check `helmfile.yaml` or `helm list -n argocd`)
- [ ] Collect **controller logs** showing: (1) the "Notifying settings subscribers" burst, (2) the last reconcile log line before silence, (3) the `Goroutines=NNNN` stats line
- [ ] Collect a **pprof goroutine dump** while the controller is stuck (requires `ARGOCD_APPLICATION_CONTROLLER_PPROF=true` env var — already enabled in this repo as of commit `e3cdde4`)
- [ ] Search existing issues once more before filing: <https://github.com/argoproj/argo-cd/issues?q=is%3Aissue+goroutine+application-controller+stuck>
- [ ] Sanitize logs (no internal hostnames, tokens) before attaching

<br/>

## How to collect the pprof dump (next time stuck is observed)

```bash
# 1) Verify stuck with the helper
./cicd/argo-cd/scripts/notify-rule-change.sh status
# Expected: Goroutines > 1000, reconciledAt of all apps > 15 min

# 2) Open pprof port-forward
kubectl port-forward -n argocd argocd-application-controller-0 6060:6060 &
PF_PID=$!
sleep 2

# 3) Dump goroutines (debug=2 gives full stack traces)
TS=$(date +%Y%m%d-%H%M%S)
curl -s "http://localhost:6060/debug/pprof/goroutine?debug=2" > /tmp/argocd-goroutine-${TS}.txt
curl -s "http://localhost:6060/debug/pprof/goroutine?debug=1" > /tmp/argocd-goroutine-summary-${TS}.txt

# 4) Close port-forward
kill $PF_PID

# 5) Quick triage — see top stack patterns
grep -c "^goroutine " /tmp/argocd-goroutine-${TS}.txt         # total goroutine count
grep "^goroutine " /tmp/argocd-goroutine-${TS}.txt | sort | uniq -c | sort -rn | head -10
head -200 /tmp/argocd-goroutine-summary-${TS}.txt             # grouped summary

# 6) Now safe to restart
kubectl rollout restart statefulset/argocd-application-controller -n argocd
```

Attach `/tmp/argocd-goroutine-summary-*.txt` to the GitHub issue (the `debug=1` summary is much shorter and already groups goroutines by stack trace — ideal for maintainers).

<br/>

## Issue body template (copy-paste)

```markdown
### Describe the bug

On Argo CD **v3.3.7** (helm chart `argo-cd` 9.5.2), the `application-controller` StatefulSet silently stops processing its reconcile queue while the pod remains `Running` with healthy probes. The internal `Goroutines` counter (visible in the 10-minute stats log line) climbs past **1000** and plateaus (observed: `Goroutines=1446`), with memory slightly decreasing over time — indicative of leaked

### To reproduce

1. Install Argo CD v3.3.7 via helm chart 9.5.2 with ~10 Applications under management.
2. Patch any of `argocd-cm`, `argocd-notifications-cm`, `argocd-rbac-cm` (e.g. via `helm upgrade`, or have `notifications-controller` write `notified.notifications.argoproj.io` annotations en masse to Applications, which triggers the controller's watch on Application metadata).
3. Within ~5 seconds of the patch, the controller logs a burst of:
   ```
   msg="Notifying 1 settings subscribers: [0xc00...]"
   msg="Using diffing customizations to ignore resource updates"
   msg="Ignore status for all objects"
   ```
   The pattern repeats 10–20 times over a few seconds.
4. After this burst, **application reconcile logs go completely silent**. Only the 10-minute `Alloc=... Goroutines=NNNN` stats line keeps appearing, with `Goroutines` stuck at a high value (observed 1446).
5. `kubectl get application -n argocd` shows `reconciledAt` frozen for all applications.

### Expected behavior

Controller should continue processing the reconcile queue after settings reload. Goroutine count should return to steady-state (typically 100–300 for a 10-app cluster) within 1–2 minutes of the reload.

### Version

```
# argocd version --short
argocd: v3.3.7+<commit>
  BuildDate: <date>
  GitCommit: <hash>
  GitTreeState: clean
  GoVersion: go1.23.x
  Compiler: gc
  Platform: linux/amd64
argocd-server: v3.3.7+<commit>
```

- Helm chart: `argo-cd-9.5.2`
- Kubernetes: v1.34.3 (Kubespray, containerd 2.2.1)
- Installation method: Helmfile → helm chart `argo/argo-cd`

### Logs

**Burst preceding the freeze (edited for brevity, pattern repeats ~20x over 5s):**
```
time="2026-04-23T02:11:30Z" level=info msg="Notifying 1 settings subscribers: [0xc0005b2070]"
time="2026-04-23T02:11:30Z" level=info msg="Using diffing customizations to ignore resource updates"
time="2026-04-23T02:11:30Z" level=info msg="Ignore status for all objects"
...
time="2026-04-23T02:11:35Z" level=info msg="Using diffing customizations to ignore resource updates"
time="2026-04-23T02:11:35Z" level=info msg="Ignore status for all objects"
----- after this line, NO application reconcile logs appear -----
```

**Stats log confirming goroutine plateau (only lines printed during stuck period):**
```
time="2026-04-23T02:11:32Z" level=info msg="Alloc=173129 TotalAlloc=170588644 Sys=596474 NumGC=2058 Goroutines=1446"
time="2026-04-23T02:21:32Z" level=info msg="Alloc=145764 TotalAlloc=171288879 Sys=596474 NumGC=2067 Goroutines=1446"
```

### pprof goroutine dump

_Attach `argocd-goroutine-summary-*.txt` (pprof `?debug=1` output) here. See the [collection procedure](#)._ 

### Recurrence

- Observed **3 times in a single day** (2026-04-23 KST). Each recurrence was preceded by ConfigMap patches (helm upgrade) or large-scale Application annotation updates (notifications-controller bulk writes after restart).
- Recovery time: `kubectl rollout restart` succeeds immediately; controller resumes for 10–60 minutes before next recurrence.

### Workaround

```bash
kubectl rollout restart statefulset/argocd-application-controller -n argocd
```

Temporary only — the leak reoccurs on the next ConfigMap patch or bulk annotation update.

### Possibly related upstream changes in v3.3.7

- PR #27230 (cherry-pick of #25290): "fix: prevent automatic refreshes from informer resync"
- PR #27093: `notifications-engine` version bump
- PR #27049: `SettingsManager` secret deepcopy refactor — touches the `updateSettingsFromSecret` path that emits "Notifying settings subscribers"

### Related existing issues

- #27344 — git repository changes not triggering OutOfSync status (partially overlapping, controller refresh path regression)
- #26863 — Application Controller Performance regression in 3.3.X (similar goroutine/memory symptom, reportedly partially fixed but recurred)
- #27192 — UI does not auto-refresh (watch-leak flavor)
- #27209 — slow-fail failed clusters cause reconciliation queue buildup

### Environment notes

- 10 Applications, 1 destination cluster (in-cluster)
- Notifications-controller is active and writes `notified.notifications.argoproj.io` annotations per Application
- Settings watch / Application watch both active
- No ApplicationSet generators that would churn CRs

### Additional context

This appears to be a new fingerprint not captured by existing issues, though it likely shares a root cause with #26863 and/or interacts with the #27230 refresh-path regression noted in the v3.3.7 release notes. Happy to run any additional diagnostics.
```

<br/>

## Submission methods

Pick one of the three.

### A. Web browser (simplest)

1. Go to <https://github.com/argoproj/argo-cd/issues/new?template=bug_report.md>
2. Paste the filled-out body above.
3. Attach the goroutine dump file.
4. Submit.

### B. `gh` CLI

```bash
# Save body to a file first
cat > /tmp/argocd-issue-body.md <<'EOF'
### Describe the bug
... (paste full body here) ...
EOF

gh issue create \
  --repo argoproj/argo-cd \
  --title "application-controller reconcile queue silently halts with goroutines climbing to 1000+ after settings reload on v3.3.7" \
  --body-file /tmp/argocd-issue-body.md
```

After creation, attach the goroutine dump as a comment (gh doesn't attach files directly):

```bash
gh issue comment <ISSUE_NUMBER> --repo argoproj/argo-cd \
  --body "$(cat /tmp/argocd-goroutine-summary-*.txt)"
```

Or drag-and-drop the file in the issue web view after creation.

### C. Delegate

Ask Claude: _"please submit this issue using `gh issue create`"_ — will be done only after you have reviewed the exact title/body.

<br/>

## After submission

1. Link the new issue number back to this repo by adding a mention in `cicd/argo-cd/docs/ghost-alarm-incident-2026-04-23.md` § 후속 조사 과제.
2. Subscribe to the issue for updates.
3. If maintainers ask for additional data (timing correlation, specific pprof profiles), the infrastructure is ready via the `pprof` endpoint enabled in `values/mgmt-server.yaml`.
