#!/usr/bin/env python3
# upgrade-template: argocd-pin

# ============================================================
# Configuration (ONLY section that differs between scripts)
# To reuse this script for other Helm charts, copy this file
# and modify ONLY the variables below.
# ============================================================
CONFIG = {
    "SCRIPT_NAME":    "Vaultwarden Helm Chart Upgrade Script",
    "BASE":           "standard",
    "HELM_REPO_NAME": "guerzon",
    "HELM_REPO_URL":  "https://guerzon.github.io/vaultwarden",
    "HELM_CHART":     "guerzon/vaultwarden",
    "CHANGELOG_URL":  "https://github.com/guerzon/vaultwarden",
    "CHART_TYPE":     "external",  # "local" or "external"
    # ArgoCD-managed: version SSOT is argocd/<release>.yaml chart.version (no helmfile).
    "ARGOCD_PIN_FILES": [
        "argocd/vaultwarden.yaml",
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
