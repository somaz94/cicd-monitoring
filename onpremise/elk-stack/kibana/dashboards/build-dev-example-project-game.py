#!/usr/bin/env python3
"""Reproducible builder for "Dev ExampleProject Game — User Metrics" dashboard.

The script is state-driven: identifiers (lens / dashboard / cohort data view
UUIDs) are auto-allocated on first run and cached in `dev-example-project-game.state.json`
so subsequent runs are idempotent. **You do not need to know any UUIDs.**

To add a new metric: append an entry to the `METRICS` list below. The build
script will allocate a fresh UUID on the next run, write it to the state file,
and create the Lens.

Usage:
    ./build-dev-example-project-game.py                # build (overwrite=true)
    ./build-dev-example-project-game.py --dry-run      # show what would be done
    ./build-dev-example-project-game.py --no-overwrite # fail if any object already exists

After building, run ./export.sh to capture the new state into NDJSON.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).parent
STATE_PATH = SCRIPT_DIR / "dev-example-project-game.state.json"

# ---------------------------------------------------------------------------
# Metric
# ---------------------------------------------------------------------------
DASHBOARD_TITLE       = "Dev ExampleProject Game — User Metrics"
DASHBOARD_DESCRIPTION = "DAU / NU / WAU / MAU + Retention (D-1, D-7) for dev-example-project-game. Default time range: last 90 days."
TIME_FROM             = "now-90d/d"
TIME_TO               = "now"
KIBANA_VERSION        = "9.3.3"   # used in panelsJSON entries

# Raw data view: pre-existing (ECK migration Phase 0). We only reference it.
DATA_VIEW_RAW_FIELDS = {
    "title": "dev-example-project-game",
    "name":  "dev-example-project-game-logs",
    "time_field": "@timestamp",
}
# Cohort data view: owned by us, ensured on each build.
DATA_VIEW_COHORT_FIELDS = {
    "title": "dev-example-project-game-user-cohort",
    "name":  "dev-example-project-game-user-cohort-logs",
    "time_field": "first_seen",
}

# Each metric becomes one Lens + one panel.
METRICS: list[dict[str, Any]] = [
    {
        "key": "DAU",
        "title": "DAU — dev-example-project-game",
        "description": "Daily Active Users — unique data.userId per day.",
        "data_view": "raw",
        "kind": "simple",
        "source_field": "data.userId",
        "op": "unique_count",
        "interval": "1d",
        "y_label": "Daily active users (unique data.userId)",
        "panel_title": "DAU — Daily Active Users",
        "grid": {"x": 0,  "y": 0,  "w": 24, "h": 15},
    },
    {
        "key": "NU",
        "title": "NU — dev-example-project-game",
        "description": "New Users — unique data.accountId per day on /users/create.",
        "data_view": "raw",
        "kind": "simple",
        "source_field": "data.accountId",
        "op": "unique_count",
        "interval": "1d",
        "kql_filter": 'data.requestPath : "/users/create"',
        "y_label": "New users (unique data.accountId)",
        "panel_title": "NU — New Users (/users/create)",
        "grid": {"x": 24, "y": 0,  "w": 24, "h": 15},
    },
    {
        "key": "WAU",
        "title": "WAU — dev-example-project-game",
        "description": "Weekly Active Users — unique data.userId per ISO week.",
        "data_view": "raw",
        "kind": "simple",
        "source_field": "data.userId",
        "op": "unique_count",
        "interval": "1w",
        "y_label": "Weekly active users (unique data.userId)",
        "panel_title": "WAU — Weekly Active Users",
        "grid": {"x": 0,  "y": 15, "w": 24, "h": 15},
    },
    {
        "key": "MAU",
        "title": "MAU — dev-example-project-game",
        "description": "Monthly Active Users — unique data.userId per calendar month.",
        "data_view": "raw",
        "kind": "simple",
        "source_field": "data.userId",
        "op": "unique_count",
        "interval": "1M",
        "y_label": "Monthly active users (unique data.userId)",
        "panel_title": "MAU — Monthly Active Users",
        "grid": {"x": 24, "y": 15, "w": 24, "h": 15},
    },
    {
        "key": "RET",
        "title": "Retention — dev-example-project-game",
        "description": "Cohort by signup day (first_seen): new users, D-1 returning, D-7 returning (absolute counts). Source: dev-example-project-game-user-cohort (transform).",
        "data_view": "cohort",
        "kind": "retention",   # special multi-series builder (raw counts)
        "panel_title": "Retention — Cohort size + D-1 / D-7 (counts)",
        "grid": {"x": 0, "y": 30, "w": 24, "h": 18},
    },
    {
        "key": "RET_PCT",
        "title": "Retention Rate — dev-example-project-game",
        "description": "Cohort by signup day (first_seen): D-1 retention rate %, D-7 retention rate %. Same cohort index as Retention. Use Y-axis to read percentages directly without dividing in your head.",
        "data_view": "cohort",
        "kind": "retention_rate",   # formula-based multi-series builder
        "panel_title": "Retention Rate — D-1 / D-7 (%)",
        "grid": {"x": 24, "y": 30, "w": 24, "h": 18},
    },
]


# ---------------------------------------------------------------------------
# Cluster connection (override via env if needed)
# ---------------------------------------------------------------------------
NAMESPACE     = os.environ.get("NAMESPACE", "logging")
ES_POD        = os.environ.get("ES_POD", "elasticsearch-es-default-0")
ES_CONTAINER  = os.environ.get("ES_CONTAINER", "elasticsearch")
KIBANA_SVC    = os.environ.get("KIBANA_SVC", f"kibana-kb-http.{NAMESPACE}.svc")
KIBANA_PORT   = os.environ.get("KIBANA_PORT", "5601")
KIBANA_SCHEME = os.environ.get("KIBANA_SCHEME", "http")
ES_SECRET     = os.environ.get("ES_SECRET", "elasticsearch-es-elastic-user")
ES_USER       = os.environ.get("ES_USER", "elastic")

KIBANA_URL = f"{KIBANA_SCHEME}://{KIBANA_SVC}:{KIBANA_PORT}"


# ---------------------------------------------------------------------------
# State file management — auto-allocate UUIDs and persist
# ---------------------------------------------------------------------------
def _empty_state() -> dict[str, Any]:
    return {
        "_comment": "Auto-managed by build-dev-example-project-game.py. Do not hand-edit unless you know what you're doing — the build script will preserve any existing IDs and only fill in missing ones.",
        "dashboard": {},
        "data_views": {},
        "lenses": {},
    }


def load_state() -> dict[str, Any]:
    if STATE_PATH.exists():
        return json.loads(STATE_PATH.read_text())
    return _empty_state()


def save_state(state: dict[str, Any], dry: bool) -> None:
    if dry:
        print(f"  (dry-run) would write state file → {STATE_PATH.name}")
        return
    STATE_PATH.write_text(json.dumps(state, indent=2) + "\n")


def ensure_state(state: dict[str, Any]) -> bool:
    """Fill in any missing UUIDs; returns True if state was mutated."""
    changed = False

    # Dashboard
    if not state.get("dashboard", {}).get("id"):
        state.setdefault("dashboard", {})
        state["dashboard"]["id"] = str(uuid.uuid4())
        state["dashboard"]["title"] = DASHBOARD_TITLE
        changed = True
    elif state["dashboard"].get("title") != DASHBOARD_TITLE:
        # Keep ID, update title to match current code
        state["dashboard"]["title"] = DASHBOARD_TITLE
        changed = True

    # Data views
    state.setdefault("data_views", {})

    if "raw" not in state["data_views"]:
        # Raw view must already exist in Kibana (pre-imported); we just need its
        # ID. If the state file doesn't have it, the user has to provide it.
        raise SystemExit(
            "ERROR: data_views.raw.id is missing in state file. The raw data view "
            "(dev-example-project-game-logs) must be pre-existing in Kibana — find its ID "
            "via `GET /api/data_views` and add it to dev-example-project-game.state.json."
        )

    if "cohort" not in state["data_views"]:
        state["data_views"]["cohort"] = {
            "id": str(uuid.uuid4()),
            **DATA_VIEW_COHORT_FIELDS,
            "managed_by_us": True,
        }
        changed = True

    # Lenses — one ID per METRICS entry
    state.setdefault("lenses", {})
    for m in METRICS:
        if m["key"] not in state["lenses"]:
            state["lenses"][m["key"]] = str(uuid.uuid4())
            changed = True

    # Prune lenses no longer in METRICS (safety: warn but don't delete)
    metric_keys = {m["key"] for m in METRICS}
    orphan = [k for k in state["lenses"] if k not in metric_keys]
    if orphan:
        print(f"  ! orphan lens IDs in state (not in METRICS, kept as-is): {orphan}")

    return changed


# ---------------------------------------------------------------------------
# Payload builders
# ---------------------------------------------------------------------------
def _default_xy_viz(accessors: list[str], y_left_title: str) -> dict[str, Any]:
    return {
        "preferredSeriesType": "line",
        "legend": {"isVisible": True, "position": "right"},
        "valueLabels": "hide",
        "fittingFunction": "None",
        "axisTitlesVisibilitySettings": {"x": True, "yLeft": True, "yRight": True},
        "yTitle": y_left_title,
        "tickLabelsVisibilitySettings": {"x": True, "yLeft": True, "yRight": True},
        "labelsOrientation": {"x": 0, "yLeft": 0, "yRight": 0},
        "gridlinesVisibilitySettings": {"x": True, "yLeft": True, "yRight": True},
        "layers": [{
            "layerId": "layer1",
            "accessors": accessors,
            "position": "top",
            "seriesType": "line",
            "showGridlines": False,
            "layerType": "data",
            "xAccessor": "col_x",
        }],
    }


def build_simple_lens(metric: dict[str, Any], data_view_id: str) -> dict[str, Any]:
    interval = metric["interval"]
    layer = {
        "columnOrder": ["col_x", "col_y"],
        "columns": {
            "col_x": {
                "label": f"@timestamp per {interval}",
                "customLabel": True,
                "dataType": "date",
                "operationType": "date_histogram",
                "sourceField": "@timestamp",
                "isBucketed": True,
                "scale": "interval",
                "params": {"interval": interval, "includeEmptyRows": True, "dropPartials": False},
            },
            "col_y": {
                "label": metric["y_label"],
                "customLabel": True,
                "dataType": "number",
                "operationType": metric["op"],
                "sourceField": metric["source_field"],
                "isBucketed": False,
                "scale": "ratio",
            },
        },
        "incompleteColumns": {},
        "sampling": 1,
    }
    return {
        "attributes": {
            "title": metric["title"],
            "description": metric["description"],
            "visualizationType": "lnsXY",
            "state": {
                "datasourceStates": {
                    "formBased": {"layers": {"layer1": layer}},
                    "indexpattern": {"layers": {}},
                    "textBased": {"layers": {}},
                },
                "visualization": _default_xy_viz(["col_y"], metric["y_label"]),
                "query": {"query": metric.get("kql_filter") or "", "language": "kuery"},
                "filters": [],
            },
        },
        "references": [
            {"id": data_view_id, "name": "indexpattern-datasource-layer-layer1", "type": "index-pattern"},
        ],
    }


def build_retention_lens(metric: dict[str, Any], data_view_id: str) -> dict[str, Any]:
    """Multi-series XY for Retention: cohort size + D-1 + D-7."""
    layer = {
        "columnOrder": ["col_x", "col_new", "col_d1", "col_d7"],
        "columns": {
            "col_x": {
                "label": "Signup day (first_seen, 1d)",
                "customLabel": True,
                "dataType": "date",
                "operationType": "date_histogram",
                "sourceField": "first_seen",
                "isBucketed": True,
                "scale": "interval",
                "params": {"interval": "1d", "includeEmptyRows": True, "dropPartials": False},
            },
            "col_new": {
                "label": "New users in cohort",
                "customLabel": True,
                "dataType": "number",
                "operationType": "count",
                "sourceField": "___records___",
                "isBucketed": False,
                "scale": "ratio",
            },
            "col_d1": {
                "label": "D-1 returning (next-day retention)",
                "customLabel": True,
                "dataType": "number",
                "operationType": "sum",
                "sourceField": "d1_returning",
                "isBucketed": False,
                "scale": "ratio",
            },
            "col_d7": {
                "label": "D-7 returning (week-later retention)",
                "customLabel": True,
                "dataType": "number",
                "operationType": "sum",
                "sourceField": "d7_returning",
                "isBucketed": False,
                "scale": "ratio",
            },
        },
        "incompleteColumns": {},
        "sampling": 1,
    }
    return {
        "attributes": {
            "title": metric["title"],
            "description": metric["description"],
            "visualizationType": "lnsXY",
            "state": {
                "datasourceStates": {
                    "formBased": {"layers": {"layer1": layer}},
                    "indexpattern": {"layers": {}},
                    "textBased": {"layers": {}},
                },
                "visualization": _default_xy_viz(["col_new", "col_d1", "col_d7"], "Users"),
                "query": {"query": "", "language": "kuery"},
                "filters": [],
            },
        },
        "references": [
            {"id": data_view_id, "name": "indexpattern-datasource-layer-layer1", "type": "index-pattern"},
        ],
    }


def build_retention_rate_lens(metric: dict[str, Any], data_view_id: str) -> dict[str, Any]:
    """Lens with D-1% and D-7% retention rate lines, computed via Lens formula.

    Each percent column is a `formula` operation that references two auxiliary
    columns (sum + count). The auxiliary columns must appear in `columnOrder`
    before the formula column they support.
    """
    percent_format = {"id": "number", "params": {"decimals": 1, "suffix": "%"}}

    layer = {
        "columnOrder": [
            "col_x",
            "col_d1pct_X0", "col_d1pct_X1", "col_d1pct",
            "col_d7pct_X0", "col_d7pct_X1", "col_d7pct",
        ],
        "columns": {
            "col_x": {
                "label": "Signup day (first_seen, 1d)",
                "customLabel": True,
                "dataType": "date",
                "operationType": "date_histogram",
                "sourceField": "first_seen",
                "isBucketed": True,
                "scale": "interval",
                "params": {"interval": "1d", "includeEmptyRows": True, "dropPartials": False},
            },
            # D-1 % = sum(d1_returning) / count() * 100
            "col_d1pct_X0": {
                "label": "Part of D-1 retention rate (%)",
                "dataType": "number",
                "operationType": "sum",
                "sourceField": "d1_returning",
                "isBucketed": False,
                "scale": "ratio",
                "customLabel": True,
            },
            "col_d1pct_X1": {
                "label": "Part of D-1 retention rate (%)",
                "dataType": "number",
                "operationType": "count",
                "sourceField": "___records___",
                "isBucketed": False,
                "scale": "ratio",
                "customLabel": True,
            },
            "col_d1pct": {
                "label": "D-1 retention rate (%)",
                "customLabel": True,
                "dataType": "number",
                "operationType": "formula",
                "isBucketed": False,
                "scale": "ratio",
                "params": {
                    "formula": "sum(d1_returning) / count() * 100",
                    "isFormulaBroken": False,
                    "format": percent_format,
                },
                "references": ["col_d1pct_X0", "col_d1pct_X1"],
            },
            # D-7 % = sum(d7_returning) / count() * 100
            "col_d7pct_X0": {
                "label": "Part of D-7 retention rate (%)",
                "dataType": "number",
                "operationType": "sum",
                "sourceField": "d7_returning",
                "isBucketed": False,
                "scale": "ratio",
                "customLabel": True,
            },
            "col_d7pct_X1": {
                "label": "Part of D-7 retention rate (%)",
                "dataType": "number",
                "operationType": "count",
                "sourceField": "___records___",
                "isBucketed": False,
                "scale": "ratio",
                "customLabel": True,
            },
            "col_d7pct": {
                "label": "D-7 retention rate (%)",
                "customLabel": True,
                "dataType": "number",
                "operationType": "formula",
                "isBucketed": False,
                "scale": "ratio",
                "params": {
                    "formula": "sum(d7_returning) / count() * 100",
                    "isFormulaBroken": False,
                    "format": percent_format,
                },
                "references": ["col_d7pct_X0", "col_d7pct_X1"],
            },
        },
        "incompleteColumns": {},
        "sampling": 1,
    }
    return {
        "attributes": {
            "title": metric["title"],
            "description": metric["description"],
            "visualizationType": "lnsXY",
            "state": {
                "datasourceStates": {
                    "formBased": {"layers": {"layer1": layer}},
                    "indexpattern": {"layers": {}},
                    "textBased": {"layers": {}},
                },
                "visualization": _default_xy_viz(["col_d1pct", "col_d7pct"], "Retention rate (%)"),
                "query": {"query": "", "language": "kuery"},
                "filters": [],
            },
        },
        "references": [
            {"id": data_view_id, "name": "indexpattern-datasource-layer-layer1", "type": "index-pattern"},
        ],
    }


def build_dashboard_payload(state: dict[str, Any]) -> dict[str, Any]:
    panels = []
    references = []
    for m in METRICS:
        lens_id = state["lenses"][m["key"]]
        panel_index = f"panel-{m['key'].lower()}-{state['dashboard']['id'][:8]}"
        panels.append({
            "version": KIBANA_VERSION,
            "type": "lens",
            "gridData": {**m["grid"], "i": panel_index},
            "panelIndex": panel_index,
            "embeddableConfig": {"enhancements": {}},
            "panelRefName": f"panel_{panel_index}",
            "title": m["panel_title"],
        })
        references.append({
            "id": lens_id,
            "name": f"{panel_index}:panel_{panel_index}",
            "type": "lens",
        })

    return {
        "attributes": {
            "title": DASHBOARD_TITLE,
            "description": DASHBOARD_DESCRIPTION,
            "panelsJSON": json.dumps(panels),
            "optionsJSON": json.dumps({
                "useMargins": True, "syncColors": False, "syncCursor": True,
                "syncTooltips": False, "hidePanelTitles": False,
            }),
            "timeRestore": True,
            "timeFrom": TIME_FROM,
            "timeTo": TIME_TO,
            "refreshInterval": {"pause": True, "value": 60000},
            "kibanaSavedObjectMeta": {
                "searchSourceJSON": json.dumps({"query": {"query": "", "language": "kuery"}, "filter": []}),
            },
        },
        "references": references,
    }


# ---------------------------------------------------------------------------
# HTTP via kubectl exec (no port-forward needed)
# ---------------------------------------------------------------------------
def get_password() -> str:
    res = subprocess.run(
        ["kubectl", "-n", NAMESPACE, "get", "secret", ES_SECRET,
         "-o", f"jsonpath={{.data.{ES_USER}}}"],
        capture_output=True, text=True, check=True,
    )
    return base64.b64decode(res.stdout).decode().strip()


def kibana_request(method: str, path: str, payload: dict | None, password: str) -> dict:
    cmd = [
        "kubectl", "-n", NAMESPACE, "exec", "-i", ES_POD, "-c", ES_CONTAINER, "--",
        "curl", "-s", "-u", f"{ES_USER}:{password}", "-H", "kbn-xsrf: true",
        "-H", "Content-Type: application/json", "-X", method, f"{KIBANA_URL}{path}",
    ]
    body = None
    if payload is not None:
        cmd += ["--data-binary", "@-"]
        body = json.dumps(payload)
    res = subprocess.run(cmd, input=body, capture_output=True, text=True, check=True)
    raw = res.stdout
    start = raw.find("{")
    if start < 0:
        raise RuntimeError(f"Non-JSON response: {raw[:300]}")
    return json.loads(raw[start:])


# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------
def ensure_data_view(*, id_: str, title: str, name: str, time_field: str, pw: str, dry: bool) -> None:
    print(f"  data view  id={id_}  title={title}")
    payload = {
        "data_view": {
            "id": id_, "title": title, "name": name,
            "timeFieldName": time_field, "namespaces": ["default"],
        },
        "override": True,
    }
    if dry:
        print("    (dry-run) POST /api/data_views/data_view")
        return
    resp = kibana_request("POST", "/api/data_views/data_view", payload, pw)
    if resp.get("statusCode") and resp["statusCode"] >= 400:
        raise RuntimeError(f"data view creation failed: {resp}")


def ensure_saved_object(*, kind: str, id_: str, payload: dict, overwrite: bool, pw: str, dry: bool) -> None:
    title = payload["attributes"]["title"]
    print(f"  {kind:10s} id={id_}  title={title}")
    path = f"/api/saved_objects/{kind}/{id_}"
    if overwrite:
        path += "?overwrite=true"
    if dry:
        print(f"    (dry-run) POST {path}")
        return
    resp = kibana_request("POST", path, payload, pw)
    if resp.get("statusCode") and resp["statusCode"] >= 400:
        raise RuntimeError(f"{kind} {id_} failed: {resp}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-overwrite", action="store_true",
                    help="Fail if any saved object already exists (default: overwrite=true)")
    args = ap.parse_args()

    overwrite = not args.no_overwrite
    dry = args.dry_run

    if not shutil.which("kubectl"):
        print("ERROR: kubectl not found in PATH", file=sys.stderr)
        return 2

    print(f"Building '{DASHBOARD_TITLE}'")
    print(f"  kibana    = {KIBANA_URL}")
    print(f"  namespace = {NAMESPACE}  pod = {ES_POD}")
    print(f"  overwrite = {overwrite}  dry-run = {dry}")
    print(f"  state     = {STATE_PATH.name}")
    print()

    state = load_state()
    if ensure_state(state):
        print("  state file mutated → saving")
        save_state(state, dry)
    else:
        print("  state file unchanged")
    print()

    pw = "" if dry else get_password()

    # ---------------- Step 1: cohort data view ----------------
    print("Step 1) cohort data view")
    cohort = state["data_views"]["cohort"]
    ensure_data_view(
        id_=cohort["id"],
        title=cohort["title"],
        name=cohort["name"],
        time_field=cohort["time_field"],
        pw=pw, dry=dry,
    )

    # ---------------- Step 2: Lenses ----------------
    print("\nStep 2) Lens visualizations")
    dv_raw_id    = state["data_views"]["raw"]["id"]
    dv_cohort_id = state["data_views"]["cohort"]["id"]
    for m in METRICS:
        dv_id = dv_raw_id if m["data_view"] == "raw" else dv_cohort_id
        if m["kind"] == "retention":
            payload = build_retention_lens(m, dv_id)
        elif m["kind"] == "retention_rate":
            payload = build_retention_rate_lens(m, dv_id)
        else:
            payload = build_simple_lens(m, dv_id)
        ensure_saved_object(
            kind="lens", id_=state["lenses"][m["key"]], payload=payload,
            overwrite=overwrite, pw=pw, dry=dry,
        )

    # ---------------- Step 3: Dashboard ----------------
    print("\nStep 3) Dashboard")
    ensure_saved_object(
        kind="dashboard", id_=state["dashboard"]["id"],
        payload=build_dashboard_payload(state),
        overwrite=overwrite, pw=pw, dry=dry,
    )

    print("\n✓ Done." + ("  (dry-run)" if dry else "  Run ./export.sh to refresh repo NDJSON."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
