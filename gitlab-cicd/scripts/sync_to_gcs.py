import sys
import os
from google.cloud import storage
from google.api_core.exceptions import GoogleAPIError


def upload_directory_to_gcs(bucket_name, source_folder, destination_blob_prefix):
    if not os.path.isdir(source_folder):
        print(f"Error: source folder does not exist: {source_folder}", file=sys.stderr)
        sys.exit(1)

    try:
        client = storage.Client()
        bucket = client.bucket(bucket_name)
    except GoogleAPIError as e:
        print(f"Error: failed to connect to GCS: {e}", file=sys.stderr)
        sys.exit(1)

    failed = []
    for root, _, files in os.walk(source_folder):
        for file in files:
            local_path = os.path.join(root, file)
            relative_path = os.path.relpath(local_path, source_folder)
            blob_path = os.path.join(destination_blob_prefix, relative_path)

            try:
                blob = bucket.blob(blob_path)
                blob.upload_from_filename(local_path)
                print(f"Uploaded {local_path} to {blob_path}")
            except (GoogleAPIError, OSError) as e:
                print(f"Error: failed to upload {local_path}: {e}", file=sys.stderr)
                failed.append(local_path)

    if failed:
        print(f"\n{len(failed)} file(s) failed to upload:", file=sys.stderr)
        for f in failed:
            print(f"  - {f}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python sync_to_gcs.py <bucket_name> <destination_blob_prefix>")
        sys.exit(1)

    bucket_name = sys.argv[1]
    destination_blob_prefix = sys.argv[2]
    source_folder = './Convertor/ClientJson'

    upload_directory_to_gcs(bucket_name, source_folder, destination_blob_prefix)
