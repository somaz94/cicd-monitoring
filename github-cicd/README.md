# GitHub CI/CD

GitHub Actions workflow patterns for AWS, GCP, and hybrid cloud environments.

<br/>

## Directory Structure

```
github-cicd/
├── aws/
│   ├── build-deploy-repo/                      # AWS build & deploy workflows
│   │   ├── aws-build.yml                       # Docker build → ECR push
│   │   ├── aws-deploy.yml                      # Helm-based deployment
│   │   ├── aws-prod-deploy.yml                 # Production deployment
│   │   ├── s3-upload-cloudfront-cache-invalidate.yml  # S3 upload + CDN invalidation
│   │   └── generate_files.yml                  # TypeScript file generation
│   └── data-repo/                              # AWS data pipeline workflows
│       ├── 1.check-data.yml                    # Detect JSON data changes
│       ├── 2.archive-artifact.yml              # Archive as GitHub artifacts
│       ├── 3.deploy-data.yml                   # Upload to S3 patch buckets
│       └── 4.trigger-ts-generate.yml           # Trigger downstream generation
│
├── gcp/
│   ├── build-deploy-repo/                      # GCP build & deploy workflows
│   │   ├── gcp-build.yml                       # Docker build → Artifact Registry
│   │   ├── gcp-deploy.yml                      # Helm-based deployment
│   │   ├── gcp-prod-deploy.yml                 # Production deployment
│   │   ├── gcs-upload-cloudcdn-cache-invalidate.yml  # GCS upload + CDN invalidation
│   │   ├── generate_files.yml                  # TypeScript file generation
│   │   └── set_content_type.py                 # GCS content-type metadata utility
│   ├── data-repo/                              # GCP data pipeline workflows
│   │   ├── 1.check-data.yml                    # Detect JSON data changes
│   │   ├── 2.archive-artifact.yml              # Archive as GitHub artifacts
│   │   ├── 3.deploy-data.yml                   # Upload to GCS patch buckets
│   │   └── 4.trigger-ts-generate.yml           # Trigger downstream generation
│   ├── data-build-deploy-repo/                 # Combined data + build + deploy
│   │   ├── build.yml, deploy.yml, generate_files.yml
│   ├── matrix-strategy/                        # Matrix strategy example
│   │   └── cicd.yml                            # Multi-branch, multi-service matrix
│   ├── upgrade-data-build-deploy-repo/         # Enhanced data pipeline v1
│   │   ├── build.yml, deploy.yml, generate_files.yml, trigger.yml
│   └── upgrade-data-build-deploy-repo-v2/      # Enhanced data pipeline v2
│       ├── build.yml, deploy.yml, generate_files.yml, trigger.yml
│
├── aws-gcp/
│   └── ci_cd.yml                               # Hybrid AWS + GCP workflow
│
└── README.md
```

<br/>

## Workflow Patterns

### Build & Deploy

| Workflow | AWS | GCP | Description |
|----------|:---:|:---:|-------------|
| **Build** | `aws-build.yml` | `gcp-build.yml` | Docker image build with multi-service support |
| **Deploy** | `aws-deploy.yml` | `gcp-deploy.yml` | Helm-based deployment via config repo update |
| **Prod Deploy** | `aws-prod-deploy.yml` | `gcp-prod-deploy.yml` | Production-only deployment (manual trigger) |
| **CDN Upload** | `s3-upload-...` | `gcs-upload-...` | Static asset upload + CDN cache invalidation |
| **Generate** | `generate_files.yml` | `generate_files.yml` | TypeScript generation from data artifacts |

<br/>

### Data Pipeline

Sequential workflow orchestration:

```
1. check-data.yml        → Detect JSON file changes
2. archive-artifact.yml  → Archive as GitHub artifacts
3. deploy-data.yml       → Upload to S3/GCS buckets
4. trigger-ts-generate   → Trigger TypeScript generation
```

<br/>

### Pipeline Evolution

| Version | Directory | Changes |
|---------|-----------|---------|
| v1 | `data-build-deploy-repo/` | Basic combined pipeline |
| v2 | `upgrade-data-build-deploy-repo/` | Multi-service, conditional logic |
| v3 | `upgrade-data-build-deploy-repo-v2/` | Additional services, improved triggers |

<br/>

## Authentication

| Provider | Method |
|----------|--------|
| **GCP** | Workload Identity Federation (OIDC) |
| **AWS** | IAM Access Key / Secret Key |
| **Hybrid** | Both + SSH key for direct server access |

<br/>

## GitHub Secrets

Required secrets in repository or organization settings:

| Secret | Description |
|--------|-------------|
| `CICD_PAT` | GitHub Personal Access Token for cross-repo triggers |
| `GCP_SERVICE_ACCOUNT` | GCP service account email |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | GCP Workload Identity provider |
| `AWS_ACCESS_KEY_ID` | AWS IAM access key |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM secret key |
| `SLACK_WEBHOOK_URL` | Slack notification webhook |
| `GCE_SSH_PRIVATE_KEY` | SSH key for GCE instances (optional) |

<br/>

## Action Modules

Commonly used GitHub Action modules:

#### General
- [checkout](https://github.com/actions/checkout) - Repository checkout
- [changed-files](https://github.com/tj-actions/changed-files) - Detect file changes

#### Docker & Registry
- [docker/login-action](https://github.com/docker/login-action) - Registry authentication
- [docker/setup-buildx-action](https://github.com/docker/setup-buildx-action) - Buildx setup
- [docker/build-push-action](https://github.com/docker/build-push-action) - Build and push images

#### Cloud Platforms
- [google-github-actions/auth](https://github.com/google-github-actions/auth) - GCP authentication
- [google-github-actions/setup-gcloud](https://github.com/google-github-actions/setup-gcloud) - gcloud CLI
- [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials) - AWS auth
- [aws-actions/amazon-ecr-login](https://github.com/aws-actions/amazon-ecr-login) - ECR login

#### Utilities
- [repository-dispatch](https://github.com/peter-evans/repository-dispatch) - Cross-repo triggers
- [slack-github-action](https://github.com/slackapi/slack-github-action) - Slack notifications
- [ssh-action](https://github.com/appleboy/ssh-action) - SSH remote commands

<br/>

## References

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Workflow Syntax](https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions)
- [Encrypted Secrets](https://docs.github.com/en/actions/security-guides/encrypted-secrets)
