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

# Check if the script is already running with the same arguments
if pgrep -f "$0 $1 $2" > /dev/null; then
    echo "Script is already running with the same arguments. Exiting."
    exit 1
fi

# Check if the bucket name is provided as a command line argument
if [ -z "$1" ]; then
    echo "Usage: $0 <bucket-name> [source-path]"
    exit 1
fi

# Define the S3 bucket name
BUCKET_NAME="$1"

# Get the source path (current directory if not provided)
SOURCE_PATH="${2:-$(pwd)}"

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

    local relative_path=${dir_path#"$SOURCE_PATH/"}
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
    local part_size_bytes=$((5 * 1024 * 1024 * 1024))  # 5GB in bytes

    # Check if the file has already been split
    echo "$(current_datetime) Checking for existing split files: $(basename "${dir}").zip"
    
    if compgen -G "${dir}.zip.???" > /dev/null; then
        echo "$(current_datetime) Split files exist. Skipping 7z command."
        return 0
    fi

    echo "$(current_datetime) Creating split 7z file $dir.zip..."
    /usr/local/bin/7z a -mx0 -v"$part_size" "$dir".zip "$dir" || { 
        echo "$(current_datetime) Error creating split 7z file"; 
        exit 1; 
    }
}

# Function to upload a file to S3 using multipart upload
multipart_upload_to_s3() {
    local dir="$1"
    local s3_path="$2"

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
    if verify_file_exists_in_s3 "$dir"; then
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
        local zip_file="${base_name}.zip"
        local relative_path=${dir_path#"$SOURCE_PATH/"}
        local s3_path="$relative_path/$zip_file"
        
        # Check for existing multipart upload
        upload_id=$($AWS_CLI_PATH s3api list-multipart-uploads \
            --bucket "$BUCKET_NAME" \
            --query "Uploads[?Key=='$s3_path'].UploadId" \
            --output text)
            
        if [ -n "$upload_id" ] && [ "$upload_id" != "None" ]; then
            incomplete+=("${dir_path}/${base_name}")
        fi
    done < <(find_zip_parts "$search_dir")
    
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
            echo ""
            echo "----------------------------------------"
            echo "$(current_datetime) Resuming upload: $(basename "$upload")"
            local relative_path=${upload#"$SOURCE_PATH/"}
            echo relative_path "$relative_path"
            local s3_path="$(dirname "$relative_path")/$(basename "$upload").zip"
            echo s3_path "$s3_path"
            # TODO Fix the s3 path that is the expected second argument
            echo multipart_upload_to_s3 "$upload" "$s3_path"
            multipart_upload_to_s3 "$upload" "$s3_path"
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
            local relative_path=${dir#"$SOURCE_PATH/"}
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
    local source_dir="$1"
    echo "$(current_datetime) Uploading files and Final Cut Pro libraries from $source_dir to S3 bucket: $BUCKET_NAME"
    process_uploads "$source_dir"
}

main "$SOURCE_PATH"
exit 0
