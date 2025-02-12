#!/bin/bash

# Add notification helper functions at the start of the script
send_notification() {
    local title="$1"
    local message="$2"
    osascript -e "display notification \"$message\" with title \"$title\""
}

send_alert() {
    local title="$1"
    local message="$2"
    osascript -e "tell application \"System Events\" to display alert \"$title\" message \"$message\" buttons {\"OK\"} giving up after 10" &
}

# Function to get the current date and time with milliseconds
current_datetime() {
    # macOS gdate command with nanoseconds if available
    # brew install coreutils
    if command -v gdate >/dev/null 2>&1; then
        gdate +"%Y-%m-%d %H:%M:%S.%3N"
    else
        # Fallback using perl for millisecond precision
        perl -MTime::HiRes -e '
            $time = Time::HiRes::time();
            ($sec, $min, $hour, $day, $month, $year) = localtime($time);
            $year += 1900;
            $month += 1;
            $milliseconds = int(($time * 1000) % 1000);
            printf("%04d-%02d-%02d %02d:%02d:%02d.%03d\n", 
                $year, $month, $day, 
                $hour, $min, $sec, 
                $milliseconds);
        '
    fi
}

# Check if the script is already running with same command line and parameters
if pgrep -f "$(echo "$0 $*" | sed 's/[^[:alnum:]]/\\&/g')" > /dev/null; then
    echo "$(current_datetime) Script is already running with the same arguments. Exiting."
    exit 1
fi

# Check if the first argument (bucket name) is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <bucket-name> [source-path1 source-path2 ...]"
    exit 1
fi

# Define the S3 bucket name from first argument
BUCKET_NAME="$1"
shift  # Remove bucket name from arguments

# If no paths provided, use current directory
if [ $# -eq 0 ]; then
    set -- "$(pwd)"
fi

# SOURCE_PATH="$(pwd)"

# Verify AWS CLI exists
AWS_CLI_PATH="/usr/local/bin/aws"
if [ -z "$AWS_CLI_PATH" ]; then
    echo "$(current_datetime) AWS CLI not found. Please install it and configure your credentials."
    exit 1
fi

# Function to check if a file exists in S3
check_file_exists_in_s3() {
    local file_path="$1"
    echo "$(current_datetime) Checking if $(basename "$file_path") exists in S3 bucket..."
    if $AWS_CLI_PATH s3 ls "s3://$BUCKET_NAME/$file_path" &>/dev/null; then
        echo "$(current_datetime) $(basename "$file_path") already exists in S3. Skipping upload."
        return 0  # File exists
    else
        return 1  # File does not exist
    fi
}

# Function to verify file exists in S3
verify_file_exists_in_s3() {
    local file_path="$1"
    local source_dir="$2"
    echo "$(current_datetime) Verifying if $(basename "$file_path").zip exists in S3 bucket..."
    
    # Calculate total size of all zip parts
    local local_size=0
    local base_path="${file_path%.zip}"
    local dir_path=$(dirname "$base_path")
    local file_name=$(basename "$base_path")
    
    # Sum sizes using find with proper path handling
    while IFS= read -r -d '' part; do
        local part_size=$(stat -f%z "$dir_path/$part")
        if [ $? -ne 0 ]; then
            echo "$(current_datetime) Error getting size for: $part" >&2
            return 1
        fi
        local_size=$((local_size + part_size))
    done < <(cd "$dir_path" && find . -maxdepth 1 -name "${file_name}.zip.???" -print0)

    local relative_path=${dir_path#"$source_dir/"}
    local s3_path="$relative_path/$file_name.zip"
    local s3_size=$($AWS_CLI_PATH s3api head-object \
        --bucket "$BUCKET_NAME" \
        --key "$s3_path" \
        --query 'ContentLength' \
        --output text 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$s3_size" ]; then
        echo "$(current_datetime) File $(basename "$file_path") not found in S3 or size unavailable"
        return 1
    fi
    
    # Ensure we have numeric values
    if ! [[ "$local_size" =~ ^[0-9]+$ ]] || ! [[ "$s3_size" =~ ^[0-9]+$ ]]; then
        echo "$(current_datetime) Invalid size values - local: $local_size, S3: $s3_size" >&2
        return 1
    fi
    
    # Compare sizes
    if [ "$local_size" -eq "$s3_size" ]; then
        echo "$(current_datetime) File $(basename "$file_path") exists in S3 with matching size ($local_size bytes)"
        return 0
    else
        echo "$(current_datetime) File $(basename "$file_path") exists in S3 but size mismatch (local: $local_size, S3: $s3_size bytes)"
        return 1
    fi
}

create_split_zip_file() {
    local dir="$1"
    local part_size="5g"
    local error_log=$(mktemp)
    local checksum_file="${dir}.zip.md5"
    
    # Check if files and checksum exist
    if compgen -G "${dir}.zip.???" > /dev/null && [ -f "$checksum_file" ]; then
        echo "$(current_datetime) Split files and checksum exist. Verifying..."
        if verify_zip_checksum "$dir"; then
            echo "$(current_datetime) Checksum verified. Using existing files."
            return 0
        else
            echo "$(current_datetime) Checksum mismatch. Recreating archive..."
            rm -f "${dir}".zip.???
            rm -f "$checksum_file"
        fi
    fi

    echo "$(current_datetime) Creating split 7z file $dir.zip..."
    if ! /usr/local/bin/7z a -mx0 -v"$part_size" "$dir".zip "$dir" 2>"$error_log"; then
        echo "$(current_datetime) Error creating split 7z file" >&2
        cat "$error_log" >&2
        rm -f "$error_log" "${dir}".zip.??? "$checksum_file"
        send_alert "7z Error" "Failed to create split archive for $(basename "$dir")"
        return 1
    fi

    echo "$(current_datetime) Creating checksum..."
    # Create checksum file
    if ! create_zip_checksum "$dir"; then
        echo "$(current_datetime) Error creating checksum" >&2
        rm -f "$error_log" "${dir}".zip.??? "$checksum_file"
        send_alert "Checksum Error" "Failed to create checksum for $(basename "$dir")"
        return 1
    fi
    
    rm -f "$error_log"
    return 0
}

create_zip_checksum() {
    local dir="$1"
    local checksum_file="${dir}.zip.md5"
        find "$(dirname "$dir")" -name "$(basename "$dir").zip.???" -type f -print0 | \
        xargs -0 md5 -r > "$checksum_file"
}

verify_zip_checksum() {
    local dir="$1"
    local checksum_file="${dir}.zip.md5"
    [ -f "$checksum_file" ] && md5 -c "$checksum_file" >/dev/null 2>&1
}

# Function to upload a file to S3 using multipart upload
multipart_upload_to_s3() {
    local dir="$1"
    local s3_path="$2"
    local source_dir="$3"

    # Create split zip file
    create_split_zip_file "$dir"
    if [ $? -ne 0 ]; then
        echo "$(current_datetime) Error creating split zip file $dir. Skipping upload."
        send_notification "S3 Upload Error" "Failed to create split file for $(basename "$dir")"
        return 1
    fi

    # Check for existing multipart upload
    echo "$(current_datetime) Checking for existing multipart upload..."
    
    upload_id=$($AWS_CLI_PATH s3api list-multipart-uploads --bucket "$BUCKET_NAME" --query "Uploads[?Key=='$s3_path'].UploadId" --output text)
    if [ -z "$upload_id" ] || [ "$upload_id" == "None" ]; then
        # Initiate new multipart upload if none exists
        echo "$(current_datetime) Initiating new multipart upload"
        upload_id=$($AWS_CLI_PATH s3api create-multipart-upload --bucket "$BUCKET_NAME" --key "$s3_path" --storage-class DEEP_ARCHIVE --query UploadId --output text)
        if [ $? -ne 0 ]; then
            echo "$(current_datetime) Error initiating multipart upload"
            send_alert "S3 Upload Error" "Failed to initiate multipart upload for $(basename "$dir")"
            exit 1
        fi
        echo "$(current_datetime) Initiated multipart upload with UploadId: $upload_id"
    else
        echo "$(current_datetime) Resuming multipart upload with UploadId: $upload_id"
    fi

    # List existing parts
    existing_parts=$($AWS_CLI_PATH s3api list-parts --bucket "$BUCKET_NAME" --key "$s3_path" --upload-id "$upload_id" --query 'Parts[].{ETag:ETag,PartNumber:PartNumber}' --output json)

    # Upload each part
    part_number=1
    parts=""
    for part in "${dir}".zip.*; do
        # Check if part already exists
        if echo "$existing_parts" | grep -q "\"PartNumber\": $part_number"; then
            echo "$(current_datetime) Part $part_number already exists. Skipping upload."
            etag=$(echo "$existing_parts" | jq -r ".[] | select(.PartNumber == $part_number) | .ETag")
        else
            echo "$(current_datetime) Uploading part $part_number..."
            etag=$($AWS_CLI_PATH s3api upload-part --bucket "$BUCKET_NAME" --key "$s3_path" --part-number $part_number --body "$part" --upload-id "$upload_id" --query ETag --output text)
            if [ $? -ne 0 ]; then
                send_alert "S3 Upload Error" "Failed to upload part $part_number for $(basename "$dir")"
                echo "$(current_datetime) Error uploading part $part_number"
                exit 1
            fi
        fi
        parts="$parts{\"ETag\": $etag, \"PartNumber\": $part_number},"
        part_number=$((part_number + 1))
    done

    # Complete multipart upload
    parts="[${parts%,}]"
    $AWS_CLI_PATH s3api complete-multipart-upload --bucket "$BUCKET_NAME" --key "$s3_path" --upload-id "$upload_id" --multipart-upload "{\"Parts\": $parts}"
    if [ $? -ne 0 ]; then
        echo "$(current_datetime) Error completing multipart upload" >&2
        send_alert "S3 Upload Error" "Failed to complete upload for $(basename "$dir")"
        return 1
    fi
    
    # Verify upload and clean up
    echo "$(current_datetime) Verifying upload for $s3_path..."
    if verify_file_exists_in_s3 "$dir" "$source_dir"; then
        echo "$(current_datetime) Upload verified. Cleaning up local zip files..."
        rm "${dir}".zip.??? 2>/dev/null
        echo "$(current_datetime) Local zip files removed for $(basename "$dir")"
        send_notification "S3 Upload Complete" "Successfully uploaded and verified $(basename "$dir")"
    else
        echo "$(current_datetime) Upload verification failed for $(basename "$dir"). Keeping local zip files." >&2
        send_alert "S3 Upload Warning" "Upload verification failed for $(basename "$dir"). Local files preserved."
        return 1
    fi
    
    return 0
}

find_zip_parts() {
    local search_dir="$1"
    find "$search_dir" -name "*.zip.001" -type f
}

get_incomplete_uploads() {
    local search_dir="$1"
    local incomplete=()
    
    while IFS= read -r zip_part; do
        local base_name=$(basename "${zip_part}" .zip.001)
        local dir_path=$(dirname "${zip_part}")
        local checksum_file="${dir_path}/${base_name}.zip.md5"
        
        # Only process if checksum file exists and verifies
        if [ -f "$checksum_file" ] && verify_zip_checksum "${dir_path}/${base_name}"; then
            incomplete+=("${dir_path}/${base_name}")
        fi
    done < <(find "$search_dir" -name "*.zip.001" -type f)
    
    echo "${incomplete[@]}"
}

process_uploads() {
    local source_dir="$1"
    local work_found=0

    echo "$(current_datetime) Scanning for incomplete uploads in ${source_dir}..."
    
    # Initialize array
    declare -a incomplete_uploads
    
    # Read into array with proper space handling
    while IFS= read -r line; do
        [ -n "$line" ] && incomplete_uploads+=("$line")
    done < <(get_incomplete_uploads "$source_dir")
    
    if [ ${#incomplete_uploads[@]} -gt 0 ]; then
        work_found=1
        echo "$(current_datetime) Found ${#incomplete_uploads[@]} incomplete uploads"
        for upload in "${incomplete_uploads[@]}"; do
            local relative_path=${upload#"$source_dir/"}
            local s3_path="$(dirname "$relative_path")/$(basename "$upload").zip"
            echo ""
            echo "----------------------------------------"
            echo "$(current_datetime) Resuming upload: $relative_path.zip"
            multipart_upload_to_s3 "$upload" "$s3_path" "$source_dir"
        done
    fi
    
    # Second pass - process new files
    echo "$(current_datetime) Scanning for new files..."
    local new_files=0
    while IFS= read -r dir; do
        if [ -n "$dir" ]; then
            echo ""
            echo "----------------------------------------"
            local zip_file="${dir}.zip"
            local relative_path=${dir#"$source_dir/"}
            local s3_path="$(dirname "$relative_path")/$(basename "$zip_file")"
            if check_file_exists_in_s3 "$s3_path"; then
                echo "$(current_datetime) Skipping ${dir} - already processed"
                continue
            fi
            new_files=1
            work_found=1
            echo "$(current_datetime) Processing library: $(basename "$dir")"
            multipart_upload_to_s3 "$dir" "$s3_path"
        fi
    done < <(find "$source_dir" -name "*.fcpbundle" -type d)

    if [ $work_found -eq 0 ]; then
        echo "$(current_datetime) No work found. Exiting successfully."
        exit 0
    fi
}

main() {
    echo "$(current_datetime) Starting upload process to S3 bucket: $BUCKET_NAME"
    
    # Process each source path
    for source_dir in "$@"; do
        if [ ! -d "$source_dir" ]; then
            echo "$(current_datetime) Warning: Directory not found - $source_dir"
            continue
        fi
        
        echo ""
        echo "========================================"
        echo "$(current_datetime) Processing directory: $source_dir"
        echo "========================================"
        
        process_uploads "$source_dir"
    done
}

# Run the main function with all arguments
main "$@"
exit 0
