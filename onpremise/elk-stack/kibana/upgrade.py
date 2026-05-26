#!/usr/bin/env python3
# upgrade-template: external-oci-cr-version

# ============================================================
# Configuration (ONLY section that differs between scripts)
# ============================================================
CONFIG = {
    "SCRIPT_NAME":            "Kibana (ECK CR, OCI chart) Stack Version Upgrade Script",
    "COMPONENT_LABEL":        "kibana",
    # One of: elastic-artifacts | github-releases | docker-hub-tags
    "VERSION_SOURCE":         "elastic-artifacts",
    # Argument for the selected VERSION_SOURCE. Interpretation varies:
    #   elastic-artifacts : ignored
    #   github-releases   : "<owner>/<repo>" (e.g. "cloudnative-pg/cloudnative-pg")
    #   docker-hub-tags   : "<namespace>/<repository>" (e.g. "bitnami/redis")
    "VERSION_SOURCE_ARG":     "",
    # Path relative to CHART_DIR holding the version field (e.g. values/dev.yaml)
    "VALUES_FILE":            "values/dev.yaml",
    # Top-level YAML key holding the version string (e.g. version)
    "VERSION_KEY":             "version",
    # Major-line pin. Empty = any. E.g. "9" to lock to 9.x.
    "MAJOR_PIN":              "9",
    "CHANGELOG_URL":          "https://www.elastic.co/guide/en/kibana/current/release-notes.html",
    # Container image to verify before upgrading (registry/repository format).
    # Tag is appended automatically from the target version. Empty = skip.
    "CONTAINER_IMAGE":        "docker.elastic.co/kibana/kibana",
    # Operator webhook handling for rollback (all four required to enable).
    "CR_WEBHOOK_NAME":        "elastic-operator.elastic-system.k8s.elastic.co",
    "CR_OPERATOR_NS":         "elastic-system",
    "CR_OPERATOR_STS":        "elastic-operator",
    "CR_OPERATOR_CHART_DIR":  "eck-operator",
    # Dependency CR: ensures the target version is <= this CR's current version.
    # E.g., Kibana must be <= the linked Elasticsearch version. Empty = skip.
    "DEPENDENCY_CR_KIND":     "elasticsearch",
    "DEPENDENCY_CR_NAME":     "elasticsearch",
    # OCI chart pin tracking (for --check-chart / --upgrade-chart).
    # When all three are set, the script can detect and bump the chart version in
    # helmfile.yaml. Leave CHART_SOURCE_TYPE empty ("") to disable chart tracking
    # (the script then only manages the Stack/component version in VALUES_FILE).
    "CHART_SOURCE_TYPE":      "github-releases",   # "github-releases" or ""
    "CHART_SOURCE_REPO":      "somaz94/helm-charts",   # "<owner>/<repo>"
    "CHART_NAME":             "kibana-eck",          # tag prefix (e.g. "elasticsearch-eck")
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
