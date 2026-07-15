#!/usr/bin/env python3
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "external-oci" upgrade.py body.
#
# Used by external Helm charts distributed via OCI registries (ghcr.io,
# Docker Hub OCI, ECR) where `helm search repo` is unavailable. Latest
# version detection uses the GitHub Releases API instead. Everything
# else mirrors `external-standard`, with two optional CONFIG flags for
# wrapper-mode Chart.yaml and tracked-chart-scoped helmfile rewrites.
#
# Required CONFIG keys (per-chart):
#   SCRIPT_NAME / HELM_REPO_NAME / HELM_REPO_URL / HELM_CHART
#   CHANGELOG_URL / CHART_TYPE                — same as external-standard
#   GITHUB_REPO                               — "owner/repo" for Releases API
#   GITHUB_TAG_PREFIX                         — prefix stripped from tag
#                                              (default "v"; "" for bare;
#                                              "<chart>-" for multi-chart repos)
#
# Optional CONFIG keys (default off — single-chart helmfile mirrors keep working):
#   WRAPPER_CHART_YAML        True when local Chart.yaml is wrapper metadata
#                             for a multi-chart helmfile component (only the
#                             `version:` line is patched; values.yaml /
#                             values.schema.json are NOT written).
#                             Default False.
#   HELMFILE_TRACKED_CHART    OCI URL substring used to scope the helmfile
#                             version-pin update. When set, only the pin in
#                             the release block whose `chart:` line contains
#                             this substring is bumped. Required for
#                             multi-release helmfiles where this script tracks
#                             only one chart. Default "".
#
# HELM_REPO_NAME / HELM_REPO_URL are unused for OCI charts (no `helm repo add`
# needed) but kept in CONFIG for cross-template compatibility — set them to
# empty strings or descriptive placeholders.
#
# Real per-chart upgrade.py files are kept in sync via:
#   scripts/upgrade-sync/sync.py --apply
# Only the body below the third `# ===` marker is propagated.

# ============================================================
# Configuration (per-chart placeholders — replaced in real upgrade.py)
# ============================================================
CONFIG = {
    "SCRIPT_NAME":            "__SCRIPT_NAME__",
    "HELM_REPO_NAME":         "__HELM_REPO_NAME__",  # informational only for OCI
    "HELM_REPO_URL":          "__HELM_REPO_URL__",   # informational only for OCI
    "HELM_CHART":             "__HELM_CHART__",      # oci://... URL
    "GITHUB_REPO":            "__GITHUB_REPO__",     # owner/repo for Releases API
    "GITHUB_TAG_PREFIX":      "v",                   # strip from tag; "" for bare
    "CHANGELOG_URL":          "__CHANGELOG_URL__",
    "CHART_TYPE":             "__CHART_TYPE__",      # "local" or "external"
    "WRAPPER_CHART_YAML":     False,                 # default: full Chart.yaml replace
    "HELMFILE_TRACKED_CHART": "",                    # default: bump all matching pins
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
