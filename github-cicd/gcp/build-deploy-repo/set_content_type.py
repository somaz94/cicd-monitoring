from google.cloud import storage
from urllib.parse import unquote

def set_content_type(bucket_name, blob_name):
    # Decode the URL-encoded object name
    blob_name = unquote(blob_name)
    
    # Connect to GCS
    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)
    
    # Get the object (blob) and update its content type
    try:
        blob = bucket.blob(blob_name)
        blob.content_type = "text/html"
        blob.patch()
    except Exception as e:
        print(f"Failed to set content type for blob {blob_name} in bucket {bucket_name}. Error: {str(e)}")

if __name__ == "__main__":
    import sys
    bucket_name = sys.argv[1]
    blob_name = sys.argv[2]
    set_content_type(bucket_name, blob_name)

