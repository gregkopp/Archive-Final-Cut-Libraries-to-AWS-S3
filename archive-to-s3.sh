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
    echo "$(current_datetime) Verifying if $(basename "$file_path") exists in S3 bucket..."
    if $AWS_CLI_PATH s3 ls "s3://$BUCKET_NAME/$file_path" &>/dev/null; then
        echo "$(current_datetime) $(basename "$file_path") exists in S3."
        return 0  # File exists
    else
        return 1  # File does not exist
    fi
}

create_split_zip_file() {
    local dir="$1"
    local part_size="5g"

    # Check if the file has already been split
    echo "$(current_datetime) Checking for existing split files: $(basename "${dir}").zip"
    if compgen -G "${dir}.zip.???" > /dev/null; then
        echo "$(current_datetime) File has already been split. Skipping 7z command."
        return 0
    fi

    echo "$(current_datetime) Creating split 7z file $dir.zip..."
    # brew install p7zip
    7z a -mx1 -v"$part_size" "$dir".zip "$dir" || { echo "Error creating split 7z file"; exit 1; }
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
    # echo "$AWS_CLI_PATH s3api list-multipart-uploads --bucket \"$BUCKET_NAME\" --query \"Uploads[?Key=='$s3_path'].UploadId\" --output text"
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
        echo "$(current_datetime) Error completing multipart upload"
        exit 1
    fi
    echo "$(current_datetime) Completed multipart upload for $s3_path"
    send_notification "S3 Upload Complete" "Successfully uploaded $(basename "$dir") to S3"
}

# Function to upload a file to S3
upload_to_s3() {
    local dir="$1"
    local s3_path="$2"
    
    echo "$(current_datetime) Uploading $(basename "$dir") to $s3_path..."
    multipart_upload_to_s3 "$dir" "$s3_path"

    # Verify that the file was uploaded and recombined
    if verify_file_exists_in_s3 "$s3_path"; then
        echo "$(current_datetime) Verification successful: $(basename "$dir") was uploaded and recombined correctly."
    else
        send_alert "S3 Upload Error" "Verification failed for $(basename "$dir")"
            echo "$(current_datetime) Verification failed: $(basename "$dir")"
        exit 1
    fi
}

# Function to compress and upload a Final Cut Pro library
compress_and_upload_fcp_library() {
    local dir="$1"
    local zip_file="${dir}.zip"

    # Define the S3 path for the compressed library
    local relative_path=${dir#"$SOURCE_PATH/"}
    local s3_path="$(dirname "$relative_path")/$(basename "$zip_file")"

    if ! check_file_exists_in_s3 "$s3_path"; then
        # Upload the compressed file to S3
        if upload_to_s3 "$dir" "$s3_path"; then
            echo "$(current_datetime) Removing local zip file: $(basename "$zip_file")"
            rm "$zip_file".*
        else
            echo "$(current_datetime) Upload failed. Keeping local zip file: $(basename "$zip_file")"
        fi
    else
        echo "*$(current_datetime) $(basename "$zip_file") already exists in S3. Keeping local zip file: $(basename "$zip_file")"
    fi
}

# Function to upload directories and their contents
upload_directory_and_contents() {
    local dir="$1"
    echo ""

    if [[ "$dir" == *.fcpbundle ]]; then
        echo "$(current_datetime) Found Final Cut Pro library: $(basename "$dir")"
        compress_and_upload_fcp_library "$dir"
    else
        echo "$(current_datetime) Processing directory: $(basename "$dir")"

        # Recurse through the directories here and upload the files within
        find "$dir" -mindepth 1 -maxdepth 1 -type d | while read -r subdir; do
            # Check if the directory or its contents are in use
            if lsof +D "$subdir" >/dev/null 2>&1; then
                echo "$(current_datetime) Skipping directory (files in use): $(basename "$subdir")"
                continue
            fi
            upload_directory_and_contents "$subdir"
        done
    fi
}

echo "$(current_datetime) Uploading files and Final Cut Pro libraries from $SOURCE_PATH to S3 bucket: $BUCKET_NAME"

upload_directory_and_contents "$SOURCE_PATH"

echo "$(current_datetime) All files and Final Cut Pro libraries have been processed for upload to S3 bucket: $BUCKET_NAME"
