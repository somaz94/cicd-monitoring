#!/usr/bin/env python3
# CANONICAL TEMPLATE — DO NOT RUN DIRECTLY
# Source of truth for the "ansible-github-release" upgrade.py body.
#
# Used by components deployed via Ansible (NOT Helm) that:
#   - Track versions from a GitHub Releases feed.
#   - Keep the version in a single YAML file (e.g. group_vars/all.yml).
#
# Typical shape:
#   - ansible/group_vars/all.yml (has `<COMPONENT>_version: "X.Y.Z"`)
#   - ansible/playbook.yml, upgrade.yml (reference the version var via group_vars)
#   - No Chart.yaml, no helmfile.yaml
#
# What this script does:
#   1. Reads current version from <CHART_DIR>/<VERSION_FILE>.
#   2. Queries GitHub Releases for the latest GA version (respecting MAJOR_PIN).
#   3. Diffs and, on apply, updates the version field in VERSION_FILE + backs up.
#   4. Prints next step: run ansible-playbook upgrade.yml.
#
# Real per-component upgrade.py files are kept in sync via:
#   scripts/upgrade-sync/sync.py --apply
# Only the body below the third `# ===` marker is propagated.

# ============================================================
# Configuration (per-component placeholders — replaced in real upgrade.py)
# ============================================================
CONFIG = {
    "SCRIPT_NAME":              "__SCRIPT_NAME__",
    "COMPONENT_NAME":           "__COMPONENT_NAME__",
    "GITHUB_REPO":              "__GITHUB_REPO__",
    "VERSION_FILE":             "__VERSION_FILE__",
    "VERSION_KEY":              "__VERSION_KEY__",
    "ANSIBLE_DIR":              "__ANSIBLE_DIR__",
    "ANSIBLE_INVENTORY":        "__ANSIBLE_INVENTORY__",
    "ANSIBLE_UPGRADE_PLAYBOOK": "__ANSIBLE_UPGRADE_PLAYBOOK__",
    "CHANGELOG_URL":            "__CHANGELOG_URL__",
    "MAJOR_PIN":                "__MAJOR_PIN__",
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

from upgrade_core.ansible_github_release import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(CONFIG, sys.argv[1:], script_path=__file__))
