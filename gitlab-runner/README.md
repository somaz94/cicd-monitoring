# GitLab Runner Installation Guide
This guide walks you through the process of installing GitLab Runner on Kubernetes using Helm.

<br/>

## Pre-requisites
Ensure you have Helm and kubectl installed and configured for your Kubernetes cluster.

<br/>

## Steps

<br/>

### 1. Check Available Helm Chart Versions:

Before installing, it's a good practice to check the available versions of the GitLab Runner Helm Chart.
```bash
helm search repo -l gitlab/gitlab-runner
```

<br/>

### 2. Create a Namespace:

Decide on a dedicated namespace for GitLab Runner. Replace <namespace> with your desired namespace name.
```bash
kubectl create namespace <namespace>
```

<br/>

### 3. Setup Role and RoleBinding (Optional):

For deployment using GitLab Runner, it is essential to apply roles and role bindings within the specific application namespace to ensure the runner has the necessary permissions. This step is crucial for maintaining proper security configurations and access controls required for the deployment process. Apply the provided role and role binding configurations to the appropriate namespace as determined by your access control requirements.
```bash
kubectl apply -f gitlab-runner-role.yaml -f gitlab-runner-role-binding.yaml -n <namespace>
```

<br/>

### 4. Install or Upgrade GitLab Runner:

Use Helm to install or upgrade the GitLab Runner. Replace placeholders (<namespace>, <release name>, and <helm values file>.yaml) with appropriate values.

To install:
```bash
helm install -n <namespace> <release name> -f <helm values file>.yaml gitlab/gitlab-runner
```

To upgrade:
```bash
helm upgrade -n <namespace> <release nam> -f <helm values file>.yaml gitlab/gitlab-runner
```

<br/>

## Reference
- [Official GitLab Runner Helm Chart](https://gitlab.com/gitlab-org/charts/gitlab-runner)
- [GitLab Runner documentation for Kubernetes installation](https://docs.gitlab.com/runner/install/kubernetes.html)

