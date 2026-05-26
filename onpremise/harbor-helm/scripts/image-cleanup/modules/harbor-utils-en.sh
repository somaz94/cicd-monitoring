#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Harbor Utilities Module
# Manages utility functions

# Debug function
debug_print() {
    if [ "$DEBUG" = true ]; then
        echo -e "${YELLOW}DEBUG: $1${NC}"
    fi
}

# Function to ask user for confirmation
confirm_deletion() {
    local repo=$1
    local total_images=$2
    local keep_count=$3
    local delete_count=$4
    
    echo -e "\n${YELLOW}============== DELETION CONFIRMATION ==============${NC}"
    echo -e "${YELLOW}Repository: $PROJECT_NAME/$repo${NC}"
    echo -e "${YELLOW}Total images: $total_images${NC}"
    echo -e "${YELLOW}Images to keep: $keep_count (newest images)${NC}"
    echo -e "${YELLOW}Images to delete: $delete_count (oldest images)${NC}"
    echo -e "${YELLOW}=====================================${NC}"
    
    # Check if running in dry run mode
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY RUN MODE: Would delete $delete_count images (not actually deleting)${NC}"
        return 1
    fi
    
    # Check for -y option (immediate deletion)
    if [ "$YES_TO_ALL" = true ]; then
        echo -e "${GREEN}-y option specified. Proceeding with deletion without confirmation...${NC}"
        return 0
    fi
    
    # Automatic confirmation
    if [ "$AUTO_CONFIRM" = true ]; then
        echo -e "${YELLOW}Auto-confirmation enabled. Proceeding with deletion...${NC}"
        return 0
    fi
    
    # Manual confirmation with timeout
    local answer
    echo -e "${YELLOW}Do you want to delete these images? (y/n) [Default: n in 10s]:${NC}"
    read -t 10 answer </dev/tty
    echo ""
    
    # Process the answer
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

# Function to check Harbor API version
check_harbor_api() {
    echo -e "${YELLOW}Checking Harbor API version...${NC}"
    
    # Send GET request to Harbor API
    local version_url="${HARBOR_PROTOCOL}://${HARBOR_URL}/api/v2.0/systeminfo"
    
    # Debug: Show URL
    debug_print "Requesting system info from: $version_url"
    
    # Add Accept header and increased timeout
    local version_response=""; version_response=$(curl -s -k -m 30 \
        -H "Accept: application/json" \
        -u "$HARBOR_USER:$HARBOR_PASS" "$version_url")
    
    # Debug: Show response
    debug_print "Response: $version_response"
    
    # Check if response is JSON
    if ! echo "$version_response" | jq . >/dev/null 2>&1; then
        echo -e "${RED}Error: Invalid JSON response from server when checking API version${NC}"
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
    
    # Check API version (Harbor v2.11.0 doesn't have separate API version field)
    if echo "$version_response" | jq -e '.api_version' >/dev/null 2>&1; then
        local api_version=""; api_version=$(echo "$version_response" | jq -r '.api_version')
        echo -e "${GREEN}API version: $api_version${NC}"
    fi
    
    return 0
}

# Function to display startup information
show_startup_info() {
    echo -e "${GREEN}Starting Harbor image cleanup...${NC}"
    if [ "$AUTO_CONFIRM" = true ]; then
        echo -e "${YELLOW}AUTO CONFIRMATION MODE: Will delete images without asking${NC}"
    fi
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY RUN MODE: Will not actually delete any images${NC}"
    fi
    echo -e "${YELLOW}Project: $PROJECT_NAME${NC}"
    echo -e "${YELLOW}Keep newest: $IMAGES_TO_KEEP images${NC}"
    echo -e "${YELLOW}Batch size: $BATCH_SIZE images at a time${NC}"
} 