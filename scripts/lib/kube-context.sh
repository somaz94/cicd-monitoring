# shellcheck shell=bash
# =============================================================================
# scripts/lib/kube-context.sh — mandatory kube-context gate, shared by every
# cluster-mutating script in this repo. Source this file — do not execute it.
# =============================================================================
#
# Why this exists
# ---------------
# This repo drives two clusters: the on-prem dev cluster and the AWS
# prod-example-app EKS cluster. Their logging namespaces are name-for-name
# identical — both expose `logging/elasticsearch-es-default-0`, the service
# `elasticsearch-es-http`, a Kibana behind `kibana-kb-http`, and the same
# `elasticsearch-es-elastic-user` secret. A bare `kubectl` therefore SUCCEEDS
# against whichever context happens to be current, so a command intended for one
# cluster lands on the other silently and with a zero exit code.
#
# Verified 2026-08-03: an AWS-targeted Kibana saved-objects apply ran against
# on-prem and overwrote three example-project cohort data views. `AWS_PROFILE` does not
# select a kube-context, and a clean exit is not evidence the right cluster was
# touched.
#
# Usage
# -----
#   source "<repo-root>/scripts/lib/kube-context.sh"
#   ...                     # argument loop that sets KUBE_CONTEXT from --context
#   require_kube_context    # MANDATORY, before any cluster call
#   kctl -n logging get pods
#
# The gate is enforced for --dry-run too: the operator must state the target
# cluster up front, and a dry-run whose context is only supplied on the real run
# has verified nothing.
#
# Context names are LOCAL kubeconfig aliases
# -------------------------------------------
# A context name is whatever the local kubeconfig calls it, not a property of the
# cluster: the same EKS cluster is `example-app-prod` on one machine and the raw ARN
# on another, and an alias can be renamed or repointed at any time. So callers
# must NOT hardcode a name as if it were canonical — help text should send the
# operator to `kubectl config get-contexts -o name`, and every banner should print
# kube_context_cluster() next to the name. The resolved cluster is the stable
# identifier and the thing an operator should actually read before confirming.

[ "${_KUBE_CONTEXT_LIB_SOURCED:-0}" = "1" ] && return 0
_KUBE_CONTEXT_LIB_SOURCED=1

# Target kube-context. Deliberately no default and no fallback to the current
# context — see the rationale above.
KUBE_CONTEXT="${KUBE_CONTEXT:-}"

# Optional. Callers set this to a `namespace/resource` that exists identically on
# both clusters, so the failure message names the concrete collision instead of
# talking in the abstract (e.g. KUBE_CONTEXT_HINT="logging/elasticsearch-es-default-0").
KUBE_CONTEXT_HINT="${KUBE_CONTEXT_HINT:-}"

# Self-contained stderr helper — this lib must not depend on a caller's log/err
# being defined first, since callers source it at different points. Colour only
# when stderr is a terminal, so CI logs do not collect raw escape sequences.
if [ -t 2 ]; then
  _kc_err() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
else
  _kc_err() { printf '✗ %s\n' "$*" >&2; }
fi

_kc_list_contexts() {
  _kc_err "Available contexts:"
  # `|| true` keeps the documented exit code: under `set -e` + `pipefail` a missing
  # kubectl or a broken kubeconfig would fail this pipeline and abort with 127
  # before the caller reaches `exit 2`. Fail-closed either way, but the contract is 2.
  kubectl config get-contexts -o name 2>/dev/null | sed 's/^/  /' >&2 || true
}

# require_kube_context — hard-fail unless KUBE_CONTEXT names a real context.
# Exits 2 on a missing or unknown context. Call AFTER the argument loop (so
# --context has been parsed) and BEFORE any cluster call.
require_kube_context() {
  if [ -z "$KUBE_CONTEXT" ]; then
    _kc_err "--context is required (or set KUBE_CONTEXT)."
    _kc_err "This script never falls back to the current kube-context: the on-prem and"
    _kc_err "AWS clusters carry identically named resources, so an implicit context"
    _kc_err "silently targets the wrong cluster — successfully, and with exit code 0."
    # Keep the collision on its own line: hints naming several resources would
    # otherwise run past the width of the sentence they were spliced into.
    [ -n "$KUBE_CONTEXT_HINT" ] && _kc_err "  Collision here: ${KUBE_CONTEXT_HINT}"
    _kc_list_contexts
    exit 2
  fi
  # -F (fixed string), not a regex: context names routinely contain dots — both
  # eksctl's default `user@cluster.region.eksctl.io` and any dotted alias — and a
  # bare `grep -qx` would let `prod.example-app` match a real context `prodXexample-app`.
  # For a gate whose entire job is exact target identification, that is disqualifying.
  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qxF -- "$KUBE_CONTEXT"; then
    _kc_err "unknown kube-context: $KUBE_CONTEXT"
    _kc_list_contexts
    exit 2
  fi
}

# kctl — single chokepoint for every kubectl call, so the context can never be
# omitted by an edit that adds a new call site later.
#
# The empty-value guard is not redundant with require_kube_context: `kubectl
# --context ""` is NOT an error — kubectl treats an empty string as unset and
# falls back to the current context, which is exactly the silent wrong-cluster
# failure this lib exists to prevent. A caller that forgets require_kube_context
# would otherwise reintroduce the bug, so fail loudly instead.
kctl() {
  [ -n "$KUBE_CONTEXT" ] || {
    _kc_err "internal error: kctl called before require_kube_context (KUBE_CONTEXT is empty)"
    exit 2
  }
  kubectl --context "$KUBE_CONTEXT" "$@"
}

# kube_context_cluster — the cluster KUBE_CONTEXT resolves to. Startup banners
# should print this next to the context name: a context can be renamed or
# repointed, so the cluster is what actually identifies the target, and it is the
# operator's last chance to catch a wrong-cluster run.
kube_context_cluster() {
  kubectl config view \
    -o "jsonpath={.contexts[?(@.name=='${KUBE_CONTEXT}')].context.cluster}" 2>/dev/null
}

# kube_context_prescan ARGS... — echo the value following the first `--context`
# in ARGS (empty when absent). Accepts both `--context VAL` and `--context=VAL`.
#
# For scripts that must open a connection BEFORE their argument loop runs (e.g. a
# port-forward that the loop's own `--list` action already depends on). Those
# cannot wait for the loop to assign KUBE_CONTEXT, so they pre-scan argv.
#
# The flag MUST win over the environment — write it in this order:
#
#   _ctx_arg="$(kube_context_prescan "$@")"
#   KUBE_CONTEXT="${_ctx_arg:-${KUBE_CONTEXT:-}}"
#   require_kube_context
#
# NOT `KUBE_CONTEXT="${KUBE_CONTEXT:-$(kube_context_prescan "$@")}"`: that makes an
# exported KUBE_CONTEXT silently beat an explicit `--context` on the command line,
# which is precisely the "the banner says one cluster, the traffic goes to another"
# failure this lib exists to prevent — and every sibling script has the flag win.
#
# The main loop should still accept `--context` and assign it again, so the loop
# agrees with the pre-scan rather than discarding the value.
kube_context_prescan() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --context)
        shift
        [ $# -gt 0 ] && printf '%s' "$1"
        return 0
        ;;
      --context=*)
        printf '%s' "${1#--context=}"
        return 0
        ;;
    esac
    shift
  done
}
