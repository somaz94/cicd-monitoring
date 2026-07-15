#!/usr/bin/env python3
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "argocd-pin" upgrade.py body.
# Used by infra components migrated to the ArgoCD app-of-apps: the chart-version
# SSOT lives in <component>/argocd/<release>.yaml (chart.version), not a helmfile
# (retired to backup/). Reuses the external-standard / external-oci-with-mirror
# fetch + diff flow and redirects only the version-pin WRITE to the ArgoCD
# metadata file(s) via upgrade_core.argocd_pin.
# Real per-chart upgrade.py files are kept in sync via:
#   scripts/upgrade-sync/sync.py --apply
# Only the body below the third `# ===` marker is propagated; CONFIG is per-chart.

# ============================================================
# Configuration (per-chart placeholders — replaced in real upgrade.py)
#   BASE             "standard" (helm repo) or "oci" (OCI chart + optional mirror)
#   ARGOCD_PIN_FILES list of argocd/<release>.yaml paths (component-relative) to
#                    bump; list only the TRACKED releases (omit pinned/old ones).
#   For BASE="oci" also set GITHUB_REPO / GITHUB_TAG_PREFIX (and optional
#   do_mirror / print_values_summary), same as external-oci-with-mirror.
# ============================================================
CONFIG = {
    "SCRIPT_NAME":      "__SCRIPT_NAME__",
    "BASE":             "__BASE__",  # "standard" or "oci"
    "HELM_REPO_NAME":   "__HELM_REPO_NAME__",
    "HELM_REPO_URL":    "__HELM_REPO_URL__",
    "HELM_CHART":       "__HELM_CHART__",
    "CHANGELOG_URL":    "__CHANGELOG_URL__",
    "CHART_TYPE":       "__CHART_TYPE__",  # "local" or "external"
    "ARGOCD_PIN_FILES": ["__ARGOCD_PIN_FILE__"],
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
