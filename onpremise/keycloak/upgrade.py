#!/usr/bin/env python3
# upgrade-template: external-oci

# ============================================================
# Configuration — keycloak (dev cluster, somaz94 OCI chart)
# - Tracks the somaz94/keycloak-cr OCI chart version (helmfile.yaml.version of the `keycloak` release).
# - The sibling postgresql release is bumped via the db-redis cycle (out of scope here).
# - Body is canonical-managed via scripts/upgrade-sync/sync.py --apply.
# ============================================================
CONFIG = {
    "SCRIPT_NAME":            "Keycloak (CR + DB) Helm Chart Upgrade Script",
    "HELM_REPO_NAME":         "",                                                # OCI — informational only
    "HELM_REPO_URL":          "",                                                # OCI — informational only
    "HELM_CHART":             "oci://ghcr.io/somaz94/charts/keycloak-cr",
    "GITHUB_REPO":            "somaz94/helm-charts",
    "GITHUB_TAG_PREFIX":      "keycloak-cr-",                                    # release tag = keycloak-cr-0.1.0
    "CHANGELOG_URL":          "https://github.com/somaz94/helm-charts/releases?q=keycloak-cr",
    "CHART_TYPE":             "external",
    # Wrapper Chart.yaml: local Chart.yaml is component metadata (name=keycloak,
    # describes the keycloak-cr+postgresql bundle) — NOT a mirror of the upstream
    # keycloak-cr chart. Only the chart wrapper `version:` line is bumped;
    # appVersion stays the actual Keycloak app version (manually maintained).
    "WRAPPER_CHART_YAML":     True,
    # Multi-release helmfile: only the `keycloak` release (chart: keycloak-cr) is
    # tracked here. The `keycloak-postgresql` release is bumped via the db-redis
    # cycle and must NOT be touched by this script.
    "HELMFILE_TRACKED_CHART": "oci://ghcr.io/somaz94/charts/keycloak-cr",
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
