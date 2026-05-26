#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Harbor Authentication Module
# Manages authentication-related functions

# Function to get authentication token
get_auth_token() {
    local token
    local url="${HARBOR_PROTOCOL}://${HARBOR_URL}/service/token"
    echo -e "${YELLOW}Attempting to get token from: $url${NC}"
    
    # Debug: Print the full curl command
    debug_print "Curl command: curl -s -k -X POST -H \"Content-Type: application/x-www-form-urlencoded\" -d \"principal=$HARBOR_USER&password=***\" \"$url\""
    
    local response=""
    response=$(curl -s -k -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "principal=$HARBOR_USER&password=$HARBOR_PASS" \
        "$url")
    
    # Debug: Print raw response
    debug_print "Raw response: $response"
    
    # Check if response is valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        echo -e "${RED}Error: Invalid JSON response from server${NC}"
        echo "$response"
        return 1
    fi
    
    token=$(echo "$response" | jq -r '.token')
    
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        echo -e "${RED}Error: Failed to get authentication token${NC}"
        echo -e "${RED}Response from server:${NC}"
        echo "$response"
        return 1
    fi
    
    echo "$token"
} 