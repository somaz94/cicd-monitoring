#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

source modules/harbor-config.sh
source modules/harbor-project-stats.sh

initialize_config

show_stats_help
