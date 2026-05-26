#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Harbor image management module
# Manages image-related functions

# Fetch image tags for a repository via Harbor V2 API
get_image_tags() {
    local repo=$1
    local page_size=100
    local all_images=""
    local total_count=0

    echo -e "${YELLOW}Fetching images from repository: $repo${NC}"

    local repo_encoded=""; repo_encoded=$(echo "$repo" | sed 's|/|%2F|g')
    local api_url="${HARBOR_PROTOCOL}://${HARBOR_URL}/api/v2.0/projects/$PROJECT_NAME/repositories/$repo_encoded/artifacts"

    echo -e "${YELLOW}Using Harbor V2 API: $api_url${NC}"

    # Fetch total count first
    local total_items=0
    local count_response=""; count_response=$(curl -s -k -H "Accept: application/json" -u "$HARBOR_USER:$HARBOR_PASS" "$api_url?page=1&page_size=1")

    if ! echo "$count_response" | jq . >/dev/null 2>&1; then
        echo -e "${RED}Error: invalid JSON response from server${NC}"
        return
    fi

    # Try to read count from header
    local header_info=""; header_info=$(curl -s -k -I -u "$HARBOR_USER:$HARBOR_PASS" "$api_url?page=1&page_size=1")
    if echo "$header_info" | grep -i "x-total-count" > /dev/null; then
        total_items=$(echo "$header_info" | grep -i "x-total-count" | awk '{print $2}' | tr -d '\r')
        echo -e "${GREEN}Total artifacts from header: $total_items${NC}"
    fi

    if [ -z "$total_items" ] || [ "$total_items" = "null" ] || [ "$total_items" -eq 0 ]; then
        total_items=500
    fi

    local pages_needed=$(( (total_items + page_size - 1) / page_size ))
    if [ "$pages_needed" -gt 10 ]; then
        pages_needed=10
    fi

    # Fetch artifacts page by page
    for ((page=1; page<=pages_needed; page++)); do
        echo -e "${YELLOW}Fetching page $page/$pages_needed${NC}"
        local page_url="$api_url?page=$page&page_size=$page_size&with_tag=true&with_label=false"

        local response=""; response=$(curl -s -k -H "Accept: application/json" -u "$HARBOR_USER:$HARBOR_PASS" "$page_url")

        if ! echo "$response" | jq . >/dev/null 2>&1; then
            echo -e "${RED}Error: invalid JSON response from server on page $page${NC}"
            continue
        fi

        local is_array=""; is_array=$(echo "$response" | jq 'if type=="array" then true else false end')
        local artifacts=""

        if [ "$is_array" = "true" ]; then
            artifacts="$response"
        else
            if echo "$response" | jq -e '.items' >/dev/null 2>&1; then
                artifacts=$(echo "$response" | jq '.items')
            else
                continue
            fi
        fi

        local page_count=""; page_count=$(echo "$artifacts" | jq '. | length')
        echo -e "${GREEN}Found $page_count artifacts on page $page${NC}"

        if [ "$page_count" -eq 0 ]; then
            break
        fi

        # Process artifacts
        for ((i=0; i<page_count; i++)); do
            local digest=""; digest=$(echo "$artifacts" | jq -r ".[$i].digest")

            if [ -z "$digest" ] || [ "$digest" = "null" ]; then
                continue
            fi

            if ! [[ "$digest" == "sha256:"* ]]; then
                continue
            fi

            local push_time=""
            if echo "$artifacts" | jq -e ".[$i].push_time" >/dev/null 2>&1; then
                push_time=$(echo "$artifacts" | jq -r ".[$i].push_time")
            elif echo "$artifacts" | jq -e ".[$i].created" >/dev/null 2>&1; then
                push_time=$(echo "$artifacts" | jq -r ".[$i].created")
            else
                push_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            fi

            local tags_count=0
            local tag_names=""

            if echo "$artifacts" | jq -e ".[$i].tags" >/dev/null 2>&1; then
                if echo "$artifacts" | jq -e ".[$i].tags | type == \"array\"" >/dev/null 2>&1; then
                    tags_count=$(echo "$artifacts" | jq -r ".[$i].tags | length")
                    if [ "$tags_count" -gt 0 ]; then
                        tag_names=$(echo "$artifacts" | jq -r ".[$i].tags[].name" | tr '\n' ',' | sed 's/,$//')
                    fi
                fi
            fi

            all_images="${all_images}${digest}\t${push_time}\t${tags_count}\t${tag_names}\n"
            total_count=$((total_count + 1))
        done
    done

    if [ -z "$all_images" ]; then
        echo -e "${YELLOW}No artifacts found in repository${NC}"
        return
    fi

    # Sort by push time (newest first)
    all_images=$(echo -e "$all_images" | sort -t $'\t' -k2,2r)
    echo -e "${GREEN}Total artifacts retrieved: $total_count${NC}"

    echo -e "$all_images"
}

# Delete a single image
delete_image() {
    local repo=$1
    local digest=$2

    if [ -z "$digest" ]; then
        echo -e "${RED}Error: empty digest, skipping deletion${NC}"
        return 1
    fi

    if ! [[ "$digest" == "sha256:"* ]]; then
        echo -e "${RED}Error: invalid digest format: $digest, skipping deletion${NC}"
        return 1
    fi

    digest=$(echo "$digest" | awk '{print $1}' | tr -d '\r' | tr -d '\n')

    if [ "$DEBUG" = true ]; then
        echo -e "${YELLOW}Deleting image by digest: $digest (repository: $PROJECT_NAME/$repo)${NC}"
    fi

    if [ "$DRY_RUN" = true ]; then
        if [ "$DEBUG" = true ]; then
            echo -e "${YELLOW}Dry-run mode: would delete image by digest: $digest${NC}"
        fi
        return 0
    fi

    local repo_encoded=""; repo_encoded=$(echo "$repo" | sed 's|/|%2F|g')
    local delete_url="${HARBOR_PROTOCOL}://${HARBOR_URL}/api/v2.0/projects/$PROJECT_NAME/repositories/$repo_encoded/artifacts/$digest"

    if [ "$DEBUG" = true ]; then
        echo -e "${YELLOW}Trying delete URL: $delete_url${NC}"
    fi

    local http_code=""
    http_code=$(curl -s -k -X DELETE \
        -u "$HARBOR_USER:$HARBOR_PASS" \
        -w "%{http_code}" -o /dev/null \
        "$delete_url")

    if [ "$DEBUG" = true ]; then
        echo -e "${YELLOW}HTTP status: $http_code${NC}"
    fi

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        if [ "$DEBUG" = true ]; then
            echo -e "${GREEN}Successfully deleted image by digest: $digest${NC}"
        fi
        return 0
    elif [ "$http_code" -eq 404 ]; then
        if [ "$DEBUG" = true ]; then
            echo -e "${YELLOW}Artifact not found: $digest (HTTP status: 404)${NC}"
        fi
        return 0
    else
        if [ "$DEBUG" = true ]; then
            echo -e "${RED}Failed to delete image: $digest (HTTP status: $http_code)${NC}"
        else
            echo -e "${RED}Failed to delete image: $digest${NC}"
        fi
        return 1
    fi
}

# Delete images in batches
delete_images_in_batches() {
    local REPO=$1
    local IMAGES_TO_DELETE=$2
    local DELETE_COUNT=$3

    echo -e "${GREEN}Proceeding with deletion...${NC}"
    local DELETED_COUNT=0
    local FAILED_COUNT=0

    if [ "$BATCH_SIZE" -lt 1 ]; then
        BATCH_SIZE=1
    fi

    echo -e "${YELLOW}Using batch size: $BATCH_SIZE${NC}"

    # Collect all digests
    local DIGESTS=()
    while read -r line; do
        [ -z "$line" ] && continue
        digest=$(echo "$line" | tr -d '\r' | tr -d '\n' | xargs)
        [ -z "$digest" ] && continue
        DIGESTS+=("$digest")
    done < <(echo -e "$IMAGES_TO_DELETE")

    local TOTAL_DIGESTS=${#DIGESTS[@]}
    printf "${GREEN}Found %s digests to process with batch size %s${NC}\n" "$TOTAL_DIGESTS" "$BATCH_SIZE"

    # Process in batches
    local BATCH_NUM=0
    for ((i=0; i<TOTAL_DIGESTS; i+=$BATCH_SIZE)); do
        BATCH_NUM=$((BATCH_NUM+1))
        local BATCH_START=$i
        local BATCH_END=$((i+BATCH_SIZE-1))
        [ $BATCH_END -ge $TOTAL_DIGESTS ] && BATCH_END=$((TOTAL_DIGESTS-1))

        echo -e "${YELLOW}Processing batch $BATCH_NUM (digests $((BATCH_START+1))-$((BATCH_END+1)) / $TOTAL_DIGESTS)${NC}"

        for ((j=BATCH_START; j<=BATCH_END; j++)); do
            local DIGEST="${DIGESTS[$j]}"
            local DIGEST_NUMBER=$((j+1))

            if [ "$DEBUG" = true ]; then
                echo -e "${YELLOW}Processing digest $DIGEST_NUMBER/$TOTAL_DIGESTS: $DIGEST${NC}"
            else
                if [ $((DIGEST_NUMBER % 10)) -eq 0 ] || [ "$DIGEST_NUMBER" -eq "$TOTAL_DIGESTS" ]; then
                    echo -ne "\rProcessing: $DIGEST_NUMBER/$TOTAL_DIGESTS"
                fi
            fi

            if delete_image "$REPO" "$DIGEST"; then
                if [ "$DEBUG" = true ]; then
                    echo -e "${GREEN}Successfully deleted digest $DIGEST_NUMBER/$TOTAL_DIGESTS${NC}"
                fi
                DELETED_COUNT=$((DELETED_COUNT+1))
            else
                if [ "$DEBUG" = true ]; then
                    echo -e "${RED}Failed to delete digest $DIGEST_NUMBER/$TOTAL_DIGESTS${NC}"
                fi
                FAILED_COUNT=$((FAILED_COUNT+1))
            fi
        done

        if [ "$DEBUG" = false ]; then
            echo ""
        fi

        printf "${GREEN}Batch %s complete: %s deleted so far, %s failed${NC}\n" "$BATCH_NUM" "$DELETED_COUNT" "$FAILED_COUNT"

        [ $BATCH_END -lt $((TOTAL_DIGESTS-1)) ] && sleep 1
    done

    printf "${GREEN}Deletion summary: %s artifacts deleted successfully, %s artifacts failed to delete.${NC}\n" "$DELETED_COUNT" "$FAILED_COUNT"
}