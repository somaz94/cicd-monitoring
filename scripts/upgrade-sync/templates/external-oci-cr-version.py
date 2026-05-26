#!/usr/bin/env python3
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "external-oci-cr-version" upgrade.py body.
#
# Used by CONSUMER repos that deploy a Custom Resource via an EXTERNAL Helm
# chart distributed over OCI (e.g. oci://ghcr.io/org/charts/foo). The consumer
# does NOT own the chart templates — chart upgrades happen in the publishing
# repo. This script only tracks the Stack/component version in values/<env>.yaml.
#
# Typical shape:
#   - helmfile.yaml        # chart: oci://..., version: "<chart semver>"
#   - values/<env>.yaml    # holds .<VERSION_KEY> — the Stack/component version
#   - upgrade.py           # this script
#   - (NO Chart.yaml, NO templates/ — those live in the chart publisher repo)
#
# What this script does:
#   1. Reads the current version from <CHART_DIR>/<VALUES_FILE>.
#   2. Queries the component's version feed for the latest GA version.
#   3. Verifies the container image exists in the registry before applying.
#   4. Diffs and, on apply, updates <VALUES_FILE> only.
#
# Supported VERSION_SOURCE values (set per chart):
#   - elastic-artifacts : GETs https://artifacts-api.elastic.co/v1/versions
#                         Applies to all Elastic Stack components.
#   - github-releases   : GitHub Releases API for a given owner/repo.
#   - docker-hub-tags   : Docker Hub tags API for a given namespace/repository.
#
# Difference vs "local-cr-version":
#   - No Chart.yaml manipulation (chart metadata lives upstream).
#   - No MIRROR_CHART_VERSION option (irrelevant without local Chart.yaml).
#   - Backup contains only the values file (Chart.yaml restore path removed).
#   - OCI chart version in helmfile.yaml is bumped via the script's
#     `--check-chart` / `--upgrade-chart` subcommands when
#     CHART_SOURCE_TYPE is configured. Without that config the chart pin
#     stays a manual `helm pull` + review responsibility.
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
    # E.g., Kibana must be <= the linked Elasticsearch version. Empty = skip.
    "DEPENDENCY_CR_KIND":     "__DEPENDENCY_CR_KIND__",
    "DEPENDENCY_CR_NAME":     "__DEPENDENCY_CR_NAME__",
    # OCI chart pin tracking (for --check-chart / --upgrade-chart).
    # When all three are set, the script can detect and bump the chart version in
    # helmfile.yaml. Leave CHART_SOURCE_TYPE empty ("") to disable chart tracking
    # (the script then only manages the Stack/component version in VALUES_FILE).
    "CHART_SOURCE_TYPE":      "__CHART_SOURCE_TYPE__",   # "github-releases" or ""
    "CHART_SOURCE_REPO":      "__CHART_SOURCE_REPO__",   # "<owner>/<repo>"
    "CHART_NAME":             "__CHART_NAME__",          # tag prefix (e.g. "elasticsearch-eck")
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

from upgrade_core.external_oci_cr_version import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(CONFIG, sys.argv[1:], script_path=__file__))
