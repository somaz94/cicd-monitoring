# CI/CD & Monitoring

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Production-ready CI/CD pipelines and monitoring configurations for **AWS**, **GCP**, and **On-Premise** Kubernetes environments.

<br/>

## Tech Stack

![Kubernetes](https://img.shields.io/badge/-Kubernetes-326CE5?style=flat-square&logo=kubernetes&logoColor=white)![Docker](https://img.shields.io/badge/-Docker-2496ED?style=flat-square&logo=docker&logoColor=white)![Helm](https://img.shields.io/badge/-Helm-0F1689?style=flat-square&logo=helm&logoColor=white)![Prometheus](https://img.shields.io/badge/-Prometheus-E6522C?style=flat-square&logo=prometheus&logoColor=white)![Grafana](https://img.shields.io/badge/-Grafana-F46800?style=flat-square&logo=grafana&logoColor=white)![Loki](https://img.shields.io/badge/-Loki-FF4500?style=flat-square&logo=loki&logoColor=white)![Thanos](https://img.shields.io/badge/-Thanos-4C51BF?style=flat-square&logo=thanos&logoColor=white)![ArgoCD](https://img.shields.io/badge/-ArgoCD-0D658D?style=flat-square&logo=argocd&logoColor=white)![Jenkins](https://img.shields.io/badge/-Jenkins-D24939?style=flat-square&logo=jenkins&logoColor=white)![GitHub Actions](https://img.shields.io/badge/-GitHub_Actions-2088FF?style=flat-square&logo=github-actions&logoColor=white)![GitLab CI](https://img.shields.io/badge/-GitLab_CI-FCA121?style=flat-square&logo=gitlab&logoColor=white)![Elasticsearch](https://img.shields.io/badge/-Elasticsearch-005571?style=flat-square&logo=elasticsearch&logoColor=white)![Kibana](https://img.shields.io/badge/-Kibana-005571?style=flat-square&logo=kibana&logoColor=white)![Fluent Bit](https://img.shields.io/badge/-Fluent%20Bit-0D9CFC?style=flat-square&logo=fluentd&logoColor=white)![Nginx](https://img.shields.io/badge/-Nginx-009639?style=flat-square&logo=nginx&logoColor=white)

<br/>

## Platform Coverage

| Tool | AWS | GCP | On-Premise |
|------|:---:|:---:|:----------:|
| **Kube-Prometheus-Stack** | O | O | O |
| **Grafana** | O | O | O |
| **Loki** | O | O | O |
| **ArgoCD** | O | O | O |
| **Fluent Bit** | O | - | - |
| **Thanos** | - | - | O |
| **ELK Stack** | - | - | O |
| **Harbor** | - | - | O |
| **Jenkins** | - | - | O |
| **Promtail** | - | - | O |

<br/>

## Directory Structure

<details>
<summary><b>aws/</b> - AWS EKS Monitoring & GitOps</summary>

```
aws/
├── argocd/                  # ArgoCD with ALB Ingress
├── grafana/                 # Grafana (grafana-community chart v11.3.5)
├── kube-prometheus-stack/   # Prometheus + Alertmanager + Operator
├── loki/                    # Loki log aggregation
├── fluent-bit-aws/          # Fluent Bit log collector
└── gitlab-runner-aws/       # GitLab Runner for AWS
```

| Component | Chart | Version |
|-----------|-------|---------|
| [ArgoCD](aws/argocd/) | `argo/argo-cd` | 9.4.16 |
| [Grafana](aws/grafana/) | `grafana-community/grafana` | 11.3.5 |
| [Kube-Prometheus-Stack](aws/kube-prometheus-stack/) | `prometheus-community/kube-prometheus-stack` | 82.14.1 |
| [Loki](aws/loki/) | `grafana/loki` | 6.55.0 |
| [Fluent Bit](aws/fluent-bit-aws/) | `fluent/fluent-bit` | 0.49.3 |
| [GitLab Runner](aws/gitlab-runner-aws/) | `gitlab/gitlab-runner` | 0.87.0 |

</details>

<details>
<summary><b>gcp/</b> - GCP GKE Monitoring & GitOps</summary>

```
gcp/
├── argocd/                  # ArgoCD with GKE Ingress
├── grafana/                 # Grafana (grafana-community chart v11.3.5)
├── kube-prometheus-stack/   # Prometheus + Alertmanager + Operator
└── loki/                    # Loki log aggregation
```

| Component | Chart | Version |
|-----------|-------|---------|
| [ArgoCD](gcp/argocd/) | `argo/argo-cd` | 9.4.16 |
| [Grafana](gcp/grafana/) | `grafana-community/grafana` | 11.3.5 |
| [Kube-Prometheus-Stack](gcp/kube-prometheus-stack/) | `prometheus-community/kube-prometheus-stack` | 82.14.1 |
| [Loki](gcp/loki/) | `grafana/loki` | 6.55.0 |

</details>

<details>
<summary><b>onpremise/</b> - On-Premise Full Stack</summary>

```
onpremise/
├── argocd/                          # ArgoCD with Dex SSO & Slack notifications
├── elk-stack/                       # Elasticsearch, Kibana, Filebeat, Logstash, APM
├── grafana/                         # Grafana dashboards
├── harbor-helm/                     # Harbor container registry
├── ingress-nginx-sidecar-fluentbit/ # Nginx ingress with Fluent Bit sidecar
├── jenkins/                         # Jenkins CI server
├── kube-prometheus-stack/           # Full Kubernetes monitoring stack
├── loki/                            # Log aggregation
├── promtail/                        # Log collector for Loki
└── thanos/                          # Long-term metrics storage
```

| Component | Link |
|-----------|------|
| [ArgoCD](onpremise/argocd/) | GitLab SSO, Redis HA, Slack notifications |
| [ELK Stack](onpremise/elk-stack/) | APM, Elasticsearch, Filebeat, Kibana, Logstash, Metricbeat |
| [Grafana](onpremise/grafana/) | Dashboards and data source configuration |
| [Harbor](onpremise/harbor-helm/) | Container registry with Helm chart |
| [Ingress Nginx + Fluent Bit](onpremise/ingress-nginx-sidecar-fluentbit/) | Access log collection sidecar |
| [Jenkins](onpremise/jenkins/) | CI/CD server |
| [Kube-Prometheus-Stack](onpremise/kube-prometheus-stack/) | Prometheus, Alertmanager, Operator |
| [Loki](onpremise/loki/) | Log aggregation system |
| [Promtail](onpremise/promtail/) | Log collector agent |
| [Thanos](onpremise/thanos/) | Long-term Prometheus storage |

</details>

<details>
<summary><b>github-cicd/</b> - GitHub Actions Workflows</summary>

```
github-cicd/
├── aws/                     # AWS build & deploy workflows
│   ├── build-deploy-repo/   # ECR build, Helm deploy, S3 upload
│   └── data-repo/           # Data validation & upload pipeline
├── gcp/                     # GCP build & deploy workflows
│   ├── build-deploy-repo/   # GAR build, Helm deploy, GCS upload
│   ├── data-repo/           # Data validation & upload pipeline
│   ├── data-build-deploy-repo/          # Combined data + build + deploy
│   ├── matrix-strategy/                 # Matrix strategy example
│   ├── upgrade-data-build-deploy-repo/  # Enhanced pipeline v1
│   └── upgrade-data-build-deploy-repo-v2/  # Enhanced pipeline v2
└── aws-gcp/                 # Hybrid multi-cloud workflow
```

See [github-cicd/README.md](github-cicd/) for details.

</details>

<details>
<summary><b>gitlab-cicd/</b> - GitLab CI/CD Templates & Pipelines</summary>

```
gitlab-cicd/
├── templates/               # Reusable CI/CD components
│   ├── variables/           # Common variables and service definitions
│   ├── auth/                # AWS ECR authentication
│   ├── build/               # Kaniko build (Harbor & ECR)
│   ├── deploy/              # ArgoCD GitOps deployment
│   ├── backup/              # Google Drive backup
│   └── examples/            # Template usage examples
├── pipelines/               # Complete pipeline patterns (48 files)
│   ├── server/              # Server service (harbor/aws/module versions)
│   ├── data/                # Data pipeline (harbor/aws/module versions)
│   ├── client/              # Client CI pipelines
│   ├── admin/               # Admin service pipelines
│   ├── battle/              # Battle service pipelines
│   ├── build-deploy/        # Basic build & deploy patterns
│   ├── gcp-artifact-registry/  # GCP Artifact Registry patterns
│   ├── data-upload/         # Data upload utilities
│   └── backup/              # Google Drive backup
└── scripts/                 # Utility scripts (Python, TypeScript)
```

See [gitlab-cicd/README.md](gitlab-cicd/) for details.

</details>

<details>
<summary><b>github-runner/</b> - Self-hosted GitHub Actions Runner</summary>

```
github-runner/
└── actions-runner-controller/   # ARC with Helmfile
```

| Component | Link |
|-----------|------|
| [Actions Runner Controller](github-runner/actions-runner-controller/) | Self-hosted runner on Kubernetes |

</details>

<details>
<summary><b>gitlab-runner/</b> - Self-hosted GitLab Runner</summary>

```
gitlab-runner/
├── helmfile.yaml            # Helmfile release definition
├── values/                  # Environment-specific values
└── upgrade.sh               # Version upgrade script
```

See [gitlab-runner/README.md](gitlab-runner/) for details.

</details>

<details>
<summary><b>jenkins/</b> - Jenkins Pipeline Examples</summary>

```
jenkins/
├── init-jenkinsfile         # Initialization pipeline
├── ios-jenkinsfile          # iOS build pipeline
├── lua-jenkinsfile          # Lua build pipeline
└── res-jenkinsfile          # Resource build pipeline
```

</details>

<br/>

## Getting Started

1. Choose your target platform (`aws/`, `gcp/`, or `onpremise/`)
2. Navigate to the specific tool directory
3. Follow the README instructions in each directory
4. Customize values files for your environment

```bash
# Example: Deploy kube-prometheus-stack on AWS
cd aws/kube-prometheus-stack
helmfile apply

# Example: Deploy ArgoCD on GCP
cd gcp/argocd
helmfile apply
```

<br/>

## Helmfile Pattern

All monitoring components follow a consistent Helmfile remote chart pattern:

```
component/
├── Chart.yaml          # Version tracking (upstream format)
├── helmfile.yaml       # Helmfile release definition (remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Environment-specific overrides
├── examples/           # Storage, ingress, and other examples
├── upgrade.sh          # Automated version upgrade script
├── backup/             # Auto backup on upgrade
└── README.md
```

```bash
# Common operations
helmfile lint     # Validate
helmfile diff     # Preview changes
helmfile apply    # Deploy
helmfile destroy  # Delete

# Upgrade
./upgrade.sh              # Upgrade to latest
./upgrade.sh --dry-run    # Preview only
./upgrade.sh --rollback   # Restore from backup
```

<br/>

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
