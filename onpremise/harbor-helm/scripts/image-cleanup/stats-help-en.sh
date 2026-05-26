#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Load modules
source modules/harbor-config-en.sh
source modules/harbor-project-stats-en.sh

# Initialize configuration
initialize_config

# Show statistics help
show_stats_help
