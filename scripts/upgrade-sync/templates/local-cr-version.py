#!/usr/bin/env python3
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "local-cr-version" upgrade.py body.
#
# Used by LOCAL Helm charts that wrap a Custom Resource and have NO upstream
# Helm chart to sync from. Typical shape:
#   - Chart.yaml (local metadata, appVersion tracks component version)
#   - helmfile.yaml (chart: .)
#   - values/<env>.yaml (holds .<VERSION_KEY> — e.g. .version)
#   - templates/*.yaml (owned by us, not synced from upstream)
#
# What this script does:
#   1. Reads the current version from <CHART_DIR>/<VALUES_FILE>.
#   2. Queries the component's version feed for the latest GA version.
#   3. Verifies the container image exists in the registry before applying.
#   4. Diffs and, on apply, updates both <VALUES_FILE> and Chart.yaml appVersion.
#      When MIRROR_CHART_VERSION is true, also updates Chart.yaml version.
#
# Supported VERSION_SOURCE values (set per chart):
#   - elastic-artifacts : Elastic Stack version feed.
#   - github-releases   : GitHub Releases API for a given owner/repo.
#   - docker-hub-tags   : Docker Hub tags API for a given namespace/repository.
#
# Difference vs "external-oci-cr-version":
#   - K12 owns Chart.yaml (local metadata mirror); K13 does not.
#   - K12 has the MIRROR_CHART_VERSION option; K13 does not.
#   - K12 backup contains Chart.yaml + values file; K13 = values only.
#   - K12 has NO OCI chart-pin sub-flow (--check-chart / --upgrade-chart);
#     K13 does because it consumes an external OCI chart.
#
# Real per-chart upgrade.py files are kept in sync via:
#   scripts/upgrade-sync/sync.py --apply
# Only the body below the third `# ===` marker is propagated.

# ============================================================
# Configuration (per-chart placeholders — replaced in real upgrade.py)
# ============================================================
CONFIG = {
    "SCRIPT_NAME":            "__SCRIPT_NAME__",
    "COMPONENT_LABEL":        "__COMPONENT_LABEL__",
    # One of: elastic-artifacts | github-releases | docker-hub-tags
    "VERSION_SOURCE":         "__VERSION_SOURCE__",
    # Argument for the selected VERSION_SOURCE. Interpretation varies:
    #   elastic-artifacts : ignored
    #   github-releases   : "<owner>/<repo>" (e.g. "cloudnative-pg/cloudnative-pg")
    #   docker-hub-tags   : "<namespace>/<repository>" (e.g. "bitnami/redis")
    "VERSION_SOURCE_ARG":     "__VERSION_SOURCE_ARG__",
    # Path relative to CHART_DIR holding the version field (e.g. values/dev.yaml)
    "VALUES_FILE":            "__VALUES_FILE__",
    # Top-level YAML key holding the version string (e.g. version)
    "VERSION_KEY":             "__VERSION_KEY__",
    # Major-line pin. Empty = any. E.g. "9" to lock to 9.x.
    "MAJOR_PIN":              "__MAJOR_PIN__",
    "CHANGELOG_URL":          "__CHANGELOG_URL__",
    # Container image to verify before upgrading (registry/repository format).
    # Tag is appended automatically from the target version. Empty = skip.
    "CONTAINER_IMAGE":        "__CONTAINER_IMAGE__",
    # Operator webhook handling for rollback (all four required to enable).
    "CR_WEBHOOK_NAME":        "__CR_WEBHOOK_NAME__",
    "CR_OPERATOR_NS":         "__CR_OPERATOR_NS__",
    "CR_OPERATOR_STS":        "__CR_OPERATOR_STS__",
    "CR_OPERATOR_CHART_DIR":  "__CR_OPERATOR_CHART_DIR__",
    # Dependency CR: ensures the target version is <= this CR's current version.
    # Leave empty ("") to skip.
    "DEPENDENCY_CR_KIND":     "__DEPENDENCY_CR_KIND__",
    "DEPENDENCY_CR_NAME":     "__DEPENDENCY_CR_NAME__",
    # Mirror appVersion into Chart.yaml 'version' field. Useful for single-CR
    # wrapper charts where chart version and app version are functionally the
    # same. True to enable, False (default) to keep chart version manual.
    "MIRROR_CHART_VERSION":   False,
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

from upgrade_core.local_cr_version import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(CONFIG, sys.argv[1:], script_path=__file__))
