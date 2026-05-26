#!/usr/bin/env python3
# upgrade-template: local-with-templates

# ============================================================
# Configuration — Fluent Bit (example dev cluster, LOCAL chart)
# - Tracks the upstream fluent/fluent-bit Helm chart
# - Preserves repo-local custom templates: pv.yaml, pvc.yaml
# - Re-applies the _pod.tpl PVC volume block patch after upstream sync
# ============================================================
CUSTOM_POD_PATCH = """{{- if and .Values.persistentVolumeClaims.enabled .Values.persistentVolumeClaims.items }}
{{- range $persistentVolumeClaim := .Values.persistentVolumeClaims.items }}
  - name: {{ $persistentVolumeClaim.name }}
    persistentVolumeClaim:
      claimName: {{ $persistentVolumeClaim.name }}
{{- end }}
{{- end }}"""

CONFIG = {
    "SCRIPT_NAME":      "Fluent Bit Helm Chart Upgrade Script (Local Chart)",
    "HELM_REPO_NAME":   "fluent",
    "HELM_REPO_URL":    "https://fluent.github.io/helm-charts",
    "HELM_CHART":       "fluent/fluent-bit",
    "CHANGELOG_URL":    "https://github.com/fluent/helm-charts/tree/main/charts/fluent-bit",
    # Helm pull mode — git source unused for fluent-bit.
    "CHART_GIT_REPO":   "",
    "CHART_GIT_PATH":   "",
    "CUSTOM_TEMPLATES": ["pv.yaml", "pvc.yaml"],
    "CUSTOM_POD_PATCH": CUSTOM_POD_PATCH,
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
