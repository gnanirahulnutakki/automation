#!/bin/bash

# Set strict error handling
set -eo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default log locations (can be extended via command line)
LOG_PATHS=(
    "/opt/radiantone/vds/vds_server/logs"
    "/opt/radiantone/vds/vds_server/logs/jetty"
    "/opt/radiantone/vds/vds_server/logs/sync_engine"
    "/opt/radiantone/vds/logs"
)

LOG_FILES=(
    "vds_server.log,vds_server_access.log,periodiccache.log,vds_events.log"
    "web.log,web_access.log"
    "sync_engine.log"
    "alerts.log"
)

# File extensions to ignore
IGNORED_EXTENSIONS=("csv" "pos" "csv.[0-9]+" "csv.[0-9]+[0-9]")

# Function to log messages
log() {
    local level=$1
    shift
    local message=$@
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} ${timestamp} - $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} ${timestamp} - $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} ${timestamp} - $message" >&2
            ;;
    esac
}

# Function to validate date format
validate_date() {
    local date_str=$1

    # Remove any whitespace
    date_str=$(echo "$date_str" | tr -d '[:space:]')

    # Check format using grep
    if ! echo "$date_str" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        return 1
    fi

    # Parse year, month, day
    local year="${date_str:0:4}"
    local month="${date_str:5:2}"
    local day="${date_str:8:2}"

    # Basic range validation
    if [ "$month" -lt 1 ] || [ "$month" -gt 12 ]; then
        return 1
    fi

    # Validate day based on month
    case "$month" in
        01|03|05|07|08|10|12) max_days=31 ;;
        04|06|09|11) max_days=30 ;;
        02)
            # Leap year check
            if (( year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) )); then
                max_days=29
            else
                max_days=28
            fi
            ;;
    esac

    if [ "$day" -lt 1 ] || [ "$day" -gt "$max_days" ]; then
        return 1
    fi

    return 0
}

# Function to convert date to timestamp
date_to_timestamp() {
    local date_str=$1
    local year="${date_str:0:4}"
    local month="${date_str:5:2}"
    local day="${date_str:8:2}"

    # Use printf for date conversion (more portable than date command)
    printf "%d%02d%02d" "$year" "$month" "$day"
}

# Update the date comparison in get_interactive_input()
    while true; do
        read -p "Enter start date (YYYY-MM-DD) or press enter to skip: " START_DATE

        if [[ -z "$START_DATE" ]]; then
            break
        fi

        if validate_date "$START_DATE"; then
            read -p "Enter end date (YYYY-MM-DD): " END_DATE
            if validate_date "$END_DATE"; then
                # Compare dates using simple string comparison
                start_ts=$(date_to_timestamp "$START_DATE")
                end_ts=$(date_to_timestamp "$END_DATE")
                if [ "$start_ts" -le "$end_ts" ]; then
                    break
                else
                    echo -e "${RED}Error: End date must be after start date${NC}"
                fi
            else
                echo -e "${RED}Error: Invalid end date format. Use YYYY-MM-DD${NC}"
            fi
        else
            echo -e "${RED}Error: Invalid start date format. Use YYYY-MM-DD${NC}"
        fi
    done
# Function to compare dates
is_date_in_range() {
    local file_date=$1
    local start_date=$2
    local end_date=$3

    local file_seconds=$(date -d "$file_date" +%s)
    local start_seconds=$(date -d "$start_date" +%s)
    local end_seconds=$(date -d "$end_date" +%s)

    if [[ $file_seconds -ge $start_seconds && $file_seconds -le $end_seconds ]]; then
        return 0
    fi
    return 1
}

# Function to extract date from filename
extract_date() {
    local filename=$1
    echo "$filename" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo ""
}

# Function to validate Kubernetes connection
validate_kubernetes() {
    local kubeconfig=$1
    local namespace=$2

    export KUBECONFIG=$kubeconfig

    if ! kubectl auth can-i get pods -n "$namespace" >/dev/null 2>&1; then
        log "ERROR" "Failed to authenticate with the cluster. Please ensure you're logged in."
        log "INFO" "Try running: kubectl get pods -n $namespace"
        return 1
    fi

    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        log "ERROR" "Cannot access namespace $namespace"
        return 1
    fi

    log "INFO" "Successfully connected to Kubernetes cluster and validated namespace $namespace"
    return 0
}

# Function to get available dates from logs
get_available_dates() {
    local namespace=$1
    local pod_name=$2
    local dates=()

    if ! kubectl get pod -n "$namespace" "$pod_name" >/dev/null 2>&1; then
        log "ERROR" "Cannot access pod $pod_name. Please check your credentials."
        return 1
    fi

    for i in "${!LOG_PATHS[@]}"; do
        local path=${LOG_PATHS[$i]}
        local file_list

        file_list=$(kubectl exec -n "$namespace" "$pod_name" -- ls -1 "$path" 2>/dev/null) || {
            log "WARN" "Could not list files in $path for $pod_name"
            continue
        }

        while read -r file; do
            local date_str=$(extract_date "$file")
            if [[ -n "$date_str" ]]; then
                dates+=("$date_str")
            fi
        done <<< "$file_list"
    done

    if [ ${#dates[@]} -gt 0 ]; then
        printf '%s\n' "${dates[@]}" | sort -u
    else
        log "WARN" "No dates found in log files"
        return 1
    fi
}

# Function to check if file should be ignored
should_ignore_file() {
    local filename=$1
    local ignored_logs=$2

    for ext in "${IGNORED_EXTENSIONS[@]}"; do
        if [[ $filename =~ \.${ext}$ ]]; then
            return 0
        fi
    done

    if [[ -n "$ignored_logs" ]]; then
        IFS=',' read -ra IGNORE_ARRAY <<< "$ignored_logs"
        for ignore_pattern in "${IGNORE_ARRAY[@]}"; do
            if [[ $filename == ${ignore_pattern}* ]]; then
                return 0
            fi
        done
    fi

    return 1
}

# Function to add new log location
add_new_log_location() {
    local path=$1
    local files=$2

    LOG_PATHS+=("$path")
    LOG_FILES+=("$files")
    log "INFO" "Added new log location: $path with files: $files"
}

# Function to get interactive input
get_interactive_input() {
    echo -e "${GREEN}Interactive Log Collection Setup${NC}"
    echo "----------------------------------------"

    if [[ -z "${KUBECONFIG:-}" ]]; then
        read -p "Enter path to kubeconfig file: " KUBECONFIG
        while [[ ! -f "$KUBECONFIG" ]]; do
            echo -e "${RED}Error: File not found${NC}"
            read -p "Enter path to kubeconfig file: " KUBECONFIG
        done
    fi

    if [[ -z "${NAMESPACE:-}" ]]; then
        read -p "Enter namespace: " NAMESPACE
        while [[ -z "$NAMESPACE" ]]; do
            echo -e "${RED}Error: Namespace cannot be empty${NC}"
            read -p "Enter namespace: " NAMESPACE
        done
    fi

    if [[ -z "${DESTINATION:-}" ]]; then
        read -p "Enter destination path for logs: " DESTINATION
        while [[ -z "$DESTINATION" ]]; do
            echo -e "${RED}Error: Destination path cannot be empty${NC}"
            read -p "Enter destination path for logs: " DESTINATION
        done
    fi

    if [[ -z "${S3_BUCKET:-}" ]]; then
        read -p "Enter S3 bucket name (optional, press enter to skip): " S3_BUCKET
    fi

    if [[ -z "${IGNORED_LOGS:-}" ]]; then
        echo -e "\n${YELLOW}Current log files that can be ignored:${NC}"
        echo "----------------------------------------"
        for files in "${LOG_FILES[@]}"; do
            echo "$files"
        done
        echo "----------------------------------------"
        read -p "Enter comma-separated list of logs to ignore (optional, press enter to skip): " IGNORED_LOGS
    fi

    while true; do
        echo -e "\n${YELLOW}Current log locations:${NC}"
        echo "----------------------------------------"
        for i in "${!LOG_PATHS[@]}"; do
            echo "Path: ${LOG_PATHS[$i]}"
            echo "Files: ${LOG_FILES[$i]}"
            echo "----------------------------------------"
        done

        read -p "Would you like to add a new log location? (y/n): " add_new
        if [[ "$add_new" =~ ^[Yy]$ ]]; then
            read -p "Enter new log path: " new_path
            while [[ -z "$new_path" ]]; do
                echo -e "${RED}Error: Path cannot be empty${NC}"
                read -p "Enter new log path: " new_path
            done

            read -p "Enter comma-separated list of log files for this path: " new_files
            while [[ -z "$new_files" ]]; do
                echo -e "${RED}Error: File list cannot be empty${NC}"
                read -p "Enter comma-separated list of log files for this path: " new_files
            done

            add_new_log_location "$new_path" "$new_files"
        else
            break
        fi
    done

# Update the date input section in get_interactive_input()
    echo -e "\n${YELLOW}Would you like to filter logs by date range? (y/n):${NC} "
    read -r use_date_range

    if [[ "$use_date_range" =~ ^[Yy]$ ]]; then
        # First validate kubernetes connection and get available dates
        if validate_kubernetes "$KUBECONFIG" "$NAMESPACE"; then
            # Get a sample pod to show available dates
            local sample_pod=$(kubectl get pods -n "$NAMESPACE" -l app=fid -o name 2>/dev/null | head -n1 | cut -d/ -f2)

            if [[ -n "$sample_pod" ]]; then
                echo -e "\n${YELLOW}Available dates in logs:${NC}"
                echo "----------------------------------------"
                if ! get_available_dates "$NAMESPACE" "$sample_pod"; then
                    echo -e "${YELLOW}Warning: Could not fetch available dates. Continuing without date list.${NC}"
                fi
                echo "----------------------------------------"
            else
                echo -e "${YELLOW}Warning: No pods found to fetch dates from.${NC}"
            fi
        else
            echo -e "${YELLOW}Warning: Could not connect to cluster to fetch dates. Continuing without date list.${NC}"
        fi

        # Now prompt for dates
        while true; do
            echo -e "\n${GREEN}Enter date range for log collection:${NC}"
            read -p "Enter start date (YYYY-MM-DD) or press enter to skip: " START_DATE

            if [[ -z "$START_DATE" ]]; then
                break
            fi

            if validate_date "$START_DATE"; then
                read -p "Enter end date (YYYY-MM-DD): " END_DATE
                if validate_date "$END_DATE"; then
                    # Compare dates using simple string comparison
                    start_ts=$(date_to_timestamp "$START_DATE")
                    end_ts=$(date_to_timestamp "$END_DATE")
                    if [ "$start_ts" -le "$end_ts" ]; then
                        break
                    else
                        echo -e "${RED}Error: End date must be after start date${NC}"
                    fi
                else
                    echo -e "${RED}Error: Invalid end date format. Use YYYY-MM-DD${NC}"
                fi
            else
                echo -e "${RED}Error: Invalid start date format. Use YYYY-MM-DD${NC}"
            fi
        done
    fi

    if [[ -z "${KUBECONFIG:-}" ]]; then
        read -p "Enter path to kubeconfig file: " KUBECONFIG
        while [[ ! -f "$KUBECONFIG" ]]; do
            echo -e "${RED}Error: File not found${NC}"
            read -p "Enter path to kubeconfig file: " KUBECONFIG
        done
    fi

    echo -e "\n${GREEN}Configuration Summary:${NC}"
    echo "----------------------------------------"
    echo "Kubeconfig: $KUBECONFIG"
    echo "Namespace: $NAMESPACE"
    echo "Destination: $DESTINATION"
    echo "S3 Bucket: ${S3_BUCKET:-None}"
    echo "Ignored Logs: ${IGNORED_LOGS:-None}"
    if [[ -n "${START_DATE:-}" && -n "${END_DATE:-}" ]]; then
        echo "Date Range: $START_DATE to $END_DATE"
    else
        echo "Date Range: All dates"
    fi
    echo -e "Log Locations:"
    for i in "${!LOG_PATHS[@]}"; do
        echo "  Path: ${LOG_PATHS[$i]}"
        echo "  Files: ${LOG_FILES[$i]}"
    done
    echo "----------------------------------------"

    read -p "Would you like to proceed with this configuration? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "Configuration cancelled by user"
        exit 0
    fi
}

# Function to validate S3 bucket if provided
validate_s3() {
    local bucket=$1
    if ! aws s3 ls "s3://$bucket" >/dev/null 2>&1; then
        log "ERROR" "Cannot access S3 bucket $bucket"
        return 1
    fi
    log "INFO" "Successfully validated S3 bucket access"
    return 0
}

# Function to check if required commands exist
check_prerequisites() {
    local required_commands=("kubectl" "awk" "date")

    if [[ -n "${S3_BUCKET:-}" ]]; then
        required_commands+=("aws")
    fi

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "ERROR" "$cmd is required but not installed."
            return 1
        fi
    done
    return 0
}

# Function to copy logs from a single pod
copy_pod_logs() {
    local namespace=$1
    local pod_name=$2
    local destination=$3
    local s3_bucket=$4
    local ignored_logs=$5

    if ! kubectl get pod -n "$namespace" "$pod_name" >/dev/null 2>&1; then
        log "ERROR" "Cannot access pod $pod_name. Please check your credentials."
        return 1
    fi

    for i in "${!LOG_PATHS[@]}"; do
        local path=${LOG_PATHS[$i]}
        IFS=',' read -ra log_files <<< "${LOG_FILES[$i]}"

        log "INFO" "Checking logs in $path for $pod_name"

        local file_list
        if ! file_list=$(kubectl exec -n "$namespace" "$pod_name" -- ls -1 "$path" 2>/dev/null); then
            log "WARN" "Could not list files in $path for $pod_name"
            continue
        fi

        for log_file in "${log_files[@]}"; do
            local base_name="${log_file%.log}"

            echo "$file_list" | while read -r found_file; do
                if should_ignore_file "$found_file" "$ignored_logs"; then
                    log "INFO" "Skipping ignored file: $found_file"
                    continue
                fi

                if [[ $found_file == $base_name* ]]; then
                    local date_str
                    date_str=$(extract_date "$found_file")

                    if [[ -n "$date_str" && -n "${START_DATE:-}" && -n "${END_DATE:-}" ]]; then
                        if ! is_date_in_range "$date_str" "$START_DATE" "$END_DATE"; then
                            log "INFO" "Skipping $found_file (out of date range)"
                            continue
                        fi
                    fi

                    local pod_folder
                    if [ -n "$date_str" ]; then
                        pod_folder="${pod_name}-${date_str}"
                    else
                        pod_folder="${pod_name}"
                    fi

                    local full_dest_path="$destination/$namespace/$pod_folder"
                    mkdir -p "$full_dest_path"

                    log "INFO" "Copying $found_file from $pod_name"

if kubectl cp -n "$namespace" "$pod_name:$path/$found_file" "$full_dest_path/$found_file" >/dev/null 2>&1; then
                        log "INFO" "Successfully copied $found_file"

                        if [ -n "$s3_bucket" ]; then
                            local s3_path="s3://$s3_bucket/$namespace/$pod_folder/$found_file"
                            if aws s3 cp "$full_dest_path/$found_file" "$s3_path" >/dev/null 2>&1; then
                                log "INFO" "Uploaded $found_file to S3"
                            else
                                log "ERROR" "Failed to upload $found_file to S3"
                            fi
                        fi
                    else
                        log "ERROR" "Failed to copy $found_file from $pod_name"
                    fi

                    sleep 1
                fi
            done
        done
        sleep 2
    done
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  --kubeconfig     Path to kubernetes config file"
    echo "  --namespace      Kubernetes namespace"
    echo "  --destination    Local path to store logs"
    echo "  --s3-bucket      S3 bucket name for uploading logs (optional)"
    echo "  --ignore-logs    Comma-separated list of log names to ignore (optional)"
    echo "                   Example: --ignore-logs 'vds_server,vds_server_access'"
    echo "  --add-log-path   Add new log path (optional)"
    echo "                   Format: --add-log-path '/path/to/logs:log1.log,log2.log'"
    echo "  --start-date     Start date for log collection (YYYY-MM-DD format)"
    echo "  --end-date       End date for log collection (YYYY-MM-DD format)"
    echo "  --help           Show this help message"
    echo
    echo "If options are not provided, the script will prompt for input interactively."
    echo
    echo "Examples:"
    echo "1. Basic usage with all parameters:"
    echo "   $0 --kubeconfig ~/.kube/config --namespace my-namespace --destination /logs"
    echo
    echo "2. Ignore specific logs:"
    echo "   $0 --kubeconfig ~/.kube/config --namespace my-namespace --destination /logs \\"
    echo "      --ignore-logs 'vds_server.log,web_access.log'"
    echo
    echo "3. Add new log location:"
    echo "   $0 --kubeconfig ~/.kube/config --namespace my-namespace --destination /logs \\"
    echo "      --add-log-path '/custom/path:custom1.log,custom2.log'"
    echo
    echo "4. Collect logs for a specific date range:"
    echo "   $0 --kubeconfig ~/.kube/config --namespace my-namespace --destination /logs \\"
    echo "      --start-date 2024-01-01 --end-date 2024-01-31"
    echo
    echo "5. Combine multiple options:"
    echo "   $0 --kubeconfig ~/.kube/config --namespace my-namespace --destination /logs \\"
    echo "      --ignore-logs 'vds_server.log' --s3-bucket my-bucket \\"
    echo "      --add-log-path '/custom/path:custom.log' \\"
    echo "      --start-date 2024-01-01 --end-date 2024-01-31"
    echo
    echo "Notes:"
    echo "- The script automatically ignores files with extensions: .csv, .pos, .csv.1, .csv.2, etc."
    echo "- Multiple --add-log-path options can be specified"
    echo "- The ignore list is applied to the base name of the log files"
    echo "- Date filtering only applies to logs with dates in their filenames"
}

# Main function
main() {
    # Initialize variables
    KUBECONFIG=""
    NAMESPACE=""
    DESTINATION=""
    S3_BUCKET=""
    IGNORED_LOGS=""
    START_DATE=""
    END_DATE=""

    # Parse command line arguments if provided
    while [[ $# -gt 0 ]]; do
        case $1 in
            --kubeconfig)
                KUBECONFIG="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --destination)
                DESTINATION="$2"
                shift 2
                ;;
            --s3-bucket)
                S3_BUCKET="$2"
                shift 2
                ;;
            --ignore-logs)
                IGNORED_LOGS="$2"
                shift 2
                ;;
            --add-log-path)
                IFS=':' read -r path files <<< "$2"
                add_new_log_location "$path" "$files"
                shift 2
                ;;
            --start-date)
                START_DATE="$2"
                shift 2
                ;;
            --end-date)
                END_DATE="$2"
                shift 2
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                log "ERROR" "Unknown parameter: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Get interactive input for any missing parameters
    get_interactive_input

    # Check prerequisites
    if ! check_prerequisites; then
        exit 1
    fi

    # Validate Kubernetes connection
    if ! validate_kubernetes "$KUBECONFIG" "$NAMESPACE"; then
        exit 1
    fi

    # Validate S3 bucket if provided
    if [ -n "$S3_BUCKET" ]; then
        if ! validate_s3 "$S3_BUCKET"; then
            exit 1
        fi
    fi

    # Validate dates if provided
    if [[ -n "$START_DATE" ]]; then
        if ! validate_date "$START_DATE"; then
            log "ERROR" "Invalid start date format. Use YYYY-MM-DD"
            exit 1
        fi
        if [[ -z "$END_DATE" ]]; then
            log "ERROR" "End date must be provided when start date is specified"
            exit 1
        fi
        if ! validate_date "$END_DATE"; then
            log "ERROR" "Invalid end date format. Use YYYY-MM-DD"
            exit 1
        fi
        if [[ $(date -d "$START_DATE" +%s) -gt $(date -d "$END_DATE" +%s) ]]; then
            log "ERROR" "End date must be after start date"
            exit 1
        fi
    fi

    # Create destination directory
    mkdir -p "$DESTINATION"

    # Get FID pods
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -l app=fid -o name | cut -d/ -f2)

    if [ -z "$pods" ]; then
        log "ERROR" "No FID pods found in namespace $NAMESPACE"
        exit 1
    fi

    # Process each pod
    for pod in $pods; do
        log "INFO" "Processing pod: $pod"
        copy_pod_logs "$NAMESPACE" "$pod" "$DESTINATION" "$S3_BUCKET" "$IGNORED_LOGS"
    done

    log "INFO" "Log collection completed successfully"
}

# Call main function with all arguments
main "$@"

