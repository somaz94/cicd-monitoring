#!/usr/bin/env python3
# upgrade-template: external-standard

# ============================================================
# Configuration (ONLY section that differs between scripts)
# To reuse this script for other Helm charts, copy this file
# and modify ONLY the variables below.
# ============================================================
CONFIG = {
    "SCRIPT_NAME":    "prometheus-elasticsearch-exporter Helm Chart Upgrade Script",
    "HELM_REPO_NAME": "prometheus-community",
    "HELM_REPO_URL":  "https://prometheus-community.github.io/helm-charts",
    "HELM_CHART":     "prometheus-community/prometheus-elasticsearch-exporter",
    "CHANGELOG_URL":  "https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-elasticsearch-exporter",
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
