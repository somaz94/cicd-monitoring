#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

source modules/harbor-config-en.sh
source modules/harbor-project-stats-en.sh

initialize_config

show_stats_help
