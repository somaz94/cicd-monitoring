#!/usr/bin/env python3
"""Thin entry-point wrapper for the upgrade-sync system.

Located alongside ``check-versions.py`` and the canonical ``templates/``
so that operators reach for ``scripts/upgrade-sync/sync.py`` (or, via the
canonical wrapper, ``scripts/python/run.sh sync.py``). The actual logic
lives in ``scripts/python/upgrade_sync/`` — this file just resolves the
package root via an ancestor walk and dispatches to ``cli.main``.

Same ancestor walk as every consumer upgrade.py, so the file also works
when invoked from an arbitrary cwd or via a symlink.
"""

from __future__ import annotations

import sys
from pathlib import Path


def _bootstrap_package_root() -> None:
    here = Path(__file__).resolve().parent
    # Standalone layout — the packages sit next to this script.
    if (here / "upgrade_sync").is_dir():
        sys.path.insert(0, str(here))
        return
    # Embedded layout — <repo>/scripts/upgrade-sync/ next to <repo>/scripts/python/.
    for anc in [here, *here.parents]:
        if (anc / "scripts" / "python" / "upgrade_sync").is_dir():
            sys.path.insert(0, str(anc / "scripts" / "python"))
            return
    # Last-resort fallback (development env where layout drifted).
    here_pkg = here.parent.parent / "scripts" / "python"
    if here_pkg.is_dir():
        sys.path.insert(0, str(here_pkg))


_bootstrap_package_root()

from upgrade_sync.cli import main  # noqa: E402


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], script_path=__file__))
