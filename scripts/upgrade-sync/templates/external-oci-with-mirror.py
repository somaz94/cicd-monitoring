#!/usr/bin/env python3
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "external-oci-with-mirror" upgrade.py body.
#
# Variant of "external-oci" that adds an optional Step 7 mirror stage:
# upstream container images referenced by the chart are copied to a private
# registry (e.g. Harbor) before values rewrite, so air-gapped / private
# clusters can pull from the mirror instead of upstream Docker Hub / ghcr.io.
#
# Required CONFIG keys (per-chart, same set as external-oci):
#   SCRIPT_NAME / HELM_REPO_NAME / HELM_REPO_URL / HELM_CHART
#   GITHUB_REPO / GITHUB_TAG_PREFIX / CHANGELOG_URL / CHART_TYPE
#
# Optional CONFIG plumbing for the mirror + Step 1 hooks:
#   do_mirror               Per-chart Python callable. Receives kwargs
#                           chart_dir / temp_dir / values_dir /
#                           latest_version / latest_app_version /
#                           mirror_image. Returns 0 to proceed, non-zero
#                           to abort the upgrade (Step 8 apply will not
#                           run). When omitted, Step 7 is skipped
#                           silently.
#   print_values_summary    Per-chart Python callable invoked at the
#                           tail of Step 1. Receives kwarg values_dir.
#                           When omitted, the K10 default surfaces
#                           `.image.tag` per `values/*.yaml` via yq.
#
# Helper exposed via the do_mirror kwargs:
#   mirror_image(upstream_ref, harbor_ref, *, insecure=False) -> int
#                           Compares digests; copies via `crane copy`
#                           only when different; verifies digest match
#                           after copy. Return code propagates to the
#                           caller (non-zero aborts via do_mirror).
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
}

# Per-chart hooks (optional). Define here in the real upgrade.py — the
# `do_mirror` callable receives `mirror_image` as a kwarg so the body can
# stay short. Leave either entry out of CONFIG to fall back to the
# defaults documented in the header comment above.
#
# Example skeleton:
#
#   def do_mirror(*, chart_dir, temp_dir, values_dir,
#                 latest_version, latest_app_version, mirror_image):
#       rc = mirror_image("docker.io/library/foo:1.2.3",
#                         "harbor.example.com/library/foo:1.2.3",
#                         insecure=True)
#       return rc
#
#   def print_values_summary(*, values_dir):
#       ...
#
#   CONFIG["do_mirror"] = do_mirror
#   CONFIG["print_values_summary"] = print_values_summary
# ============================================================

# ── canonical body (sync-managed, do not edit below) ────────
import sys
from pathlib import Path

_here = Path(__file__).resolve().parent
for _anc in [_here, *_here.parents]:
    if (_anc / "scripts" / "python" / "upgrade_core").is_dir():
        sys.path.insert(0, str(_anc / "scripts" / "python"))
        break

from upgrade_core.external_oci_with_mirror import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(CONFIG, sys.argv[1:], script_path=__file__))
