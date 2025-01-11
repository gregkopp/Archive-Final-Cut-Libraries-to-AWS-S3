#!/bin/bash

# Check if the bucket name is provided as a command line argument
if [ -z "$1" ]; then
    echo "Usage: $0 <bucket-name> [days]"
    exit 1
fi

BUCKET_NAME="$1"
DAYS="${2:-3}"

# Calculate the threshold date
THRESHOLD_DATE=$(date -v -"$DAYS"d -u +%Y-%m-%dT%H:%M:%SZ)

# List multipart uploads
uploads=$(aws s3api list-multipart-uploads --bucket $BUCKET_NAME --query 'Uploads[?Initiated<=`'$THRESHOLD_DATE'`].[Key,UploadId]' --output text)

# Loop through the uploads and delete them
echo "$uploads" | while IFS=$'\t' read -r key upload_id; do
  if [ -n "$key" ] && [ -n "$upload_id" ]; then
    echo "Deleting multipart upload: \"$key\""
    aws s3api abort-multipart-upload --bucket $BUCKET_NAME --key "$key" --upload-id "$upload_id"
    if [ $? -ne 0 ]; then
        echo "Failed to abort upload for file: $key in bucket: $BUCKET_NAME. It may have already been aborted or completed."
    else
        echo "Successfully aborted upload for file: $key in bucket: $BUCKET_NAME"
    fi
  fi
done