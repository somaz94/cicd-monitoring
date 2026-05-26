#!/usr/bin/env python3
# upgrade-template: ansible-github-release

# ============================================================
# Configuration (per-component — sync-managed body below)
# ============================================================
CONFIG = {
    "SCRIPT_NAME":              "Node Exporter Ansible Upgrade Script",
    "COMPONENT_NAME":           "node_exporter",
    "GITHUB_REPO":              "prometheus/node_exporter",
    "VERSION_FILE":             "ansible/group_vars/all.yml",
    "VERSION_KEY":              "node_exporter_version",
    "ANSIBLE_DIR":              "ansible",
    "ANSIBLE_INVENTORY":        "inventory.ini",
    "ANSIBLE_UPGRADE_PLAYBOOK": "upgrade.yml",
    "CHANGELOG_URL":            "https://github.com/prometheus/node_exporter/releases",
    "MAJOR_PIN":                "",
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
