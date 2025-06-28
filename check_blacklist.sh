# check_blacklist.sh - Check if an SMTP domain is listed on RBLs (Real-time Blackhole Lists)
# using MXToolbox and/or HetrixTools service APIs, designed for integration with Zabbix monitoring.
#
# Purpose:
#   This script queries the MXToolbox and/or HetrixTools APIs to check if a specified domain is listed
#   on email blacklists. It consolidates results, deduplicates blacklist names, and outputs JSON for
#   Zabbix with the state (OK, WARNING, CRITICAL, UNKNOWN), blacklist count, names, and a message.
#
# Usage:
#   check_blacklist.sh -d <domain> [-m <mxtoolbox_api_key>] [-x <hetrix_api_key>] [-w <warning_count>] [-c <critical_count>] [-v] [-h]
#
# Note: 
#   At least one API key (-m for MXToolbox or -x for HetrixTools) or both is required to perform the checks.
#
# Options:
#   -d <domain>             Required: Domain name to check (e.g., example.com).
#   -m <mxtoolbox_api_key>  Optional: MXToolbox API key for blacklist lookup.
#   -x <hetrix_api_key>     Optional: HetrixTools API key for blacklist lookup.
#   -w <warning_count>      Optional: Number of blacklists to trigger WARNING state (default: 1).
#   -c <critical_count>     Optional: Number of blacklists to trigger CRITICAL state (default: 2).
#   -v                      Display script version and exit.
#   -h                      Display this help message and exit.
#
# Output:
#   JSON object for Zabbix with the following fields:
#     - state: "OK" (no issues), "WARNING" (>= warning_count), "CRITICAL" (>= critical_count), or "UNKNOWN" (error).
#     - blacklist_count: Number of unique blacklists the domain is listed on.
#     - blacklist_names: Comma-separated list of RBLs or "none" if not listed.
#     - message: Details of API calls, including HTTP status, response size, and errors (if any).
#
# Example:
#   check_blacklist.sh -d example.com -m XXXXX-XXXXX-XXXXX-XXXXX
#   check_blacklist.sh -d example.com -x XXXXXXXXXXXXXXXXXXXXXXXXX
#   check_blacklist.sh -d example.com -m XXXXX-XXXXX-XXXXX-XXXXX -x XXXXXXXXXXXXXXXXXXXXXXXXX
#   Output: {"state":"OK","blacklist_count":"0","blacklist_names":"none","message":"MXTOOLBOX check for example.com, HTTP status: 200, response size: 4563 bytes; HETRIXTOOLS check for example.com, HTTP status: 200, response size: 584 bytes, api_calls_left: 1938, blacklist_check_credits_left: 90"}
#
# Dependencies:
#   - curl: For making HTTP requests to APIs.
#   - jq: For parsing JSON responses from APIs.
#   - xargs: For trimming whitespace from blacklist names.
#
# Notes:
#   - At least one API key (-m or -x) is required.
#   - Critical threshold count must be greater than Warning threshold count.
#   - Blacklist names from MXToolbox (e.g., "SURBL multi") are normalized to HetrixTools format (e.g., "multi.surbl.org") for deduplication.
#   - Temporary files are stored in a unique directory (e.g., /tmp/check_blacklist.XXXXXX) and cleaned up on exit.
#   - HetrixTools API may return rate limit errors; the script handles this by reporting UNKNOWN state.
#   - Debug logs are written to $tmpdir/debug.txt, $tmpdir/mxtoolbox_raw_names.txt, and $tmpdir/hetrix_raw_names.txt for troubleshooting.

#!/bin/sh

# Default values
VERSION="1.0.0"
WARNING_COUNT=1
CRITICAL_COUNT=2
MXTOOLBOX_SERVICE="https://mxtoolbox.com/api/v1/lookup/blacklist"
HETRIXTOOLS_SERVICE="https://api.hetrixtools.com/v2"
TIMEOUT=300
MAX_RETRIES=3
MXT_API_KEY=""
HETRIX_API_KEY=""

# Create temporary directory
tmpdir=$(mktemp -d -t check_blacklist.XXXXXX 2>/dev/null || echo "${TMPDIR:-/tmp}/check_blacklist_$$_$RANDOM")
[ -d "$tmpdir" ] || mkdir -p "$tmpdir" || {
    echo "{\"state\":\"UNKNOWN\",\"blacklist_count\":\"0\",\"blacklist_names\":\"none\",\"message\":\"UNKNOWN: Cannot create temporary directory\"}"
    exit 1
}

# Cleanup on exit
trap 'rm -rf "$tmpdir"' EXIT

# Print usage information
usage() {
    echo "Usage: $0 -d <domain> [-m <mxtoolbox_api_key>] [-x <hetrix_api_key>] [-w <warning_count>] [-c <critical_count>] [-v] [-h]"
    echo "  -d   Domain name to check (e.g., example.com)"
    echo "  -m   MXToolbox API key (optional, required for MXToolbox check)"
    echo "  -x   HetrixTools API key (optional, required for HetrixTools API check)"
    echo "  -w   Number of blacklists for WARNING state (default: $WARNING_COUNT)"
    echo "  -c   Number of blacklists for CRITICAL state (default: $CRITICAL_COUNT)"
    echo "  -v   Display version and exit"
    echo "  -h   Display this help and exit"
    exit 3
}

# Normalize blacklist names (map MXToolbox names to HetrixTools DNS-style names)
normalize_blacklist_name() {
    local name="$1"
    case "$name" in
        "SURBL multi") echo "multi.surbl.org" ;;
        "Nordspam DBL") echo "NordSpam" ;;
        "Spamhaus DBL") echo "dbl.spamhaus.org" ;;
        "ivmURI") echo "invaluement URI" ;;
        *) echo "$name" ;;
    esac
}

# Check for version or help flag first
while getopts "d:m:x:w:c:vh" opt; do
    case $opt in
        v) echo "$VERSION"; exit 0 ;;
        h) usage ;;
        *) ;; # Handle other options later
    esac
done

# Reset getopts to parse other options
OPTIND=1
while getopts "d:m:x:w:c:vh" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        m) MXT_API_KEY="$OPTARG" ;;
        x) HETRIX_API_KEY="$OPTARG" ;;
        w) WARNING_COUNT="$OPTARG" ;;
        c) CRITICAL_COUNT="$OPTARG" ;;
        v|h) ;; # Already handled
        *) usage ;;
    esac
done

# Validate required parameters
if [ -z "$DOMAIN" ]; then
    echo "{\"state\":\"UNKNOWN\",\"blacklist_count\":\"0\",\"blacklist_names\":\"none\",\"message\":\"UNKNOWN: Domain not specified\"}"
    exit 3
fi
if [ -z "$MXT_API_KEY" ] && [ -z "$HETRIX_API_KEY" ]; then
    echo "{\"state\":\"UNKNOWN\",\"blacklist_count\":\"0\",\"blacklist_names\":\"none\",\"message\":\"UNKNOWN: At least one API key (MXToolbox or HetrixTools) must be provided\"}"
    exit 3
fi

# Validate numeric inputs
case "$WARNING_COUNT" in
    ''|*[!0-9]*) echo "{\"state\":\"UNKNOWN\",\"blacklist_count\":\"0\",\"blacklist_names\":\"none\",\"message\":\"UNKNOWN: Warning threshold must be a number\"}"; exit 3 ;;
esac
case "$CRITICAL_COUNT" in
    ''|*[!0-9]*) echo "{\"state\":\"UNKNOWN\",\"blacklist_count\":\"0\",\"blacklist_names\":\"none\",\"message\":\"UNKNOWN: Critical threshold must be a number\"}"; exit 3 ;;
esac

# Ensure critical count is strictly greater than warning count
if [ "$CRITICAL_COUNT" -le "$WARNING_COUNT" ]; then
    echo "{\"state\":\"UNKNOWN\",\"blacklist_count\":\"0\",\"blacklist_names\":\"none\",\"message\":\"UNKNOWN: Critical threshold must be greater than Warning threshold\"}"
    exit 3
fi

# Check if curl is installed
if ! command -v curl >/dev/null 2>&1; then
    echo "{\"state\":\"UNKNOWN\",\"blacklist_count\":\"0\",\"blacklist_names\":\"none\",\"message\":\"UNKNOWN: curl not installed\"}"
    exit 1
fi

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
    echo "{\"state\":\"UNKNOWN\",\"blacklist_count\":\"0\",\"blacklist_names\":\"none\",\"message\":\"UNKNOWN: jq not installed\"}"
    exit 1
fi

# Check if xargs is installed
if ! command -v xargs >/dev/null 2>&1; then
    echo "{\"state\":\"UNKNOWN\",\"blacklist_count\":\"0\",\"blacklist_names\":\"none\",\"message\":\"UNKNOWN: xargs not installed\"}"
    exit 1
fi

# Initialize variables for consolidated results
BLACKLIST_COUNT=0
BLACKLIST_NAMES=""
MESSAGE=""
MXT_MESSAGE=""
HETRIX_MESSAGE=""
MXT_STATUS=1
HETRIX_STATUS=1
HETRIX_RATE_LIMITED=0

# Function to query MXToolbox v1 API
query_mxtoolbox() {
    local retry=0
    local response=""
    local curl_exit=0
    local http_status=""
    local response_size=0
    local curl_error=""

    while [ $retry -le $MAX_RETRIES ]; do
        response=$(curl -4 -s -L -m "$TIMEOUT" -H "User-Agent: Mozilla/5.0 (curl)" "$MXTOOLBOX_SERVICE/$DOMAIN?authorization=$MXT_API_KEY" 2>"$tmpdir/mxtoolbox_curl_error")
        curl_exit=$?
        echo "$response" > "$tmpdir/mxtoolbox_response.txt"
        curl -4 -s -L -m "$TIMEOUT" -H "User-Agent: Mozilla/5.0 (curl)" -w "%{http_code}" "$MXTOOLBOX_SERVICE/$DOMAIN?authorization=$MXT_API_KEY" -o /dev/null 2>"$tmpdir/mxtoolbox_curl_error" > "$tmpdir/mxtoolbox_status.txt"
        response_size=$(wc -c < "$tmpdir/mxtoolbox_response.txt" 2>/dev/null || echo 0)
        http_status=$(cat "$tmpdir/mxtoolbox_status.txt" 2>/dev/null || echo "unknown")

        if [ $curl_exit -eq 0 ]; then
            if echo "$response" | grep -qi 'Invalid ApiKey'; then
                curl_error="MXToolbox API error: $(echo "$response" | sed 's/"/\\"/g')"
            elif echo "$response" | jq -e '. | has("Passed") or has("Failed") or has("Errors")' >/dev/null 2>&1; then
                MXT_COUNT=$(echo "$response" | jq '.Failed | length')
                MXT_NAMES=""
                echo "$response" | jq -r '.Failed[].Name' > "$tmpdir/mxtoolbox_raw_names.txt"
                while IFS= read -r name; do
                    if [ -n "$name" ]; then
                        normalized_name=$(normalize_blacklist_name "$name")
                        normalized_name=$(echo "$normalized_name" | xargs)
                        if [ -z "$MXT_NAMES" ]; then
                            MXT_NAMES="$normalized_name"
                        else
                            MXT_NAMES="$MXT_NAMES,$normalized_name"
                        fi
                    fi
                done < "$tmpdir/mxtoolbox_raw_names.txt"
                echo "MXT_NAMES: '$MXT_NAMES'" >> "$tmpdir/debug.txt"
                MXT_MESSAGE="MXTOOLBOX check for $DOMAIN, HTTP status: $http_status, response size: $response_size bytes"
                return 0
            else
                curl_error="MXToolbox response lacks expected JSON structure (size: $response_size bytes)"
            fi
        else
            curl_error=$(cat "$tmpdir/mxtoolbox_curl_error" 2>/dev/null || echo "unknown curl error")
        fi

        retry=$((retry + 1))
        if [ $retry -le $MAX_RETRIES ]; then
            sleep 2
        else
            MXT_MESSAGE="MXTOOLBOX check for $DOMAIN, HTTP status: $http_status, response size: $response_size bytes, error: $curl_error"
            return 1
        fi
    done
}

# Function to query HetrixTools v2 API
query_hetrixtools() {
    local retry=0
    local response=""
    local curl_exit=0
    local http_status=""
    local response_size=0
    local curl_error=""
    local api_calls_left="unknown"
    local blacklist_check_credits_left="unknown"

    while [ $retry -le $MAX_RETRIES ]; do
        response=$(curl -4 -s -L -m "$TIMEOUT" -H "User-Agent: Mozilla/5.0 (curl)" -H "Accept: application/json" "$HETRIXTOOLS_SERVICE/$HETRIX_API_KEY/blacklist-check/domain/$DOMAIN/" 2>"$tmpdir/hetrix_curl_error" -D "$tmpdir/hetrix_headers.txt")
        curl_exit=$?
        echo "$response" > "$tmpdir/hetrix_response.txt"
        curl -4 -s -L -m "$TIMEOUT" -H "User-Agent: Mozilla/5.0 (curl)" -H "Accept: application/json" -w "%{http_code}" "$HETRIXTOOLS_SERVICE/$HETRIX_API_KEY/blacklist-check/domain/$DOMAIN/" -o /dev/null 2>"$tmpdir/hetrix_curl_error" > "$tmpdir/hetrix_status.txt"
        response_size=$(wc -c < "$tmpdir/hetrix_response.txt" 2>/dev/null || echo 0)
        http_status=$(cat "$tmpdir/hetrix_status.txt" 2>/dev/null || echo "unknown")
        api_calls_left=$(echo "$response" | jq -r '.api_calls_left // "unknown"')
        blacklist_check_credits_left=$(echo "$response" | jq -r '.blacklist_check_credits_left // "unknown"')

        if [ $curl_exit -eq 0 ]; then
            if echo "$response" | jq -e '. | has("status")' >/dev/null 2>&1; then
                if echo "$response" | jq -e '.status == "ERROR"' >/dev/null 2>&1; then
                    curl_error="HetrixTools API error: $(echo "$response" | jq -r '.error_message' | sed 's/"/\\"/g')"
                elif echo "$response" | jq -e '. | has("blacklisted_count")' >/dev/null 2>&1; then
                    if [ "$api_calls_left" != "unknown" ] && [ "$api_calls_left" -le 0 ] || [ "$blacklist_check_credits_left" != "unknown" ] && [ "$blacklist_check_credits_left" -le 0 ]; then
                        HETRIX_MESSAGE="UNKNOWN: HETRIXTOOLS rate limit reached, api_calls_left: $api_calls_left, blacklist_check_credits_left: $blacklist_check_credits_left"
                        HETRIX_RATE_LIMITED=1
                        return 1
                    fi
                    HETRIX_COUNT=$(echo "$response" | jq '.blacklisted_count')
                    HETRIX_NAMES=""
                    echo "$response" | jq -r '.blacklisted_on[].rbl' > "$tmpdir/hetrix_raw_names.txt"
                    while IFS= read -r name; do
                        if [ -n "$name" ]; then
                            name=$(echo "$name" | xargs)
                            if [ -z "$HETRIX_NAMES" ]; then
                                HETRIX_NAMES="$name"
                            else
                                HETRIX_NAMES="$HETRIX_NAMES,$name"
                            fi
                        fi
                    done < "$tmpdir/hetrix_raw_names.txt"
                    echo "HETRIX_NAMES: '$HETRIX_NAMES'" >> "$tmpdir/debug.txt"
                    HETRIX_MESSAGE="HETRIXTOOLS check for $DOMAIN, HTTP status: $http_status, response size: $response_size bytes, api_calls_left: $api_calls_left, blacklist_check_credits_left: $blacklist_check_credits_left"
                    return 0
                else
                    curl_error="HetrixTools response lacks expected JSON structure (size: $response_size bytes)"
                fi
            else
                curl_error="HetrixTools response lacks status field (size: $response_size bytes)"
            fi
        else
            curl_error=$(cat "$tmpdir/hetrix_curl_error" 2>/dev/null || echo "unknown curl error")
        fi

        retry=$((retry + 1))
        if [ "$api_calls_left" = "0" ]; then
            sleep 60
        elif [ $retry -le $MAX_RETRIES ]; then
            sleep 3
        else
            HETRIX_MESSAGE="HETRIXTOOLS check for $DOMAIN, HTTP status: $http_status, response size: $response_size bytes, api_calls_left: $api_calls_left, blacklist_check_credits_left: $blacklist_check_credits_left, error: $curl_error"
            return 1
        fi
    done
}

# Query services based on provided keys
MXT_COUNT=0
MXT_NAMES=""
HETRIX_COUNT=0
HETRIX_NAMES=""
if [ -n "$MXT_API_KEY" ]; then
    query_mxtoolbox
    MXT_STATUS=$?
fi
if [ -n "$HETRIX_API_KEY" ]; then
    sleep 3
    query_hetrixtools
    HETRIX_STATUS=$?
fi

# Build message
if [ -n "$MXT_API_KEY" ]; then
    MESSAGE="$MXT_MESSAGE"
fi
if [ -n "$HETRIX_API_KEY" ]; then
    if [ -n "$MESSAGE" ]; then
        MESSAGE="$MESSAGE; $HETRIX_MESSAGE"
    else
        MESSAGE="$HETRIX_MESSAGE"
    fi
fi

# Consolidate results
BLACKLIST_COUNT=0
BLACKLIST_NAMES=""
if [ -n "$MXT_API_KEY" ] && [ -n "$HETRIX_API_KEY" ]; then
    : > "$tmpdir/blacklist_names.txt"
    if [ $MXT_STATUS -eq 0 ] && [ -n "$MXT_NAMES" ]; then
        echo "$MXT_NAMES" | tr ',' '\n' | while IFS= read -r name; do
            name=$(echo "$name" | xargs)
            echo "$name" >> "$tmpdir/blacklist_names.txt"
        done
    fi
    if [ $HETRIX_STATUS -eq 0 ] && [ -n "$HETRIX_NAMES" ]; then
        echo "$HETRIX_NAMES" | tr ',' '\n' | while IFS= read -r name; do
            name=$(echo "$name" | xargs)
            echo "$name" >> "$tmpdir/blacklist_names.txt"
        done
    fi
    if [ -s "$tmpdir/blacklist_names.txt" ]; then
        BLACKLIST_NAMES=$(sort -u "$tmpdir/blacklist_names.txt" | tr '\n' ',' | sed 's/,$//')
        BLACKLIST_COUNT=$(sort -u "$tmpdir/blacklist_names.txt" | wc -l | xargs)
    fi
    echo "Consolidated BLACKLIST_NAMES: '$BLACKLIST_NAMES'" >> "$tmpdir/debug.txt"
    echo "Consolidated BLACKLIST_COUNT: '$BLACKLIST_COUNT'" >> "$tmpdir/debug.txt"
elif [ -n "$MXT_API_KEY" ] && [ $MXT_STATUS -eq 0 ]; then
    BLACKLIST_COUNT=$MXT_COUNT
    BLACKLIST_NAMES="$MXT_NAMES"
elif [ -n "$HETRIX_API_KEY" ] && [ $HETRIX_STATUS -eq 0 ]; then
    BLACKLIST_COUNT=$HETRIX_COUNT
    BLACKLIST_NAMES="$HETRIX_NAMES"
fi

# Handle empty blacklist names
if [ -z "$BLACKLIST_NAMES" ]; then
    BLACKLIST_NAMES="none"
    BLACKLIST_COUNT=0
fi

# Determine state based on thresholds
if [ -n "$HETRIX_API_KEY" ] && [ -z "$MXT_API_KEY" ] && [ $HETRIX_RATE_LIMITED -eq 1 ]; then
    echo "{\"state\":\"UNKNOWN\",\"blacklist_count\":\"0\",\"blacklist_names\":\"none\",\"message\":\"$HETRIX_MESSAGE\"}"
    exit 1
fi
if [ "$BLACKLIST_COUNT" -ge "$CRITICAL_COUNT" ]; then
    STATE="CRITICAL"
elif [ "$BLACKLIST_COUNT" -ge "$WARNING_COUNT" ]; then
    STATE="WARNING"
else
    STATE="OK"
fi

# Output JSON for Zabbix
if [ $MXT_STATUS -ne 0 ] && [ $HETRIX_STATUS -ne 0 ]; then
    echo "{\"state\":\"UNKNOWN\",\"blacklist_count\":\"0\",\"blacklist_names\":\"none\",\"message\":\"$MESSAGE\"}"
    exit 1
fi
echo "{\"state\":\"$STATE\",\"blacklist_count\":\"$BLACKLIST_COUNT\",\"blacklist_names\":\"$BLACKLIST_NAMES\",\"message\":\"$MESSAGE\"}"

exit 0