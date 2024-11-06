import os
import sys
import argparse
from kubernetes import client, config
import tempfile
import gzip
import zipfile
import boto3
import re
from datetime import datetime
from pathlib import Path
import logging
from concurrent.futures import ThreadPoolExecutor
import time

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class K8sLogCollector:
    def __init__(self):
        self.v1 = None
        self.namespace = None
        self.destination = None
        self.s3_bucket = None
        self.s3_client = None

    LOG_LOCATIONS = {
        'vds_server': {
            'path': '/opt/radiantone/vds/vds_server/logs',
            'files': ['vds_server.log', 'vds_server_access.log', 'periodiccache.log', 'vds_events.log']
        },
        'jetty': {
            'path': '/opt/radiantone/vds/vds_server/logs/jetty',
            'files': ['web.log', 'web_access.log']
        },
        'sync_engine': {
            'path': '/opt/radiantone/vds/vds_server/logs/sync_engine',
            'files': ['sync_engine.log']
        },
        'alerts': {
            'path': '/opt/radiantone/vds/logs',
            'files': ['alerts.log']
        }
    }

    def initialize_kubernetes(self, kubeconfig_path):
        """Initialize Kubernetes client with provided kubeconfig"""
        try:
            config.load_kube_config(kubeconfig_path)
            self.v1 = client.CoreV1Api()
            # Test connection
            self.v1.list_namespace()
            logger.info("Successfully connected to Kubernetes cluster")
            return True
        except Exception as e:
            logger.error(f"Failed to connect to Kubernetes cluster: {e}")
            return False

    def setup_s3(self, bucket_name):
        """Initialize S3 client and verify bucket access"""
        try:
            self.s3_client = boto3.client('s3')
            self.s3_bucket = bucket_name
            # Test bucket access
            self.s3_client.head_bucket(Bucket=bucket_name)
            logger.info(f"Successfully connected to S3 bucket: {bucket_name}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect to S3 bucket: {e}")
            return False

    def get_statefulset_pods(self, namespace, statefulset_name):
        """Get pods belonging to a StatefulSet"""
        try:
            pods = self.v1.list_namespaced_pod(
                namespace,
                label_selector=f"app={statefulset_name}"
            )
            return [pod for pod in pods.items if pod.status.phase == 'Running']
        except Exception as e:
            logger.error(f"Failed to get pods for StatefulSet {statefulset_name}: {e}")
            return []

    def extract_date_from_filename(self, filename):
        """Extract date from log filename"""
        date_pattern = r'\d{4}-\d{2}-\d{2}'
        match = re.search(date_pattern, filename)
        return match.group(0) if match else None

    def copy_logs_from_pod(self, pod, location_info, base_dest_path):
        """Copy logs from a specific location in a pod"""
        pod_name = pod.metadata.name

        for log_file in location_info['files']:
            try:
                # List files in the directory
                exec_command = ['/bin/sh', '-c', f'ls -1 {location_info["path"]}']
                resp = stream = self.v1.connect_get_namespaced_pod_exec(
                    pod_name,
                    self.namespace,
                    command=exec_command,
                    stderr=True, stdin=False,
                    stdout=True, tty=False
                )

                files = resp.split('\n')
                matching_files = [f for f in files if f.startswith(log_file.replace('.log', ''))]

                for file in matching_files:
                    # Extract date if present
                    date_str = self.extract_date_from_filename(file)
                    dest_folder = f"{pod_name}-{date_str}" if date_str else pod_name

                    # Create destination folder
                    dest_path = os.path.join(base_dest_path, self.namespace, dest_folder)
                    os.makedirs(dest_path, exist_ok=True)

                    # Copy file
                    source_path = f"{location_info['path']}/{file}"
                    self.copy_single_file(pod_name, source_path, dest_path, file)

                    # Add delay between files
                    time.sleep(1)

            except Exception as e:
                logger.error(f"Error copying {log_file} from {pod_name}: {e}")

    def copy_single_file(self, pod_name, source_path, dest_path, filename):
        """Copy a single file from pod"""
        try:
            # Use kubectl cp command through exec
            exec_command = ['/bin/sh', '-c', f'cat {source_path}']
            resp = self.v1.connect_get_namespaced_pod_exec(
                pod_name,
                self.namespace,
                command=exec_command,
                stderr=True, stdin=False,
                stdout=True, tty=False
            )

            dest_file = os.path.join(dest_path, filename)
            with open(dest_file, 'wb') as f:
                f.write(resp.encode())

            if self.s3_bucket:
                s3_key = f"{self.namespace}/{pod_name}/{filename}"
                self.s3_client.upload_file(dest_file, self.s3_bucket, s3_key)
                logger.info(f"Uploaded {filename} to S3: {s3_key}")

            logger.info(f"Successfully copied {filename} from {pod_name}")

        except Exception as e:
            logger.error(f"Failed to copy {filename} from {pod_name}: {e}")

    def collect_logs(self, namespace, destination, s3_bucket=None):
        """Main method to collect logs"""
        self.namespace = namespace
        self.destination = destination

        if s3_bucket:
            if not self.setup_s3(s3_bucket):
                return False

        # Create base destination directory
        os.makedirs(destination, exist_ok=True)

        # Process FID pods
        fid_pods = self.get_statefulset_pods(namespace, "fid")

        for pod in fid_pods:
            logger.info(f"Processing pod: {pod.metadata.name}")

            # Process each log location
            for location_info in self.LOG_LOCATIONS.values():
                self.copy_logs_from_pod(pod, location_info, destination)
                time.sleep(2)  # Delay between locations

        return True

def main():
    parser = argparse.ArgumentParser(description='Kubernetes Log Collector')
    parser.add_argument('--kubeconfig', required=True, help='Path to kubeconfig file')
    parser.add_argument('--namespace', required=True, help='Kubernetes namespace')
    parser.add_argument('--destination', required=True, help='Local destination path')
    parser.add_argument('--s3-bucket', help='Optional S3 bucket name')

    args = parser.parse_args()

    collector = K8sLogCollector()

    if not collector.initialize_kubernetes(args.kubeconfig):
        sys.exit(1)

    if collector.collect_logs(args.namespace, args.destination, args.s3_bucket):
        logger.info("Log collection completed successfully")
    else:
        logger.error("Log collection failed")
        sys.exit(1)

if __name__ == "__main__":
    main()
