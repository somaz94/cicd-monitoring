#!/usr/bin/env bash
# bash + zsh compatible: re-exec under bash if invoked through zsh BEFORE
# enabling shell options. The body + sourced modules use `echo -e` and
# bash arrays — both depend on bash semantics.
if [ -n "${ZSH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail
IFS=$'\n\t'

# UTF-8 encoding
export LANG=ko_KR.UTF-8
export LC_ALL=ko_KR.UTF-8

# Modular Harbor image cleanup script
# -------------------------
# Main script that loads all modules and runs the cleanup process

# Script directory
# Resolve script path portably across bash and zsh (BASH_SOURCE → $0 fallback).
_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
unset _SCRIPT_PATH

# Load all modules
source "$SCRIPT_DIR/modules/harbor-config.sh"
source "$SCRIPT_DIR/modules/harbor-utils.sh"
source "$SCRIPT_DIR/modules/harbor-auth.sh"
source "$SCRIPT_DIR/modules/harbor-repository.sh"
source "$SCRIPT_DIR/modules/harbor-image.sh"
source "$SCRIPT_DIR/modules/harbor-project-stats.sh"

# Global variables
SHOW_PROJECT_STATS=false
STATS_PROJECT=""

# Print help
show_help() {
    echo -e "${GREEN}Usage: $0 [options]${NC}"
    echo -e "${YELLOW}Options:${NC}"
    echo -e "  -h, --help              Show this help and exit"
    echo -e "  -d, --debug             Enable debug mode"
    echo -e "  --dry-run               Print images that would be deleted without actually deleting"
    echo -e "  --auto-confirm          Delete images automatically without confirmation"
    echo -e "  -y, --yes               Auto-select 'yes' on confirmation prompts (immediate deletion)"
    echo -e "  -k, --keep N            Keep the latest N images (default: 100)"
    echo -e "  -p, --project NAME      Harbor project name (default: example-project)"
    echo -e "  -r, --repo NAME         Repository name (e.g. example-project). Can be specified multiple times."
    echo -e "                          Use 'all' to process every repository in the project."
    echo -e "  -b, --batch-size N      Number of images to delete in parallel (default: 10)"
    echo -e "  --stats PROJECT         Show per-repository artifact counts for the given project"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  $0 --dry-run -k 50 -p <project> -r <repo> -b 20"
    echo -e "  $0 -p <project> -r <repo1> -r <repo2> -k 20 --auto-confirm"
    echo -e "  $0 -p <project> -r all -k 50"
    echo -e "  $0 -p <project> -r <repo> -k 50 -y"
    echo -e "  $0 --stats example-project"
    echo ""
}

# Parse command-line arguments
parse_arguments() {
    # Defaults
    PROJECT_NAME=""
    REPOSITORIES=()
    IMAGES_TO_KEEP=""
    BATCH_SIZE=""
    DEBUG=""
    DRY_RUN=""
    AUTO_CONFIRM=""
    YES_TO_ALL=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --stats)
                SHOW_PROJECT_STATS=true
                if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                    STATS_PROJECT="$2"
                    shift 2
                else
                    # Next argument is missing or another option
                    shift
                fi
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
            -y|--yes)
                YES_TO_ALL=true
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
            -r|--repo)
                REPOSITORIES+=("$2")
                shift 2
                ;;
            -b|--batch-size)
                BATCH_SIZE="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                echo -e "${YELLOW}Run $0 --help for usage${NC}" >&2
                exit 1
                ;;
        esac
    done

    # Check whether we are in stats mode
    if [[ "$SHOW_PROJECT_STATS" == true ]]; then
        if [[ -z "$STATS_PROJECT" ]]; then
            echo -e "${RED}Error: --stats requires a project name${NC}" >&2
            echo -e "${YELLOW}Usage: $0 --stats <project>${NC}" >&2
            echo -e "${CYAN}Example: $0 --stats example-project${NC}" >&2
            exit 1
        fi
        return 0
    fi

    # Normal cleanup mode requires project + repository arguments
    if [[ -z "$PROJECT_NAME" ]] || [[ ${#REPOSITORIES[@]} -eq 0 ]]; then
        echo -e "${RED}Error: project (-p) and repository (-r) are required${NC}" >&2
        echo -e "${YELLOW}Usage: $0 -p <project> -r <repo1> [-r <repo2>] ...${NC}" >&2
        echo -e "${CYAN}Help: $0 --help${NC}" >&2
        exit 1
    fi
}

# Stats-only execution
run_stats_mode() {
    echo -e "${GREEN}=== Harbor project stats mode ===${NC}\n"

    # Initialize config
    initialize_config

    # Check Harbor API
    check_harbor_api

    # Show project stats
    show_project_repositories_stats "$STATS_PROJECT"
}

# Process a single repository
process_repository() {
    local REPO=$1
    local repo_info=$2

    echo -e "\n${GREEN}Processing repository: $PROJECT_NAME/$REPO${NC}"

    # Fetch artifact count
    echo -e "${YELLOW}Attempting direct artifact count lookup...${NC}"
    local direct_count_output=""; direct_count_output=$(get_direct_repository_info "$REPO")
    ARTIFACT_COUNT=$(echo "$direct_count_output" | tail -n 1)

    # Verify the artifact count is numeric
    if ! [[ "$ARTIFACT_COUNT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid artifact count: $ARTIFACT_COUNT${NC}"
        ARTIFACT_COUNT=$(get_artifact_count "$REPO" "$repo_info")
    fi

    echo -e "${YELLOW}Artifact count from API: $ARTIFACT_COUNT${NC}"

    # Skip when artifact count is zero or unavailable
    if [ -z "$ARTIFACT_COUNT" ] || [ "$ARTIFACT_COUNT" = "null" ] || [ "$ARTIFACT_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}No artifacts found in repository. Skipping...${NC}"
        return
    fi

    # Skip when artifact count is at or below the keep threshold
    if [ "$ARTIFACT_COUNT" -le "$IMAGES_TO_KEEP" ]; then
        printf "${YELLOW}Repository has %s artifacts, which is at or below the keep limit (%s). Skipping...${NC}\n" "$ARTIFACT_COUNT" "$IMAGES_TO_KEEP"
        return
    fi

    # Compute number of images to delete
    DELETE_COUNT=$((ARTIFACT_COUNT - IMAGES_TO_KEEP))

    printf "${YELLOW}Found %s artifacts. Keeping the latest %s and deleting %s older artifacts.${NC}\n" "$ARTIFACT_COUNT" "$IMAGES_TO_KEEP" "$DELETE_COUNT"

    # Stats-only path (dry-run without fetching individual images)
    if [ "$DRY_RUN" = true ]; then
        printf "${YELLOW}Dry-run mode: would delete %s artifacts (no actual deletion)${NC}\n" "$DELETE_COUNT"
        return
    fi

    # If actual deletion is required, fetch image tags
    echo -e "${YELLOW}Fetching images from repository...${NC}"
    IMAGES=$(get_image_tags "$REPO")

    # Verify images were retrieved successfully
    if [ -z "$IMAGES" ]; then
        echo -e "${RED}Failed to retrieve artifact details. Cannot proceed with deletion.${NC}"
        printf "${YELLOW}API reports %s artifacts exist, but they could not be retrieved.${NC}\n" "$ARTIFACT_COUNT"
        return
    fi

    # Strip blank lines and recount actual images
    IMAGES=$(echo -e "$IMAGES" | grep -v "^$")
    TOTAL_IMAGES=$(echo -e "$IMAGES" | wc -l | tr -d ' \t')

    printf "${YELLOW}Successfully retrieved %s of %s reported artifacts${NC}\n" "$TOTAL_IMAGES" "$ARTIFACT_COUNT"

    # Handle case where fewer images were retrieved than reported by the API
    if [ "$TOTAL_IMAGES" -lt "$ARTIFACT_COUNT" ]; then
        printf "${YELLOW}Warning: retrieved artifacts (%s) is less than what the API reports (%s)${NC}\n" "$TOTAL_IMAGES" "$ARTIFACT_COUNT"
        ARTIFACT_COUNT=$TOTAL_IMAGES

        if [ "$TOTAL_IMAGES" -lt "$IMAGES_TO_KEEP" ]; then
            printf "${RED}Not enough artifacts retrieved to perform cleanup (retrieved: %s, required: %s)${NC}\n" "$TOTAL_IMAGES" "$IMAGES_TO_KEEP"

            if [ "$AUTO_CONFIRM" = true ]; then
                ADJUSTED_KEEP_COUNT=$(( TOTAL_IMAGES * 80 / 100 ))
                if [ "$ADJUSTED_KEEP_COUNT" -eq 0 ]; then
                    ADJUSTED_KEEP_COUNT=1
                fi
                printf "${YELLOW}Adjusting keep count from %s to %s${NC}\n" "$IMAGES_TO_KEEP" "$ADJUSTED_KEEP_COUNT"
                IMAGES_TO_KEEP=$ADJUSTED_KEEP_COUNT
            else
                echo -e "${YELLOW}Skipping repository...${NC}"
                return
            fi
        fi
    fi

    # Recompute delete count
    DELETE_COUNT=$((ARTIFACT_COUNT - IMAGES_TO_KEEP))

    if [ "$DELETE_COUNT" -le 0 ]; then
        printf "${YELLOW}After adjustment, nothing to delete (keeping %s of %s). Skipping...${NC}\n" "$IMAGES_TO_KEEP" "$ARTIFACT_COUNT"
        return
    fi

    printf "${YELLOW}Deleting %s of %s retrieved artifacts (keeping the latest %s).${NC}\n" "$DELETE_COUNT" "$ARTIFACT_COUNT" "$IMAGES_TO_KEEP"

    # List of images to delete (oldest first)
    IMAGES_TO_DELETE=$(echo -e "$IMAGES" | tail -n $DELETE_COUNT)

    # Filter out invalid digests
    IMAGES_TO_DELETE_FILTERED=""
    while IFS=$'\t' read -r DIGEST PUSH_TIME TAGS_COUNT TAG_NAMES; do
        if [ -z "$DIGEST" ]; then
            continue
        fi

        if [[ "$DIGEST" == "sha256:"* ]] && [[ ${#DIGEST} -ge 70 ]]; then
            IMAGES_TO_DELETE_FILTERED="${IMAGES_TO_DELETE_FILTERED}${DIGEST}\n"
        else
            echo -e "${YELLOW}Skipping invalid digest format: $DIGEST${NC}"
        fi
    done <<< "$IMAGES_TO_DELETE"

    IMAGES_TO_DELETE="$IMAGES_TO_DELETE_FILTERED"

    # Recount actual deletions after filtering
    FILTERED_DELETE_COUNT=$(echo -e "$IMAGES_TO_DELETE" | grep -v "^$" | wc -l | tr -d ' \t')
    if [ "$FILTERED_DELETE_COUNT" -ne "$DELETE_COUNT" ]; then
        printf "${YELLOW}After filtering invalid digests, deleting %s artifacts (previously: %s)${NC}\n" "$FILTERED_DELETE_COUNT" "$DELETE_COUNT"
        DELETE_COUNT=$FILTERED_DELETE_COUNT
    fi

    if [ "$DELETE_COUNT" -le 0 ]; then
        echo -e "${YELLOW}No valid artifacts to delete after filtering. Skipping...${NC}"
        return
    fi

    # Show only digests
    echo -e "${YELLOW}Digests to delete:${NC}"
    echo -e "$IMAGES_TO_DELETE" | head -5
    if [ "$DELETE_COUNT" -gt 5 ]; then
        printf "${YELLOW}(and %s more...)${NC}\n" "$((DELETE_COUNT - 5))"
    fi

    # Request user confirmation
    if confirm_deletion "$REPO" "$ARTIFACT_COUNT" "$IMAGES_TO_KEEP" "$DELETE_COUNT"; then
        delete_images_in_batches "$REPO" "$IMAGES_TO_DELETE" "$DELETE_COUNT"
    else
        echo -e "${YELLOW}Deletion cancelled for repository: $PROJECT_NAME/$REPO${NC}"
    fi
}

# Main function
main() {
    # Parse command-line arguments
    parse_arguments "$@"

    # Check whether stats-only mode was requested
    if [[ "$SHOW_PROJECT_STATS" == true ]]; then
        run_stats_mode
        exit 0
    fi

    # Initialize config
    initialize_config

    # Show startup info
    show_startup_info

    # Check requirements and validate config
    check_requirements
    validate_config

    # Check Harbor API version
    check_harbor_api

    # Fetch repository info including artifact counts
    echo -e "${YELLOW}Fetching repository info...${NC}"
    REPO_INFO=$(get_repository_info)

    # Attempt to fetch auth token (fall back to basic auth on failure)
    echo -e "${YELLOW}Fetching auth token...${NC}"
    TOKEN=$(get_auth_token)
    if [ -n "$TOKEN" ]; then
        echo -e "${GREEN}Successfully obtained auth token${NC}"
    else
        echo -e "${YELLOW}Failed to obtain token. Using basic auth instead${NC}"
    fi

    # Check whether the 'all' repositories option was selected
    if [[ "${REPOSITORIES[*]}" =~ "all" ]]; then
        echo -e "${YELLOW}Processing all repositories in project $PROJECT_NAME${NC}"

        # Fetch all repository names
        local all_repos=""; all_repos=$(get_repositories)

        if [ -z "$all_repos" ]; then
            echo -e "${RED}Failed to list repositories in project $PROJECT_NAME${NC}"
            exit 1
        fi

        # Count valid repositories
        local repo_count=""; repo_count=$(echo "$all_repos" | grep -v "^$" | wc -l | tr -d ' ')
        echo -e "${GREEN}Found $repo_count repositories to process${NC}"

        # Reset repository array and populate with all repositories
        REPOSITORIES=()
        while IFS= read -r repo; do
            [ -z "$repo" ] && continue
            REPOSITORIES+=("$repo")
        done < <(echo "$all_repos")
    fi

    # Show repositories to process
    echo -e "${YELLOW}Repositories to process: ${REPOSITORIES[*]}${NC}"

    # Process each repository
    for REPO in "${REPOSITORIES[@]}"; do
        [ -z "$REPO" ] && continue

        process_repository "$REPO" "$REPO_INFO"
    done

    echo -e "\n${GREEN}Cleanup completed!${NC}"
}

# Run main with all arguments
main "$@"
