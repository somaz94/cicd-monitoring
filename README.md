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
| **Prometheus** | O | O | O |
| **Grafana** | O | O | O |
| **Loki** | O | O | O |
| **ArgoCD** | O | O | O |
| **Thanos** | - | - | O |
| **ELK Stack** | - | - | O |
| **Jenkins** | - | - | O |
| **Promtail** | - | - | O |
| **Kube-Prometheus-Stack** | - | - | O |

<br/>

## Directory Structure

<details>
<summary><b>aws/</b> - AWS Monitoring & GitOps</summary>

```
aws/
├── argocd/          # ArgoCD configurations for AWS
├── grafana/         # Grafana dashboards and configurations
├── loki/            # Loki logging stack setup
└── prometheus/      # Prometheus monitoring configurations
```
</details>

<details>
<summary><b>gcp/</b> - GCP Monitoring & GitOps</summary>

```
gcp/
├── argocd/          # ArgoCD configurations for GCP
├── grafana/         # Grafana dashboards and configurations
├── loki/            # Loki logging stack setup
└── prometheus/      # Prometheus monitoring configurations
```
</details>

<details>
<summary><b>onpremise/</b> - On-Premise Full Stack</summary>

```
onpremise/
├── argocd/                          # ArgoCD setup with Helm charts
│   └── helm/                        # Charts, templates, values
├── elk-stack/                       # Elastic Stack (APM, ES, Filebeat, Kibana, Logstash, Metricbeat)
├── grafana/                         # Dashboards and templates
├── ingress-nginx-sidecar-fluentbit/ # Logging with ingress sidecar
├── jenkins/                         # CI/CD server configurations
├── kube-prometheus-stack/           # Full Kubernetes monitoring stack
├── loki/                            # Log aggregation system
├── promtail/                        # Log collector
└── thanos/                          # Long-term metrics storage
```
</details>

<details>
<summary><b>github-cicd/</b> - GitHub Actions Workflows</summary>

```
github-cicd/
├── aws/             # AWS build & deploy workflows
├── gcp/             # GCP build & deploy workflows (matrix strategy, data pipelines)
└── aws-gcp/         # Cross-cloud configurations
```
</details>

<details>
<summary><b>gitlab-cicd/</b> - GitLab CI/CD Pipelines</summary>

```
gitlab-cicd/
└── script/          # Pipeline scripts and utilities
```
</details>

<details>
<summary><b>github-runner/</b> - Self-hosted GitHub Actions Runner</summary>

```
github-runner/
└── actions-runner-controller/   # CRDs, CRs, and templates
```
</details>

<details>
<summary><b>gitlab-runner/</b> - Self-hosted GitLab Runner</summary>

```
gitlab-runner/
└── templates/       # Runner configuration templates
```
</details>

<br/>

## Getting Started

1. Choose your target platform (`aws/`, `gcp/`, or `onpremise/`)
2. Navigate to the specific tool directory
3. Follow the README instructions in each directory for setup steps
4. Customize values files for your environment

```bash
# Example: Deploy Prometheus on On-Premise
cd onpremise/kube-prometheus-stack
helm install prometheus . -f values/values.yaml -n monitoring --create-namespace
```

<br/>

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
