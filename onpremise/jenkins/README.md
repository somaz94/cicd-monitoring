# Jenkins Helm Chart

Manages Jenkins CI/CD server using Helmfile.

<br/>

## Directory Structure

```
jenkins/
├── Chart.yaml          # Version tracking (no local templates)
├── helmfile.yaml       # Helmfile release definition (uses remote chart)
├── values.yaml         # Upstream default values (auto-managed by upgrade.sh)
├── values/
│   └── mgmt.yaml       # Custom values (manually managed)
├── upgrade.sh          # Version upgrade script
├── backup/             # Auto backup on upgrade
├── _backup/            # Old plain YAML files (pre-helmfile migration)
└── README.md
```

<br/>

## Prerequisites

- Kubernetes cluster
- Helm 3
- Helmfile
- Ingress controller (nginx)
- StorageClass (e.g., `nfs-client`)

<br/>

## Quick Start

```bash
# Validate configuration
helmfile lint

# Preview changes
helmfile diff

# Deploy
helmfile apply

# Delete
helmfile destroy
```

<br/>

## Upgrade

```bash
# Check latest version and upgrade
./upgrade.sh

# Preview changes only
./upgrade.sh --dry-run

# Upgrade to a specific version
./upgrade.sh --version 5.9.9

# Rollback from backup
./upgrade.sh --rollback
```

<br/>

## Jenkins CLI

```bash
wget http://jenkins.somaz.example.com/jnlpJars/jenkins-cli.jar

# Check version
java -jar jenkins-cli.jar -s http://jenkins.somaz.example.com/ -auth <user>:<api-token> -version

# Copy job
java -jar jenkins-cli.jar -s http://jenkins.somaz.example.com/ -auth <user>:<api-token> copy-job <origin-job> <copy-job>

# Reload configuration
java -jar jenkins-cli.jar -s http://jenkins.somaz.example.com/ -auth <user>:<api-token> reload-configuration
```

<br/>

## API Token

1. Navigate to Jenkins Dashboard
2. Go to Jenkins Management > Users
3. Select your username > Settings
4. Under API Token, click 'ADD new Token'

<br/>

## References

- https://github.com/jenkinsci/helm-charts
- https://www.jenkins.io/doc/
