#!/usr/bin/env python3
"""
Vault Audit Log Exporter for Prometheus

This exporter tails the Vault audit log file, parses JSON entries,
and exposes Prometheus metrics for monitoring Vault operations.
"""

import json
import logging
import os
import sys
import time
from collections import defaultdict
from datetime import datetime
from typing import Dict, Optional

from prometheus_client import Counter, Gauge, Histogram, start_http_server

# Configure logging
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('vault_audit_exporter')

# Configuration
AUDIT_LOG_PATH = os.getenv('AUDIT_LOG_PATH', '/audit/audit.log')
EXPORTER_PORT = int(os.getenv('EXPORTER_PORT', '9091'))
TAIL_INTERVAL = float(os.getenv('TAIL_INTERVAL', '0.5'))  # seconds

# Prometheus Metrics
# 1. Request Count Metrics
requests_total = Counter(
    'vault_audit_requests_total',
    'Total number of Vault requests',
    ['operation', 'path', 'mount_type', 'namespace', 'status']
)

# 2. Response Status Metrics
responses_total = Counter(
    'vault_audit_responses_total',
    'Total number of Vault responses',
    ['status_code', 'mount_type', 'operation']
)

# 3. Authentication Metrics
auth_requests_total = Counter(
    'vault_audit_auth_requests_total',
    'Total number of authenticated requests',
    ['auth_method', 'display_name', 'namespace']
)

# 4. Mount Point Activity
mount_requests_total = Counter(
    'vault_audit_mount_requests_total',
    'Total requests per mount point',
    ['mount_point', 'mount_type', 'operation']
)

# 5. Error and Warning Metrics
errors_total = Counter(
    'vault_audit_errors_total',
    'Total number of errors',
    ['error_type', 'path', 'operation']
)

warnings_total = Counter(
    'vault_audit_warnings_total',
    'Total number of warnings',
    ['warning_type', 'path']
)

# 6. Latency Metrics (Histogram)
request_duration_seconds = Histogram(
    'vault_audit_request_duration_seconds',
    'Request duration in seconds',
    ['operation', 'mount_type'],
    buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0]
)

# 7. Lease Metrics
lease_operations_total = Counter(
    'vault_audit_lease_operations_total',
    'Total lease operations',
    ['operation', 'mount_type']
)

# 8. PKI-Specific Metrics
pki_operations_total = Counter(
    'vault_audit_pki_operations_total',
    'Total PKI operations',
    ['operation']
)

# 9. Exporter Health Metrics
lines_processed_total = Counter(
    'vault_audit_exporter_lines_processed_total',
    'Total lines processed by exporter'
)

parse_errors_total = Counter(
    'vault_audit_exporter_parse_errors_total',
    'Total parse errors encountered'
)

last_processed_timestamp = Gauge(
    'vault_audit_exporter_last_processed_timestamp',
    'Timestamp of last processed log entry'
)


class AuditLogProcessor:
    """Process Vault audit log entries and update Prometheus metrics."""
    
    def __init__(self):
        self.request_cache: Dict[str, Dict] = {}  # Cache requests for latency calculation
        self.cache_max_age = 300  # 5 minutes
        
    def process_line(self, line: str) -> None:
        """Process a single audit log line."""
        try:
            entry = json.loads(line.strip())
            lines_processed_total.inc()
            
            entry_type = entry.get('type')
            timestamp = entry.get('time')
            
            if timestamp:
                try:
                    ts = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
                    last_processed_timestamp.set(ts.timestamp())
                except Exception as e:
                    logger.debug(f"Failed to parse timestamp: {e}")
            
            if entry_type == 'request':
                self._process_request(entry)
            elif entry_type == 'response':
                self._process_response(entry)
            else:
                logger.debug(f"Unknown entry type: {entry_type}")
                
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            parse_errors_total.inc()
        except Exception as e:
            logger.error(f"Error processing line: {e}")
            parse_errors_total.inc()
    
    def _process_request(self, entry: Dict) -> None:
        """Process a request entry."""
        request = entry.get('request', {})
        auth = entry.get('auth', {})
        
        request_id = request.get('id')
        operation = request.get('operation', 'unknown')
        path = request.get('path', 'unknown')
        mount_point = request.get('mount_point', 'unknown')
        mount_type = request.get('mount_type', 'unknown')
        
        # Extract namespace - try multiple fields
        namespace_obj = request.get('namespace', {})
        if isinstance(namespace_obj, dict):
            # Try 'path' first (e.g., "master-demo/"), then 'id'
            namespace = namespace_obj.get('path', namespace_obj.get('id', 'root'))
            # Clean up namespace path (remove trailing slash)
            namespace = namespace.rstrip('/') if namespace else 'root'
        else:
            namespace = str(namespace_obj) if namespace_obj else 'root'
        
        # Cache request for latency calculation
        if request_id:
            self.request_cache[request_id] = {
                'timestamp': entry.get('time'),
                'operation': operation,
                'mount_type': mount_type
            }
        
        # Update request counter
        requests_total.labels(
            operation=operation,
            path=self._sanitize_path(path),
            mount_type=mount_type,
            namespace=namespace,
            status='pending'
        ).inc()
        
        # Update mount point counter
        if mount_point != 'unknown':
            mount_requests_total.labels(
                mount_point=mount_point,
                mount_type=mount_type,
                operation=operation
            ).inc()
        
        # Update authentication metrics
        if auth:
            display_name = auth.get('display_name', 'unknown')
            # Also check auth metadata for more context
            auth_metadata = auth.get('metadata', {})
            auth_accessor = auth.get('accessor', '')
            
            # Extract auth method from multiple sources
            auth_method = self._extract_auth_method(display_name, auth_metadata, auth_accessor)
            
            auth_requests_total.labels(
                auth_method=auth_method,
                display_name=self._sanitize_display_name(display_name),
                namespace=namespace
            ).inc()
        
        # Track lease operations
        if 'lease' in path.lower():
            lease_op = 'renew' if 'renew' in path else 'revoke' if 'revoke' in path else 'other'
            lease_operations_total.labels(
                operation=lease_op,
                mount_type=mount_type
            ).inc()
        
        # Track PKI operations
        if mount_type == 'pki':
            pki_op = self._extract_pki_operation(path)
            if pki_op:
                pki_operations_total.labels(operation=pki_op).inc()
    
    def _process_response(self, entry: Dict) -> None:
        """Process a response entry."""
        request = entry.get('request', {})
        response = entry.get('response', {})
        
        request_id = request.get('id')
        operation = request.get('operation', 'unknown')
        path = request.get('path', 'unknown')
        mount_type = request.get('mount_type', 'unknown')
        
        # Extract namespace - try multiple fields (same as _process_request)
        namespace_obj = request.get('namespace', {})
        if isinstance(namespace_obj, dict):
            namespace = namespace_obj.get('path', namespace_obj.get('id', 'root'))
            namespace = namespace.rstrip('/') if namespace else 'root'
        else:
            namespace = str(namespace_obj) if namespace_obj else 'root'
        
        # Determine status
        error = entry.get('error')
        status = 'error' if error else 'success'
        
        # Update request counter with final status
        requests_total.labels(
            operation=operation,
            path=self._sanitize_path(path),
            mount_type=mount_type,
            namespace=namespace,
            status=status
        ).inc()
        
        # Update response status counter
        # Vault doesn't include HTTP status codes in audit logs, so we infer
        status_code = '500' if error else '200'
        responses_total.labels(
            status_code=status_code,
            mount_type=mount_type,
            operation=operation
        ).inc()
        
        # Calculate latency if we have the request
        if request_id and request_id in self.request_cache:
            try:
                req_time = self.request_cache[request_id]['timestamp']
                resp_time = entry.get('time')
                
                if req_time and resp_time:
                    req_ts = datetime.fromisoformat(req_time.replace('Z', '+00:00'))
                    resp_ts = datetime.fromisoformat(resp_time.replace('Z', '+00:00'))
                    duration = (resp_ts - req_ts).total_seconds()
                    
                    request_duration_seconds.labels(
                        operation=operation,
                        mount_type=mount_type
                    ).observe(duration)
                
                # Clean up cache
                del self.request_cache[request_id]
            except Exception as e:
                logger.debug(f"Failed to calculate latency: {e}")
        
        # Track errors
        if error:
            errors_total.labels(
                error_type=self._sanitize_error(error),
                path=self._sanitize_path(path),
                operation=operation
            ).inc()
        
        # Track warnings
        warnings = response.get('warnings', [])
        if warnings:
            for warning in warnings:
                warnings_total.labels(
                    warning_type=self._sanitize_warning(warning),
                    path=self._sanitize_path(path)
                ).inc()
    
    def _sanitize_path(self, path: str) -> str:
        """Sanitize path to reduce cardinality."""
        # Remove UUIDs and other high-cardinality components
        parts = path.split('/')
        sanitized = []
        for part in parts:
            # Keep known path segments, replace dynamic ones
            if len(part) > 20 or '-' in part and len(part) > 10:
                sanitized.append('<dynamic>')
            else:
                sanitized.append(part)
        return '/'.join(sanitized)
    
    def _sanitize_display_name(self, name: str) -> str:
        """Sanitize display name to reduce cardinality."""
        # Keep the role/service account pattern but remove namespace details
        if 'master-demo-auth' in name:
            parts = name.split('-')
            if len(parts) >= 4:
                return f"{parts[0]}-{parts[1]}-{parts[2]}-<namespace>-<sa>"
        return name[:50]  # Limit length
    
    def _extract_auth_method(self, display_name: str, auth_metadata: Dict = None, auth_accessor: str = '') -> str:
        """Extract authentication method from display name and metadata."""
        if auth_metadata is None:
            auth_metadata = {}
            
        # Check metadata for auth method (most reliable)
        if 'role_name' in auth_metadata:
            # Kubernetes auth has role_name in metadata
            return 'kubernetes'
        
        # Check accessor for auth method prefix (e.g., "auth_kubernetes_...")
        if auth_accessor:
            if auth_accessor.startswith('auth_kubernetes'):
                return 'kubernetes'
            elif auth_accessor.startswith('auth_userpass'):
                return 'userpass'
            elif auth_accessor.startswith('auth_github'):
                return 'github'
            elif auth_accessor.startswith('auth_cert'):
                return 'cert'
        
        # Fall back to display_name patterns
        # Kubernetes auth: service accounts contain namespace/sa pattern
        if '/' in display_name or 'system:serviceaccount' in display_name:
            return 'kubernetes'
        elif 'master-demo-auth' in display_name:
            return 'kubernetes'
        elif 'userpass' in display_name.lower() or display_name == 'demo':
            return 'userpass'
        elif 'github' in display_name.lower():
            return 'github'
        elif 'cert' in display_name.lower():
            return 'cert'
        elif 'token' in display_name.lower():
            return 'token'
        elif 'root' in display_name.lower():
            return 'root'
        
        return 'unknown'
    
    def _extract_pki_operation(self, path: str) -> Optional[str]:
        """Extract PKI operation from path."""
        if 'issue' in path:
            return 'issue'
        elif 'revoke' in path:
            return 'revoke'
        elif 'sign' in path:
            return 'sign'
        return None
    
    def _sanitize_error(self, error: str) -> str:
        """Sanitize error message to reduce cardinality."""
        # Extract error type, not full message
        if 'permission denied' in error.lower():
            return 'permission_denied'
        elif 'not found' in error.lower():
            return 'not_found'
        elif 'invalid' in error.lower():
            return 'invalid_request'
        return 'other'
    
    def _sanitize_warning(self, warning: str) -> str:
        """Sanitize warning message to reduce cardinality."""
        if 'ttl' in warning.lower():
            return 'ttl_exceeded'
        elif 'deprecat' in warning.lower():
            return 'deprecated'
        return 'other'
    
    def cleanup_cache(self) -> None:
        """Remove old entries from request cache."""
        now = datetime.now()
        to_remove = []
        
        for req_id, req_data in self.request_cache.items():
            try:
                req_time = req_data['timestamp']
                req_ts = datetime.fromisoformat(req_time.replace('Z', '+00:00'))
                age = (now - req_ts.replace(tzinfo=None)).total_seconds()
                
                if age > self.cache_max_age:
                    to_remove.append(req_id)
            except Exception:
                to_remove.append(req_id)
        
        for req_id in to_remove:
            del self.request_cache[req_id]
        
        if to_remove:
            logger.debug(f"Cleaned up {len(to_remove)} old cache entries")


def tail_file(filepath: str, processor: AuditLogProcessor) -> None:
    """Tail a file and process new lines."""
    logger.info(f"Starting to tail {filepath}")
    
    # Wait for file to exist
    while not os.path.exists(filepath):
        logger.warning(f"Waiting for {filepath} to exist...")
        time.sleep(5)
    
    logger.info(f"File {filepath} found, starting to process")
    
    # Open file and seek to end
    with open(filepath, 'r') as f:
        # Go to end of file
        f.seek(0, 2)
        
        last_cleanup = time.time()
        
        while True:
            line = f.readline()
            
            if line:
                processor.process_line(line)
            else:
                # No new line, sleep briefly
                time.sleep(TAIL_INTERVAL)
                
                # Check if file was rotated
                try:
                    current_inode = os.stat(filepath).st_ino
                    file_inode = os.fstat(f.fileno()).st_ino
                    
                    if current_inode != file_inode:
                        logger.info("Log file rotated, reopening...")
                        break  # Exit loop to reopen file
                except Exception as e:
                    logger.error(f"Error checking file rotation: {e}")
            
            # Periodic cache cleanup
            if time.time() - last_cleanup > 60:
                processor.cleanup_cache()
                last_cleanup = time.time()


def main():
    """Main entry point."""
    logger.info(f"Vault Audit Exporter starting on port {EXPORTER_PORT}")
    logger.info(f"Monitoring audit log: {AUDIT_LOG_PATH}")
    logger.info(f"Log level: {LOG_LEVEL}")
    
    # Start Prometheus HTTP server
    start_http_server(EXPORTER_PORT)
    logger.info(f"Metrics server started on port {EXPORTER_PORT}")
    
    # Create processor
    processor = AuditLogProcessor()
    
    # Tail file in a loop (handles rotation)
    while True:
        try:
            tail_file(AUDIT_LOG_PATH, processor)
        except Exception as e:
            logger.error(f"Error in tail loop: {e}")
            time.sleep(5)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        logger.info("Exporter stopped by user")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)

# Made with Bob
