#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Harbor utilities module
# Manages utility functions

# Debug print
debug_print() {
    if [ "$DEBUG" = true ]; then
        echo -e "${YELLOW}DEBUG: $1${NC}"
    fi
}

# Deletion confirmation
confirm_deletion() {
    local repo=$1
    local total_images=$2
    local keep_count=$3
    local delete_count=$4

    echo -e "\n${YELLOW}============== Deletion confirmation ==============${NC}"
    echo -e "${YELLOW}Repository: $PROJECT_NAME/$repo${NC}"
    echo -e "${YELLOW}Total images: $total_images${NC}"
    echo -e "${YELLOW}Images to keep: $keep_count (latest)${NC}"
    echo -e "${YELLOW}Images to delete: $delete_count (oldest)${NC}"
    echo -e "${YELLOW}===================================================${NC}"

    # Check dry-run mode
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Dry-run mode: would delete $delete_count images (no actual deletion)${NC}"
        return 1
    fi

    # Check -y option (immediate deletion)
    if [ "$YES_TO_ALL" = true ]; then
        echo -e "${GREEN}-y option specified. Proceeding with deletion without confirmation...${NC}"
        return 0
    fi

    # Auto-confirm
    if [ "$AUTO_CONFIRM" = true ]; then
        echo -e "${YELLOW}Auto-confirm enabled. Proceeding with deletion...${NC}"
        return 0
    fi

    # Manual confirmation (with timeout)
    local answer
    echo -e "${YELLOW}Delete these images? (y/n) [default after 10s: n]:${NC}"
    read -t 10 answer </dev/tty
    echo ""

    # Handle answer
    case "$answer" in
        [Yy]* )
            echo -e "${GREEN}Confirmed. Proceeding with deletion...${NC}"
            return 0
            ;;
        * )
            echo -e "${YELLOW}Deletion cancelled or no input received.${NC}"
            return 1
            ;;
    esac
}

# Check Harbor API version
check_harbor_api() {
    echo -e "${YELLOW}Checking Harbor API version...${NC}"

    # Send GET request to Harbor API
    local version_url="${HARBOR_PROTOCOL}://${HARBOR_URL}/api/v2.0/systeminfo"

    # Debug: show URL
    debug_print "System info request URL: $version_url"

    # Add Accept header and increase timeout
    local version_response=""; version_response=$(curl -s -k -m 30 \
        -H "Accept: application/json" \
        -u "$HARBOR_USER:$HARBOR_PASS" "$version_url")

    # Debug: show response
    debug_print "Response: $version_response"

    # Ensure the response is JSON
    if ! echo "$version_response" | jq . >/dev/null 2>&1; then
        echo -e "${RED}Error: invalid JSON response from server during API version check${NC}"
        echo "$version_response"
        return 1
    fi

    # Extract version info
    local harbor_version=""; harbor_version=$(echo "$version_response" | jq -r '.harbor_version' 2>/dev/null)
    if [ -n "$harbor_version" ] && [ "$harbor_version" != "null" ]; then
        echo -e "${GREEN}Harbor version: $harbor_version${NC}"
    else
        echo -e "${YELLOW}Harbor version not found in response${NC}"
    fi

    # Check API version (Harbor v2.11.0 does not expose a separate api_version field)
    if echo "$version_response" | jq -e '.api_version' >/dev/null 2>&1; then
        local api_version=""; api_version=$(echo "$version_response" | jq -r '.api_version')
        echo -e "${GREEN}API version: $api_version${NC}"
    fi

    return 0
}

# Show startup info
show_startup_info() {
    echo -e "${GREEN}Starting Harbor image cleanup...${NC}"
    if [ "$AUTO_CONFIRM" = true ]; then
        echo -e "${YELLOW}Auto-confirm mode: deleting images without confirmation${NC}"
    fi
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Dry-run mode: no actual deletion${NC}"
    fi
    echo -e "${YELLOW}Project: $PROJECT_NAME${NC}"
    printf "${YELLOW}Latest images to keep: %s${NC}\n" "$IMAGES_TO_KEEP"
    printf "${YELLOW}Batch size: %s per batch${NC}\n" "$BATCH_SIZE"
}
