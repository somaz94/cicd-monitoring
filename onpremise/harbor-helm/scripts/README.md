# Harbor Scripts

Operational utilities for the Harbor registry, organized per tool in sub-directories.

Korean: [README.md](./README.md)

<br/>

## Layout

```
cicd/harbor-helm/scripts/
├── image-cleanup/        # Bulk old-image cleanup + project stats
│   ├── harbor-image-cleanup.sh / harbor-image-cleanup-en.sh
│   ├── stats-help.sh / stats-help-en.sh
│   ├── modules/          # Feature modules (KR/EN)
│   ├── backup/           # Original single-file script (legacy)
│   └── README.md / README-en.md
└── admin/                # Users / project members / OIDC group management
    ├── harbor-admin.sh
    └── README.md / README-en.md
```

<br/>

## Tools

### [image-cleanup/](./image-cleanup/)

Prunes old images in a Harbor project based on a keep-count, and reports per-project artifact stats.

```bash
./image-cleanup/harbor-image-cleanup-en.sh --dry-run -k 50 -p example-project -r all
./image-cleanup/harbor-image-cleanup-en.sh --stats example-project
```

Details: [`image-cleanup/README-en.md`](./image-cleanup/README-en.md)

<br/>

### [admin/](./admin/)

Manages users, project members, and OIDC group mappings via the Harbor v2.0 REST API. Pulls `harborAdminPassword` from [`cicd/harbor-helm/values/dev.yaml`](../../cicd/harbor-helm/values/dev.yaml).

```bash
./admin/harbor-admin.sh users
./admin/harbor-admin.sh promote admin@example.com
./admin/harbor-admin.sh add-member library group:server developer
./admin/harbor-admin.sh config
```

Details: [`admin/README-en.md`](./admin/README-en.md)

<br/>

## Naming Convention

- `<name>.sh` — Korean UI (default)
- `<name>-en.sh` — English UI

Both variants share identical logic; only user-facing messages/help text differ.

<br/>

## Related

- Harbor Helm chart: [`cicd/harbor-helm/`](../../cicd/harbor-helm/)
- TLS (self-signed) setup: [`cicd/harbor-helm/docs/tls-setup-en.md`](../../cicd/harbor-helm/docs/tls-setup-en.md)
- Keycloak OIDC SSO setup (current standard): [`cicd/harbor-helm/docs/oidc-setup-keycloak-en.md`](../../cicd/harbor-helm/docs/oidc-setup-keycloak-en.md)
- GitLab OIDC direct (pre-Phase 4, rollback reference): [`cicd/harbor-helm/docs/legacy/oidc-setup-gitlab-en.md`](../../cicd/harbor-helm/docs/legacy/oidc-setup-gitlab-en.md)
