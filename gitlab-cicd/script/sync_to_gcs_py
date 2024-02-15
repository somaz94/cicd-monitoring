import sys
from google.cloud import storage
import os

def upload_directory_to_gcs(bucket_name, source_folder, destination_blob_prefix):
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    
    for root, _, files in os.walk(source_folder):
        for file in files:
            local_path = os.path.join(root, file)
            relative_path = os.path.relpath(local_path, source_folder)
            blob_path = os.path.join(destination_blob_prefix, relative_path)
            
            blob = bucket.blob(blob_path)
            blob.upload_from_filename(local_path)
            print(f"Uploaded {local_path} to {blob_path}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python sync_to_gcs.py <bucket_name> <destination_blob_prefix>")
        sys.exit(1)

    bucket_name = sys.argv[1]
    destination_blob_prefix = sys.argv[2]
    source_folder = './Convertor/SomazClientJson'

    upload_directory_to_gcs(bucket_name, source_folder, destination_blob_prefix)

