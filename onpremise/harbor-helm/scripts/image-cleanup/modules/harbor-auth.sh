#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Harbor auth module
# Manages authentication-related functions

# Obtain an auth token
get_auth_token() {
    local token
    local url="${HARBOR_PROTOCOL}://${HARBOR_URL}/service/token"
    echo -e "${YELLOW}Attempting to obtain token: $url${NC}"

    # Debug: print the full curl command
    debug_print "Curl command: curl -s -k -X POST -H \"Content-Type: application/x-www-form-urlencoded\" -d \"principal=$HARBOR_USER&password=***\" \"$url\""

    local response=""
    response=$(curl -s -k -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "principal=$HARBOR_USER&password=$HARBOR_PASS" \
        "$url")

    # Debug: print raw response
    debug_print "Raw response: $response"

    # Ensure the response is valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        echo -e "${RED}Error: invalid JSON response from server${NC}"
        echo "$response"
        return 1
    fi

    token=$(echo "$response" | jq -r '.token')

    if [ -z "$token" ] || [ "$token" = "null" ]; then
        echo -e "${RED}Error: failed to obtain auth token${NC}"
        echo -e "${RED}Server response:${NC}"
        echo "$response"
        return 1
    fi

    echo "$token"
}