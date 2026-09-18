#!/usr/bin/env python3
# upgrade-template: argocd-pin

# ============================================================
# Configuration (ONLY section that differs between scripts)
# To reuse this script for other Helm charts, copy this file
# and modify ONLY the variables below.
# ============================================================
CONFIG = {
    "SCRIPT_NAME":    "GitLab Runner Helm Chart Upgrade Script",
    "BASE":           "standard",
    "HELM_REPO_NAME": "gitlab",
    "HELM_REPO_URL":  "https://charts.gitlab.io",
    "HELM_CHART":     "gitlab/gitlab-runner",
    "CHANGELOG_URL":  "https://gitlab.com/gitlab-org/charts/gitlab-runner/-/blob/main/CHANGELOG.md",
    "CHART_TYPE":     "local",  # "local" or "external"
    # ArgoCD-managed: version SSOT is argocd/<release>.yaml chart.version (no helmfile).
    # All three runner releases track the same chart. old-build-deploy-image was
    # excluded while it sat on chart 0.70.3, because diffing a 0.70.x values file
    # against a current chart produced nothing but noise. It was brought up to
    # 0.91.0 on 2026-08-31, so that exclusion no longer has a reason to exist.
    #
    # Note what including it implies: this release serves gitlab-old, whose image
    # tag is pinned by hand to the gitlab-old server version, while the chart now
    # follows gitlab-main. Every bump here widens that gap until the 21-hop path
    # brings the server up to 19.x -- so review this release's diff rather than
    # waving it through. See scripts/gitlab/old-upgrade/UPGRADE-PATH.md.
    "ARGOCD_PIN_FILES": [
        "argocd/build-image.yaml",
        "argocd/deploy-image.yaml",
        "argocd/old-build-deploy-image.yaml",
    ],
}
# ============================================================

# ── canonical body (sync-managed, do not edit below) ────────
import sys
from pathlib import Path

_here = Path(__file__).resolve().parent
for _anc in [_here, *_here.parents]:
    if (_anc / "scripts" / "python" / "upgrade_core").is_dir():
        sys.path.insert(0, str(_anc / "scripts" / "python"))
        break

from upgrade_core.argocd_pin import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(CONFIG, sys.argv[1:], script_path=__file__))
