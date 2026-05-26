#!/usr/bin/env python3
# upgrade-template: external-oci

# ============================================================
# Configuration — keycloak-operator (dev cluster, somaz94 OCI chart)
# - Tracks the somaz94/keycloak-operator OCI chart version (helmfile.yaml.version)
# - Body is canonical-managed via scripts/upgrade-sync/sync.py --apply
# ============================================================
CONFIG = {
    "SCRIPT_NAME":            "Keycloak Operator Helm Chart Upgrade Script",
    "HELM_REPO_NAME":         "",                                                      # OCI — informational only
    "HELM_REPO_URL":          "",                                                      # OCI — informational only
    "HELM_CHART":             "oci://ghcr.io/somaz94/charts/keycloak-operator",
    "GITHUB_REPO":            "somaz94/helm-charts",
    "GITHUB_TAG_PREFIX":      "keycloak-operator-",                                    # release tag = keycloak-operator-0.1.0
    "CHANGELOG_URL":          "https://github.com/somaz94/helm-charts/releases?q=keycloak-operator",
    "CHART_TYPE":             "external",
    "WRAPPER_CHART_YAML":     False,
    "HELMFILE_TRACKED_CHART": "",
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

from upgrade_core.external_oci import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(CONFIG, sys.argv[1:], script_path=__file__))
