#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Harbor Repository Module
# Manages repository-related functions

# Function to get repository list
get_repositories() {
    local url="${HARBOR_PROTOCOL}://${HARBOR_URL}/api/v2.0/projects/$PROJECT_NAME/repositories"
    local response

    debug_print "Fetching repositories from: $url"
    debug_print "Curl command: curl -s -k -u \"$HARBOR_USER:***\" \"$url\""
    response=$(curl -s -k -u "$HARBOR_USER:$HARBOR_PASS" "$url")
    debug_print "Raw response: $response"

    # Handle case when response is not JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        echo -e "${RED}Error: Invalid JSON response from server${NC}"
        echo "$response"
        return 1
    fi

    # Check for error message in response
    if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
        local error_msg=""; error_msg=$(echo "$response" | jq -r '.errors[0].message')
        echo -e "${RED}Error from server: $error_msg${NC}"
        return 1
    fi

    # Extract repository names and remove project prefix
    echo "$response" | jq -r '.[].name' | sed "s|^$PROJECT_NAME/||" | grep -v "^$"
}

# Function to list available repositories
list_repositories() {
    echo -e "\n${GREEN}Available repositories in project $PROJECT_NAME:${NC}"
    
    local repos=""; repos=$(get_repositories)
    if [ -z "$repos" ] || [ "$repos" = "[]" ]; then
        echo -e "${YELLOW}No repositories found in project $PROJECT_NAME${NC}"
        return 1
    fi
    
    # Print the repository names
    echo "$repos" | while read -r repo; do
        [ -z "$repo" ] && continue
        echo "- $repo"
    done
    
    echo "$repos"
    return 0
}

# Function to get repository information with artifact counts
get_repository_info() {
    local url="${HARBOR_PROTOCOL}://${HARBOR_URL}/api/v2.0/projects/$PROJECT_NAME/repositories?page=1&page_size=100"
    local response
    
    echo -e "${YELLOW}Fetching repository information from: $url${NC}"
    
    response=$(curl -s -k -m 30 \
        -H "Accept: application/json" \
        -u "$HARBOR_USER:$HARBOR_PASS" "$url")
    
    debug_print "Raw response: $response"
    
    # Validate JSON response
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        echo -e "${RED}Error: Invalid JSON response from server${NC}"
        echo "[]"
        return 1
    fi
    
    # Check for error message in response
    if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
        local error_msg=""; error_msg=$(echo "$response" | jq -r '.errors[0].message')
        echo -e "${RED}Error from server: $error_msg${NC}"
        echo "[]"
        return 1
    fi
    
    echo "$response"
}

# Function to extract artifact count for a repository
get_artifact_count() {
    local repo=$1
    local repo_info=$2
    
    if [ -z "$repo_info" ] || [ "$repo_info" = "[]" ]; then
        echo "0"
        return 1
    fi
    
    local full_repo_path="$PROJECT_NAME/$repo"
    local count
    
    if echo "$repo_info" | grep -q "\"$full_repo_path\""; then
        count=$(echo "$repo_info" | jq -r ".[] | select(.name==\"$full_repo_path\") | .artifact_count")
        
        if [ -n "$count" ] && [ "$count" != "null" ]; then
            echo "$count"
            return 0
        fi
    fi
    
    echo "0"
    return 1
}

# Function to get direct repository info
get_direct_repository_info() {
    local repo=$1
    echo -e "${YELLOW}Getting direct repository info for: $repo${NC}"
    
    local encoded_repo=""; encoded_repo=$(echo "$repo" | sed 's|/|%2F|g')
    local url="${HARBOR_PROTOCOL}://${HARBOR_URL}/api/v2.0/projects/$PROJECT_NAME/repositories/$encoded_repo"
    
    local response=""; response=$(curl -s -k -m 30 \
        -H "Accept: application/json" \
        -u "$HARBOR_USER:$HARBOR_PASS" "$url")
    
    if echo "$response" | jq . >/dev/null 2>&1; then
        if echo "$response" | jq -e '.artifact_count' >/dev/null 2>&1; then
            local count=""; count=$(echo "$response" | jq -r '.artifact_count')
            echo "$count"
            return 0
        fi
    fi
    
    echo "0"
    return 1
}