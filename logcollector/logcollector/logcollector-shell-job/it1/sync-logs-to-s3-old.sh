#!/bin/bash

# Configuration
NAMESPACE="duploservices-rli-ops05-raht"
S3_BUCKET="your-s3-bucket-name"
STATE_FILE="/tmp/log_sync_state.json"
POD_PREFIX="fid"

# Log directories to monitor
LOG_PATHS=(
    "/opt/radiantone/vds/vds_server/logs"
    "/opt/radiantone/vds/vds_server/logs/jetty"
    "/opt/radiantone/vds/vds_server/logs/sync_engine"
    "/opt/radiantone/vds/logs"
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
    local source_path="$2"
    local filename="$3"
    local target_date="$4"
    local pod_name=$(echo "$pod" | sed 's/^pod\///')

    # Construct S3 path
    local s3_path="s3://${S3_BUCKET}/${target_date}/${pod_name}/"

    # Use kubectl cp to get the file to a temporary location
    local temp_dir="/tmp/logs_to_sync"
    mkdir -p "$temp_dir"

    echo "Copying $filename from $pod:$source_path to S3..."
    if kubectl cp -n "$NAMESPACE" "${pod_name}:${source_path}/${filename}" "${temp_dir}/${filename}" -c fid; then
        # Upload to S3
        if aws s3 cp "${temp_dir}/${filename}" "${s3_path}${filename}"; then
            echo "Successfully uploaded ${filename} to ${s3_path}"
            rm -f "${temp_dir}/${filename}"
            return 0
        else
            echo "Failed to upload ${filename} to S3"
            rm -f "${temp_dir}/${filename}"
            return 1
        fi
    else
        echo "Failed to copy ${filename} from pod"
        return 1
    fi
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
    local all_processed_files=()

    # Process each pod
    for pod in $pods; do
        local pod_name=$(echo "$pod" | sed 's/^pod\///')

        # Process each log directory
        for log_path in "${LOG_PATHS[@]}"; do
            # Get all log files in the directory
            local files=$(kubectl -n "$NAMESPACE" exec "$pod_name" -c fid -- find "$log_path" -type f \( -name "*.log" -o -name "*.zip" -o -name "*.gz" \))

            # Separate active and archived files
            local active_files=()
            local archived_files=()

            while IFS= read -r file; do
                if [ -n "$file" ]; then
                    local filename=$(basename "$file")

                    # Skip unwanted files
                    if should_skip_file "$filename"; then
                        continue
                    fi

                    # Get file's last modification time
                    local file_mtime=$(kubectl -n "$NAMESPACE" exec "$pod_name" -c fid -- stat -c %Y "$file")
                    local file_mtime_date=$(date -d "@$file_mtime" +%Y-%m-%d)

                    # If not first run, skip files that haven't been modified since last run
                    if [ "$first_run" = "false" ] && [ -n "$last_run" ]; then
                        if [[ "$file_mtime_date" < "$last_run" ]] && \
                           echo "$processed_files" | jq -e --arg f "$filename" '.[] | select(. == $f)' > /dev/null; then
                            echo "Skipping previously processed file: $filename"
                            continue
                        fi
                    fi

                    if is_active_file "$filename"; then
                        active_files+=("$filename")
                    else
                        archived_files+=("$filename")
                    fi
                fi
            done <<< "$files"

            echo "Processing archived files for $pod_name in $log_path"
            # Process archived files first
            for filename in "${archived_files[@]}"; do
                local file_date=$(get_date_from_filename "$filename")
                local sync_date="${file_date:-$target_date}"

                if sync_logs_to_s3 "$pod" "$log_path" "$filename" "$sync_date"; then
                    all_processed_files+=("$filename")
                fi
            done

            echo "Processing active files for $pod_name in $log_path"
            # Then process active files
            for filename in "${active_files[@]}"; do
                if sync_logs_to_s3 "$pod" "$log_path" "$filename" "$target_date"; then
                    all_processed_files+=("$filename")
                fi
            done
        done
    done

    # Update state with all successfully processed files
    local new_processed_files=$(printf '%s\n' "${all_processed_files[@]}" | jq -R . | jq -s .)
    update_state "$target_date" "$new_processed_files"

    echo "Completed processing. Updated state with $(echo "$new_processed_files" | jq length) processed files"
}

# Run main process
process_logs
