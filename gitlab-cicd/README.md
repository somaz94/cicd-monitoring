# GitLab CI/CD

Reusable CI/CD templates and complete pipeline patterns for GitLab CI/CD.

<br/>

## Directory Structure

```
gitlab-cicd/
├── templates/                          # Reusable CI/CD components
│   ├── variables/
│   │   ├── common.yml                  # Common variables, base templates, script fragments
│   │   └── services.yml                # Service name variables
│   ├── auth/
│   │   └── aws.yml                     # AWS ECR authentication
│   ├── build/
│   │   ├── kaniko-ecr.yml              # AWS ECR Kaniko build
│   │   └── kaniko-harbor.yml           # Harbor registry Kaniko build
│   ├── deploy/
│   │   └── argocd.yml                  # ArgoCD GitOps deployment
│   ├── backup/
│   │   └── gdrive.yml                  # Google Drive backup via rclone
│   └── examples/
│       ├── monorepo.gitlab-ci.yml      # Monorepo multi-service pipeline example
│       └── basic.gitlab-ci.yml         # Basic template usage example
│
├── pipelines/                          # Complete pipeline patterns
│   ├── build-deploy/                   # Basic build & deploy patterns
│   │   ├── basic.yml                   # Generator → Build → Update
│   │   ├── with-slack.yml              # With Slack notifications
│   │   ├── with-slack-v2.yml           # Slack notifications v2
│   │   └── manual-auto-trigger.yml     # Manual/auto trigger separation
│   ├── gcp-artifact-registry/          # GCP Artifact Registry patterns
│   │   ├── basic.yml                   # Standard GAR build & deploy
│   │   └── advanced.yml               # Advanced GAR with more options
│   ├── server/                         # Server service pipelines (v1-v6 evolution)
│   │   ├── harbor-v1.yml ~ v6.yml     # Harbor registry versions
│   │   ├── aws-v1.yml ~ v2.yml        # AWS ECR versions
│   │   └── aws-module-v1.yml ~ v3.yml # Template-based modular versions
│   ├── data/                           # Data pipeline patterns (v1-v11 evolution)
│   │   ├── harbor-v1.yml ~ v11.yml    # NFS upload, validation, versioning
│   │   ├── aws-v1.yml ~ v2.yml        # S3 upload versions
│   │   └── aws-module-v1.yml ~ v3.yml # Template-based modular versions
│   ├── client/                         # Client pipelines
│   │   ├── v1.yml, v2.yml             # Basic client CI
│   │   └── module-v1.yml, v2.yml      # Template-based versions
│   ├── client-cs/                      # Client C# code generation
│   │   └── v1.yml
│   ├── admin/                          # Admin service pipelines
│   │   ├── harbor-v1.yml              # Harbor build
│   │   ├── aws-v1.yml                 # AWS ECR build
│   │   └── aws-module-v1.yml          # Template-based
│   ├── battle/                         # Battle service pipelines
│   │   ├── harbor-v1.yml              # Harbor build
│   │   ├── aws-v1.yml                 # AWS ECR build
│   │   └── aws-module-v1.yml          # Template-based
│   ├── data-upload/                    # Data upload utilities
│   │   ├── basic.yml                  # Basic rsync upload
│   │   └── server-client.yml          # Server/client split upload
│   └── backup/                         # Backup pipelines
│       ├── gdrive-v1.yml              # Google Drive sync v1
│       └── gdrive-v2.yml              # Google Drive sync v2
│
├── scripts/
│   ├── sync_to_gcs.py                 # GCS data synchronization
│   └── version-scripts/                # Version parsing tools
│       ├── package.json
│       ├── parser.ts
│       ├── versions.ts
│       └── tsconfig.json
│
└── README.md
```

<br/>

## Templates

Reusable CI/CD building blocks designed to be included via `include:` in `.gitlab-ci.yml`.

| Template | Description |
|----------|-------------|
| `variables/common.yml` | Common variables, base job configs (`.common_job_config`, `.build_kaniko_base`, `.deploy_argocd_base`), script fragments (git, SSH, packages) |
| `variables/services.yml` | Service name variable definitions |
| `auth/aws.yml` | AWS ECR authentication with STS role support |
| `build/kaniko-ecr.yml` | Kaniko image build for AWS ECR (ARM64 support, 24h cache) |
| `build/kaniko-harbor.yml` | Kaniko image build for Harbor registry |
| `deploy/argocd.yml` | ArgoCD deployment (clone → update image tag → commit → push) |
| `backup/gdrive.yml` | Git mirror backup to Google Drive via rclone |

<br/>

## Pipeline Patterns

Complete pipeline examples showing different CI/CD strategies:

| Category | Description | Files |
|----------|-------------|-------|
| **build-deploy** | Basic generator → build → deploy patterns | 4 |
| **gcp-artifact-registry** | GCP Artifact Registry with gcloud auth | 2 |
| **server** | Server service evolution from basic to modular | 11 |
| **data** | Data validation, upload, and versioning | 16 |
| **client** | Client CI and code generation | 5 |
| **admin** | Admin service build & deploy | 3 |
| **battle** | Battle service build & deploy | 3 |
| **data-upload** | Data file upload utilities | 2 |
| **backup** | Google Drive backup | 2 |

<br/>

## Pipeline Evolution

The versioned pipeline files (v1 → vN) show the evolution of CI/CD patterns:

1. **Basic** (v1-v2): Simple build and deploy with hardcoded values
2. **Enhanced** (v3-v6): Added validation, versioning, multi-environment support
3. **AWS** (aws-v1-v2): Extended to AWS ECR with STS authentication
4. **Modular** (aws-module-v1-v3): Refactored to use shared templates via `include:`

<br/>

## Prerequisites

- GitLab instance with CI/CD enabled
- GitLab Runner (Docker executor recommended)
- Container registry (Harbor or AWS ECR)
- ArgoCD for GitOps deployment (optional)

<br/>

## CI/CD Variables

Required variables to configure in GitLab CI/CD settings:

| Variable | Description |
|----------|-------------|
| `CI_REGISTRY_USER` | Container registry username |
| `CI_REGISTRY_PASSWORD` | Container registry password |
| `GITLAB_SSH_PRIVATE_KEY` | SSH key for Git operations |
| `AWS_SSH_PRIVATE_KEY` | SSH key for AWS EC2 access (optional) |
| `NFS_SSH_PRIVATE_KEY` | SSH key for NFS server (optional) |
| `AWS_ACCESS_KEY` | AWS access key for ECR (optional) |
| `AWS_SECRET_KEY` | AWS secret key for ECR (optional) |

<br/>

## References

- [GitLab CI/CD Documentation](https://docs.gitlab.com/ee/ci/)
- [Predefined Variables](https://docs.gitlab.com/ee/ci/variables/predefined_variables.html)
- [GitLab CI/CD Templates](https://docs.gitlab.com/ee/ci/examples/)
