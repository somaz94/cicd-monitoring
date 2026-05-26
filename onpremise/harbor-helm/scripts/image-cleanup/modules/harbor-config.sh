#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# UTF-8 encoding
export LANG=ko_KR.UTF-8
export LC_ALL=ko_KR.UTF-8

# Harbor config module
# Manages configuration-related functions

# -- Global variable definitions --

# Default settings
DEFAULT_HARBOR_URL="harbor.example.com"           # Default Harbor registry URL
DEFAULT_HARBOR_PROTOCOL="https"                  # Default protocol for the Harbor API (http/https) — matches harbor-helm externalURL
DEFAULT_HARBOR_USER="admin"                      # Default Harbor admin username
DEFAULT_HARBOR_PASS="exampleAdminPassword"                # Default Harbor admin password
DEFAULT_PROJECT_NAME="example-project"                  # Default Harbor project to clean up
DEFAULT_IMAGES_TO_KEEP=100                       # Number of latest images to keep
DEFAULT_BATCH_SIZE=10                            # Number of images to delete in parallel
DEFAULT_DEBUG=false                              # Debug mode (verbose logging when true)
DEFAULT_DRY_RUN=false                            # Dry-run mode (no actual deletion when true)
DEFAULT_AUTO_CONFIRM=false                       # Auto-confirm (skip prompts when true)
DEFAULT_REPOSITORIES=("admin")                    # Default repositories to process within the project

# Output colors — scripts/lib/colors.sh
# Resolve script path portably across bash and zsh (BASH_SOURCE → $0 fallback).
_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
# shellcheck disable=SC1091
source "$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)/../../../lib/colors.sh"
unset _SCRIPT_PATH

# Print help message
show_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help              Show this help and exit"
    echo "  -d, --debug             Enable debug mode"
    echo "  --dry-run               Print images that would be deleted without actually deleting"
    echo "  --auto-confirm          Delete images automatically without confirmation"
    echo "  -k, --keep N            Keep the latest N images (default: $DEFAULT_IMAGES_TO_KEEP)"
    echo "  -p, --project NAME      Harbor project name (default: $DEFAULT_PROJECT_NAME)"
    echo "  -r, --repo NAME         Repository name (e.g. example-project). Can be specified multiple times."
    echo "                          Use 'all' to process every repository in the project."
    echo "  -b, --batch-size N      Number of images to delete in parallel (default: $DEFAULT_BATCH_SIZE)"
    echo ""
    echo "Examples:"
    echo "  $0 --dry-run -k 50 -p <project> -r <repo> -b 20"
    echo "  $0 -p <project> -r <repo1> -r <repo2> -k 20 --auto-confirm"
    echo "  $0 -p <project> -r all -k 50"
}

# Validate configuration
validate_config() {
    if [ -z "$HARBOR_URL" ] || [ -z "$HARBOR_USER" ] || [ -z "$HARBOR_PASS" ] || [ -z "$PROJECT_NAME" ]; then
        echo -e "${RED}Error: please fill in all configuration variables in the script${NC}"
        exit 1
    fi

    if [[ "$HARBOR_PROTOCOL" != "http" && "$HARBOR_PROTOCOL" != "https" ]]; then
        echo -e "${RED}Error: HARBOR_PROTOCOL must be 'http' or 'https'${NC}"
        exit 1
    fi
}

# -- Parse command-line arguments --
parse_arguments() {
    local print_help=false
    local repo_set=false

    # Initialize empty REPOSITORIES array
    REPOSITORIES=()

    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            -h|--help)
                print_help=true
                shift
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --auto-confirm)
                AUTO_CONFIRM=true
                shift
                ;;
            -k|--keep)
                IMAGES_TO_KEEP="$2"
                shift 2
                ;;
            -p|--project)
                PROJECT_NAME="$2"
                shift 2
                ;;
            -b|--batch-size)
                BATCH_SIZE="$2"
                shift 2
                ;;
            -r|--repo)
                REPOSITORIES+=("$2")
                repo_set=true
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                print_help=true
                shift
                ;;
        esac
    done

    # Show help if requested
    if [ "$print_help" = true ]; then
        show_help
        exit 0
    fi

    # Apply default if no repositories specified
    if [ ${#REPOSITORIES[@]} -eq 0 ]; then
        REPOSITORIES=("${DEFAULT_REPOSITORIES[@]}")
    fi
}

# -- Initialize configuration --
initialize_config() {
    # Apply defaults when not provided
    HARBOR_URL="${HARBOR_URL:-$DEFAULT_HARBOR_URL}"
    HARBOR_PROTOCOL="${HARBOR_PROTOCOL:-$DEFAULT_HARBOR_PROTOCOL}"
    HARBOR_USER="${HARBOR_USER:-$DEFAULT_HARBOR_USER}"
    HARBOR_PASS="${HARBOR_PASS:-$DEFAULT_HARBOR_PASS}"
    PROJECT_NAME="${PROJECT_NAME:-$DEFAULT_PROJECT_NAME}"
    IMAGES_TO_KEEP="${IMAGES_TO_KEEP:-$DEFAULT_IMAGES_TO_KEEP}"
    DEBUG="${DEBUG:-$DEFAULT_DEBUG}"
    AUTO_CONFIRM="${AUTO_CONFIRM:-$DEFAULT_AUTO_CONFIRM}"
    DRY_RUN="${DRY_RUN:-$DEFAULT_DRY_RUN}"
    BATCH_SIZE="${BATCH_SIZE:-$DEFAULT_BATCH_SIZE}"

    # Ensure BATCH_SIZE is at least 1
    if [ "$BATCH_SIZE" -lt 1 ]; then
        echo -e "${YELLOW}Invalid batch size $BATCH_SIZE, setting to 1${NC}"
        BATCH_SIZE=1
    fi
}

# Verify required commands are present
check_requirements() {
    local missing_commands=()

    for cmd in curl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        echo -e "${RED}Error: the following required commands are missing:${NC}"
        printf '%s\n' "${missing_commands[@]}"
        exit 1
    fi
}