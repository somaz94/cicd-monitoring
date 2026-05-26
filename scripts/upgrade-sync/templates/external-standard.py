#!/usr/bin/env python3
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "external-standard" upgrade.py body.
# Used by external Helm charts (helm repo + helmfile) with the default flow.
# Real per-chart upgrade.py files are kept in sync via:
#   scripts/upgrade-sync/sync.py --apply
# Only the body below the third `# ===` marker is propagated.

# ============================================================
# Configuration (per-chart placeholders — replaced in real upgrade.py)
# ============================================================
CONFIG = {
    "SCRIPT_NAME":    "__SCRIPT_NAME__",
    "HELM_REPO_NAME": "__HELM_REPO_NAME__",
    "HELM_REPO_URL":  "__HELM_REPO_URL__",
    "HELM_CHART":     "__HELM_CHART__",
    "CHANGELOG_URL":  "__CHANGELOG_URL__",
    "CHART_TYPE":     "__CHART_TYPE__",  # "local" or "external"
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

from upgrade_core.external_standard import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(CONFIG, sys.argv[1:], script_path=__file__))
