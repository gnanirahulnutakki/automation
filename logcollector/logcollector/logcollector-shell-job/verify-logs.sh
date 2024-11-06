#!/bin/bash

# Configuration
NAMESPACE="duploservices-rli-ops05-raht"
STATE_FILE="/tmp/test_state.json"

# Function to extract date from filename with multiple patterns
get_date_from_filename() {
    local filename="$1"
    local patterns=(
        # YYYY-MM-DD pattern (e.g., vds_server-2024-07-13_12-03-18.log.zip)
        "([0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]))"
        # YYYY-MM-DD pattern in gc logs (e.g., gc2024-03-11_13-34-45.log)
        "gc([0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]))"
    )

    for pattern in "${patterns[@]}"; do
        if [[ $filename =~ $pattern ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    done
    return 1
}

# Function to check if file is currently active
is_active_file() {
    local filename="$1"
    # Files that are not compressed and have standard log extensions
    if [[ ! "$filename" =~ \.(zip|gz)$ ]] && [[ "$filename" =~ \.(log|csv)$ ]]; then
        return 0
    fi
    return 1
}

# Function to get current date in YYYY-MM-DD format
get_current_date() {
    date -u +"%Y-%m-%d"
}

# Function to print in color
print_color() {
    local color=$1
    local text=$2
    case $color in
        "green") echo -e "\033[0;32m${text}\033[0m" ;;
        "red") echo -e "\033[0;31m${text}\033[0m" ;;
        "blue") echo -e "\033[0;34m${text}\033[0m" ;;
        "yellow") echo -e "\033[0;33m${text}\033[0m" ;;
    esac
}

# Test pod access and collect environment details
test_pod_access() {
    print_color "blue" "\n=== Testing Pod Access and Environment ==="

    # Get all fid pods
    local pods=$(kubectl -n $NAMESPACE get pods -l app.kubernetes.io/name=fid -o name)
    if [ -z "$pods" ]; then
        print_color "red" "❌ No FID pods found in namespace $NAMESPACE"
        return 1
    fi
    print_color "green" "✓ Successfully found FID pods in namespace $NAMESPACE"

    # Print pod details
    echo -e "\nPod Details:"
    while IFS= read -r pod; do
        local pod_name=$(echo "$pod" | sed 's|^pod/||')
        echo "  - $pod_name"
        kubectl -n $NAMESPACE get pod "$pod_name" -o wide
    done <<< "$pods"

    # Test with first pod
    local test_pod="fid-0"
    echo -e "\nUsing pod '$test_pod' for testing..."

    # Test log directory access
    local log_paths=(
        "/opt/radiantone/vds/vds_server/logs"
        "/opt/radiantone/vds/vds_server/logs/jetty"
        "/opt/radiantone/vds/vds_server/logs/sync_engine"
        "/opt/radiantone/vds/logs"
    )

    echo -e "\nTesting log directory access:"
    for path in "${log_paths[@]}"; do
        if kubectl -n $NAMESPACE exec $test_pod -c fid -- ls $path &>/dev/null; then
            print_color "green" "✓ Can access $path"
            echo "  Sample files:"
            kubectl -n $NAMESPACE exec $test_pod -c fid -- ls -la $path | head -n 5
        else
            print_color "red" "❌ Cannot access $path"
        fi
    done

    return 0
}

# Function to analyze log dates
analyze_log_dates() {
    local test_pod=$1
    local path=$2
    local dates=()

    print_color "blue" "\nAnalyzing files in $path:"

    # Get all files with log-related extensions
    local files=$(kubectl -n $NAMESPACE exec $test_pod -c fid -- find $path -type f \( -name "*.log" -o -name "*.log.*" -o -name "*.zip" -o -name "*.gz" \) 2>/dev/null)

    local active_files=0
    local dated_files=0
    local total_files=0

    while IFS= read -r file; do
        if [ -n "$file" ]; then
            ((total_files++))
            local filename=$(basename "$file")
            local date=$(get_date_from_filename "$filename")

            echo -e "\nFile: $filename"
            if [ -n "$date" ]; then
                print_color "green" "  ✓ Found date: $date"
                ((dated_files++))
                dates+=("$date")
            else
                print_color "yellow" "  ℹ No date found - will use current date"
            fi

            if is_active_file "$filename"; then
                print_color "yellow" "  ℹ Active log file - will be processed last"
                ((active_files++))
            fi
        fi
    done <<< "$files"

    # Print summary
    echo -e "\nSummary for $path:"
    echo "  Total files: $total_files"
    echo "  Files with dates: $dated_files"
    echo "  Active files: $active_files"

    # Print unique dates found
    if [ ${#dates[@]} -gt 0 ]; then
        echo -e "\nUnique dates found:"
        printf '%s\n' "${dates[@]}" | sort -u
    fi
}

# Test full log analysis
test_full_analysis() {
    local test_pod=$1
    print_color "blue" "\n=== Testing Full Log Analysis ==="

    local log_paths=(
        "/opt/radiantone/vds/vds_server/logs"
        "/opt/radiantone/vds/vds_server/logs/jetty"
        "/opt/radiantone/vds/vds_server/logs/sync_engine"
        "/opt/radiantone/vds/logs"
    )

    for path in "${log_paths[@]}"; do
        analyze_log_dates "$test_pod" "$path"
    done
}

# Main execution
main() {
    print_color "blue" "Starting Verification Tests..."

    # Test pod access first
    if test_pod_access; then
        test_full_analysis "fid-0"
    else
        print_color "red" "❌ Critical: Pod access failed. Please check your kubectl configuration and permissions."
        exit 1
    fi
}

# Run main function
main
