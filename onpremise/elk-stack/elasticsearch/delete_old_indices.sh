#!/bin/bash

###################
# Global Variables #
###################

# Elasticsearch connection settings
ELASTIC_USER="elastic"
ELASTIC_PASSWORD="somaz123!"
ELASTIC_HOST="http://elasticsearch.somaz.link"

# Index names to clean (array)
INDEX_NAMES=()

# Default indices to clean if none specified
DEFAULT_INDICES=("" "")

# Retention period settings
# Minimum number of days to keep data
MIN_RETENTION_DAYS=7
# Default retention period in days
RETENTION_DAYS=30

# Force merge flag
FORCE_MERGE=false

# Date format
TODAY=$(date +%Y.%m.%d)

# Function to display help message
show_help() {
    cat << EOF
Usage: $(basename $0) [OPTIONS] [INDEX_NAMES...]

Delete old documents from specified Elasticsearch indices based on retention period.

Options:
    -h, --help              Show this help message
    -d, --days DAYS         Number of days to retain data (default: 30, minimum: ${MIN_RETENTION_DAYS})
    -i, --indices INDICES   Comma-separated list of index names to clean
    -l, --list             List all available indices
    -s, --status           Show current status of all indices
    -f, --force-merge      Force merge indices after deletion to optimize disk space

Examples:
    $(basename $0)                                    # Clean default indices (30 days retention)
    $(basename $0) -d 60                             # Clean default indices (60 days retention)
    $(basename $0) index1 index2                     # Clean specified indices (30 days retention)
    $(basename $0) -d 60 index1 index2               # Clean specified indices (60 days retention)
    $(basename $0) -i "index1,index2" -d 60          # Clean indices using comma-separated list
    $(basename $0) -l                                # List all available indices
    $(basename $0) -s                                # Show current status of all indices
    $(basename $0) -f index1                         # Clean and force merge index1
    $(basename $0) -d 60 -f index1 index2           # Clean with 60 days retention and force merge

Default indices to clean: ${DEFAULT_INDICES[@]}
Note: Minimum retention period is ${MIN_RETENTION_DAYS} days for safety.
EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -d|--days)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        -i|--indices)
            IFS=',' read -ra INDEX_NAMES <<< "$2"
            shift 2
            ;;
        -l|--list)
            echo "Available indices:"
            curl -s -k -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_HOST/_cat/indices?v" | awk 'NR>1 {print $3}' | sort
            exit 0
            ;;
        -s|--status)
            echo "Current status of all indices:"
            curl -s -k -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_HOST/_cat/indices"
            exit 0
            ;;
        -f|--force-merge)
            FORCE_MERGE=true
            shift
            ;;
        -*)
            echo "Unknown option $1" >&2
            echo "Try '$(basename $0) --help' for more information." >&2
            exit 1
            ;;
        *)
            INDEX_NAMES+=("$1")
            shift
            ;;
    esac
done

# Validate RETENTION_DAYS
if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo "Error: Days must be a positive number" >&2
    echo "Try '$(basename $0) --help' for more information." >&2
    exit 1
fi

if [ "$RETENTION_DAYS" -lt "$MIN_RETENTION_DAYS" ]; then
    echo "Error: Retention period cannot be less than ${MIN_RETENTION_DAYS} days" >&2
    echo "Try '$(basename $0) --help' for more information." >&2
    exit 1
fi

# If no indices specified, use default indices
if [ ${#INDEX_NAMES[@]} -eq 0 ]; then
    INDEX_NAMES=("${DEFAULT_INDICES[@]}")
fi

# Check OS type and use appropriate date command
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    THRESHOLD_DATE=$(date -v-${RETENTION_DAYS}d -u +"%Y-%m-%dT%H:%M:%S.000Z")
else
    # Linux
    THRESHOLD_DATE=$(date -d "-${RETENTION_DAYS} days" -u +"%Y-%m-%dT%H:%M:%S.000Z")
fi

# Loop through specified indices and delete old documents
echo "Indices to clean: ${INDEX_NAMES[@]}"
echo "Retention period: ${RETENTION_DAYS} days"
echo "Will delete documents older than: $THRESHOLD_DATE"
read -p "Are you sure you want to delete old documents from these indices? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

for INDEX in "${INDEX_NAMES[@]}"; do
    echo "Processing index: $INDEX"
    
    # Delete documents older than threshold date
    DELETE_QUERY='{
        "query": {
            "range": {
                "@timestamp": {
                    "lt": "'$THRESHOLD_DATE'"
                }
            }
        }
    }'
    
    echo "Deleting old documents from $INDEX..."
    RESPONSE=$(curl -s -k -u "$ELASTIC_USER:$ELASTIC_PASSWORD" \
        -X POST "$ELASTIC_HOST/$INDEX/_delete_by_query" \
        -H "Content-Type: application/json" \
        -d "$DELETE_QUERY")
    
    # Check if deletion was successful and extract deleted count
    if echo "$RESPONSE" | grep -q '"deleted"'; then
        DELETED_COUNT=$(echo "$RESPONSE" | grep -o '"deleted":[0-9]*' | cut -d':' -f2)
        echo "✓ Successfully deleted $DELETED_COUNT documents from index: $INDEX"
    else
        echo "✗ Failed to delete documents from index: $INDEX"
        echo "Response: $RESPONSE"
    fi

    # Force merge if enabled
    # Force merge if requested
    if [ "$FORCE_MERGE" = true ]; then
        echo "Force merging index: $INDEX..."
        MERGE_RESPONSE=$(curl -s -k -u "$ELASTIC_USER:$ELASTIC_PASSWORD" \
            -X POST "$ELASTIC_HOST/$INDEX/_forcemerge?only_expunge_deletes=true" \
            -H "Content-Type: application/json")
        
        # Check if force merge was successful
        if echo "$MERGE_RESPONSE" | grep -q '"successful"'; then
            echo "✓ Successfully force merged index: $INDEX"
        else
            echo "✗ Failed to force merge index: $INDEX"
            echo "Response: $MERGE_RESPONSE"
        fi
    fi
    echo "---"
done

echo "Document cleanup process completed."
