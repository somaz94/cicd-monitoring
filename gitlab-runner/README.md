## Gitlab Runner Instal

- Check the available Helm Chart versions
```bash
helm search repo -l gitlab/gitlab-runner
```

- ADD namespace
```bash
kubectl create namespace <namespace>
```

- ADD Role, RoleBinding (I don't think I need to?)
```bash
kubectl apply -f gitlab-runner-role.yaml -f gitlab-runner-role-binding.yaml -n <namespace>
```

- GitLab Runner Install and Upgrade
```bash
helm install -n <namespace> <release name> -f <helm values file>.yaml gitlab/gitlab-runner
helm upgrade -n <namespace> <release nam> -f <helm values file>.yaml gitlab/gitlab-runner
```

## Reference
- [gitlab-runner helm chart](https://gitlab.com/gitlab-org/charts/gitlab-runner)
- [gitlab-runner docs from helm chart](https://docs.gitlab.com/runner/install/kubernetes.html)