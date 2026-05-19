#!/usr/bin/env python3
"""check-versions.py — read-only preflight that reports which managed charts
have an upstream upgrade available.

Python rewrite of scripts/upgrade-sync/check-versions.sh (Phase 3 of the
shell-to-python migration). The bash CLI contract is preserved byte-for-byte
so existing callers — `scripts/ci/auto-upgrade.py`,
`.gitlab/ci/upgrade-pipeline.yml`'s `check_versions` job, and any human
invocation — keep working with no flag or output changes:

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
import json
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field, fields
from pathlib import Path


# ---------------------------------------------------------------------------
# Module constants — table format + sentinels (byte-for-byte parity with bash).
# ---------------------------------------------------------------------------

# Status table column widths. The bash version used `printf '%-7s  %-24s
# %-15s  %-15s  %s'`; Python f-string equivalent below preserves the exact
# spacing (two-space gutter between columns).
ROW_FMT = "  {status:<7}  {template:<24}  {current:<15}  {latest:<15}  {path}"
CHART_ROW_FMT = (
    "  {status:<7}  {name:<20}  {current:<10}  {latest:<10}  {path}"
)

# `printf '%-7s'` pads a string longer than 7 chars verbatim (no truncation),
# so we emit fixed-width sentinel strings rather than relying on str.ljust().
HEADER_ROW = ROW_FMT.format(
    status="STATUS", template="TEMPLATE",
    current="CURRENT", latest="LATEST", path="PATH",
)
HEADER_RULE = ROW_FMT.format(
    status="-------", template="------------------------",
    current="---------------", latest="---------------", path="----",
)
CHART_HEADER_ROW = CHART_ROW_FMT.format(
    status="STATUS", name="CHART",
    current="CURRENT", latest="LATEST", path="PATH",
)
CHART_HEADER_RULE = CHART_ROW_FMT.format(
    status="-------", name="--------------------",
    current="----------", latest="----------", path="----",
)

# Em-dash sentinel used when a value is unknown (matches bash `${var:-—}`).
EMPTY_SENTINEL = "—"

# Container-image probe cap so a regression at upstream (e.g. all the
# top-N tags missing the image) doesn't make the script hang for minutes.
IMAGE_PROBE_MAX_ATTEMPTS = 15

# HTTP timeout (seconds) for upstream metadata fetch. Mirrors bash
# `curl --max-time` implicit behaviour (~10s on most installs).
HTTP_TIMEOUT = 10.0

# Semver triplet regex — `<major>.<minor>.<patch>`, used to filter the GA
# subset of tag lists across all version-source backends.
SEMVER_TRIPLET = re.compile(r"^\d+\.\d+\.\d+$")


@dataclass(frozen=True)
class ConfigVars:
    """CONFIG block scalars from a managed upgrade.sh.

    Mirrors the bash `dump_config_vars` output — every potentially-relevant
    variable across all template types is collected with empty-string
    defaults so the per-template switch downstream can branch cleanly.
    """

    script_name: str = ""
    helm_repo_name: str = ""
    helm_repo_url: str = ""
    helm_chart: str = ""
    chart_type: str = ""
    chart_git_repo: str = ""
    chart_git_path: str = ""
    version_source: str = ""
    version_source_arg: str = ""
    values_file: str = ""
    version_key: str = ""
    major_pin: str = ""
    container_image: str = ""
    github_repo: str = ""
    github_tag_prefix: str = ""
    version_file: str = ""
    chart_source_type: str = ""
    chart_source_repo: str = ""
    chart_name: str = ""


# Mapping from CONFIG block variable name (uppercase) to ConfigVars field
# name (lowercase). Filtered to just the keys we care about so a stray
# variable in upgrade.sh doesn't accidentally populate an attribute.
CONFIG_KEYS: dict[str, str] = {
    f.name.upper(): f.name for f in fields(ConfigVars)
}


@dataclass
class Row:
    """One row of the main status table (Phase 3)."""

    rel: str
    template: str
    label: str
    current: str
    fetcher: str
    fetcher_arg: str
    extra_arg: str
    container_image: str
    version_source_arg: str
    tag_prefix: str


@dataclass
class ChartRow:
    """One row of the OCI chart-pin status table (Phase 4)."""

    rel: str
    name: str
    current: str
    source_type: str
    source_repo: str


# ---------------------------------------------------------------------------
# File discovery + CONFIG parsing.
# ---------------------------------------------------------------------------


def find_managed_files(repo_root: Path) -> list[Path]:
    """Mirror sync.sh's find_managed_files: every upgrade.sh except backup,
    deprecated/optional, the sync tool itself, and the test fixtures dir.
    """
    excluded_substrings = (
        "/backup/",
        "/_deprecated/",
        "/_optional/",
        "/scripts/upgrade-sync/",
        "/tests/python/fixtures/",
    )
    matches: list[Path] = []
    for path in repo_root.rglob("upgrade.sh"):
        if not path.is_file():
            continue
        rel = str(path.relative_to(repo_root))
        if any(s.lstrip("/") in rel for s in excluded_substrings):
            continue
        matches.append(path)
    return sorted(matches)


def parse_template_header(upgrade_sh: Path) -> str:
    """Return the `# upgrade-template: <name>` value on line 2.

    Same contract as auto-upgrade.py's parse_template_header — returns ""
    when the header is absent.
    """
    try:
        with upgrade_sh.open("r", encoding="utf-8") as fh:
            next(fh)  # skip shebang
            line = next(fh, "")
    except OSError:
        return ""
    line = line.rstrip("\n")
    prefix = "# upgrade-template: "
    return line[len(prefix):] if line.startswith(prefix) else ""


# CONFIG block boundary — bash's `extract_config_block` walked from the
# first `# ===…===` separator through the third (inclusive). Three `=`-runs
# wrap the CONFIG section in every canonical upgrade.sh template.
CONFIG_BLOCK_FENCE = re.compile(r"^# ={10,}$")

# CONFIG-line shape: KEY="VALUE" or KEY='VALUE' or KEY=VALUE (bare).
# Captures the key + the raw value text up to the first `#` (comment) or
# the end of line. Trailing whitespace + surrounding quotes are stripped in
# `_clean_value()` below.
CONFIG_LINE = re.compile(r'^([A-Z_][A-Z0-9_]*)=(.*)$')


# Shell parameter expansion: `${VAR:-default}` or `${VAR-default}`. The bash
# eval resolved this to <default> when VAR was unset (the standard case in our
# CONFIG blocks — e.g. `GITHUB_TAG_PREFIX="${GITHUB_TAG_PREFIX:-v}"`). The
# python parser doesn't run bash, so we substitute the default explicitly.
SHELL_PARAM_DEFAULT = re.compile(r'^\$\{([A-Z_][A-Z0-9_]*):?-([^}]*)\}$')


def _clean_value(raw: str) -> str:
    """Strip surrounding quotes + trailing whitespace/comment from a CONFIG
    value, then resolve `${VAR:-default}` to <default> (the bash-eval result
    when VAR is unset, which is always the case in our CONFIG blocks).
    """
    # Drop trailing inline comment (` # ...`) — same as bash's awk strip.
    if " #" in raw:
        raw = raw[: raw.index(" #")]
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ('"', "'"):
        raw = raw[1:-1]
    m = SHELL_PARAM_DEFAULT.match(raw)
    if m:
        return m.group(2)
    return raw


def parse_config_block(upgrade_sh: Path) -> ConfigVars:
    """Read the CONFIG block (first `# ===` through third) and pull the
    scalar assignments into a ConfigVars instance.

    No `eval` — every KEY=VALUE line is matched against `CONFIG_LINE` and
    routed to a known ConfigVars field. Unknown keys are silently ignored
    (matches the bash version's `set +u` tolerance).
    """
    fence_count = 0
    values: dict[str, str] = {}
    try:
        with upgrade_sh.open("r", encoding="utf-8") as fh:
            for line in fh:
                stripped = line.rstrip("\n")
                if CONFIG_BLOCK_FENCE.match(stripped):
                    fence_count += 1
                    if fence_count >= 3:
                        break
                    continue
                if fence_count < 1:
                    continue
                m = CONFIG_LINE.match(stripped)
                if not m:
                    continue
                key = m.group(1)
                field_name = CONFIG_KEYS.get(key)
                if field_name is None:
                    continue
                values[field_name] = _clean_value(m.group(2))
    except OSError:
        pass
    return ConfigVars(**values)


# ---------------------------------------------------------------------------
# YAML scalar readers (re-based — no PyYAML dep).
# ---------------------------------------------------------------------------


def read_yaml_value(yaml_file: Path, key: str) -> str:
    """Top-level scalar read: `<key>: value` (with optional surrounding
    quotes + trailing comment). Mirrors the awk-based helper in bash.
    """
    pattern = re.compile(
        r'^' + re.escape(key) + r':[ \t]*(.*?)(?:[ \t]+#.*)?$'
    )
    try:
        with yaml_file.open("r", encoding="utf-8") as fh:
            for line in fh:
                m = pattern.match(line.rstrip("\n"))
                if m:
                    val = m.group(1).strip()
                    if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                        val = val[1:-1]
                    return val
    except OSError:
        pass
    return ""


# Helmfile chart-pin hoist (in .gotmpl templates):
#   {{- $chartVersion := "X.Y.Z" -}}
HELMFILE_HOIST_PIN = re.compile(
    r'\$chartVersion[ \t]*:=[ \t]+"([^"]+)"'
)
# Helmfile release-level `  version: X.Y.Z` (indented). Mirrors the
# awk filter that skips lines containing `{{` (templated values).
HELMFILE_RELEASE_PIN = re.compile(r'^[ \t]+version:[ \t]+(.+)$')


def read_helmfile_chart_pin(component_dir: Path) -> str:
    """Read the OCI chart pin from helmfile.yaml.gotmpl preferred, else .yaml.

    For .gotmpl files the `$chartVersion := "X"` hoist is preferred — falls
    back to the first indented release-level `version:` line (skipping
    templated values that still contain `{{`).
    """
    gotmpl = component_dir / "helmfile.yaml.gotmpl"
    yaml = component_dir / "helmfile.yaml"
    if gotmpl.is_file():
        target = gotmpl
    elif yaml.is_file():
        target = yaml
    else:
        return ""
    try:
        with target.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                m = HELMFILE_HOIST_PIN.search(line)
                if m:
                    return m.group(1)
                m = HELMFILE_RELEASE_PIN.match(line)
                if m:
                    val = m.group(1).strip().strip('"').strip("'")
                    # Skip trailing comment after the value.
                    if " #" in val:
                        val = val[: val.index(" #")].strip()
                    if "{{" in val:
                        continue
                    return val
    except OSError:
        pass
    return ""


# ---------------------------------------------------------------------------
# Upstream fetchers.
# ---------------------------------------------------------------------------


def fetch_latest_helm_repo(chart: str) -> str:
    """`helm search repo <chart> --output json` → first version, or ""."""
    if not chart:
        return ""
    result = subprocess.run(
        ["helm", "search", "repo", chart, "--output", "json"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return ""
    try:
        rows = json.loads(result.stdout)
    except json.JSONDecodeError:
        return ""
    if not rows:
        return ""
    return str(rows[0].get("version", ""))


# Tag-shape filter for git-tags: optional `v` prefix + semver triplet.
GIT_TAG_SEMVER = re.compile(r"^v?(\d+\.\d+\.\d+)$")


def fetch_latest_git_tags(repo: str) -> str:
    """`git ls-remote --tags --refs --sort='-v:refname' <repo>` → newest
    semver triplet (with `v` prefix dropped), or "".
    """
    if not repo:
        return ""
    result = subprocess.run(
        ["git", "ls-remote", "--tags", "--refs", "--sort=-v:refname", repo],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        return ""
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        ref = parts[1].removeprefix("refs/tags/")
        m = GIT_TAG_SEMVER.match(ref)
        if m:
            return m.group(1)
    return ""


# User-Agent for upstream metadata calls. GitHub API requires a User-Agent
# and rate-limits the generic urllib default more aggressively. Match the
# bash script's effective curl identity so per-IP/UA buckets match.
HTTP_USER_AGENT = "kuberntes-infra-check-versions/1.0"


def _http_get_json(url: str) -> object | None:
    """GET <url>, parse body as JSON. Returns None on any failure.

    No bearer auth; the bash version's `curl -sSfL` likewise was anonymous.
    A stable User-Agent is sent so GitHub's anonymous rate-limit bucket is
    keyed consistently with the bash version's curl traffic.
    """
    req = urllib.request.Request(url, headers={"User-Agent": HTTP_USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            body = resp.read()
    except (urllib.error.URLError, TimeoutError, OSError):
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return None


def _semver_sort_desc(versions: list[str]) -> list[str]:
    """Descending numeric sort by (major, minor, patch) triplet."""
    def key(v: str) -> tuple[int, int, int]:
        try:
            return tuple(int(p) for p in v.split("."))  # type: ignore[return-value]
        except ValueError:
            return (-1, -1, -1)
    return sorted(versions, key=key, reverse=True)


def fetch_ga_versions_source(
    source: str, major_pin: str, source_arg: str = "", tag_prefix: str = "",
) -> list[str]:
    """Return the descending GA-version list for a version-source backend.

    Three backends supported (parity with bash):
      elastic-artifacts → https://artifacts-api.elastic.co/v1/versions
      github-releases   → GitHub Releases API (per_page=100, skip pre/draft)
      docker-hub-tags   → Docker Hub tags API (page_size=100, ordering=last_updated)
    """
    versions: list[str] = []
    if source == "elastic-artifacts":
        data = _http_get_json("https://artifacts-api.elastic.co/v1/versions")
        if not isinstance(data, dict):
            return []
        raw = data.get("versions", []) or []
        versions = [v for v in raw if isinstance(v, str) and SEMVER_TRIPLET.match(v)]
    elif source == "github-releases":
        if not source_arg:
            return []
        url = f"https://api.github.com/repos/{source_arg}/releases?per_page=100"
        data = _http_get_json(url)
        if not isinstance(data, list):
            return []
        tags = [
            r.get("tag_name", "") for r in data
            if isinstance(r, dict) and not r.get("prerelease") and not r.get("draft")
        ]
        # Tag prefix policy: when a non-`v` prefix is set, strip it explicitly;
        # when unset or `v`, strip a leading `v` defensively.
        prefix = tag_prefix.strip()
        if prefix and prefix != "v":
            stripped = [t[len(prefix):] for t in tags if t.startswith(prefix)]
        else:
            stripped = [re.sub(r"^v", "", t) for t in tags]
        versions = [t for t in stripped if SEMVER_TRIPLET.match(t)]
    elif source == "docker-hub-tags":
        if not source_arg:
            return []
        url = (
            f"https://hub.docker.com/v2/repositories/{source_arg}"
            "/tags?page_size=100&ordering=last_updated"
        )
        data = _http_get_json(url)
        if not isinstance(data, dict):
            return []
        raw = [t.get("name", "") for t in data.get("results", []) or []]
        stripped = [re.sub(r"^v", "", t) for t in raw]
        versions = [t for t in stripped if SEMVER_TRIPLET.match(t)]
    else:
        return []

    major = major_pin.strip()
    if major:
        versions = [v for v in versions if v.startswith(major + ".")]
    return _semver_sort_desc(versions)


def fetch_latest_version_source(
    source: str, major_pin: str, source_arg: str = "", tag_prefix: str = "",
) -> str:
    """Top of the descending GA list, or "".
    """
    versions = fetch_ga_versions_source(source, major_pin, source_arg, tag_prefix)
    return versions[0] if versions else ""


# OCI chart-pin release tag shape: `<chart-name>-X.Y.Z` (bash's
# fetch_latest_chart_version_gh).
def fetch_latest_chart_version_gh(repo: str, name: str) -> str:
    if not repo or not name:
        return ""
    url = f"https://api.github.com/repos/{repo}/releases?per_page=100"
    data = _http_get_json(url)
    if not isinstance(data, list):
        return ""
    prefix = f"{name}-"
    versions: list[str] = []
    for r in data:
        if not isinstance(r, dict):
            continue
        if r.get("prerelease") or r.get("draft"):
            continue
        tag = r.get("tag_name", "") or ""
        if not tag.startswith(prefix):
            continue
        candidate = tag[len(prefix):]
        if SEMVER_TRIPLET.match(candidate):
            versions.append(candidate)
    versions = _semver_sort_desc(versions)
    return versions[0] if versions else ""


# ---------------------------------------------------------------------------
# Container image existence probe (Docker Registry HTTP API v2 + bearer).
# ---------------------------------------------------------------------------

_WWW_AUTH_REALM = re.compile(r'realm="([^"]*)"')
_WWW_AUTH_SERVICE = re.compile(r'service="([^"]*)"')
_WWW_AUTH_SCOPE = re.compile(r'scope="([^"]*)"')


def _registry_token(www_auth: str) -> str:
    """Parse a `WWW-Authenticate: Bearer realm=...,service=...,scope=...`
    header and exchange it for an anonymous read token.
    """
    realm_m = _WWW_AUTH_REALM.search(www_auth)
    service_m = _WWW_AUTH_SERVICE.search(www_auth)
    scope_m = _WWW_AUTH_SCOPE.search(www_auth)
    if not realm_m:
        return ""
    realm = realm_m.group(1)
    params = {}
    if service_m:
        params["service"] = service_m.group(1)
    if scope_m:
        params["scope"] = scope_m.group(1)
    url = realm
    if params:
        url = f"{realm}?{urllib.parse.urlencode(params)}"
    body = _http_get_json(url)
    if not isinstance(body, dict):
        return ""
    return str(body.get("token", ""))


def verify_image_exists(image: str, tag: str) -> bool:
    """True when `<image>:<tag>` resolves to a manifest in its registry.

    Two-pass flow mirrors the bash helper:
      1. HEAD the manifest URL anonymously.
      2. If the registry returns 401 with `WWW-Authenticate: Bearer ...`,
         fetch the token and retry with `Authorization: Bearer <token>`.
    Empty image or tag short-circuits to True (mirrors bash).
    """
    if not image or not tag:
        return True
    registry, _, repo = image.partition("/")
    manifest_url = f"https://{registry}/v2/{repo}/manifests/{tag}"
    accept = "application/vnd.docker.distribution.manifest.v2+json"

    # Pass 1 — anonymous HEAD (matches bash `curl -I`). Most registries
    # answer HEAD with the same auth challenge / status as GET but skip the
    # manifest body, saving bandwidth.
    req = urllib.request.Request(
        manifest_url, method="HEAD", headers={"Accept": accept},
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return 200 <= resp.status < 300
    except urllib.error.HTTPError as e:
        if e.code != 401:
            return False
        www_auth = e.headers.get("WWW-Authenticate", "") if e.headers else ""
        token = _registry_token(www_auth)
        if not token:
            return False
        req2 = urllib.request.Request(
            manifest_url,
            method="HEAD",
            headers={
                "Accept": accept,
                "Authorization": f"Bearer {token}",
            },
        )
        try:
            with urllib.request.urlopen(req2, timeout=HTTP_TIMEOUT) as resp:
                return 200 <= resp.status < 300
        except (urllib.error.URLError, TimeoutError, OSError):
            return False
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def find_latest_available_source(
    source: str, major_pin: str, image: str,
    source_arg: str = "", tag_prefix: str = "",
) -> str:
    """Walk the descending GA list, returning the newest version that has
    a published image. Caps at IMAGE_PROBE_MAX_ATTEMPTS so a regression at
    upstream doesn't make the script hang.
    """
    versions = fetch_ga_versions_source(source, major_pin, source_arg, tag_prefix)
    for i, v in enumerate(versions, start=1):
        if i > IMAGE_PROBE_MAX_ATTEMPTS:
            break
        if verify_image_exists(image, v):
            return v
    return ""


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
            chart_current = read_helmfile_chart_pin(chart_dir)
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
# Phase 3
# ---------------------------------------------------------------------------


@dataclass
class RowResult:
    status: str
    current: str
    latest: str
    err: str = ""


def resolve_row(row: Row, helm_installed: bool) -> RowResult:
    """Query the appropriate upstream + classify the row's status."""
    latest = ""
    err = ""
    if row.fetcher == "helm-repo":
        if not helm_installed:
            err = "helm not installed"
        elif not row.fetcher_arg:
            err = "HELM_CHART empty in CONFIG"
        else:
            latest = fetch_latest_helm_repo(row.fetcher_arg)
            if not latest:
                err = f"helm search repo '{row.fetcher_arg}' returned nothing"
    elif row.fetcher == "git-tags":
        if not _which("git"):
            err = "git not installed"
        else:
            latest = fetch_latest_git_tags(row.fetcher_arg)
            if not latest:
                err = (
                    f"git ls-remote --tags '{row.fetcher_arg}' returned no semver"
                )
    elif row.fetcher == "version-source":
        if not row.fetcher_arg:
            err = "VERSION_SOURCE empty in CONFIG"
        else:
            latest = fetch_latest_version_source(
                row.fetcher_arg, row.extra_arg,
                row.version_source_arg, row.tag_prefix,
            )
            if not latest:
                err = (
                    f"version-source '{row.fetcher_arg}' failed or unsupported"
                )
    else:
        err = f"unknown template '{row.template}'"

    current = row.current
    if err:
        return RowResult(status="ERROR", current=current or EMPTY_SENTINEL,
                         latest=latest or EMPTY_SENTINEL, err=err)
    if not current:
        return RowResult(
            status="ERROR", current=EMPTY_SENTINEL, latest=latest or EMPTY_SENTINEL,
            err="could not read current version",
        )
    if current == latest:
        return RowResult(status="OK", current=current, latest=latest)

    # Verify the image is actually published before reporting UPDATE.
    if row.container_image and not verify_image_exists(row.container_image, latest):
        available = find_latest_available_source(
            row.fetcher_arg, row.extra_arg, row.container_image,
            row.version_source_arg, row.tag_prefix,
        )
        if available and available != current:
            return RowResult(
                status="NO_IMG", current=current,
                latest=f"{latest} (→{available})",
                err=(
                    f"{latest} image missing; latest available: {available} "
                    f"(use --version {available})"
                ),
            )
        return RowResult(
            status="NO_IMG", current=current, latest=latest,
            err=(
                f"image {row.container_image}:{latest} not found; "
                f"no older published image found"
            ),
        )
    return RowResult(status="UPDATE", current=current, latest=latest)


def resolve_chart_row(row: ChartRow) -> RowResult:
    latest = ""
    err = ""
    if row.source_type == "github-releases":
        if not row.source_repo or not row.name:
            err = "CHART_SOURCE_REPO or CHART_NAME empty"
        else:
            latest = fetch_latest_chart_version_gh(row.source_repo, row.name)
            if not latest:
                err = (
                    f"no matching '{row.name}-X.Y.Z' release in {row.source_repo}"
                )
    else:
        err = f"unsupported CHART_SOURCE_TYPE '{row.source_type}'"

    current = row.current
    if err:
        return RowResult(status="ERROR", current=current or EMPTY_SENTINEL,
                         latest=latest or EMPTY_SENTINEL, err=err)
    if not current:
        return RowResult(
            status="ERROR", current=EMPTY_SENTINEL, latest=latest or EMPTY_SENTINEL,
            err="could not read chart pin from helmfile (yaml or gotmpl)",
        )
    if current == latest:
        return RowResult(status="OK", current=current, latest=latest)
    return RowResult(status="UPDATE", current=current, latest=latest)


def _which(cmd: str) -> bool:
    """True when `cmd` resolves on PATH. Thin wrapper around `shutil.which`
    so tests can `mock.patch.object(cv, "_which", ...)` without touching the
    real $PATH."""
    return shutil.which(cmd) is not None


# ---------------------------------------------------------------------------
# Output / orchestration.
# ---------------------------------------------------------------------------


def print_main_table(
    rows: list[Row], helm_installed: bool, updates_only: bool,
) -> tuple[int, int, int, int]:
    """Print the Phase 3 status table. Returns (ok, update, error, no_image)."""
    print("")
    print(HEADER_ROW)
    print(HEADER_RULE)
    ok_count = 0
    update_count = 0
    error_count = 0
    no_image_count = 0
    for row in rows:
        result = resolve_row(row, helm_installed)
        if result.status == "OK":
            ok_count += 1
        elif result.status == "UPDATE":
            update_count += 1
        elif result.status == "NO_IMG":
            no_image_count += 1
        else:
            error_count += 1
        if updates_only and result.status == "OK":
            continue
        print(ROW_FMT.format(
            status=result.status,
            template=row.template,
            current=result.current or EMPTY_SENTINEL,
            latest=result.latest or EMPTY_SENTINEL,
            path=row.rel,
        ))
        if result.err:
            print(f"           -> {result.err}")
    return ok_count, update_count, error_count, no_image_count


def print_chart_table(
    chart_rows: list[ChartRow], updates_only: bool,
) -> tuple[int, int, int]:
    """Print the Phase 4 OCI chart-pin table. Returns (ok, update, error)."""
    print("")
    print("OCI chart pin status (external-oci-cr-version consumers):")
    print("")
    print(CHART_HEADER_ROW)
    print(CHART_HEADER_RULE)
    ok = 0
    update = 0
    error = 0
    for row in chart_rows:
        result = resolve_chart_row(row)
        if result.status == "OK":
            ok += 1
        elif result.status == "UPDATE":
            update += 1
        else:
            error += 1
        if updates_only and result.status == "OK":
            continue
        print(CHART_ROW_FMT.format(
            status=result.status,
            name=row.name or EMPTY_SENTINEL,
            current=result.current or EMPTY_SENTINEL,
            latest=result.latest or EMPTY_SENTINEL,
            path=row.rel,
        ))
        if result.err:
            print(f"           -> {result.err}")
    return ok, update, error


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

    print("Collecting managed upgrade.sh configs...")
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
            "Upgrades are available. Run 'cd <path> && ./upgrade.sh --dry-run' "
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
            print("  ./upgrade.sh --check-chart              # details")
            print("  ./upgrade.sh --upgrade-chart --dry-run  # preview + render diff")
            print("  ./upgrade.sh --upgrade-chart            # apply")
        if chart_error > 0:
            any_error = True

    return 1 if any_error else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
