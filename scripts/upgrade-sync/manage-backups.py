#!/usr/bin/env python3
"""Thin entry-point wrapper for the backup-management system.

See ``scripts/python/upgrade_sync/manage_backups.py`` for the actual
implementation. This wrapper resolves the package root via an ancestor
walk (same pattern as the K6..K12 consumer upgrade.py files) so the
module is importable from any cwd.
"""

from __future__ import annotations

import sys
from pathlib import Path


def _bootstrap_package_root() -> None:
    here = Path(__file__).resolve().parent
    for anc in [here, *here.parents]:
        if (anc / "scripts" / "python" / "upgrade_sync").is_dir():
            sys.path.insert(0, str(anc / "scripts" / "python"))
            return
    here_pkg = here.parent.parent / "scripts" / "python"
    if here_pkg.is_dir():
        sys.path.insert(0, str(here_pkg))


_bootstrap_package_root()

from upgrade_sync.manage_backups import main  # noqa: E402


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], script_path=__file__))
