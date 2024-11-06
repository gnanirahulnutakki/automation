#!/usr/bin/env python3
import os
import boto3
import time
from datetime import datetime, timedelta
import glob
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import logging
from pathlib import Path

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class LogArchiver:
    def __init__(self, base_paths, s3_bucket, s3_prefix):
        """
        Initialize the LogArchiver with configuration

        base_paths: List of paths to check for logs
        s3_bucket: S3 bucket name
        s3_prefix: Prefix for S3 keys
        """
        self.base_paths = base_paths
        self.s3_bucket = s3_bucket
        self.s3_prefix = s3_prefix
        self.s3_client = boto3.client('s3')
        self.state_file = '/var/run/archive-state.json'
        self.yesterday = (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d')

        # Load previous state if exists
        self.state = self._load_state()

    def _load_state(self):
        """Load the previous run state from file"""
        try:
            with open(self.state_file, 'r') as f:
                return json.load(f)
        except FileNotFoundError:
            return {'last_run': None, 'processed_files': {}}

    def _save_state(self):
        """Save the current run state to file"""
        with open(self.state_file, 'w') as f:
            json.dump(self.state, f)

    def _get_file_hash(self, filepath):
        """Get hash of file for change detection"""
        with open(filepath, 'rb') as f:
            return hashlib.md5(f.read()).hexdigest()

    def _should_process_file(self, filepath):
        """Determine if file should be processed based on previous state"""
        if not os.path.exists(filepath):
            return False

        current_hash = self._get_file_hash(filepath)
        last_hash = self.state['processed_files'].get(filepath)

        if last_hash != current_hash:
            self.state['processed_files'][filepath] = current_hash
            return True
        return False

    def _get_timestamp_from_filename(self, filename):
        """Extract timestamp from filename if present"""
        try:
            # Look for date patterns like 2024-10-30 in filename
            for part in filename.split('_'):
                if len(part) == 10 and part.count('-') == 2:
                    return datetime.strptime(part, '%Y-%m-%d')
        except ValueError:
            pass
        return None

    def _get_pod_name(self):
        """Get the current pod name from environment"""
        return os.environ.get('POD_NAME', 'unknown-pod')

    def _upload_to_s3(self, local_path, date_folder):
        """Upload file to S3 with retry logic"""
        pod_name = self._get_pod_name()
        filename = os.path.basename(local_path)

        s3_key = f"{self.s3_prefix}/{date_folder}/{pod_name}/{filename}"

        max_retries = 3
        for attempt in range(max_retries):
            try:
                # Use multipart upload for large files
                self.s3_client.upload_file(
                    local_path,
                    self.s3_bucket,
                    s3_key,
                    Config=boto3.s3.transfer.TransferConfig(
                        multipart_threshold=8388608,  # 8MB
                        max_concurrency=10
                    )
                )
                logger.info(f"Successfully uploaded {local_path} to s3://{self.s3_bucket}/{s3_key}")
                return True
            except Exception as e:
                if attempt == max_retries - 1:
                    logger.error(f"Failed to upload {local_path} after {max_retries} attempts: {str(e)}")
                    return False
                time.sleep(2 ** attempt)  # Exponential backoff
        return False

    def process_logs(self):
        """Main method to process and archive logs"""
        for base_path in self.base_paths:
            if not os.path.exists(base_path):
                logger.warning(f"Path {base_path} does not exist, skipping...")
                continue

            # Get all log files in the path
            log_files = []
            for ext in ['*.log', '*.log.*', '*.log.zip']:
                log_files.extend(glob.glob(os.path.join(base_path, ext)))

            # Process files in parallel
            with ThreadPoolExecutor(max_workers=10) as executor:
                futures = []
                for log_file in log_files:
                    if self._should_process_file(log_file):
                        timestamp = self._get_timestamp_from_filename(os.path.basename(log_file))
                        date_folder = timestamp.strftime('%Y-%m-%d') if timestamp else self.yesterday

                        futures.append(
                            executor.submit(self._upload_to_s3, log_file, date_folder)
                        )

                # Wait for all uploads to complete
                for future in futures:
                    future.result()

        # Save state after processing
        self._save_state()

if __name__ == "__main__":
    # Configuration
    BASE_PATHS = [
        "/opt/radiantone/vds/vds_server/logs",
        "/opt/radiantone/vds/vds_server/logs/jetty",
        "/opt/radiantone/vds/vds_server/logs/sync_engine",
        "/opt/radiantone/vds/logs"
    ]

    archiver = LogArchiver(
        base_paths=BASE_PATHS,
        s3_bucket=os.environ['S3_BUCKET'],
        s3_prefix=os.environ['S3_PREFIX']
    )

    archiver.process_logs()
