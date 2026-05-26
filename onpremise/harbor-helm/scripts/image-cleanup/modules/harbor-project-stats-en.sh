#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Harbor Project Statistics Module (English Version) - Simple Version
# Description: Module for querying artifact counts by repository for specific Harbor projects

# Show repository statistics for a specific project
show_project_repositories_stats() {
    local project_name="$1"
    
    if [[ -z "$project_name" ]]; then
        echo -e "${RED}Error: Project name is required.${NC}"
        echo -e "${YELLOW}Usage: show_project_repositories_stats <project_name>${NC}"
        return 1
    fi
    
    echo -e "${GREEN}=== Repository Artifact Counts for Project '${project_name}' ===${NC}\n"
    
    # Query repository list for the project via Harbor API
    echo -e "${YELLOW}Fetching repository list...${NC}"
    
    local api_url="${HARBOR_PROTOCOL}://${HARBOR_URL}/api/v2.0/projects/${project_name}/repositories"
    local response=""
    
    response=$(curl -s -k -H "Accept: application/json" -u "$HARBOR_USER:$HARBOR_PASS" "$api_url")
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Error: Failed to call Harbor API.${NC}"
        return 1
    fi
    
    # Check if JSON response is empty or contains errors
    if [[ -z "$response" ]] || echo "$response" | grep -q '"errors"'; then
        echo -e "${RED}Error: Cannot fetch repository list for project '${project_name}'.${NC}"
        echo "Response: $response"
        return 1
    fi
    
    # Check if response is a JSON array
    if ! echo "$response" | jq -e '. | type == "array"' >/dev/null 2>&1; then
        echo -e "${RED}Error: Unexpected response format.${NC}"
        return 1
    fi
    
    # Check repository count
    local repo_count=""
    repo_count=$(echo "$response" | jq '. | length' 2>/dev/null)
    
    if [[ -z "$repo_count" ]] || [[ "$repo_count" == "0" ]]; then
        echo -e "${YELLOW}No repositories found in project '${project_name}'.${NC}"
        return 0
    fi
    
    echo -e "${GREEN}Found ${repo_count} repositories in total.${NC}\n"
    
    # Print table header
    printf "%-4s %-40s %-15s %-20s\n" "No." "Repository Name" "Artifact Count" "Last Updated"
    printf "%-4s %-40s %-15s %-20s\n" "----" "----------------------------------------" "---------------" "--------------------"
    
    local total_artifacts=0
    local repo_number=1
    
    # Process each repository's information
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
        
        # Format time (from ISO 8601 to readable format)
        if [[ "$update_time" != "N/A" ]] && [[ "$update_time" != "null" ]]; then
            update_time=$(echo "$update_time" | sed 's/T/ /' | sed 's/\.[0-9]*Z$//')
        fi
        
        # Color coding based on artifact count
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
        
        # Remove project name from repository name for cleaner display
        local clean_repo_name=""
        clean_repo_name=$(echo "$repo_name" | sed "s|^${project_name}/||")
        
        printf "${color_code}%-4d %-40s %-15d %-20s${NC}\n" \
            "$repo_number" "$clean_repo_name" "$artifact_count" "$update_time"
        
        total_artifacts=$((total_artifacts + artifact_count))
        repo_number=$((repo_number + 1))
        
    done < <(echo "$response" | jq -c '.[]')
    
    # Print summary information
    echo -e "\n${GREEN}=== Summary ===${NC}"
    echo -e "${YELLOW}Total Repositories:${NC} $repo_count"
    echo -e "${YELLOW}Total Artifacts:${NC} $total_artifacts"
    echo -e "${YELLOW}Average Artifacts per Repository:${NC} $(( repo_count > 0 ? total_artifacts / repo_count : 0 ))"
    
    return 0
}

# Help function
show_stats_help() {
    echo -e "${GREEN}=== Harbor Project Repository Statistics Help ===${NC}\n"
    
    echo -e "${YELLOW}Available Functions:${NC}"
    echo -e "${CYAN}  show_project_repositories_stats <project_name>${NC} - Show artifact counts by repository for a specific project"
    echo -e "${CYAN}  show_stats_help${NC}                                - Show this help message"
    
    echo -e "\n${YELLOW}Usage Examples:${NC}"
    echo -e "${GREEN}  # Show all repository statistics for example-project${NC}"
    echo -e "  show_project_repositories_stats example-project"
    
    echo -e "\n${GREEN}  # Show all repository statistics for projecta${NC}"
    echo -e "  show_project_repositories_stats projecta"
    
    echo -e "\n${YELLOW}Color Meanings:${NC}"
    echo -e "${RED}  Red${NC} - More than 100 artifacts"
    echo -e "${YELLOW}  Yellow${NC} - 11-100 artifacts"
    echo -e "${GREEN}  Green${NC} - 10 or fewer artifacts"
    
    echo -e "\n${YELLOW}Notes:${NC}"
    echo -e "  • harbor-config-en.sh must be loaded before using this module."
    echo -e "  • HARBOR_URL, HARBOR_USER, HARBOR_PASS variables must be set."
}

# Handle direct execution of this module
# Main-or-source guard — zsh lacks BASH_SOURCE; :-} fallback gives empty string so the guard passes naturally.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    echo -e "${YELLOW}This module should be loaded via source from another script.${NC}"
    echo -e "${CYAN}Usage: source harbor-project-stats-en.sh${NC}"
    exit 1
fi
