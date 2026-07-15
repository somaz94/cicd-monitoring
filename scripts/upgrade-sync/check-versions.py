#!/usr/bin/env python3
"""check-versions.py — read-only preflight that reports which managed charts
have an upstream upgrade available.

Callers — `scripts/ci/auto-upgrade.py`, `.gitlab/ci/upgrade-pipeline.yml`'s
`check_versions` job, and any human invocation — share one CLI:

  check-versions.py [--only <substring>]... [--no-update] [--updates-only]

Supported template types (matched against the `# upgrade-template:` header
on line 2 of each managed upgrade.sh):
  external-standard         -> helm search repo
  external-with-image-tag   -> helm search repo
  external-oci              -> GitHub Releases API (GITHUB_REPO, honors GITHUB_TAG_PREFIX)
  external-oci-with-mirror  -> same as external-oci (mirror stage runs at apply time only)
  external-oci-cr-version   -> VERSION_SOURCE feed (VALUES_FILE-backed CR version)
  local-with-templates      -> helm search repo OR git ls-remote --tags
  local-cr-version          -> VERSION_SOURCE feed
  ansible-github-release    -> GitHub Releases API (GITHUB_REPO)
  argocd-pin                -> helm repo (BASE=standard) or GitHub Releases
                               (BASE=oci); version SSOT in argocd/<release>.yaml

Output: human-readable status table on stdout. Format string widths match the
bash version verbatim so the awk state machine in `auto-upgrade.py`'s
`parse_check_versions_phase()` keeps working.

Exit codes:
  0 — all scans succeeded (regardless of whether upgrades were found).
  1 — one or more scans failed (network / missing helm / bad config).
  2 — usage error.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# upgrade_sync package bootstrap — share discovery / parse-header helpers
# with sync.py and auto-upgrade.py. Ancestor-walk pattern mirrors the
# consumer upgrade.py files so the import resolves under both venv and the
# CI helmfile-tools image.
# ---------------------------------------------------------------------------
_here = Path(__file__).resolve().parent
for _anc in [_here, *_here.parents]:
    if (_anc / "scripts" / "python" / "upgrade_sync").is_dir():
        sys.path.insert(0, str(_anc / "scripts" / "python"))
        break

from upgrade_sync.config_parse import parse_config_block  # noqa: E402
from upgrade_sync.discovery import (  # noqa: E402
    find_managed_files,
    parse_template_header,
)
from upgrade_sync.table import (  # noqa: E402
    EMPTY_SENTINEL,
    ChartRow,
    Row,
    print_chart_table,
    print_main_table,
)
from upgrade_sync.yaml_helpers import (  # noqa: E402
    read_argocd_chart_version,
    read_helmfile_chart_pin,
    read_yaml_value,
)


# ---------------------------------------------------------------------------
# Phase 1 — parse every managed upgrade.sh into rows.
# ---------------------------------------------------------------------------


def matches_only(rel: str, only_patterns: list[str]) -> bool:
    if not only_patterns:
        return True
    return any(p in rel for p in only_patterns)


def parse_managed_files(
    repo_root: Path, only_patterns: list[str],
) -> tuple[list[Row], list[ChartRow], list[str], int, int, int]:
    """Walk every managed upgrade.sh and emit (rows, chart_rows, helm_repos,
    total, skipped, filtered).

    `skipped` counts files without an `# upgrade-template:` header.
    `filtered` counts files removed by `--only` substring(s).
    `helm_repos` is the de-duplicated `name=url` list to register.
    """
    rows: list[Row] = []
    chart_rows: list[ChartRow] = []
    helm_repos_seen: list[str] = []  # ordered de-dup
    total = 0
    skipped = 0
    filtered = 0

    for f in find_managed_files(repo_root):
        total += 1
        rel = str(f.relative_to(repo_root))

        template = parse_template_header(f)
        if not template:
            skipped += 1
            continue
        if not matches_only(rel, only_patterns):
            filtered += 1
            continue

        cfg = parse_config_block(f)
        chart_dir = f.parent
        current = ""
        fetcher = ""
        fetcher_arg = ""
        extra_arg = ""
        tag_prefix = ""
        version_source_arg = ""
        container_image = cfg.container_image
        label = cfg.script_name or chart_dir.name

        if template in ("external-standard", "external-with-image-tag"):
            chart_yaml = chart_dir / "Chart.yaml"
            if chart_yaml.is_file():
                current = read_yaml_value(chart_yaml, "version")
            fetcher = "helm-repo"
            fetcher_arg = cfg.helm_chart
            if cfg.helm_repo_name and cfg.helm_repo_url:
                pair = f"{cfg.helm_repo_name}={cfg.helm_repo_url}"
                if pair not in helm_repos_seen:
                    helm_repos_seen.append(pair)
        elif template in ("external-oci", "external-oci-with-mirror"):
            chart_yaml = chart_dir / "Chart.yaml"
            if chart_yaml.is_file():
                current = read_yaml_value(chart_yaml, "version")
            fetcher = "version-source"
            fetcher_arg = "github-releases"
            version_source_arg = cfg.github_repo
            tag_prefix = cfg.github_tag_prefix
        elif template == "argocd-pin":
            # Version SSOT is <component>/argocd/<release>.yaml chart.version
            # (the migrated components have no helmfile). BASE selects the
            # fetcher: "oci" -> GitHub Releases, else helm repo.
            current = read_argocd_chart_version(chart_dir)
            if cfg.base == "oci":
                fetcher = "version-source"
                fetcher_arg = "github-releases"
                version_source_arg = cfg.github_repo
                tag_prefix = cfg.github_tag_prefix
            else:
                fetcher = "helm-repo"
                fetcher_arg = cfg.helm_chart
                if cfg.helm_repo_name and cfg.helm_repo_url:
                    pair = f"{cfg.helm_repo_name}={cfg.helm_repo_url}"
                    if pair not in helm_repos_seen:
                        helm_repos_seen.append(pair)
        elif template == "local-with-templates":
            chart_yaml = chart_dir / "Chart.yaml"
            if chart_yaml.is_file():
                current = read_yaml_value(chart_yaml, "version")
            if cfg.chart_git_repo:
                fetcher = "git-tags"
                fetcher_arg = cfg.chart_git_repo
            else:
                fetcher = "helm-repo"
                fetcher_arg = cfg.helm_chart
                if cfg.helm_repo_name and cfg.helm_repo_url:
                    pair = f"{cfg.helm_repo_name}={cfg.helm_repo_url}"
                    if pair not in helm_repos_seen:
                        helm_repos_seen.append(pair)
        elif template in ("local-cr-version", "external-oci-cr-version"):
            if cfg.values_file and cfg.version_key:
                values_path = chart_dir / cfg.values_file
                if values_path.is_file():
                    current = read_yaml_value(values_path, cfg.version_key)
            fetcher = "version-source"
            fetcher_arg = cfg.version_source
            extra_arg = cfg.major_pin
            # `local-cr-version` historically uses VERSION_SOURCE_ARG (e.g.
            # `elastic/eck-operator`) and `external-oci-cr-version` does not.
            # Both go through the same column in the Row.
            version_source_arg = cfg.version_source_arg
        elif template == "ansible-github-release":
            if cfg.version_file and cfg.version_key:
                vf = chart_dir / cfg.version_file
                if vf.is_file():
                    current = read_yaml_value(vf, cfg.version_key)
            fetcher = "version-source"
            fetcher_arg = "github-releases"
            extra_arg = cfg.major_pin
            version_source_arg = cfg.github_repo
        else:
            fetcher = "unknown"

        rows.append(Row(
            rel=rel,
            template=template,
            label=label,
            current=current,
            fetcher=fetcher,
            fetcher_arg=fetcher_arg,
            extra_arg=extra_arg,
            container_image=container_image,
            version_source_arg=version_source_arg,
            tag_prefix=tag_prefix,
        ))

        # OCI chart-pin tracking (Phase 4 — external-oci-cr-version today).
        if cfg.chart_source_type and cfg.chart_source_repo and cfg.chart_name:
            # Migrated CR components (elasticsearch / kibana) have no helmfile;
            # their chart-pin SSOT moved to argocd/<release>.yaml. Prefer the
            # helmfile pin, fall back to the ArgoCD metadata.
            chart_current = (
                read_helmfile_chart_pin(chart_dir)
                or read_argocd_chart_version(chart_dir)
            )
            chart_rows.append(ChartRow(
                rel=rel,
                name=cfg.chart_name,
                current=chart_current,
                source_type=cfg.chart_source_type,
                source_repo=cfg.chart_source_repo,
            ))

    return rows, chart_rows, helm_repos_seen, total, skipped, filtered


# ---------------------------------------------------------------------------
# Phase 2 — register + update helm repos (best-effort).
# ---------------------------------------------------------------------------


def helm_available() -> bool:
    result = subprocess.run(
        ["helm", "version", "--short"],
        capture_output=True, text=True, check=False,
    )
    return result.returncode == 0


def setup_helm_repos(helm_repos: list[str], skip_update: bool) -> None:
    """Best-effort `helm repo add` + `helm repo update`. All failures are
    silenced (matches bash `|| true`) — the per-row fetcher will surface
    helm errors with a row-level ERROR status instead.
    """
    if not helm_repos:
        return
    print(f"Registering {len(helm_repos)} helm repo(s)...")
    for pair in helm_repos:
        name, _, url = pair.partition("=")
        subprocess.run(
            ["helm", "repo", "add", name, url],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
    if skip_update:
        return
    print("Running 'helm repo update'...")
    result = subprocess.run(
        ["helm", "repo", "update"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    if result.returncode != 0:
        print("  WARN: helm repo update failed (stale cache will be used)")


# ---------------------------------------------------------------------------
# Argument parsing + entry point.
# ---------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Build the same surface as the bash version: --only repeatable, --no-update,
    --updates-only. argparse.ArgumentParser auto-generates --help."""
    parser = argparse.ArgumentParser(
        prog=Path(argv[0]).name,
        description=(
            "Scans all managed upgrade.sh files and reports charts that have "
            "an upstream upgrade available. Read-only; no files are modified."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Exit codes:\n"
            "  0  All scans succeeded (regardless of whether upgrades were found).\n"
            "  1  One or more scans failed (network, missing helm, bad config, etc).\n"
        ),
    )
    parser.add_argument(
        "--only", action="append", metavar="SUBSTRING", default=[],
        help="Only check paths whose relative path contains <substring>. Repeatable.",
    )
    parser.add_argument(
        "--no-update", action="store_true",
        help="Skip 'helm repo update' (faster on repeated runs).",
    )
    parser.add_argument(
        "--updates-only", action="store_true",
        help="Only print rows with status UPDATE or ERROR.",
    )
    return parser.parse_args(argv[1:])


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent

    print("Collecting managed upgrade.{sh,py} configs...")
    rows, chart_rows, helm_repos, total, skipped, filtered = parse_managed_files(
        repo_root, args.only,
    )
    managed = total - skipped
    if filtered > 0:
        print(
            f"  Managed: {managed}  Skipped (no header): {skipped}  "
            f"Filtered out by --only: {filtered}"
        )
    else:
        print(f"  Managed: {managed}  Skipped (no header): {skipped}")

    if not rows:
        print("")
        print("No files to check.")
        return 0

    helm_installed = helm_available()
    if helm_installed:
        setup_helm_repos(helm_repos, args.no_update)
    else:
        print("WARN: 'helm' not found on PATH — helm-repo checks will error out.")

    ok, update, error, no_image = print_main_table(rows, helm_installed, args.updates_only)
    print("")
    if no_image > 0:
        print(
            f"Summary: OK={ok}  UPDATE={update}  NO_IMG={no_image}  ERROR={error}  "
            f"(total={len(rows)})"
        )
    else:
        print(f"Summary: OK={ok}  UPDATE={update}  ERROR={error}  (total={len(rows)})")
    if update > 0:
        print(
            "Upgrades are available. Run 'cd <path> && ./upgrade.py --dry-run' "
            "in each directory above."
        )
    elif error == 0 and no_image == 0:
        print("All managed charts are up to date.")
    if no_image > 0:
        print(
            "NO_IMG: version listed in upstream feed but container image not "
            "published yet. Wait or skip."
        )

    any_error = error > 0

    if chart_rows:
        chart_ok, chart_update, chart_error = print_chart_table(
            chart_rows, args.updates_only,
        )
        print("")
        print(
            f"Chart summary: OK={chart_ok}  UPDATE={chart_update}  "
            f"ERROR={chart_error}  (total={len(chart_rows)})"
        )
        if chart_update > 0:
            print("Chart pin updates available. In each path above:")
            print("  ./upgrade.py --check-chart              # details")
            print("  ./upgrade.py --upgrade-chart --dry-run  # preview + render diff")
            print("  ./upgrade.py --upgrade-chart            # apply")
        if chart_error > 0:
            any_error = True

    return 1 if any_error else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
