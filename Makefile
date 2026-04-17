# ============================================================
# Root Makefile for kuberntes-infra
#
# Single entry point for the most common workflows:
#   - validate the repo (test / lint / ci)
#   - inspect what's changed (status / diff)
#   - manage the upgrade-sync sync system (sync-*)
#   - manage chart backups (backups-*)
#   - review and commit changes (commit-review / commit)
#
# Run `make help` (or just `make`) to see all available targets.
# ============================================================

.DEFAULT_GOAL := help

# Use bash for recipes (process substitution, [[ ]], etc.).
# Auto-detect bash from PATH so it works with system bash, Homebrew bash, custom installs.
# Override with: make SHELL=/custom/path/to/bash <target>
SHELL := $(shell command -v bash 2>/dev/null || echo /bin/bash)

# PHONY targets grouped by category (mirrors `make help` output)
# Validation
.PHONY: help test lint ci pre-commit
# Status / Inspection
.PHONY: status diff
# Sync system (upgrade-sync)
.PHONY: sync-check sync-apply sync-status
# Backup management
.PHONY: backups-list backups-cleanup
# Commit workflow
.PHONY: commit-review commit

# Repo root: prefer git, fall back to current dir
REPO_ROOT := $(shell git rev-parse --show-toplevel 2>/dev/null || pwd)
SYNC      := $(REPO_ROOT)/scripts/upgrade-sync/sync.sh

# Color helpers (disabled if NO_COLOR is set)
ifdef NO_COLOR
CYAN  :=
GREEN :=
YELLOW :=
RED   :=
RESET :=
else
CYAN  := \033[36m
GREEN := \033[32m
YELLOW := \033[33m
RED   := \033[31m
RESET := \033[0m
endif

# ------------------------------------------------------------
# Help (default target)
# ------------------------------------------------------------

# Note: 'help' itself is intentionally NOT documented with `## help: ...`
# (its description is the printf banner below). The awk pattern only matches
# `## <target>: <desc>` lines, so this stays out of the auto-generated list.
help:
##
## How to add a new target so it shows up here:
##   1. Place it under (or create) a `## --- CATEGORY: <name> ---` divider.
##   2. Document it on the line above the target with `## <target>: <description>`.
## The awk below scans for these two patterns automatically — no help-target edits needed.
help:
	@printf "$(CYAN)kuberntes-infra Makefile$(RESET)\n"
	@printf "Usage: make <target>\n"
	@awk 'BEGIN {FS = ":.*?## "} \
	     /^## --- CATEGORY: / { \
	       cat = $$0; \
	       sub(/^## --- CATEGORY: /, "", cat); \
	       sub(/ ---$$/, "", cat); \
	       printf "\n$(YELLOW)%s$(RESET)\n", cat; \
	       next; \
	     } \
	     /^## [a-zA-Z][a-zA-Z0-9_-]*:/ { \
	       sub(/^## /, "", $$0); \
	       split($$0, a, ": "); \
	       printf "  $(GREEN)%-18s$(RESET) %s\n", a[1], a[2]; \
	     }' \
	     $(MAKEFILE_LIST)
	@printf "\n$(YELLOW)Examples$(RESET)\n"
	@printf "  make test                                # Run all CI checks\n"
	@printf "  make status                              # See sync state + git changes\n"
	@printf "  make commit-review                       # Preview what would be committed\n"
	@printf "  make commit MSG=\"feat: upgrade foo 1.0.0->1.1.0\"\n"
	@printf "  make sync-apply                          # Propagate canonical -> all upgrade.sh\n"
	@printf "\n"

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------
## --- CATEGORY: Validation ---

## test: Run all CI checks (sync drift + bash syntax + README pairs + perms)
test:
	@printf "$(CYAN)[1/4]$(RESET) sync.sh --check\n"
	@$(SYNC) --check
	@printf "\n$(CYAN)[2/4]$(RESET) bash -n syntax check\n"
	@count=0; failed=0; \
	while IFS= read -r f; do \
	  count=$$((count+1)); \
	  bash -n "$$f" 2>&1 || { printf "$(RED)  FAIL$(RESET) %s\n" "$$f"; failed=$$((failed+1)); }; \
	done < <(find "$(REPO_ROOT)" -type f -name '*.sh' \
	  -not -path '*/backup/*' \
	  -not -path '*/_deprecated/*'); \
	if [ $$failed -gt 0 ]; then \
	  printf "$(RED)  %d/%d files failed$(RESET)\n" $$failed $$count; exit 1; \
	fi; \
	printf "  $(GREEN)all $$count file(s) OK$(RESET)\n"
	@printf "\n$(CYAN)[3/4]$(RESET) README pair check (README.md <-> README-en.md)\n"
	@count=0; missing=0; \
	while IFS= read -r ko; do \
	  count=$$((count+1)); \
	  en="$${ko%.md}-en.md"; \
	  if [ ! -f "$$en" ]; then \
	    printf "$(RED)  MISSING$(RESET) %s (for %s)\n" "$$en" "$$ko"; \
	    missing=$$((missing+1)); \
	  fi; \
	done < <(find "$(REPO_ROOT)" -type f -name '*.md' \
	  -not -path '*/backup/*' \
	  -not -path '*/_deprecated/*' \
	  -not -name 'CLAUDE.md' \
	  -not -name '*-en.md'); \
	if [ $$missing -gt 0 ]; then \
	  printf "$(RED)  %d/%d README files missing -en mirror$(RESET)\n" $$missing $$count; exit 1; \
	fi; \
	printf "  $(GREEN)all $$count Korean README(s) have an English mirror$(RESET)\n"
	@printf "\n$(CYAN)[4/4]$(RESET) upgrade.sh executable bit check\n"
	@count=0; not_exec=0; \
	while IFS= read -r f; do \
	  count=$$((count+1)); \
	  if [ ! -x "$$f" ]; then \
	    printf "$(RED)  NOT EXECUTABLE$(RESET) %s\n" "$$f"; \
	    not_exec=$$((not_exec+1)); \
	  fi; \
	done < <(find "$(REPO_ROOT)" -type f -name 'upgrade.sh' \
	  -not -path '*/backup/*' \
	  -not -path '*/_deprecated/*' \
	  -not -path '*/scripts/upgrade-sync/*'); \
	if [ $$not_exec -gt 0 ]; then \
	  printf "$(RED)  %d/%d upgrade.sh missing +x$(RESET)\n" $$not_exec $$count; exit 1; \
	fi; \
	printf "  $(GREEN)all $$count upgrade.sh have +x$(RESET)\n"
	@printf "\n$(GREEN)All test checks passed.$(RESET)\n"

## lint: Run helmfile lint on every active chart
lint:
	@count=0; failed=0; \
	while IFS= read -r helmfile; do \
	  count=$$((count+1)); \
	  dir="$$(dirname "$$helmfile")"; \
	  rel="$${dir#$(REPO_ROOT)/}"; \
	  printf "$(CYAN)>>$(RESET) helmfile lint $(YELLOW)%s$(RESET)\n" "$$rel"; \
	  if ! (cd "$$dir" && helmfile lint > /dev/null 2>&1); then \
	    printf "$(RED)   FAIL$(RESET) %s\n" "$$rel"; \
	    failed=$$((failed+1)); \
	  fi; \
	done < <(find "$(REPO_ROOT)" -type f -name 'helmfile.yaml' \
	  -not -path '*/backup/*' \
	  -not -path '*/_deprecated/*'); \
	printf "\n"; \
	if [ $$failed -gt 0 ]; then \
	  printf "$(RED)%d/%d helmfile(s) failed lint$(RESET)\n" $$failed $$count; exit 1; \
	fi; \
	printf "$(GREEN)all %d helmfile(s) lint clean$(RESET)\n" $$count

## ci: Full CI pipeline (test + lint)
ci: test lint

## pre-commit: Pre-commit safety net (test + status)
pre-commit: test status

# ------------------------------------------------------------
# Status / Inspection
# ------------------------------------------------------------
## --- CATEGORY: Status / Inspection ---

## status: Show sync.sh status + git status + git diff --stat
status:
	@printf "$(CYAN)=== sync.sh --status ===$(RESET)\n"
	@$(SYNC) --status
	@printf "\n$(CYAN)=== git status (short) ===$(RESET)\n"
	@git status --short || true
	@printf "\n$(CYAN)=== git diff --stat ===$(RESET)\n"
	@git diff --stat || true

## diff: Show git diff (working tree -> HEAD) for the whole repo
diff:
	@git --no-pager diff || true

# ------------------------------------------------------------
# Sync system wrappers (scripts/upgrade-sync/sync.sh)
# ------------------------------------------------------------
## --- CATEGORY: Sync system (upgrade-sync) ---

## sync-check: Verify all upgrade.sh files match their canonical
sync-check:
	@$(SYNC) --check

## sync-apply: Propagate canonical changes to all managed upgrade.sh files
sync-apply:
	@$(SYNC) --apply

## sync-status: Show template assignment + unmanaged charts
sync-status:
	@$(SYNC) --status

# ------------------------------------------------------------
# Backup management
# ------------------------------------------------------------
## --- CATEGORY: Backup management ---

## backups-list: List backups for every chart
backups-list:
	@count=0; total_backups=0; \
	while IFS= read -r upgrade; do \
	  dir="$$(dirname "$$upgrade")"; \
	  rel="$${dir#$(REPO_ROOT)/}"; \
	  if [ -d "$$dir/backup" ]; then \
	    n=$$(ls -d "$$dir/backup"/2* 2>/dev/null | wc -l | tr -d ' '); \
	  else \
	    n=0; \
	  fi; \
	  if [ "$$n" -gt 0 ]; then \
	    printf "$(YELLOW)%-60s$(RESET) %s backup(s)\n" "$$rel" "$$n"; \
	    total_backups=$$((total_backups+n)); \
	  fi; \
	  count=$$((count+1)); \
	done < <(find "$(REPO_ROOT)" -type f -name 'upgrade.sh' \
	  -not -path '*/backup/*' \
	  -not -path '*/_deprecated/*' \
	  -not -path '*/scripts/upgrade-sync/*'); \
	printf "\n$(GREEN)Total: %s backup(s) across %s chart(s) checked$(RESET)\n" "$$total_backups" "$$count"

## backups-cleanup: Run upgrade.sh --cleanup-backups in every chart (keeps last 5)
backups-cleanup:
	@count=0; \
	while IFS= read -r upgrade; do \
	  dir="$$(dirname "$$upgrade")"; \
	  rel="$${dir#$(REPO_ROOT)/}"; \
	  if [ -d "$$dir/backup" ] && [ -n "$$(ls -d "$$dir/backup"/2* 2>/dev/null)" ]; then \
	    printf "$(CYAN)>>$(RESET) %s\n" "$$rel"; \
	    (cd "$$dir" && ./upgrade.sh --cleanup-backups) | sed 's/^/   /'; \
	  fi; \
	  count=$$((count+1)); \
	done < <(find "$(REPO_ROOT)" -type f -name 'upgrade.sh' \
	  -not -path '*/backup/*' \
	  -not -path '*/_deprecated/*' \
	  -not -path '*/scripts/upgrade-sync/*'); \
	printf "\n$(GREEN)Checked %s chart(s)$(RESET)\n" "$$count"

# ------------------------------------------------------------
# Commit workflow
# ------------------------------------------------------------
## --- CATEGORY: Commit workflow ---

## commit-review: Show what would be committed (alias to status)
commit-review: status

## commit: Stage all changes and commit (requires MSG="...")
commit:
	@if [ -z "$(MSG)" ]; then \
	  printf "$(RED)ERROR:$(RESET) Usage: make commit MSG=\"feat: ...\"\n"; \
	  printf "       Tip: run 'make commit-review' first to see changes.\n"; \
	  printf "       For messages with shell metachars (\$$, backticks, multi-line),\n"; \
	  printf "       use git directly: git commit -F <file> or git commit (editor).\n"; \
	  exit 1; \
	fi
	@git add -A
	@printf '%s\n' "$(MSG)" | git commit -F -

