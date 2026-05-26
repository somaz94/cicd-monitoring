#!/usr/bin/env python3
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "local-with-templates" upgrade.py body.
# Used by LOCAL Helm charts (Chart.yaml in repo) that need:
#   - Custom templates preserved across upstream sync (CUSTOM_TEMPLATES)
#   - _pod.tpl patches re-applied after upstream sync (CUSTOM_POD_PATCH)
#   - Extra upstream dirs synced (EXTRA_DIRS — hard-coded "ci"/"dashboards")
# Two upstream source modes:
#   1. helm repo (default): set HELM_REPO_NAME/URL/HELM_CHART, leave
#      CHART_GIT_REPO empty.
#   2. git source: set CHART_GIT_REPO/CHART_GIT_PATH (used for charts not
#      in any helm repo).
#
# Real per-chart upgrade.py files are kept in sync via:
#   scripts/upgrade-sync/sync.py --apply
# Only the body below the third `# ===` marker is propagated.

# ============================================================
# Configuration (per-chart placeholders — replaced in real upgrade.py)
# ============================================================
CONFIG = {
    "SCRIPT_NAME":     "__SCRIPT_NAME__",
    "HELM_REPO_NAME":  "__HELM_REPO_NAME__",
    "HELM_REPO_URL":   "__HELM_REPO_URL__",
    "HELM_CHART":      "__HELM_CHART__",
    "CHANGELOG_URL":   "__CHANGELOG_URL__",
    # Git source mode (used when chart is not in any helm repo). Empty
    # default = helm repo mode.
    "CHART_GIT_REPO":  "",
    "CHART_GIT_PATH":  "",
    # Custom templates that do NOT exist in upstream (will be preserved).
    "CUSTOM_TEMPLATES": ["__CUSTOM_TEMPLATE__"],
    # Patch for _pod.tpl: PVC volume block inserted before the
    # extraVolumes block.
    "CUSTOM_POD_PATCH": "__CUSTOM_POD_PATCH__",
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

from upgrade_core.local_with_templates import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(CONFIG, sys.argv[1:], script_path=__file__))
