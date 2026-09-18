#!/usr/bin/env bash
# Derive the cst-Space variants of the cohort data views + retention dashboards
# from the default-Space (KST) originals.
#
# WHY A DERIVED COPY INSTEAD OF AN IMPORT-TIME FLAG
# -------------------------------------------------
# A cohort day boundary cannot be re-sliced at query time: the transform bakes it
# into a date STRING (active_dates) when it writes the index. A Space's
# dateFormat:tz only re-renders timestamps — it cannot re-bucket a date string
# that was already written in the other zone. So the cst Space cannot reuse the
# KST cohort objects and merely relabel them: it needs objects that read the
# Asia/Shanghai twin the transform now also precomputes (active_dates_cst — see
# ../../elasticsearch/transforms/).
#
# The two cohort panels need DIFFERENT surgery, which is why an apply.sh flag
# does not cover this:
#   * Daily Cohort Retention (lens) reads a data view  -> swap the data-view id.
#   * Average Retention Curve (Vega) has NO data view (references: []). It hits
#     the index directly and inlines its own runtime_mappings, so its painless
#     must be rewritten in place.
# Leaving either one alone makes the cst dashboard disagree with itself.
#
# The KST originals are the single source of truth. Edit those, re-run this, and
# commit both. Never hand-edit the generated files — always regenerate. --check
# fails on drift, so review catches a stale or hand-edited artifact.
#
# ONE SHARED DATA-VIEW FILE, ONE SPEC PER ENVIRONMENT
# ---------------------------------------------------
# Every on-prem environment carries a live cst Space dashboard here, so this
# generator loops over all of them. That differs from the AWS side, which
# cst-ifies prod only and leaves review single-view. All environments' cohort
# views live in ONE bootstrap file (example-project-game-data-view.ndjson), so the
# cohort view id travels in the per-environment spec rather than as a single
# override, and the emitted cst data-view file carries every rewritten cohort
# view. Adding an environment is one more SPEC_* scalar plus its argument in the
# generate() call — the Python side reads them all off argv.
#
# Substitutions (each count-reported — the zone sweep is asserted, so a leftover
# Asia/Seoul is a hard error, never a silent partial rewrite):
#   ZoneId.of('Asia/Seoul')  -> ZoneId.of('Asia/Shanghai')   cohort day boundary
#   doc['active_dates']      -> doc['active_dates_cst']       the CST twin field
#   <KST data view uuid>     -> <CST data view uuid>          lens reference + state
#   remaining Asia/Seoul     -> Asia/Shanghai                 Vega ES "time_zone"
#   id / references[].id     -> cst-<id>                      single-namespace slugs
set -euo pipefail

[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch

DASHBOARDS_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$DASHBOARDS_DIR/cst}"
# Every environment's cohort view ships in this one bootstrap file, which is the
# authority on which views exist. Its raw-index siblings are timezone-agnostic
# and are left alone.
SRC_DATA_VIEW="${SRC_DATA_VIEW:-$DASHBOARDS_DIR/example-project-game-data-view.ndjson}"
ID_PREFIX="${ID_PREFIX:-cst-}"
# Per-environment spec: NAME:COHORT_DATA_VIEW_ID:DASHBOARD_FILE
# Kept as separate scalars rather than an array so the script stays runnable
# under a zsh interpreter without the re-exec dance apply.sh needs.
SPEC_DEV="${SPEC_DEV:-dev:410571c2-5b86-4ba9-a02e-418671d0b8e2:dev-pm-retention-dashboard.ndjson}"
SPEC_QA="${SPEC_QA:-qa:fb7b645e-78ff-4da7-b231-ec2c4165cf98:qa-pm-retention-dashboard.ndjson}"
SPEC_DEV2="${SPEC_DEV2:-dev2:3f6c1a84-9d27-4e05-b1c8-7a0e5d24bb93:dev2-pm-retention-dashboard.ndjson}"

if [ -t 1 ]; then
  C_OK="\033[32m"; C_ERR="\033[31m"; C_RST="\033[0m"
else
  C_OK=""; C_ERR=""; C_RST=""
fi
log() { printf "%b\n" "$*"; }
ok()  { log "${C_OK}✓${C_RST} $*"; }
err() { log "${C_ERR}✗${C_RST} $*" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check]

Regenerates the cst-Space variants into $(basename "$OUT_DIR")/ .
They live in a subdirectory on purpose: apply.sh auto-discovers *.ndjson in this
directory only (non-recursive), so a cst variant sitting here would also be
imported into the default Space.

  --check   Regenerate to a temp dir and diff. Exit 1 on drift.

Env overrides:
  OUT_DIR=$OUT_DIR
  SRC_DATA_VIEW=$SRC_DATA_VIEW
  ID_PREFIX=$ID_PREFIX
  SPEC_DEV=$SPEC_DEV
  SPEC_QA=$SPEC_QA
  SPEC_DEV2=$SPEC_DEV2
EOF
}

CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   CHECK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

[ -f "$SRC_DATA_VIEW" ] || { err "missing source: $SRC_DATA_VIEW"; exit 1; }

# A quoted heredoc, NOT `python3 -c "..."`: the substitution patterns contain
# single quotes, and inside a single-quoted -c body the shell eats them, leaving
# patterns that match nothing at all. This generator does not read stdin.
generate() {
  local outdir="$1"
  python3 - "$SRC_DATA_VIEW" "$DASHBOARDS_DIR" "$ID_PREFIX" "$outdir" "$SPEC_DEV" "$SPEC_QA" "$SPEC_DEV2" <<'PYEOF'
import json, os, sys, uuid

src_dv_path, dash_dir, id_prefix, outdir = sys.argv[1:5]
specs = [s.split(":", 2) for s in sys.argv[5:]]
SLUG_TYPES = {"dashboard", "lens", "visualization", "search"}

ZONE_FROM, ZONE_TO = "Asia/Seoul", "Asia/Shanghai"

# Deterministic ids, so regenerating never mints a second object in the cst Space.
# Every environment's mapping goes into one substitution list applied to every
# file: a dev dashboard never contains qa's uuid, so the extra pass is a no-op
# rather than a correctness risk.
cst_dv_id = {env: str(uuid.uuid5(uuid.NAMESPACE_OID, dv_id + ":cst"))
             for env, dv_id, _ in specs}
SUBS = [
    ("ZoneId.of('" + ZONE_FROM + "')", "ZoneId.of('" + ZONE_TO + "')"),
    ("doc['active_dates']", "doc['active_dates_cst']"),
] + [(dv_id, cst_dv_id[env]) for env, dv_id, _ in specs]


def rewrite(line):
    """Apply the cohort-zone substitutions to one serialized NDJSON object.

    Operates on the serialized text on purpose: a Vega panel nests JSON twice, so
    its painless lives inside a string inside a string. JSON does not escape
    single quotes, so these patterns match at any nesting depth. The zone name
    carries no quotes either, which is why the trailing Asia/Seoul sweep (the
    Vega ES "time_zone" values) works whether escaped or not.
    """
    counts = {}
    for old, new in SUBS:
        counts[old] = line.count(old)
        line = line.replace(old, new)
    # Whatever Asia/Seoul survives the targeted passes is a Vega "time_zone".
    counts[ZONE_FROM + " (time_zone)"] = line.count(ZONE_FROM)
    line = line.replace(ZONE_FROM, ZONE_TO)
    if ZONE_FROM in line:
        sys.stderr.write("FATAL: %s still present after rewrite\n" % ZONE_FROM)
        sys.exit(1)
    return line, counts


def prefix_ids(o):
    if o.get("type") in SLUG_TYPES and isinstance(o.get("id"), str):
        o["id"] = id_prefix + o["id"]
    for r in o.get("references", []) or []:
        if r.get("type") in SLUG_TYPES and isinstance(r.get("id"), str):
            r["id"] = id_prefix + r["id"]
    return o


def dump(o):
    return json.dumps(o, separators=(",", ":"), sort_keys=True)


os.makedirs(outdir, exist_ok=True)
report = []

# ---- data view: emit ONLY the cohort views, rewritten, one line per spec. The
# raw-index views in the same bootstrap file are timezone-agnostic and are
# already shared into cst by setup-spaces.sh, so re-emitting them here would only
# fight that share.
dv_out = os.path.join(outdir, os.path.basename(src_dv_path).replace(".ndjson", "-cst.ndjson"))
src_lines = [l.strip() for l in open(src_dv_path) if l.strip()]
with open(dv_out, "w") as fh:
    for env, dv_id, _ in specs:
        match = [l for l in src_lines if json.loads(l).get("id") == dv_id]
        if not match:
            sys.stderr.write("FATAL: %s cohort data view %s not found in %s\n"
                             % (env, dv_id, src_dv_path))
            sys.exit(1)
        o = json.loads(match[0])
        new_line, c = rewrite(dump(o))
        o = json.loads(new_line)
        o["attributes"]["name"] = o["attributes"].get("name", "") + "-cst"
        fh.write(dump(o) + "\n")
        report.append(("data view (%s)" % env, c))

# ---- dashboards: every object, rewritten + id-prefixed, one file per spec.
for env, _, dash_file in specs:
    src_dash_path = os.path.join(dash_dir, dash_file)
    if not os.path.isfile(src_dash_path):
        sys.stderr.write("FATAL: missing source dashboard: %s\n" % src_dash_path)
        sys.exit(1)
    dash_out = os.path.join(outdir, os.path.basename(src_dash_path).replace(".ndjson", "-cst.ndjson"))
    agg = {}
    n = 0
    with open(dash_out, "w") as fh:
        for line in open(src_dash_path):
            line = line.strip()
            if not line:
                continue
            new_line, c = rewrite(dump(json.loads(line)))
            fh.write(dump(prefix_ids(json.loads(new_line))) + "\n")
            n += 1
            for k, v in c.items():
                agg[k] = agg.get(k, 0) + v
    report.append(("dashboard %s (%d objects)" % (env, n), agg))

for what, c in report:
    sys.stderr.write("  %s\n" % what)
    for k, v in c.items():
        if v:
            sys.stderr.write("    %-36s %d\n" % (k, v))
for env in cst_dv_id:
    sys.stderr.write("  cst data view id (%s): %s\n" % (env, cst_dv_id[env]))
PYEOF
}

if [ "$CHECK" = "1" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  generate "$tmp" 2>/dev/null
  rc=0
  for f in "$tmp"/*.ndjson; do
    base="$(basename "$f")"
    if [ ! -f "$OUT_DIR/$base" ]; then
      err "generated file missing: $OUT_DIR/$base (run without --check)"
      rc=1
      continue
    fi
    if ! diff -q "$f" "$OUT_DIR/$base" >/dev/null; then
      err "drift: $base does not match what $(basename "$0") generates"
      rc=1
    fi
  done
  [ "$rc" = "0" ] && ok "cst variants up to date"
  exit "$rc"
fi

generate "$OUT_DIR"
ok "wrote $(basename "$OUT_DIR")/ variants"
