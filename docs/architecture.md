# Architecture Overview

<br/>

## Platform Architecture

This repository covers three deployment environments, each with a full CI/CD and monitoring stack.

```mermaid
graph TB
    subgraph CICD["CI/CD Platforms"]
        GL["GitLab CI\n(48 pipeline patterns)"]
        GH["GitHub Actions\n(AWS / GCP / Hybrid)"]
        JK["Jenkins\n(Game resource builds)"]
    end

    subgraph BUILD["Build Layer"]
        KN["Kaniko\n(in-cluster image build)"]
        DK["Docker\n(local build)"]
        UN["Unity\n(game client build)"]
    end

    subgraph REG["Container Registry"]
        HB["Harbor\n(On-Premise)"]
        ECR["AWS ECR"]
        GAR["GCP Artifact Registry"]
    end

    subgraph GITOPS["GitOps"]
        ARGO["ArgoCD\n(all platforms)"]
    end

    subgraph AWS["AWS EKS"]
        direction TB
        KPS_A["Kube-Prometheus-Stack"]
        GRF_A["Grafana"]
        LK_A["Loki"]
        FB_A["Fluent Bit\n(CloudWatch)"]
        GRN_A["GitLab Runner"]
        ARGO_A["ArgoCD\n(ALB Ingress)"]
    end

    subgraph GCP["GCP GKE"]
        direction TB
        KPS_G["Kube-Prometheus-Stack"]
        GRF_G["Grafana"]
        LK_G["Loki"]
        ARGO_G["ArgoCD\n(GKE Ingress)"]
    end

    subgraph OP["On-Premise Kubernetes"]
        direction TB
        KPS_O["Kube-Prometheus-Stack"]
        GRF_O["Grafana"]
        LK_O["Loki"]
        TH["Thanos\n(long-term storage)"]
        ELK["ELK Stack\n(ES + Kibana + Fluent Bit)"]
        HBR["Harbor Registry"]
        PT["Promtail"]
        JKS["Jenkins Server"]
        ARGO_O["ArgoCD\n(Dex SSO + Redis HA)"]
        NG["Ingress Nginx\n(+ Fluent Bit sidecar)"]
    end

    GL -->|"trigger"| KN
    GH -->|"trigger"| KN
    GH -->|"trigger"| DK
    JK -->|"trigger"| UN

    KN --> HB
    KN --> ECR
    KN --> GAR
    DK --> ECR
    DK --> GAR

    HB --> ARGO_O
    ECR --> ARGO_A
    GAR --> ARGO_G

    ARGO_A --> AWS
    ARGO_G --> GCP
    ARGO_O --> OP
```

<br/>

## Component Dependency Graph

```mermaid
graph LR
    subgraph Metrics["Metrics Pipeline"]
        NE["Node Exporter"] --> PROM["Prometheus"]
        KSM["kube-state-metrics"] --> PROM
        AM["Alertmanager"] --> PROM
        PROM --> GRF["Grafana"]
        PROM --> TH["Thanos\n(on-premise only)"]
        TH --> GRF
    end

    subgraph Logs["Log Pipeline"]
        FB_C["Fluent Bit\n(CloudWatch / sidecar)"] --> LK["Loki"]
        PT["Promtail\n(on-premise)"] --> LK
        LK --> GRF
    end

    subgraph ELK_G["ELK Log Pipeline (On-Premise)"]
        FB_E["Fluent Bit"] --> ES["Elasticsearch"]
        ES --> KB["Kibana"]
    end

    subgraph GitOps["GitOps"]
        RD["Redis\n(session store)"] --> ARGO["ArgoCD"]
        DEX["Dex\n(OIDC / SSO)"] --> ARGO
        ARGO -->|"sync"| K8S["Kubernetes\nworkloads"]
    end

    subgraph Registry["Registry"]
        DB["PostgreSQL"] --> HBR["Harbor"]
        RD2["Redis\n(cache)"] --> HBR
        S3C["S3-compatible storage"] --> HBR
    end

    subgraph Jenkins_S["Jenkins (On-Premise)"]
        NFS["NFS storage"] --> JKS["Jenkins Server"]
        JKS --> AGT["Jenkins Agent\n(Kubernetes pod)"]
    end
```

<br/>

## Network Flow

```mermaid
sequenceDiagram
    participant DEV as Developer
    participant GIT as GitLab / GitHub
    participant CI as CI/CD Runner
    participant REG as Container Registry
    participant ARGO as ArgoCD
    participant K8S as Kubernetes

    DEV->>GIT: git push
    GIT->>CI: trigger pipeline
    CI->>CI: build image (Kaniko)
    CI->>REG: push image
    CI->>GIT: update values YAML (image tag)
    ARGO->>GIT: detect change (polling / webhook)
    ARGO->>K8S: sync manifests
    K8S->>K8S: rolling update
```

<br/>

## Storage Architecture

| Environment | Metrics | Logs | Registry | Persistence |
|-------------|---------|------|----------|-------------|
| **AWS EKS** | EBS / EFS (Prometheus) | S3 (Loki) | AWS ECR | EBS / EFS (ReadWriteMany) |
| **GCP GKE** | PD (Prometheus) | GCS (Loki) | Artifact Registry | Persistent Disk |
| **On-Premise** | NFS (Prometheus + Thanos) | NFS (Loki) | Harbor (NFS-backed) | NFS / local-path |

<br/>

## Ingress Architecture

| Environment | Ingress Controller | TLS | Auth |
|-------------|-------------------|-----|------|
| **AWS EKS** | AWS ALB (group-based, shared) | ACM certificate | IAM / JWT |
| **GCP GKE** | GKE native ingress | Managed certificate | Workload Identity |
| **On-Premise** | ingress-nginx | cert-manager (Let's Encrypt) | Dex (GitLab SSO) |
