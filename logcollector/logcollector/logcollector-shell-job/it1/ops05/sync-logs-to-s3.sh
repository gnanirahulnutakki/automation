#!/bin/bash

# Configuration
NAMESPACE="duploservices-rli-ops05-raht"
S3_BUCKET="${S3_BUCKET}"  # Will be replaced by env variable
POD_PREFIX="fid"

# Log directories to monitor
LOG_PATHS=(
    "/opt/radiantone/vds/vds_server/logs"
    "/opt/radiantone/vds/vds_server/logs/jetty"
    "/opt/radiantone/vds/vds_server/logs/sync_engine"
    "/opt/radiantone/vds/logs"
    "/opt/radiantone/vds/logs/sync_agents"
)

# Function to get current date in YYYY-MM-DD format
get_current_date() {
    date -u +"%Y-%m-%d"
}

# Function to get previous date in YYYY-MM-DD format
get_previous_date() {
    date -u -d "yesterday" +"%Y-%m-%d"
}

# Function to extract date from filename
get_date_from_filename() {
    local filename="$1"
    local date_pattern="([0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]))"

    if [[ $filename =~ $date_pattern ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# Function to check if file should be skipped
should_skip_file() {
    local filename="$1"
    # Skip .pos files and gc logs with .current extension
    if [[ "$filename" =~ \.pos$ ]] || [[ "$filename" =~ ^gc.*\.current$ ]]; then
        return 0
    fi
    return 1
}

# Function to check if file is currently active
is_active_file() {
    local filename="$1"
    if [[ ! "$filename" =~ \.(zip|gz)$ ]] && [[ "$filename" =~ \.(log|csv)$ ]]; then
        return 0
    fi
    return 1
}

# Function to get state
get_state() {
    # Get state from ConfigMap
    local state=$(kubectl get configmap logs-sync-state -n "$NAMESPACE" -o jsonpath='{.data.state\.json}' 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$state" ]; then
        echo "$state"
    else
        echo "{\"first_run\": true, \"last_run\": null, \"processed_files\": []}"
    fi
}

# Function to update state
update_state() {
    local last_run="$1"
    local processed_files="$2"
    local new_state="{\"first_run\": false, \"last_run\": \"$last_run\", \"processed_files\": $processed_files}"

    # Update ConfigMap with new state
    kubectl create configmap logs-sync-state \
        --from-literal=state.json="$new_state" \
        -n "$NAMESPACE" \
        -o yaml --dry-run=client | kubectl apply -f -
}

# Function to sync logs to S3
sync_logs_to_s3() {
    local pod="$1"
    local full_path="$2"  # This is now the complete file path
    local filename="$3"
    local target_date="$4"
    local rel_path="$5"
    local pod_name=$(echo "$pod" | sed 's/^pod\///')

    # Construct S3 path with relative directory structure
    local s3_path="s3://${S3_BUCKET}/iddm/${target_date}/${pod_name}/"
    if [ -n "$rel_path" ]; then
        s3_path="${s3_path}${rel_path}/"
    fi

    # Use kubectl cp to get the file to a temporary location
    local temp_dir="/tmp/logs_to_sync/${pod_name}"
    if [ -n "$rel_path" ]; then
        temp_dir="${temp_dir}/${rel_path}"
    fi
    mkdir -p "$temp_dir"

    echo "Checking file existence: $filename in $pod:$full_path"

    # Check if file exists first
    if ! kubectl exec -n "$NAMESPACE" "${pod_name}" -c fid -- test -f "${full_path}"; then
        echo "File does not exist: ${filename}"
        return 1
    fi

    # Get file size
    local file_size=$(kubectl exec -n "$NAMESPACE" "${pod_name}" -c fid -- stat -c%s "${full_path}" 2>/dev/null)
    if [ -z "$file_size" ] || [ "$file_size" -eq 0 ]; then
        echo "File is empty or cannot get size: ${filename}"
        return 1
    fi

    echo "Copying $filename (size: $file_size bytes) from $pod:$full_path to S3..."

    local temp_file="${temp_dir}/${filename}"
    # Use a more robust copy method
    if kubectl exec -n "$NAMESPACE" "${pod_name}" -c fid -- cat "${full_path}" > "${temp_file}" 2>/dev/null; then
        # Verify the copied file
        if [ -f "${temp_file}" ] && [ -s "${temp_file}" ]; then
            # Upload to S3 with retries
            local retries=3
            local success=false
            while [ $retries -gt 0 ] && [ "$success" = false ]; do
                if aws s3 cp "${temp_file}" "${s3_path}${filename}" --no-progress; then
                    echo "Successfully uploaded ${filename} to ${s3_path}"
                    success=true
                    rm -f "${temp_file}"
                    return 0
                else
                    retries=$((retries-1))
                    if [ $retries -gt 0 ]; then
                        echo "Retrying upload for ${filename} ($retries attempts remaining)"
                        sleep 2
                    fi
                fi
            done
            if [ "$success" = false ]; then
                echo "Failed to upload ${filename} to S3 after all retries"
                rm -f "${temp_file}"
                return 1
            fi
        else
            echo "Failed to verify copied file: ${filename}"
            rm -f "${temp_file}"
            return 1
        fi
    else
        echo "Failed to copy ${filename} from pod"
        return 1
    fi
}

# Function to process directory
process_directory() {
    local pod="$1"
    local base_path="$2"
    local rel_path="$3"
    local target_date="$4"
    local first_run="$5"
    local last_run="$6"
    local processed_files="$7"
    local pod_name=$(echo "$pod" | sed 's/^pod\///')

    local full_path="${base_path}"
    if [ -n "$rel_path" ]; then
        full_path="${base_path}/${rel_path}"
    fi

    echo "Processing directory: $full_path"

    # Get directories first
    local dirs=$(kubectl exec -n "$NAMESPACE" "${pod_name}" -c fid -- find "${full_path}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    # Process each subdirectory
    while IFS= read -r dir; do
        if [ -n "$dir" ]; then
            local dir_name=$(basename "$dir")
            local new_rel_path="${rel_path:+${rel_path}/}${dir_name}"
            process_directory "$pod" "$base_path" "$new_rel_path" "$target_date" "$first_run" "$last_run" "$processed_files"
        fi
    done <<< "$dirs"

    # Get files in current directory with full paths
    local files=$(kubectl exec -n "$NAMESPACE" "${pod_name}" -c fid -- find "${full_path}" -maxdepth 1 -type f \( -name "*.log" -o -name "*.zip" -o -name "*.gz" \) 2>/dev/null | grep -v "\.pos$" | grep -v "gc.*\.current$")

    # Separate active and archived files
    local active_files=()
    local archived_files=()

    while IFS= read -r file; do
        if [ -n "$file" ]; then
            local filename=$(basename "$file")
            local file_rel_path=$(dirname "${file#${base_path}/}")

            if [ "$file_rel_path" = "$base_path" ]; then
                file_rel_path=""
            fi

            # Skip unwanted files
            if should_skip_file "$filename"; then
                echo "Skipping file: $filename (matched skip criteria)"
                continue
            fi

            # Get file's last modification time
            local file_mtime=$(kubectl exec -n "$NAMESPACE" "${pod_name}" -c fid -- stat -c %Y "$file")
            local file_mtime_date=$(date -d "@$file_mtime" +%Y-%m-%d)

            # If not first run, skip files that haven't been modified since last run
            if [ "$first_run" = "false" ] && [ -n "$last_run" ]; then
                if [[ "$file_mtime_date" < "$last_run" ]] && \
                   echo "$processed_files" | jq -e --arg f "${file_rel_path}/${filename}" '.[] | select(. == $f)' > /dev/null; then
                    echo "Skipping previously processed file: ${file_rel_path}/${filename}"
                    continue
                fi
            fi

            local file_info="${file}|${file_rel_path}"
            if is_active_file "$filename"; then
                echo "Adding to active files: $file"
                active_files+=("$file_info")
            else
                echo "Adding to archived files: $file"
                archived_files+=("$file_info")
            fi
        fi
    done <<< "$files"

    echo "Processing archived files for $pod_name in $full_path"
    echo "Found ${#archived_files[@]} archived files"
    # Process archived files first
    for file_info in "${archived_files[@]}"; do
        local file_path=$(echo "$file_info" | cut -d'|' -f1)
        local file_rel_path=$(echo "$file_info" | cut -d'|' -f2)
        local filename=$(basename "$file_path")
        local file_date=$(get_date_from_filename "$filename")
        local sync_date="${file_date:-$target_date}"

        if sync_logs_to_s3 "$pod" "$file_path" "$filename" "$sync_date" "$file_rel_path"; then
            all_processed_files+=("${file_rel_path}/${filename}")
        fi
    done

    echo "Processing active files for $pod_name in $full_path"
    echo "Found ${#active_files[@]} active files"
    # Then process active files
    for file_info in "${active_files[@]}"; do
        local file_path=$(echo "$file_info" | cut -d'|' -f1)
        local file_rel_path=$(echo "$file_info" | cut -d'|' -f2)
        local filename=$(basename "$file_path")

        if sync_logs_to_s3 "$pod" "$file_path" "$filename" "$target_date" "$file_rel_path"; then
            all_processed_files+=("${file_rel_path}/${filename}")
        fi
    done
}

# Main function to process logs
process_logs() {
    local current_date=$(get_current_date)
    local previous_date=$(get_previous_date)
    local target_date

    # Determine if we should use current or previous date based on time
    local current_hour=$(date +%H)
    if [ "$current_hour" -lt 1 ]; then
        target_date="$previous_date"
    else
        target_date="$current_date"
    fi

    # Get current state
    local state=$(get_state)
    local first_run=$(echo "$state" | jq -r '.first_run')
    local last_run=$(echo "$state" | jq -r '.last_run')
    local processed_files=$(echo "$state" | jq -r '.processed_files')

    echo "Current state: First run: $first_run, Last run: $last_run"

    # Get all FID pods
    local pods=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=fid -o name)

    # Arrays to track files being processed
    declare -g all_processed_files=()

    # Process each pod
    for pod in $pods; do
        local pod_name=$(echo "$pod" | sed 's/^pod\///')

        # Process each log directory
        for log_path in "${LOG_PATHS[@]}"; do
            echo "Processing base directory: $log_path in pod: $pod_name"
            process_directory "$pod" "$log_path" "" "$target_date" "$first_run" "$last_run" "$processed_files"
        done
    done

    # Update state with all successfully processed files
    if [ ${#all_processed_files[@]} -gt 0 ]; then
        local new_processed_files=$(printf '%s\n' "${all_processed_files[@]}" | jq -R . | jq -s .)
        update_state "$target_date" "$new_processed_files"
        echo "Completed processing. Updated state with $(echo "$new_processed_files" | jq length) processed files"
    else
        echo "No files were processed in this run"
    fi
}

# Run main process with error handling
echo "Starting log sync process at $(date -u)"
if ! process_logs; then
    echo "Error: Log sync process failed at $(date -u)"
    exit 1
fi
echo "Log sync process completed successfully at $(date -u)"


