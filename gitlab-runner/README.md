## Gitlab Runner Instal

- 사용가능한 Helm Chart 버전 확인
```bash
helm search repo -l gitlab/gitlab-runner
```

- NAMESPACE 추가
```bash
kubectl create namespace <네임스페이스>
```

- Role, RoleBinding 추가(안해도 되는듯?)
```bash
kubectl apply -f gitlab-runner-role.yaml -f gitlab-runner-role-binding.yaml -n <네임스페이스>
```

- GitLab Runner 설치 및 업그레이드 방법

```bash
helm install -n <네임스페이스> <릴리즈 이름> -f <브랜치별 helm values 파일명>.yaml gitlab/gitlab-runner
helm upgrade -n <네임스페이스> <릴리즈 이름> -f <브랜치별 helm values 파일명>.yaml gitlab/gitlab-runner
```

## Reference
- [gitlab-runner helm chart](https://gitlab.com/gitlab-org/charts/gitlab-runner)
- [gitlab-runner docs from helm chart](https://docs.gitlab.com/runner/install/kubernetes.html)