#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Harbor project stats module — simple version
# Description: fetches per-repository artifact counts for a given Harbor project

# Fetch all repositories and artifact counts for a given project
show_project_repositories_stats() {
    local project_name="$1"

    if [[ -z "$project_name" ]]; then
        echo -e "${RED}Error: project name is required.${NC}"
        echo -e "${YELLOW}Usage: show_project_repositories_stats <project>${NC}"
        return 1
    fi

    echo -e "${GREEN}=== Per-repository artifact counts for project '${project_name}' ===${NC}\n"

    # Fetch repository list for the project via the Harbor API
    echo -e "${YELLOW}Fetching repository list...${NC}"

    local api_url="${HARBOR_PROTOCOL}://${HARBOR_URL}/api/v2.0/projects/${project_name}/repositories"
    local response=""

    response=$(curl -s -k -H "Accept: application/json" -u "$HARBOR_USER:$HARBOR_PASS" "$api_url")

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Error: Harbor API call failed.${NC}"
        return 1
    fi

    # Check whether the JSON response is empty or contains an error
    if [[ -z "$response" ]] || echo "$response" | grep -q '"errors"'; then
        echo -e "${RED}Error: could not fetch repositories for project '${project_name}'.${NC}"
        echo "Response: $response"
        return 1
    fi

    # Ensure the response is a JSON array
    if ! echo "$response" | jq -e '. | type == "array"' >/dev/null 2>&1; then
        echo -e "${RED}Error: unexpected response format.${NC}"
        return 1
    fi

    # Count repositories
    local repo_count=""
    repo_count=$(echo "$response" | jq '. | length' 2>/dev/null)

    if [[ -z "$repo_count" ]] || [[ "$repo_count" == "0" ]]; then
        echo -e "${YELLOW}Project '${project_name}' has no repositories.${NC}"
        return 0
    fi

    echo -e "${GREEN}Found ${repo_count} repositories total.${NC}\n"

    # Print table header
    printf "%-4s %-40s %-15s %-20s\n" "NO" "REPOSITORY NAME" "ARTIFACTS" "LAST UPDATED"
    printf "%-4s %-40s %-15s %-20s\n" "----" "----------------------------------------" "---------------" "--------------------"

    local total_artifacts=0
    local repo_number=1

    # Process each repository's info
    while read -r repo_data; do
        if [[ -z "$repo_data" ]] || [[ "$repo_data" == "null" ]]; then
            continue
        fi

        local repo_name
        local artifact_count
        local update_time

        repo_name=$(echo "$repo_data" | jq -r '.name')
        artifact_count=$(echo "$repo_data" | jq -r '.artifact_count // 0')
        update_time=$(echo "$repo_data" | jq -r '.update_time // "N/A"')

        # Format timestamp (ISO 8601 → human readable)
        if [[ "$update_time" != "N/A" ]] && [[ "$update_time" != "null" ]]; then
            update_time=$(echo "$update_time" | sed 's/T/ /' | sed 's/\.[0-9]*Z$//')
        fi

        # Color based on artifact count
        local color_code=""
        if [[ $artifact_count -gt 100 ]]; then
            color_code="$RED"
        elif [[ $artifact_count -gt 50 ]]; then
            color_code="$YELLOW"
        elif [[ $artifact_count -gt 10 ]]; then
            color_code="${YELLOW}"
        else
            color_code="$GREEN"
        fi

        # Strip project prefix from repository name (for readability)
        local clean_repo_name=""
        clean_repo_name=$(echo "$repo_name" | sed "s|^${project_name}/||")

        printf "${color_code}%-4d %-40s %-15d %-20s${NC}\n" \
            "$repo_number" "$clean_repo_name" "$artifact_count" "$update_time"

        total_artifacts=$((total_artifacts + artifact_count))
        repo_number=$((repo_number + 1))

    done < <(echo "$response" | jq -c '.[]')

    # Print summary
    echo -e "\n${GREEN}=== Summary ===${NC}"
    echo -e "${YELLOW}Total repositories:${NC} $repo_count"
    echo -e "${YELLOW}Total artifacts:${NC} $total_artifacts"
    echo -e "${YELLOW}Average artifacts:${NC} $(( repo_count > 0 ? total_artifacts / repo_count : 0 ))"

    return 0
}

# Help function
show_stats_help() {
    echo -e "${GREEN}=== Harbor project repository stats help ===${NC}\n"

    echo -e "${YELLOW}Available functions:${NC}"
    echo -e "${CYAN}  show_project_repositories_stats <project>${NC} - Show per-repository artifact counts for a project"
    echo -e "${CYAN}  show_stats_help${NC}                              - Show this help"

    echo -e "\n${YELLOW}Examples:${NC}"
    echo -e "${GREEN}  # Stats for all repositories in the example-project project${NC}"
    echo -e "  show_project_repositories_stats example-project"

    echo -e "\n${GREEN}  # Stats for all repositories in the projecta project${NC}"
    echo -e "  show_project_repositories_stats projecta"

    echo -e "\n${YELLOW}Color legend:${NC}"
    echo -e "${RED}  Red${NC} - artifact count > 100"
    echo -e "${YELLOW}  Yellow${NC} - artifact count 11-100"
    echo -e "${GREEN}  Green${NC} - artifact count <= 10"

    echo -e "\n${YELLOW}Notes:${NC}"
    echo -e "  • harbor-config.sh must be loaded before using this module."
    echo -e "  • HARBOR_URL, HARBOR_USER, HARBOR_PASS variables must be set."
}

# Behavior when this module is executed directly
# Main-or-source guard — zsh lacks BASH_SOURCE; :-} fallback gives empty string so the guard passes naturally.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    echo -e "${YELLOW}This module must be sourced from another script.${NC}"
    echo -e "${CYAN}Usage: source harbor-project-stats.sh${NC}"
    exit 1
fi
