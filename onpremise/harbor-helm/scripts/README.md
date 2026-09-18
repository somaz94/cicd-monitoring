# Harbor Scripts

Operational utilities for the Harbor registry, organized per tool in sub-directories.

<br/>

## Layout

One sub-directory per tool, each with its own README — `image-cleanup/` handles bulk old-image cleanup and project stats, `admin/` handles users, project members, and OIDC group management.

The `image-cleanup/` entry scripts source their feature modules from `modules/`. `admin/` has no modules: a single entry script covers everything.

<br/>

## Tools

### [image-cleanup/](./image-cleanup/)

Prunes old images in a Harbor project based on a keep-count, and reports per-project artifact stats.

```bash
./image-cleanup/harbor-image-cleanup-en.sh --dry-run -k 50 -p example-project -r all
./image-cleanup/harbor-image-cleanup-en.sh --stats example-project
```

Details: [`image-cleanup/README-en.md`](./image-cleanup/README.md)

<br/>

### [admin/](./admin/)

Manages users, project members, and OIDC group mappings via the Harbor v2.0 REST API. Pulls `harborAdminPassword` from [`cicd/harbor-helm/values/dev.yaml`](../values/dev.yaml).

```bash
./admin/harbor-admin.sh users
./admin/harbor-admin.sh promote admin@example.com
./admin/harbor-admin.sh add-member library group:server developer
./admin/harbor-admin.sh config
```

Details: [`admin/README-en.md`](./admin/README.md)

<br/>

## Naming Convention

- `<name>.sh` / `<name>-en.sh` — two parallel variants, kept only under `image-cleanup/`
- `admin/harbor-admin.sh` is a single script with no variant

The two variants are separated by lineage, not by language — neither emits Korean. They differ in which module set the entry script sources and in message wording. See [`image-cleanup/README-en.md`](./image-cleanup/README.md).

<br/>

## Related

- Harbor Helm chart: [`cicd/harbor-helm/`](../)
- TLS (self-signed) setup: [`cicd/harbor-helm/docs/tls-setup-en.md`](../docs/tls-setup.md)
- Keycloak OIDC SSO setup (current standard): [`cicd/harbor-helm/docs/oidc-setup-keycloak-en.md`](../docs/oidc-setup-keycloak.md)
- GitLab OIDC direct (pre-Phase 4, rollback reference): [`cicd/harbor-helm/docs/legacy/oidc-setup-gitlab-en.md`](../docs/legacy/oidc-setup-gitlab.md)
