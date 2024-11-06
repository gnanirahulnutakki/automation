#!/bin/bash

set -e

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to retry a command
retry() {
    local retries=3
    local wait=5
    local command="$@"

    for i in $(seq 1 $retries); do
        if eval "$command"; then
            return 0
        fi
        echo "Command failed, retrying in $wait seconds..."
        sleep $wait
    done

    echo "Command failed after $retries attempts"
    return 1
}

# Check for required commands
for cmd in kubectl jq aws; do
    if ! command_exists "$cmd"; then
        echo "Error: $cmd is not installed. Please install it and try again."
        exit 1
    fi
done

# Function to get user input
get_input() {
    local prompt="$1"
    local var_name="$2"
    local default_value="$3"

    read -p "$prompt ${default_value:+[$default_value]} " value
    value=${value:-$default_value}
    eval $var_name='$value'
}

# Function to check available disk space
check_disk_space() {
    local required_space=$((1024 * 1024))  # 1 GB in KB
    local available_space=$(df -k . | awk 'NR==2 {print $4}')

    if [ "$available_space" -lt "$required_space" ]; then
        echo "Error: Not enough disk space. Required: 1GB, Available: $((available_space / 1024))MB"
        exit 1
    fi
}

# Get inputs
get_input "Enter the path to your kubeconfig file:" KUBECONFIG
get_input "Enter the namespace:" NAMESPACE
get_input "Enter destination type (local/s3):" DEST_TYPE "local"
get_input "Enter the destination path:" DEST_PATH

# Validate inputs
if [ ! -f "$KUBECONFIG" ]; then
    echo "Error: Kubeconfig file not found at $KUBECONFIG"
    exit 1
fi

if [ "$DEST_TYPE" != "local" ] && [ "$DEST_TYPE" != "s3" ]; then
    echo "Error: Invalid destination type. Must be 'local' or 's3'."
    exit 1
fi

# Set kubectl config
export KUBECONFIG="$KUBECONFIG"

# Test connection
if ! retry "kubectl get namespaces &>/dev/null"; then
    echo "Error: Failed to connect to the cluster. Please check your kubeconfig and try again."
    exit 1
fi

# Get number of replicas
REPLICAS=$(kubectl get statefulset fid -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
if [ -z "$REPLICAS" ]; then
    echo "Error: Failed to get number of replicas for 'fid' StatefulSet"
    exit 1
fi

# Log paths
LOG_PATHS=(
    "/opt/radiantone/vds/vds_server/logs"
    "/opt/radiantone/vds/vds_server/logs/jetty"
    "/opt/radiantone/vds/vds_server/logs/sync_engine"
    "/opt/radiantone/vds/logs"
)

# Function to copy logs
copy_logs() {
    local pod_name="$1"
    local log_path="$2"
    local dest_folder="$3"

    # List files in the log path
    files=$(retry "kubectl exec -n '$NAMESPACE' '$pod_name' -- ls -1 '$log_path'")

    for file in $files; do
        # Extract date from filename or use current date
        date_str=$(echo "$file" | grep -oP '\d{4}-\d{2}-\d{2}' || date +%Y-%m-%d)
        dest_subfolder="$dest_folder/${pod_name}-${date_str}"
        mkdir -p "$dest_subfolder"

        echo "Copying $file from $pod_name:$log_path to $dest_subfolder"

        if [[ "$file" == *.gz ]]; then
            retry "kubectl exec -n '$NAMESPACE' '$pod_name' -- cat '$log_path/$file' | gunzip > '$dest_subfolder/$file'"
        elif [[ "$file" == *.zip ]]; then
            retry "kubectl exec -n '$NAMESPACE' '$pod_name' -- cat '$log_path/$file' > '$dest_subfolder/$file'"
            unzip -q "$dest_subfolder/$file" -d "$dest_subfolder"
            rm "$dest_subfolder/$file"
        else
            retry "kubectl exec -n '$NAMESPACE' '$pod_name' -- cat '$log_path/$file' > '$dest_subfolder/$file'"
        fi

        # Verify file integrity
        local remote_md5=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- md5sum "$log_path/$file" | awk '{print $1}')
        local local_md5=$(md5sum "$dest_subfolder/$file" | awk '{print $1}')

        if [ "$remote_md5" != "$local_md5" ]; then
            echo "Error: Checksum mismatch for $file"
            rm "$dest_subfolder/$file"
        else
            echo "Successfully copied and verified $file"
        fi
    done
}

# Main loop with timeout
timeout 4h bash << EOF
for ((i=0; i<REPLICAS; i++)); do
    pod_name="fid-$i"
    echo "Processing pod: $pod_name"

    check_disk_space

    for log_path in "${LOG_PATHS[@]}"; do
        if [ "$DEST_TYPE" == "local" ]; then
            dest_folder="$DEST_PATH/$NAMESPACE"
            copy_logs "$pod_name" "$log_path" "$dest_folder"
        else
            # For S3, we'll first copy to a temporary local folder
            temp_folder="/tmp/$NAMESPACE/$pod_name"
            mkdir -p "$temp_folder"
            copy_logs "$pod_name" "$log_path" "$temp_folder"

            # Upload to S3
            aws s3 sync "$temp_folder" "$DEST_PATH/$NAMESPACE" --delete
            rm -rf "$temp_folder"
        fi
    done
done
EOF

if [ $? -eq 124 ]; then
    echo "Script timed out after 4 hours"
    exit 1
fi

echo "Log collection completed."
