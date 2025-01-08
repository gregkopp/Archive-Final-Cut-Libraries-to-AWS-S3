#!/bin/bash

# Archive to S3
# This script archives files and uploads them to an Amazon S3 bucket using multipart upload.
# © 2025 Greg Kopp. All rights reserved.
# This script is licensed under the Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0) license.

# Check if the bucket name is provided as a command line argument
if [ -z "$1" ]; then
    echo "Usage: $0 <bucket-name>"
    exit 1
fi

# Define the S3 bucket name
BUCKET_NAME="$1"

# Get the current directory
SOURCE_PATH=$(pwd)

# Check if the AWS CLI is installed
if ! command -v aws &>/dev/null; then
    echo "AWS CLI not found. Please install it and configure your credentials."
    exit 1
fi

# Function to check if a file exists in S3
check_file_exists_in_s3() {
    local file_path="$1"
    echo "Checking if $(basename "$file_path") exists in S3 bucket..."
    if aws s3 ls "s3://$BUCKET_NAME/$file_path" &>/dev/null; then
        echo "$(basename "$file_path") already exists in S3. Skipping upload."
        return 0  # File exists
    else
        return 1  # File does not exist
    fi
}

# Function to verify file exists in S3
verify_file_exists_in_s3() {
    local file_path="$1"
    echo "Verifying if $(basename "$file_path") exists in S3 bucket..."
    echo "aws s3 ls ${file_path}"
    if aws s3 ls "s3://$BUCKET_NAME/$file_path" &>/dev/null; then
        echo "$(basename "$file_path") exists in S3."
        return 0  # File exists
    else
        return 1  # File does not exist
    fi
}

create_split_zip_file() {
    local dir="$1"
    local part_size="5g"

    # Check if the file has already been split
    echo "Checking for existing split files: ${dir}.zip"
    if compgen -G "${dir}.zip.???" > /dev/null; then
        echo "File has already been split. Skipping 7z command."
        return 0
    fi

    echo "Creating split 7z file $dir.zip..."
    echo "7z a -mx1 -v$part_size $dir.zip $dir"
    7z a -mx1 -v"$part_size" "$dir".zip "$dir" || { echo "Error creating split 7z file"; exit 1; }
}

# Function to upload a file to S3 using multipart upload
multipart_upload_to_s3() {
    local dir="$1"
    local s3_path="$2"

    # Create split zip file
    create_split_zip_file "$dir"
    if [ $? -ne 0 ]; then
        echo "Error creating split zip file. Skipping upload."
        return 1
    fi

    # Check for existing multipart upload
    echo "Checking for existing multipart upload..."
    upload_id=$(aws s3api list-multipart-uploads --bucket "$BUCKET_NAME" --query "Uploads[?Key=='$s3_path'].UploadId" --output text)
    if [ -z "$upload_id" ]; then
        # Initiate new multipart upload if none exists
        upload_id=$(aws s3api create-multipart-upload --bucket "$BUCKET_NAME" --key "$s3_path" --storage-class DEEP_ARCHIVE --query UploadId --output text)
        if [ $? -ne 0 ]; then
            echo "Error initiating multipart upload"
            exit 1
        fi
        echo "Initiated multipart upload with UploadId: $upload_id"
    else
        echo "Resuming multipart upload with UploadId: $upload_id"
    fi

    # List existing parts
    existing_parts=$(aws s3api list-parts --bucket "$BUCKET_NAME" --key "$s3_path" --upload-id "$upload_id" --query 'Parts[].{ETag:ETag,PartNumber:PartNumber}' --output json)

    # Upload each part
    part_number=1
    parts=""
    for part in "${dir}".zip.*; do
        echo "Uploading part $part..."

        # Check if part already exists
        if echo "$existing_parts" | grep -q "\"PartNumber\": $part_number"; then
            echo "Part $part_number already exists. Skipping upload."
            etag=$(echo "$existing_parts" | jq -r ".[] | select(.PartNumber == $part_number) | .ETag")
        else
            echo "Uploading part $part_number..."
            etag=$(aws s3api upload-part --bucket "$BUCKET_NAME" --key "$s3_path" --part-number $part_number --body "$part" --upload-id "$upload_id" --query ETag --output text)
            if [ $? -ne 0 ]; then
                echo "Error uploading part $part_number"
                exit 1
            fi
        fi
        parts="$parts{\"ETag\": $etag, \"PartNumber\": $part_number},"
        part_number=$((part_number + 1))
    done

    # Complete multipart upload
    parts="[${parts%,}]"
    aws s3api complete-multipart-upload --bucket "$BUCKET_NAME" --key "$s3_path" --upload-id "$upload_id" --multipart-upload "{\"Parts\": $parts}"
    if [ $? -ne 0 ]; then
        echo "Error completing multipart upload"
        exit 1
    fi
    echo "Completed multipart upload for $s3_path"
}

# Function to upload a file to S3
upload_to_s3() {
    local dir="$1"
    local s3_path="$2"
    
    echo "Uploading $dir to $s3_path..."
    multipart_upload_to_s3 "$dir" "$s3_path"

    # Verify that the file was uploaded and recombined
    if verify_file_exists_in_s3 "$s3_path"; then
        echo "Verification successful: $dir was uploaded and recombined correctly."
    else
        echo "Verification failed: $dir"
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
            echo "Removing local zip file: $(basename "$zip_file")"
            rm "$zip_file".*
        else
            echo "**** Warning: Upload failed. Keeping local zip file: $(basename "$zip_file")"
        fi
    else
        echo "**** Warning: $(basename "$zip_file") already exists in S3. Keeping local zip file: $(basename "$zip_file")"
    fi
}

# Function to upload directories and their contents
upload_directory_and_contents() {
    local dir="$1"
    echo ""

    if [[ "$dir" == *.fcpbundle ]]; then
        echo "Found Final Cut Pro library: $(basename "$dir")"
        compress_and_upload_fcp_library "$dir"
    else
        echo "Processing directory: $(basename "$dir")"

        # Recurse through the directories here and upload the files within
        find "$dir" -mindepth 1 -maxdepth 1 -type d | while read -r subdir; do
            upload_directory_and_contents "$subdir"
        done
    fi
}

echo "Uploading files and Final Cut Pro libraries from $SOURCE_PATH to S3 bucket: $BUCKET_NAME"

upload_directory_and_contents "$SOURCE_PATH"

echo "All files and Final Cut Pro libraries have been processed for upload to S3 bucket: $BUCKET_NAME"
