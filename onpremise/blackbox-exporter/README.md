# blackbox-exporter

Synthetic probes that hit the example-hub entrance **from outside**.

<br/>

## Overview

Every other check in this cluster **asks a pod about itself** — readinessProbe, replica counts, ServiceMonitors, all of them. So nobody sees the state where every pod is Ready but **the path is broken**: DNS, the MetalLB-assigned IP, the Gateway, or the HTTPRoute. Any one of those going wrong means the service is down for users while everything inside the cluster reports healthy.

blackbox-exporter covers that gap.

<br/>

## Directory structure

```
observability/monitoring/blackbox-exporter/
├── README.md          # Korean version
├── README-en.md       # This document (English)
├── Chart.yaml         # Upstream chart metadata (managed by upgrade.py)
├── values.yaml        # Upstream defaults (managed by upgrade.py)
├── values/dev.yaml    # Operational overrides — probe modules and targets
├── argocd/
│   └── blackbox-exporter.yaml   # ArgoCD deploy metadata (chart version SSOT)
└── upgrade.py         # argocd-pin template (canonical sync target)
```

<br/>

## Probe targets

| Name | URL | Module | What it proves |
|---|---|---|---|
| `example-hub-portal` | `https://hub.example.com/healthz` | `http_2xx` | The **whole** path: DNS → MetalLB IP (192.0.2.55) → `ngf` Gateway → HTTPRoute → portal pod. Also the source of TLS expiry |
| `example-hub-auth-gate` | `https://hub.example.com/apps/es-ops/healthz` | `http_302_auth_gate` | 🔴 **The authorization gate is alive** — an unauthenticated request is still redirected to OIDC login |
| `git-bridge` | `http://git-bridge.example.com/` | `http_any_response` | The `ngf-public-j` path is alive |
| `slack-qr-bot` | `https://slack-qr-bot.example.com/` | `http_any_response` | The `ngf` path is alive |

<br/>

## Why the auth-gate probe matters most

The portal's authorization gate is a security boundary, and an open gate is not a state any replica count or in-cluster health check can express. **Nothing but this probe watches for it.**

The probe requests a proxied app path unauthenticated and expects **302 → `/oidc/login`**. `follow_redirects: false` is the load-bearing part: following the redirect would land on the Keycloak login page (a 200), and the probe would pass even with the gate wide open.

The full reasoning is in the internal rationale document.

<br/>

## What is deliberately not probed — the proxy-gated apps

The apps the portal proxies are excluded on purpose, for two reasons both measured on 2026-08-05:

1. **Unreachable.** Their NetworkPolicy admits ingress only from the portal's namespace, so a probe from `monitoring` is blocked outright.
2. **It would add nothing.** Each already runs a kubelet readinessProbe *and* livenessProbe against its `/healthz`. A wedged HTTP server turns the pod NotReady and trips `KubeDeploymentReplicasMismatch`.

The one gap left is "does the portal's proxy path to the app still work", and that needs an **authenticated** request — outside blackbox's reach entirely. If it becomes necessary, the answer is a separate synthetic check issuing authenticated requests with a service-account token, not more probes. Widening those NetworkPolicies to admit `monitoring` was considered and declined; the internal rationale document above records why.

<br/>

## Why TLS verification is off

Every HTTPS module sets `tls_config.insecure_skip_verify: true`. The reasoning and the way back are recorded in the corresponding comment block in `values/dev.yaml`. In short:

- `*.example.com` is signed by the internal CA, which is not in any container's trust bundle. Without the flag **every HTTPS probe fails** (measured: `probe_success=0`).
- **What is given up**: certificate identity verification. The probe path runs entirely inside the cluster/LAN, so an attacker able to MITM it already controls more than this probe could protect.
- **What is kept**: `probe_ssl_earliest_cert_expiry` still works with verification off (verified). Expiry is the only failure this manually managed certificate will realistically have, and it stays covered.
- Mounting the CA would make this probe fail for certificate reasons too. One alert would then mean either "the portal is down" or "the certificate changed", forcing that question on every page.

<br/>

## Alerts

The rules live in `observability/monitoring/kube-prometheus-stack/values/dev-alerts-network.yaml` under the `blackbox-alerts` group, not in this component — every alert group in this cluster is gathered in kube-prometheus-stack's `values/dev-alerts*.yaml`, and one place to read beats scattering them across exporters.

Selectors use the **`target` label** (the human-readable name) rather than `instance` (the URL). The chart's `metricRelabelings` set both; `target` is the one that does not silently orphan a rule when a URL changes.

<br/>

## Deployment

ArgoCD pull-managed. The chart version SSOT is `chart.version` in `argocd/blackbox-exporter.yaml`, and `./upgrade.py` updates that file (there is no helmfile).

```bash
./upgrade.py --dry-run     # check for a newer chart
./upgrade.py               # bump the pin, re-sync Chart.yaml / values.yaml
```

It is registered under `tier_1_apps` in `ci/components.yml`, so it is picked up by the weekly auto-upgrade MR flow.
