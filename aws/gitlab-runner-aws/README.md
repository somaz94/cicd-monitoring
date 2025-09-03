# GitLab Runner Installation Guide
This guide walks you through the process of installing GitLab Runner on Kubernetes using Helm or Helmfile.

<br/>

## Pre-requisites
Ensure you have Helm, Helmfile, and kubectl installed and configured for your Kubernetes cluster.

<br/>

## Steps

<br/>

### 1. Check Available Helm Chart Versions:

Before installing, it's a good practice to check the available versions of the GitLab Runner Helm Chart.
```bash
helm search repo -l gitlab/gitlab-runner
helm repo add gitlab https://charts.gitlab.io
helm repo update
helm dependency update .
```

<br/>

### 2. Create a Namespace: (Optional : use --create-namespace)

Decide on a dedicated namespace for GitLab Runner. Replace <namespace> with your desired namespace name.
```bash
kubectl create namespace <namespace>
```

<br/>

### 3. Configure Values File:

Create a values file (e.g., `values/custom-values.yaml`) to configure your GitLab Runner installation. At minimum, you'll need:
```yaml
gitlabUrl: "https://your-gitlab-instance.com"

## Choose one of the following:

# new gitlab runner registration token
runnerToken: "your-registration-token"

# old gitlab runner registration token
runnerRegistrationToken: "your-registration-token"

runners:
  ## DEPRECATED: Specify the tags associated with the runner. Comma-separated list of tags.
  ##
  ## ref: https://docs.gitlab.com/ee/ci/runners/new_creation_workflow.html
  ##
  tags: "build-image"
```

<br/>

### 4. Installation Methods

<br/>

#### Using Helm

Use Helm to install or upgrade the GitLab Runner. Replace placeholders (<namespace>, <release name>, and <helm values file>.yaml) with appropriate values.

To install:
```bash
helm install -n <namespace> <release name> -f values/<helm values file>.yaml gitlab/gitlab-runner

# projectm-client-build: NFS PVC를 사용하여 git clone 캐싱
# /volume1/nfs/projectm/repo/client -> /builds/client/projectm 마운트
helm install -n gitlab-runner projectm-client-build-image -f values/projectm-client-build.yaml .
```

To upgrade:
```bash
helm upgrade -n <namespace> <release name> -f values/<helm values file>.yaml gitlab/gitlab-runner

# projectm-client-build: NFS PVC를 사용하여 git clone 캐싱
# /volume1/nfs/projectm/repo/client -> /builds/client/projectm 마운트
helm upgrade -n gitlab-runner projectm-client-build-image -f values/projectm-client-build.yaml .
```

<br/>

#### Using Helmfile

Alternatively, you can manage all GitLab Runners at once using Helmfile:

```bash
# Compare with current state
helmfile diff

# Deploy or update
helmfile apply

# Deploy specific release
helmfile -l name=build-image sync

# Delete all releases
helmfile destroy

# Delete specific release
helmfile -l name=old-build-deploy-image destroy  # Destroy single release
```

Example helmfile.yaml configuration:
```yaml
repositories:
  - name: gitlab
    url: https://charts.gitlab.io

releases:
  - name: build-image
    namespace: gitlab-runner
    chart: gitlab/gitlab-runner  # Use External chart directory
    version: 0.71.0  # Chart version from Chart.yaml
    values:
      - values/build.yaml

  - name: deploy-image
    namespace: gitlab-runner
    chart: gitlab/gitlab-runner
    version: 0.71.0
    values:
      - values/deploy.yaml

  # ... other releases follow the same pattern
```

Currently deployed releases:
```bash
NAME                    NAMESPACE      REVISION  UPDATED                               STATUS    CHART                 APP VERSION
build-image            gitlab-runner  7         2025-02-06 17:54:57.873844 +0900 KST deployed  gitlab-runner-0.71.0  17.6.0     
deploy-image           gitlab-runner  2         2024-12-04 11:03:39.54014 +0900 KST  deployed  gitlab-runner-0.71.0  17.6.0     
old-build-deploy-image gitlab-runner  2         2024-11-12 14:20:06.704803 +0900 KST deployed  gitlab-runner-0.70.3  17.5.3
```

<br/>

### 5. Upgrading GitLab Runner

To check the latest available version of GitLab Runner chart:
```bash
helm search repo gitlab/gitlab-runner
```

Example output:
```bash
NAME                	CHART VERSION	APP VERSION	DESCRIPTION  
gitlab/gitlab-runner	0.77.3       	18.0.3     	GitLab Runner
```

To upgrade GitLab Runner using Helmfile:

1. Update the chart version in your `helmfile.yaml`:
```yaml
releases:
  - name: build-image
    namespace: gitlab-runner
    chart: gitlab/gitlab-runner
    version: 0.77.3  # Update to the latest version
    values:
      - values/build.yaml

  - name: deploy-image
    namespace: gitlab-runner
    chart: gitlab/gitlab-runner
    version: 0.77.3  # Update to the latest version
    values:
      - values/deploy.yaml
```

2. Preview changes before applying:
```bash
helmfile diff
```

3. Apply the upgrade:
```bash
# Upgrade all runners
helmfile apply

# Or upgrade specific runner
helmfile -l name=build-image sync
```

Important considerations before upgrading:
- Ensure you have a backup of your current configuration
- Schedule the upgrade during off-peak hours
- Test the upgrade in a staging environment if possible
- Keep the previous configuration for rollback purposes
- Verify runner functionality after the upgrade

⚠️ Important Note About Values.yaml:
- Always check the official chart's default values.yaml for changes:
  ```bash
  # View the default values.yaml for the specific version
  helm show values gitlab/gitlab-runner --version 0.77.3
  ```
- Compare your current values.yaml with the new version's default values.yaml
- New versions might introduce breaking changes in values.yaml structure
- Key changes to watch for:
  - New required parameters
  - Deprecated parameters
  - Changed parameter structures or naming
  - New features that might need configuration
- Reference the official chart repository for detailed release notes:
  https://gitlab.com/gitlab-org/charts/gitlab-runner/-/blob/main/CHANGELOG.md

To verify the installed version after upgrade:
```bash
helm list -n gitlab-runner
```

<br/>

## Reference
- [Official GitLab Runner Helm Chart](https://gitlab.com/gitlab-org/charts/gitlab-runner)
- [GitLab Runner documentation for Kubernetes installation](https://docs.gitlab.com/runner/install/kubernetes.html)



