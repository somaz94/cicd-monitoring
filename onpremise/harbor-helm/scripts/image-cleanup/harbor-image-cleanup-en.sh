#!/usr/bin/env bash
# bash + zsh compatible: re-exec under bash if invoked through zsh BEFORE
# enabling shell options. The body + sourced modules use `echo -e` and
# bash arrays — both depend on bash semantics.
if [ -n "${ZSH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail
IFS=$'\n\t'

# Modular Harbor Image Cleanup Script

# Resolve script path portably across bash and zsh (BASH_SOURCE → $0 fallback).
_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
unset _SCRIPT_PATH

source "$SCRIPT_DIR/modules/harbor-config-en.sh"
source "$SCRIPT_DIR/modules/harbor-utils-en.sh"
source "$SCRIPT_DIR/modules/harbor-repository-en.sh"
source "$SCRIPT_DIR/modules/harbor-image-en.sh"
source "$SCRIPT_DIR/modules/harbor-project-stats-en.sh"

SHOW_PROJECT_STATS=false
STATS_PROJECT=""

show_help() {
    echo -e "${GREEN}Usage: $0 [options]${NC}"
    echo -e "${YELLOW}Options:${NC}"
    echo -e "  -h, --help              Show this help and exit"
    echo -e "  -d, --debug             Enable debug mode"
    echo -e "  --dry-run               Don't actually delete images, just show what would be deleted"
    echo -e "  --auto-confirm          Automatically confirm image deletion without prompts"
    echo -e "  -y, --yes               Automatically answer 'yes' to confirmation prompts (immediate deletion)"
    echo -e "  -k, --keep N            Keep the newest N images (default: 100)"
    echo -e "  -p, --project NAME      Harbor project name (default: example-project)"
    echo -e "  -r, --repo NAME         Repository name (e.g., example-project). Can be specified multiple times."
    echo -e "                          Use 'all' to process all repositories in the project."
    echo -e "  -b, --batch-size N      Number of images to delete in parallel (default: 10)"
    echo -e "  --stats PROJECT         Show artifact counts by repository for a specific project"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  $0 --dry-run -k 50 -p <project> -r <repository> -b 20"
    echo -e "  $0 -p <project> -r <repository1> -r <repository2> -k 20 --auto-confirm"
    echo -e "  $0 -p <project> -r all -k 50"
    echo -e "  $0 -p <project> -r <repository> -k 50 -y"
    echo -e "  $0 --stats example-project"
    echo ""
}

parse_arguments() {
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
                echo -e "${YELLOW}Run $0 --help for usage information${NC}" >&2
                exit 1
                ;;
        esac
    done
    
    if [[ "$SHOW_PROJECT_STATS" == true ]]; then
        if [[ -z "$STATS_PROJECT" ]]; then
            echo -e "${RED}Error: --stats option requires a project name.${NC}" >&2
            echo -e "${YELLOW}Usage: $0 --stats <project_name>${NC}" >&2
            echo -e "${CYAN}Example: $0 --stats example-project${NC}" >&2
            exit 1
        fi
        return 0
    fi
    
    if [[ -z "$PROJECT_NAME" ]] || [[ ${#REPOSITORIES[@]} -eq 0 ]]; then
        echo -e "${RED}Error: Project name (-p) and repository name (-r) are required.${NC}" >&2
        echo -e "${YELLOW}Usage: $0 -p <project_name> -r <repository1> [-r <repository2>] ...${NC}" >&2
        echo -e "${CYAN}Help: $0 --help${NC}" >&2
        exit 1
    fi
}

run_stats_mode() {
    echo -e "${GREEN}=== Harbor Project Statistics Mode ===${NC}\n"
    
    initialize_config
    
    check_harbor_api
    
    show_project_repositories_stats "$STATS_PROJECT"
}

process_repository() {
    local REPO=$1
    local repo_info=$2
    
    echo -e "\n${GREEN}Processing repository: $PROJECT_NAME/$REPO${NC}"
    
    echo -e "${YELLOW}Attempting to get direct artifact count...${NC}"
    local direct_count_output=""; direct_count_output=$(get_direct_repository_info "$REPO")
    ARTIFACT_COUNT=$(echo "$direct_count_output" | tail -n 1)
    
    if ! [[ "$ARTIFACT_COUNT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid artifact count: $ARTIFACT_COUNT${NC}"
        ARTIFACT_COUNT=$(get_artifact_count "$REPO" "$repo_info")
    fi
    
    echo -e "${YELLOW}Artifact count from API: $ARTIFACT_COUNT${NC}"
    
    if [ -z "$ARTIFACT_COUNT" ] || [ "$ARTIFACT_COUNT" = "null" ] || [ "$ARTIFACT_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}No artifacts found in repository. Skipping...${NC}"
        return
    fi
    
    if [ "$ARTIFACT_COUNT" -le "$IMAGES_TO_KEEP" ]; then
        echo -e "${YELLOW}Repository has $ARTIFACT_COUNT artifacts, which is less than or equal to the keep limit ($IMAGES_TO_KEEP). Skipping...${NC}"
        return
    fi
    
    DELETE_COUNT=$((ARTIFACT_COUNT - IMAGES_TO_KEEP))
    
    echo -e "${YELLOW}Found $ARTIFACT_COUNT artifacts. Will keep the newest $IMAGES_TO_KEEP artifacts and delete the oldest $DELETE_COUNT artifacts.${NC}"
    
    # If we're just displaying stats (dry run with no image fetching), continue
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY RUN MODE: Would delete $DELETE_COUNT artifacts (not actually deleting)${NC}"
        return
    fi
    
    echo -e "${YELLOW}Fetching images from repository...${NC}"
    IMAGES=$(get_image_tags "$REPO")
    
    if [ -z "$IMAGES" ]; then
        echo -e "${RED}Failed to fetch artifact details. Cannot proceed with deletion.${NC}"
        echo -e "${YELLOW}The API reports $ARTIFACT_COUNT artifacts exist, but we couldn't fetch them.${NC}"
        return
    fi
    
    IMAGES=$(echo -e "$IMAGES" | grep -v "^$")
    TOTAL_IMAGES=$(echo -e "$IMAGES" | wc -l | tr -d ' \t')
    
    echo -e "${YELLOW}Successfully fetched $TOTAL_IMAGES artifacts of the reported $ARTIFACT_COUNT${NC}"
    
    # Handle case when we got fewer images than reported by API
    if [ "$TOTAL_IMAGES" -lt "$ARTIFACT_COUNT" ]; then
        echo -e "${YELLOW}Warning: Fetched fewer artifacts ($TOTAL_IMAGES) than reported by API ($ARTIFACT_COUNT)${NC}"
        ARTIFACT_COUNT=$TOTAL_IMAGES
        
        if [ "$TOTAL_IMAGES" -lt "$IMAGES_TO_KEEP" ]; then
            echo -e "${RED}Unable to fetch enough artifacts to perform cleanup (fetched: $TOTAL_IMAGES, need: $IMAGES_TO_KEEP)${NC}"
            
            if [ "$AUTO_CONFIRM" = true ]; then
                ADJUSTED_KEEP_COUNT=$(( TOTAL_IMAGES * 80 / 100 ))
                if [ "$ADJUSTED_KEEP_COUNT" -eq 0 ]; then
                    ADJUSTED_KEEP_COUNT=1
                fi
                echo -e "${YELLOW}Adjusting images to keep from $IMAGES_TO_KEEP to $ADJUSTED_KEEP_COUNT${NC}"
                IMAGES_TO_KEEP=$ADJUSTED_KEEP_COUNT
            else
                echo -e "${YELLOW}Skipping repository...${NC}"
                return
            fi
        fi
    fi
    
    DELETE_COUNT=$((ARTIFACT_COUNT - IMAGES_TO_KEEP))
    
    if [ "$DELETE_COUNT" -le 0 ]; then
        echo -e "${YELLOW}After adjustments, nothing to delete (keeping $IMAGES_TO_KEEP out of $ARTIFACT_COUNT). Skipping...${NC}"
        return
    fi
    
    echo -e "${YELLOW}Will delete $DELETE_COUNT artifacts of the $ARTIFACT_COUNT fetched (keeping newest $IMAGES_TO_KEEP).${NC}"
    
    IMAGES_TO_DELETE=$(echo -e "$IMAGES" | tail -n $DELETE_COUNT)
    
    # Clean the IMAGES_TO_DELETE by filtering out invalid digests
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
    
    FILTERED_DELETE_COUNT=$(echo -e "$IMAGES_TO_DELETE" | grep -v "^$" | wc -l | tr -d ' \t')
    if [ "$FILTERED_DELETE_COUNT" -ne "$DELETE_COUNT" ]; then
        echo -e "${YELLOW}After filtering invalid digests, will delete $FILTERED_DELETE_COUNT artifacts (was $DELETE_COUNT)${NC}"
        DELETE_COUNT=$FILTERED_DELETE_COUNT
    fi
    
    if [ "$DELETE_COUNT" -le 0 ]; then
        echo -e "${YELLOW}No valid artifacts to delete after filtering. Skipping...${NC}"
        return
    fi
    
    echo -e "${YELLOW}Digests to delete:${NC}"
    echo -e "$IMAGES_TO_DELETE" | head -5
    if [ "$DELETE_COUNT" -gt 5 ]; then
        echo -e "${YELLOW}(and $(($DELETE_COUNT - 5)) more...)${NC}"
    fi
    
    if confirm_deletion "$REPO" "$ARTIFACT_COUNT" "$IMAGES_TO_KEEP" "$DELETE_COUNT"; then
        delete_images_in_batches "$REPO" "$IMAGES_TO_DELETE" "$DELETE_COUNT"
    else
        echo -e "${YELLOW}Deletion cancelled for repository: $PROJECT_NAME/$REPO${NC}"
    fi
}

main() {
    parse_arguments "$@"
    
    if [[ "$SHOW_PROJECT_STATS" == true ]]; then
        run_stats_mode
        exit 0
    fi
    
    initialize_config
    
    show_startup_info
    
    check_requirements
    validate_config
    
    check_harbor_api
    
    echo -e "${YELLOW}Getting repository information...${NC}"
    REPO_INFO=$(get_repository_info)

    # All Harbor API calls below authenticate with HTTP basic auth
    # (-u "$HARBOR_USER:$HARBOR_PASS"), so no separate token fetch is needed.

    if [[ "${REPOSITORIES[*]}" =~ "all" ]]; then
        echo -e "${YELLOW}Processing ALL repositories in project $PROJECT_NAME${NC}"
        
        local all_repos=""; all_repos=$(get_repositories)
        
        if [ -z "$all_repos" ]; then
            echo -e "${RED}Failed to get repository list for project $PROJECT_NAME${NC}"
            exit 1
        fi
        
        local repo_count=""; repo_count=$(echo "$all_repos" | grep -v "^$" | wc -l | tr -d ' ')
        echo -e "${GREEN}Found $repo_count repositories to process${NC}"
        
        REPOSITORIES=()
        while IFS= read -r repo; do
            [ -z "$repo" ] && continue
            REPOSITORIES+=("$repo")
        done < <(echo "$all_repos")
    fi
    
    echo -e "${YELLOW}Repositories to process: ${REPOSITORIES[*]}${NC}"
    
    for REPO in "${REPOSITORIES[@]}"; do
        [ -z "$REPO" ] && continue
        
        process_repository "$REPO" "$REPO_INFO"
    done
    
    echo -e "\n${GREEN}Cleanup completed!${NC}" 
}

main "$@"