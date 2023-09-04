## Gitlab Runner Instal

- Check the available Helm Chart versions
```bash
helm search repo -l gitlab/gitlab-runner
```

- ADD namespace
```bash
kubectl create namespace <네임스페이스>
```

- ADD Role, RoleBinding (I don't think I need to?)
```bash
kubectl apply -f gitlab-runner-role.yaml -f gitlab-runner-role-binding.yaml -n <네임스페이스>
```

- GitLab Runner Install and Upgrade
```bash
helm install -n <네임스페이스> <릴리즈 이름> -f <브랜치별 helm values 파일명>.yaml gitlab/gitlab-runner
helm upgrade -n <네임스페이스> <릴리즈 이름> -f <브랜치별 helm values 파일명>.yaml gitlab/gitlab-runner
```

## Reference
- [gitlab-runner helm chart](https://gitlab.com/gitlab-org/charts/gitlab-runner)
- [gitlab-runner docs from helm chart](https://docs.gitlab.com/runner/install/kubernetes.html)