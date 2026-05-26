#!/usr/bin/env python3
# upgrade-template: external-standard

# ============================================================
# Configuration (ONLY section that differs between scripts)
# To reuse this script for other Helm charts, copy this file
# and modify ONLY the variables below.
# ============================================================
CONFIG = {
    "SCRIPT_NAME":    "ECK Operator Helm Chart Upgrade Script",
    "HELM_REPO_NAME": "elastic",
    "HELM_REPO_URL":  "https://helm.elastic.co",
    "HELM_CHART":     "elastic/eck-operator",
    "CHANGELOG_URL":  "https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-release-notes.html",
    "CHART_TYPE":     "external",  # "local" or "external"
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
