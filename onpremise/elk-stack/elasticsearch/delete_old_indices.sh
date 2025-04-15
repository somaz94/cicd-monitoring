#!/bin/bash

###################
# Global Variables #
###################

# Elasticsearch connection settings
ELASTIC_USER="elastic"
ELASTIC_PASSWORD="somaz123!"
ELASTIC_HOST="https://elasticsearch.somaz.link"

# Index pattern to match
INDEX_PATTERN="logstash-"

# Retention period settings
# Minimum number of days to keep indices
MIN_RETENTION_DAYS=7
# Default retention period in days
RETENTION_DAYS=30

# Date format
TODAY=$(date +%Y.%m.%d)

# Function to display help message
show_help() {
    cat << EOF
Usage: $(basename $0) [OPTIONS]

Delete Elasticsearch indices older than specified retention period.

Options:
    -h, --help      Show this help message
    -d, --days DAYS Number of days to retain indices (default: 30, minimum: ${MIN_RETENTION_DAYS})

Examples:
    $(basename $0)         # Delete indices older than 30 days
    $(basename $0) -d 60   # Delete indices older than 60 days
    $(basename $0) --days 60   # Same as above

Note: Minimum retention period is ${MIN_RETENTION_DAYS} days for safety.
EOF
    exit 0
}

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        --help)
            show_help
            ;;
        --days=*)
            RETENTION_DAYS="${arg#*=}"
            shift
            ;;
        --days)
            RETENTION_DAYS="$2"
            shift 2
            ;;
    esac
done

# Parse short options
OPTIND=1
while getopts "hd:" opt; do
    case $opt in
        h) show_help
        ;;
        d) RETENTION_DAYS="$OPTARG"
        ;;
        \?) echo "Invalid option -$OPTARG" >&2
            echo "Try '$(basename $0) --help' for more information." >&2
            exit 1
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

# Check OS type and use appropriate date command
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    THRESHOLD_DATE=$(date -v-${RETENTION_DAYS}d +%Y.%m.%d)
else
    # Linux
    THRESHOLD_DATE=$(date -d "-${RETENTION_DAYS} days" +%Y.%m.%d)
fi

# Get all indices with error handling
ALL_INDICES=$(curl -s -k -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_HOST/_cat/indices?v" | awk '{print $3}' | grep "^${INDEX_PATTERN}" || echo "")

# Check if curl command was successful
if [ -z "$ALL_INDICES" ]; then
    echo "Error: Failed to retrieve indices or no indices found"
    exit 1
fi

# Loop through indices and delete the ones older than the threshold
for INDEX in $ALL_INDICES; do
    # Extract the date part of the index
    INDEX_DATE=$(echo "$INDEX" | sed -E 's/logstash-(.+)/\1/')
    
    # Validate date format
    if [[ ! "$INDEX_DATE" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]]; then
        echo "Warning: Skipping $INDEX - Invalid date format"
        continue
    fi

    # Check if the index date is older than the threshold
    if [[ "$INDEX_DATE" < "$THRESHOLD_DATE" ]]; then
        echo "Deleting index: $INDEX (older than $THRESHOLD_DATE)"
        RESPONSE=$(curl -s -k -u "$ELASTIC_USER:$ELASTIC_PASSWORD" -X DELETE "$ELASTIC_HOST/$INDEX")
        if [[ $? -ne 0 ]]; then
            echo "Error deleting index $INDEX: $RESPONSE"
        fi
    else
        echo "Skipping index: $INDEX (newer than or equal to $THRESHOLD_DATE)"
    fi
done
