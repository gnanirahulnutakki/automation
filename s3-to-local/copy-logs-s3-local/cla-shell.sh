#!/bin/bash

# Set strict error handling
set -eo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log locations (using regular arrays for better compatibility)
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

# Function to get interactive input
get_interactive_input() {
    # If parameters are already set, skip interactive input
    if [[ -n "${KUBECONFIG:-}" && -n "${NAMESPACE:-}" && -n "${DESTINATION:-}" ]]; then
        return 0
    fi

    echo -e "${GREEN}Interactive Log Collection Setup${NC}"
    echo "----------------------------------------"

    # Get kubeconfig if not provided
    if [[ -z "${KUBECONFIG:-}" ]]; then
        read -p "Enter path to kubeconfig file: " KUBECONFIG
    fi

    # Get namespace if not provided
    if [[ -z "${NAMESPACE:-}" ]]; then
        read -p "Enter namespace: " NAMESPACE
    fi

    # Get destination if not provided
    if [[ -z "${DESTINATION:-}" ]]; then
        read -p "Enter destination path for logs: " DESTINATION
    fi

    # Get S3 bucket if desired
    if [[ -z "${S3_BUCKET:-}" ]]; then
        read -p "Enter S3 bucket name (optional, press enter to skip): " S3_BUCKET
    fi
}

# Function to check if required commands exist
check_prerequisites() {
    local required_commands=("kubectl" "awk" "date")

    # Add aws to required commands if S3_BUCKET is specified
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

# Function to validate Kubernetes connection
validate_kubernetes() {
    local kubeconfig=$1
    local namespace=$2

    export KUBECONFIG=$kubeconfig

    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        log "ERROR" "Cannot access namespace $namespace"
        return 1
    fi

    log "INFO" "Successfully connected to Kubernetes cluster and validated namespace $namespace"
    return 0
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

# Function to extract date from filename
extract_date() {
    local filename=$1
    echo "$filename" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo ""
}

# Function to copy logs from a single pod
copy_pod_logs() {
    local namespace=$1
    local pod_name=$2
    local destination=$3
    local s3_bucket=$4

    for i in "${!LOG_PATHS[@]}"; do
        local path=${LOG_PATHS[$i]}
        IFS=',' read -ra log_files <<< "${LOG_FILES[$i]}"

        log "INFO" "Checking logs in $path for $pod_name"

        # Create directory listing
        local file_list
        if ! file_list=$(kubectl exec -n "$namespace" "$pod_name" -- ls -1 "$path" 2>/dev/null); then
            log "WARN" "Could not list files in $path for $pod_name"
            continue
        fi

        for log_file in "${log_files[@]}"; do
            local base_name="${log_file%.log}"

            echo "$file_list" | while read -r found_file; do
                if [[ $found_file == $base_name* ]]; then
                    # Extract date if present
                    local date_str
                    date_str=$(extract_date "$found_file")
                    local pod_folder
                    if [ -n "$date_str" ]; then
                        pod_folder="${pod_name}-${date_str}"
                    else
                        pod_folder="${pod_name}"
                    fi

                    # Create destination folders
                    local full_dest_path="$destination/$namespace/$pod_folder"
                    mkdir -p "$full_dest_path"

                    log "INFO" "Copying $found_file from $pod_name"

                    # Copy file from pod
                    if kubectl cp -n "$namespace" "$pod_name:$path/$found_file" "$full_dest_path/$found_file" >/dev/null 2>&1; then
                        log "INFO" "Successfully copied $found_file"

                        # Upload to S3 if bucket is specified
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

                    # Add delay between files
                    sleep 1
                fi
            done
        done
        # Add delay between locations
        sleep 2
    done
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  --kubeconfig   Path to kubernetes config file"
    echo "  --namespace    Kubernetes namespace"
    echo "  --destination  Local path to store logs"
    echo "  --s3-bucket    S3 bucket name for uploading logs (optional)"
    echo "  --help         Show this help message"
    echo
    echo "If options are not provided, the script will prompt for input interactively."
}

# Main script
main() {
    # Initialize variables
    KUBECONFIG=""
    NAMESPACE=""
    DESTINATION=""
    S3_BUCKET=""

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

    # Validate required parameters
    if [[ -z "$KUBECONFIG" || -z "$NAMESPACE" || -z "$DESTINATION" ]]; then
        log "ERROR" "Required parameters missing."
        exit 1
    fi

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
        copy_pod_logs "$NAMESPACE" "$pod" "$DESTINATION" "$S3_BUCKET"
    done

    log "INFO" "Log collection completed successfully"
}

# Call main function with all arguments
main "$@"
