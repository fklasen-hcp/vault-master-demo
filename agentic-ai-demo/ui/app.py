#!/usr/bin/env python3
from flask import Flask, render_template_string, jsonify, request, session
import requests
import os
import json
from datetime import datetime
import secrets
import subprocess
import re
import hvac
import psycopg2
from psycopg2.extras import RealDictCursor
from kubernetes import client, config
from kubernetes.stream import stream

app = Flask(__name__)
app.secret_key = secrets.token_hex(32)

# Configuration
AI_AGENT_URL = os.environ.get('AI_AGENT_URL', 'http://ai-agent.agentic-demo.svc.cluster.local:8001')
JWT_SECRET = os.environ.get('JWT_SECRET', 'demo-secret-key-change-in-production')  # Fallback for HMAC
VAULT_ADDR = os.environ.get('VAULT_ADDR', 'https://host.minikube.internal:8200')
VAULT_NAMESPACE = os.environ.get('VAULT_NAMESPACE', 'master-demo')
VAULT_SKIP_VERIFY = os.environ.get('VAULT_SKIP_VERIFY', 'true').lower() == 'true'

# PostgreSQL Configuration
POSTGRES_HOST = os.environ.get('POSTGRES_HOST', 'postgres-postgresql.postgres.svc.cluster.local')
POSTGRES_PORT = os.environ.get('POSTGRES_PORT', '5432')
POSTGRES_DB = os.environ.get('POSTGRES_DB', 'products')
POSTGRES_USER = os.environ.get('POSTGRES_USER', 'postgres')
POSTGRES_PASSWORD = os.environ.get('POSTGRES_PASSWORD', 'rootpassword')

# In-memory audit log storage (in production, this would come from Vault audit logs)
audit_logs = []

# In-memory cache for raw Vault audit logs (filtered for this demo)
# This accumulates logs over time so they don't disappear
vault_audit_log_cache = []
VAULT_AUDIT_LOG_CACHE_MAX = 200  # Keep last 200 filtered logs

# In-memory cache for PostgreSQL logs
pg_log_cache = []
PG_LOG_CACHE_MAX = 50  # Keep last 50 log entries
pg_log_cleared_at = None  # Timestamp when logs were last cleared

# JWT signing key (RSA private key fetched from Vault)
JWT_PRIVATE_KEY = None
VAULT_CLIENT = None

# Kubernetes client (initialized once)
K8S_CLIENT = None

def authenticate_to_vault():
    """Authenticate to Vault using Kubernetes auth"""
    global VAULT_CLIENT
    
    try:
        # Read service account token
        with open('/var/run/secrets/kubernetes.io/serviceaccount/token', 'r') as f:
            jwt_token = f.read().strip()
        
        # Create Vault client
        client = hvac.Client(
            url=VAULT_ADDR,
            namespace=VAULT_NAMESPACE,
            verify=not VAULT_SKIP_VERIFY
        )
        
        # Authenticate using Kubernetes auth
        auth_response = client.auth.kubernetes.login(
            role='master-demo-auth-role-agentic-ui',
            jwt=jwt_token,
            mount_point='master-demo-auth'
        )
        
        VAULT_CLIENT = client
        print("✓ Authenticated to Vault using Kubernetes auth")
        return True
        
    except Exception as e:
        print(f"⚠ Failed to authenticate to Vault: {e}")
        return False

def fetch_jwt_private_key():
    """Fetch RSA private key from Vault for JWT signing"""
    global JWT_PRIVATE_KEY
    
    # Authenticate to Vault if not already done
    if not VAULT_CLIENT:
        if not authenticate_to_vault():
            print(f"  Falling back to HMAC with JWT_SECRET")
            return False
    
    try:
        # Fetch JWT key from Vault
        secret = VAULT_CLIENT.secrets.kv.v2.read_secret_version(
            path='agentic/jwt-key',
            mount_point='master-demo-kv'
        )
        
        JWT_PRIVATE_KEY = secret['data']['data']['private_key']
        print("✓ JWT private key fetched from Vault")
        return True
        
    except Exception as e:
        print(f"⚠ Failed to fetch JWT key from Vault: {e}")
        print(f"  Falling back to HMAC with JWT_SECRET")
        return False

def generate_jwt_token(user_id, groups):
    """Generate JWT token with RSA256 or fallback to HS256"""
    import jwt
    from datetime import datetime, timedelta
    
    payload = {
        'sub': user_id,
        'groups': groups,
        'iss': 'agentic-demo-ui',
        'aud': 'vault',
        'exp': datetime.utcnow() + timedelta(hours=1),
        'iat': datetime.utcnow()
    }
    
    # Use RSA if available, otherwise fallback to HMAC
    if JWT_PRIVATE_KEY:
        return jwt.encode(payload, JWT_PRIVATE_KEY, algorithm='RS256')
    else:
        return jwt.encode(payload, JWT_SECRET, algorithm='HS256')

@app.route('/')
def index():
    """Main page - login or chat interface"""
    return render_template_string(HTML_TEMPLATE)

@app.route('/api/login', methods=['POST'])
def login():
    """Handle user login"""
    data = request.json
    user_id = data.get('user_id')
    
    if not user_id:
        return jsonify({'error': 'User ID is required'}), 400
    
    # Define user groups
    user_groups = {
        'alice': ['readers'],
        'bob': ['admins']
    }
    
    groups = user_groups.get(user_id, ['readers'])
    
    # Generate JWT token
    token = generate_jwt_token(user_id, groups)
    
    # Store in session
    session['user_id'] = user_id
    session['groups'] = groups
    session['token'] = token
    
    # Add audit log
    audit_logs.append({
        'timestamp': datetime.now().isoformat(),
        'user': user_id,
        'action': 'login',
        'status': 'success'
    })
    
    return jsonify({
        'success': True,
        'user_id': user_id,
        'groups': groups,
        'message': f'Logged in as {user_id}'
    })

@app.route('/api/logout', methods=['POST'])
def logout():
    """Handle user logout"""
    user_id = session.get('user_id', 'unknown')
    
    # Add audit log
    audit_logs.append({
        'timestamp': datetime.now().isoformat(),
        'user': user_id,
        'action': 'logout',
        'status': 'success'
    })
    
    session.clear()
    
    return jsonify({'success': True})

@app.route('/api/chat', methods=['POST'])
def chat():
    """Send message to AI agent"""
    if 'user_id' not in session:
        return jsonify({'error': 'Not authenticated'}), 401
    
    data = request.json
    message = data.get('message')
    
    if not message:
        return jsonify({'error': 'Message is required'}), 400
    
    try:
        # Get token from session
        token = session.get('token')
        user_id = session.get('user_id')
        
        # Call AI agent with token in body (as expected by FastAPI model)
        response = requests.post(
            f'{AI_AGENT_URL}/chat',
            json={
                'message': message,
                'user_token': token
            },
            timeout=30
        )
        
        # Determine actual status based on db_operation field
        status = 'failed'
        response_data = None
        
        if response.status_code == 200:
            response_data = response.json()
            db_operation = response_data.get('db_operation', '')
            response_text = response_data.get('response', '')
            
            # Check if operation was denied/failed
            # Check both db_operation field AND response text for denial
            if (db_operation and '_denied' in db_operation) or 'permission denied' in response_text.lower():
                status = 'denied'
            elif (db_operation and '_failed' in db_operation) or 'operation failed' in response_text.lower():
                status = 'failed'
            else:
                status = 'success'
        
        # Add audit log with accurate status
        audit_logs.append({
            'timestamp': datetime.now().isoformat(),
            'user': user_id,
            'action': 'chat_request',
            'message': message[:50] + '...' if len(message) > 50 else message,
            'status': status
        })
        
        if response.status_code == 200:
            return jsonify(response_data)
        else:
            return jsonify({'error': response.json().get('detail', 'Unknown error')}), response.status_code
            
    except requests.exceptions.Timeout:
        audit_logs.append({
            'timestamp': datetime.now().isoformat(),
            'user': session.get('user_id'),
            'action': 'chat_request',
            'message': message[:50] + '...' if len(message) > 50 else message,
            'status': 'timeout'
        })
        return jsonify({'error': 'Request timeout'}), 504
    except Exception as e:
        audit_logs.append({
            'timestamp': datetime.now().isoformat(),
            'user': session.get('user_id'),
            'action': 'chat_request',
            'message': message[:50] + '...' if len(message) > 50 else message,
            'status': 'error',
            'error': str(e)
        })
        return jsonify({'error': str(e)}), 500

@app.route('/api/session', methods=['GET'])
def get_session():
    """Get current session info"""
    if 'user_id' in session:
        return jsonify({
            'authenticated': True,
            'user_id': session['user_id'],
            'groups': session['groups']
        })
    else:
        return jsonify({'authenticated': False})

@app.route('/api/audit_logs', methods=['GET'])
def get_audit_logs():
    """Get recent audit logs"""
    # Return last 50 logs in reverse chronological order
    return jsonify({'logs': list(reversed(audit_logs[-50:]))})

@app.route('/api/vault_audit_logs', methods=['GET'])
def get_vault_audit_logs():
    """Get raw Vault audit logs from mounted file, filtered for this demo"""
    global vault_audit_log_cache
    
    try:
        # Read from the mounted audit log file (same as Prometheus exporter)
        audit_log_path = '/host-home/audit.log'
        
        if not os.path.exists(audit_log_path):
            return jsonify({
                'logs': vault_audit_log_cache[:50],  # Return cached logs even if file not found
                'message': f'Audit log file not found. Showing cached logs.'
            })
        
        # Read last 1000 lines to find new logs
        try:
            result = subprocess.run(
                ['tail', '-n', '1000', audit_log_path],
                capture_output=True,
                text=True,
                timeout=5
            )
            
            if result.returncode == 0 and result.stdout:
                lines = result.stdout.strip().split('\n')
                
                # Parse and filter JSON lines for this demo
                new_logs = []
                for line in lines:
                    line = line.strip()
                    if line:
                        try:
                            log_entry = json.loads(line)
                            
                            # Filter for agentic demo related logs
                            # Check for database paths, JWT auth, or agentic-related operations
                            path = str(log_entry.get('request', {}).get('path', ''))
                            display_name = str(log_entry.get('auth', {}).get('display_name', ''))
                            namespace = str(log_entry.get('request', {}).get('namespace', ''))
                            
                            # Include if:
                            # 1. Path contains agentic database roles (agentic-readonly-role, agentic-admin-role)
                            # 2. Display name contains agentic demo identifiers
                            # 3. Path is related to agentic policies or auth
                            # 4. Namespace is agentic-demo
                            if (
                                'agentic-readonly-role' in path or
                                'agentic-admin-role' in path or
                                'agentic' in path.lower() or
                                'agentic' in display_name.lower() or
                                'agentic-demo' in namespace.lower() or
                                'master-demo-agentic' in path
                            ):
                                new_logs.append(log_entry)
                                
                        except json.JSONDecodeError:
                            continue
                
                # Add new logs to cache, avoiding duplicates based on time
                existing_times = {log.get('time') for log in vault_audit_log_cache}
                for log in new_logs:
                    if log.get('time') not in existing_times:
                        vault_audit_log_cache.append(log)
                
                # Keep cache size under limit (remove oldest)
                if len(vault_audit_log_cache) > VAULT_AUDIT_LOG_CACHE_MAX:
                    vault_audit_log_cache = vault_audit_log_cache[-VAULT_AUDIT_LOG_CACHE_MAX:]
                
                # Return cached logs, newest first, limited to 50
                cached_logs = sorted(vault_audit_log_cache, key=lambda x: x.get('time', ''), reverse=True)
                return jsonify({'logs': cached_logs[:50]})
            else:
                return jsonify({
                    'logs': [],
                    'message': 'Unable to read audit log file'
                })
                
        except subprocess.TimeoutExpired:
            return jsonify({
                'logs': [],
                'message': 'Timeout reading audit log file'
            })
            
    except Exception as e:
        return jsonify({'logs': [], 'error': str(e)}), 500
@app.route('/api/db_logs')
def get_db_logs():
    """Get PostgreSQL logs from pod stdout/stderr using Kubernetes API"""
    global K8S_CLIENT, pg_log_cache, pg_log_cleared_at
    try:
        # Initialize Kubernetes client once
        if K8S_CLIENT is None:
            config.load_incluster_config()
            K8S_CLIENT = client.CoreV1Api()
        
        # Get pod logs directly (PostgreSQL logs to stdout/stderr)
        # Increased tail_lines to keep more history during demos
        log_output = K8S_CLIENT.read_namespaced_pod_log(
            name='postgres-postgresql-0',
            namespace='postgres',
            tail_lines=1000,  # Keep more logs for demo purposes
            _preload_content=False  # Don't cache
        ).read().decode('utf-8')
        
        print(f"DEBUG: Got {len(log_output)} bytes of log data")
        
        log_lines = log_output.strip().split('\n') if log_output else []
        print(f"DEBUG: Processing {len(log_lines)} log lines")
        
        # Parse log lines for interesting activity
        logs = []
        for line in log_lines:
            # Show queries on products table AND permission errors
            # Exclude internal PostgreSQL operations
            if ('products' in line.lower() or 'ERROR' in line or 'permission denied' in line.lower()) and \
               'DROP ROLE' not in line and \
               'pg_catalog' not in line and \
               'pg_stat' not in line and \
               'information_schema' not in line and \
               'table_name' not in line.lower():
                # Try to extract timestamp
                # PostgreSQL log format: timestamp [pid] LOG/ERROR: message
                match = re.search(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}.\d+)', line)
                timestamp_str = match.group(1) if match else datetime.now().isoformat()
                
                # Note: Timestamp filtering removed to prevent logs from disappearing during demos
                # The clear button is kept for manual clearing if needed
                
                # Extract user if present and filter out non-agentic users
                user_match = re.search(r'(v-[^\s@]+)', line)
                if user_match:
                    user = user_match.group(1)
                    # Skip logs from other demos (not agentic)
                    if not user.startswith('v-master-d-agentic-'):
                        continue
                else:
                    # Keep system logs (no user)
                    user = 'system'
                
                # Determine state
                if 'ERROR' in line or 'permission denied' in line.lower():
                    state = 'error'
                elif 'FATAL' in line:
                    state = 'fatal'
                else:
                    state = 'info'
                
                # Extract message after LOG/ERROR/STATEMENT
                message = line
                for keyword in ['LOG:', 'ERROR:', 'STATEMENT:', 'DETAIL:']:
                    if keyword in line:
                        message = line[line.find(keyword)+len(keyword):].strip()
                        break
                
                log_entry = {
                    'timestamp': timestamp_str,
                    'user': user,
                    'state': state,
                    'query': message[:200] + '...' if len(message) > 200 else message
                }
                logs.append(log_entry)
        
        print(f"DEBUG: Found {len(logs)} matching log entries (after filtering cleared)")
        
        # Update cache
        pg_log_cache = logs[-PG_LOG_CACHE_MAX:]
        
        # Return most recent logs first
        logs.reverse()
        return jsonify({'logs': logs[:50]})  # Limit to 50 most recent
        
    except Exception as e:
        print(f"Error getting database logs: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({'logs': [], 'error': str(e)}), 500

@app.route('/api/clear_db_logs', methods=['POST'])
def clear_db_logs():
    """Clear database logs by setting a timestamp filter"""
    global pg_log_cleared_at
    pg_log_cleared_at = datetime.now()
    print(f"DEBUG: DB logs cleared at {pg_log_cleared_at} (type: {type(pg_log_cleared_at)})")
    print(f"DEBUG: Cleared timestamp ISO: {pg_log_cleared_at.isoformat()}")
    return jsonify({'success': True, 'cleared_at': pg_log_cleared_at.isoformat()})

@app.route('/api/db_users')
def get_db_users():
    """Get current PostgreSQL users (Vault-created dynamic users)"""
    try:
        conn = psycopg2.connect(
            host=POSTGRES_HOST,
            port=POSTGRES_PORT,
            database=POSTGRES_DB,
            user=POSTGRES_USER,
            password=POSTGRES_PASSWORD
        )
        cursor = conn.cursor(cursor_factory=RealDictCursor)
        
        # Query for agentic demo users only (v-master-d-agentic-*)
        cursor.execute("""
            SELECT
                u.usename,
                u.valuntil,
                CASE
                    WHEN EXISTS (
                        SELECT 1 FROM information_schema.table_privileges
                        WHERE grantee = u.usename
                        AND table_name = 'products'
                        AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE')
                    ) THEN 'readwrite'
                    ELSE 'readonly'
                END as role_type
            FROM pg_user u
            WHERE u.usename LIKE 'v-master-d-agentic-%'
            ORDER BY u.valuntil DESC NULLS LAST
            LIMIT 20
        """)
        
        users = cursor.fetchall()
        cursor.close()
        conn.close()
        
        # Format for display
        user_list = []
        # Get current time as timezone-aware UTC
        from datetime import timezone
        now = datetime.now(timezone.utc)
        
        for user in users:
            # Determine status based on expiry time
            if user['valuntil']:
                # Make valuntil timezone-aware if it isn't already
                expiry = user['valuntil']
                if expiry.tzinfo is None:
                    # Assume UTC if no timezone
                    expiry = expiry.replace(tzinfo=timezone.utc)
                
                if expiry < now:
                    status = 'expired'
                else:
                    status = 'active'
            else:
                status = 'active'  # No expiry = always active
            
            user_entry = {
                'username': user['usename'],
                'role': user['role_type'],
                'expires': user['valuntil'].isoformat() if user['valuntil'] else 'Never',
                'status': status
            }
            user_list.append(user_entry)
        
        return jsonify({'users': user_list})
        
    except Exception as e:
        return jsonify({'users': [], 'error': str(e)}), 500


# HTML Template with embedded CSS and JavaScript
HTML_TEMPLATE = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Vault Agentic AI Security</title>
    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMjggMTI4Ij48cGF0aCBmaWxsPSIjZmZkODE0IiBkPSJtMCAxLjk1MyA2My43NiAxMjQuMDk0TDEyOCAxLjk1M1ptNTMuODQxIDQ5LjI1NEg0My42ODRWNDEuMDZINTMuODR6bTAtMTUuMjI3SDQzLjY4NFYyNS44MjJINTMuODRaTTY5LjA4IDY2LjQ0NEg1OC45N1Y1Ni4yODZoMTAuMTA4em0wLTE1LjIzN0g1OC45N1Y0MS4wNmgxMC4xMDh6bTAtMTUuMjI3SDU4Ljk3VjI1LjgyMmgxMC4xMDhabTE1LjE0NyAxNS4yMjdINzQuMDI3VjQxLjA2aDEwLjE1OVpNNzQuMDI3IDM1Ljk4VjI1LjgyMmgxMC4xNTlWMzUuOTh6Ii8+PC9zdmc+">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: #000000;
            color: #FFFFFF;
            zoom: 0.8;
            overflow-x: hidden;
        }

        /* Vault logo background watermark */
        body::before {
            content: '';
            position: fixed;
            top: 50%;
            left: -100px;
            transform: translateY(-50%);
            width: 600px;
            height: 600px;
            background-image: url('data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMjggMTI4Ij48cGF0aCBmaWxsPSIjZmZkODE0IiBkPSJtMCAxLjk1MyA2My43NiAxMjQuMDk0TDEyOCAxLjk1M1ptNTMuODQxIDQ5LjI1NEg0My42ODRWNDEuMDZINTMuODR6bTAtMTUuMjI3SDQzLjY4NFYyNS44MjJINTMuODRaTTY5LjA4IDY2LjQ0NEg1OC45N1Y1Ni4yODZoMTAuMTA4em0wLTE1LjIzN0g1OC45N1Y0MS4wNmgxMC4xMDh6bTAtMTUuMjI3SDU4Ljk3VjI1LjgyMmgxMC4xMDhabTE1LjE0NyAxNS4yMjdINzQuMDI3VjQxLjA2aDEwLjE1OVpNNzQuMDI3IDM1Ljk4VjI1LjgyMmgxMC4xNTlWMzUuOTh6Ii8+PC9zdmc+');
            background-repeat: no-repeat;
            background-position: center;
            background-size: contain;
            opacity: 0.08;
            pointer-events: none;
            z-index: 0;
        }

        .container {
            position: relative;
            z-index: 1;
            max-width: 1400px;
            margin: 0 auto;
            padding: 40px 20px;
        }

        header {
            background: #1a1a1a;
            border: 2px solid #333333;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            max-width: 1400px;
            margin: 0 auto 20px auto;
            display: flex;
            align-items: center;
            justify-content: center;
            position: relative;
        }

        h1 {
            font-size: 28px;
            font-weight: 700;
            letter-spacing: -0.02em;
            color: #FFFFFF;
            margin: 0;
            text-align: center;
        }

        .subtitle {
            font-size: 16px;
            color: #CCCCCC;
            margin-top: 10px;
        }

        .user-info {
            position: absolute;
            right: 20px;
            display: flex;
            align-items: center;
            gap: 15px;
        }

        .user-info span {
            color: #FFD814;
            font-weight: 600;
        }

        .switch-user-button {
            padding: 5px 10px;
            background: #FFD814;
            color: #000000;
            border: none;
            border-radius: 6px;
            font-size: 13px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s ease;
        }

        .switch-user-button:hover {
            background: #FFC700;
            transform: translateY(-1px);
            box-shadow: 0 2px 8px rgba(255, 216, 20, 0.3);
        }

        /* Login Section */
        .login-section {
            max-width: 500px;
            margin: 60px auto;
            background: #1a1a1a;
            padding: 40px;
            border-radius: 12px;
            border: 1px solid #333333;
        }

        .login-section h2 {
            font-size: 24px;
            color: #FFFFFF;
            margin-bottom: 30px;
            text-align: center;
        }

        .user-select {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            margin-bottom: 20px;
        }

        .user-card {
            background: #0a0a0a;
            padding: 30px 20px;
            border-radius: 8px;
            border: 2px solid #333333;
            cursor: pointer;
            transition: all 0.3s ease;
            text-align: center;
        }

        .user-card:hover {
            border-color: #FFD814;
            transform: translateY(-2px);
            box-shadow: 0 4px 20px rgba(255, 216, 20, 0.2);
        }

        .user-card.selected {
            border-color: #FFD814;
            background: rgba(255, 216, 20, 0.1);
        }

        .user-card h3 {
            font-size: 20px;
            color: #FFFFFF;
            margin-bottom: 10px;
        }

        .user-card .role {
            font-size: 12px;
            color: #FFD814;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            font-weight: 600;
        }

        .user-card .permissions {
            font-size: 13px;
            color: #888888;
            margin-top: 10px;
        }

        button {
            width: 100%;
            padding: 15px;
            background: #FFD814;
            color: #000000;
            border: none;
            border-radius: 8px;
            font-size: 15px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s ease;
        }

        button:hover {
            background: #FFC700;
            transform: translateY(-1px);
            box-shadow: 0 4px 12px rgba(255, 216, 20, 0.3);
        }

        button:disabled {
            background: #666666;
            cursor: not-allowed;
            transform: none;
        }

        /* Main Content */
        .main-content {
            display: grid;
            grid-template-columns: 2fr 1fr;
            gap: 30px;
            margin-bottom: 30px;
        }
        
        .raw-logs-panel {
            grid-column: 1 / -1;
        }

        .panel {
            background: #1a1a1a;
            border-radius: 12px;
            border: 1px solid #333333;
            padding: 30px;
        }

        .panel h2 {
            font-size: 18px;
            font-weight: 700;
            color: #FFFFFF;
            margin-bottom: 20px;
            padding-bottom: 15px;
            border-bottom: 1px solid #333333;
        }

        /* Chat Interface */
        .chat-container {
            display: flex;
            flex-direction: column;
            height: auto;
        }

        .chat-messages {
            height: 150px;
            overflow-y: auto;
            padding: 20px;
            background: #0a0a0a;
            border-radius: 8px;
            margin-bottom: 20px;
        }

        .message {
            margin-bottom: 20px;
            padding: 15px;
            border-radius: 8px;
            max-width: 80%;
        }

        .message.user {
            background: rgba(255, 216, 20, 0.1);
            border: 1px solid #FFD814;
            margin-left: auto;
        }

        .message.agent {
            background: #1a1a1a;
            border: 1px solid #333333;
        }

        .message .sender {
            font-size: 12px;
            color: #FFD814;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            font-weight: 600;
            margin-bottom: 8px;
        }

        .message .content {
            font-size: 14px;
            color: #FFFFFF;
            line-height: 1.6;
            white-space: pre-wrap;
        }

        .message .timestamp {
            font-size: 11px;
            color: #888888;
            margin-top: 8px;
        }

        .chat-input-container {
            display: flex;
            gap: 10px;
        }

        input[type="text"] {
            flex: 1;
            padding: 15px;
            background: #0a0a0a;
            border: 1px solid #333333;
            border-radius: 8px;
            color: #FFFFFF;
            font-size: 14px;
            transition: border-color 0.3s ease;
        }

        input[type="text"]:focus {
            outline: none;
            border-color: #FFD814;
        }

        .send-button {
            width: auto;
            padding: 15px 30px;
        }

        /* Audit Logs */
        .audit-logs {
            height: 200px;
            overflow-y: auto;
        }
        
        .raw-audit-logs {
            height: 400px;
            overflow-y: auto;
            background: #0a0a0a;
            border-radius: 8px;
            padding: 15px;
            font-family: 'Courier New', monospace;
            font-size: 11px;
        }
        
        .raw-log-entry {
            padding: 8px;
            border-bottom: 1px solid #1a1a1a;
            color: #888888;
            word-wrap: break-word;
        }
        
        .raw-log-entry:hover {
            background: #1a1a1a;
        }
        
        .raw-log-entry pre {
            margin: 0;
            white-space: pre-wrap;
            word-wrap: break-word;
        }
        
        /* JSON syntax highlighting */
        .json-key {
            color: #9CDCFE;
        }
        
        .json-string {
            color: #CE9178;
        }
        
        .json-number {
            color: #B5CEA8;
        }
        
        .json-boolean {
            color: #569CD6;
        }
        
        .json-null {
            color: #569CD6;
        }

        .log-entry {
            padding: 12px;
            background: #0a0a0a;
            border-radius: 6px;
            border: 1px solid #333333;
            margin-bottom: 10px;
            font-size: 13px;
        }

        .log-entry .log-time {
            color: #888888;
            font-size: 11px;
            margin-bottom: 5px;
        }

        .log-entry .log-user {
            color: #FFD814;
            font-weight: 600;
        }

        .log-entry .log-action {
            color: #CCCCCC;
        }

        .log-entry .log-status {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 11px;
            font-weight: 600;
            margin-left: 10px;
        }

        .log-entry .log-status.success {
            background: rgba(0, 255, 0, 0.1);
            color: #00FF00;
        }

        .log-entry .log-status.failed {
            background: rgba(255, 0, 0, 0.1);
            color: #FF0000;
        }
        
        .log-entry .log-status.denied {
            background: rgba(255, 0, 0, 0.1);
            color: #FF0000;
        }

        .logout-button {
            margin-top: 20px;
            background: #333333;
            color: #FFFFFF;
        }

        .logout-button:hover {
            background: #444444;
        }

        .loading {
            text-align: center;
            color: #888888;
            padding: 20px;
        }

        .error {
            background: rgba(255, 0, 0, 0.1);
            border: 1px solid #FF0000;
        }

        /* Database Monitoring Panels - Use same grid as chat/audit */
        .db-monitoring-content {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            margin-bottom: 30px;
        }

        .db-panel {
            background: #1a1a1a;
            border: 1px solid #333333;
            border-radius: 12px;
            padding: 25px;
        }

        .db-panel h2 {
            font-size: 18px;
            font-weight: 600;
            color: #FFFFFF;
            margin-bottom: 15px;
            padding-bottom: 10px;
            border-bottom: 1px solid #333333;
        }

        .db-logs, .db-users {
            max-height: 250px;
            overflow-y: auto;
        }

        .db-log-entry, .db-user-entry {
            padding: 10px;
            background: #0a0a0a;
            border-radius: 6px;
            border: 1px solid #333333;
            margin-bottom: 8px;
            font-size: 12px;
        }

        .db-log-entry:hover, .db-user-entry:hover {
            background: #1a1a1a;
            border-color: #444444;
        }

        .db-log-time, .db-user-name {
            color: #FFD814;
            font-weight: 600;
            margin-bottom: 4px;
        }

        .db-log-user, .db-user-role {
            color: #FF69B4;
            font-size: 11px;
        }

        .db-log-query {
            color: #CCCCCC;
            margin-top: 4px;
            font-family: 'Courier New', monospace;
            font-size: 11px;
        }

        .db-log-state {
            display: inline-block;
            padding: 2px 6px;
            border-radius: 3px;
            font-size: 10px;
            font-weight: 600;
            margin-left: 8px;
        }

        .db-log-state.active {
            background: rgba(0, 255, 0, 0.1);
            color: #00FF00;
        }

        .db-log-state.idle {
            background: rgba(136, 136, 136, 0.1);
            color: #888888;
        }

        .db-user-expires {
            color: #888888;
            font-size: 11px;
            margin-top: 4px;
        }

        .db-user-status {
            display: inline-block;
            padding: 2px 6px;
            border-radius: 3px;
            font-size: 10px;
            font-weight: 600;
            margin-left: 8px;
        }
        
        .db-user-status.active {
            background: rgba(0, 255, 0, 0.1);
            color: #00FF00;
        }
        
        .db-user-status.expired {
            background: rgba(255, 0, 0, 0.1);
            color: #FF0000;
        }
            color: #FF0000;
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 20px;
        }

        /* Scrollbar styling */
        ::-webkit-scrollbar {
            width: 8px;
        }

        ::-webkit-scrollbar-track {
            background: #0a0a0a;
        }

        ::-webkit-scrollbar-thumb {
            background: #333333;
            border-radius: 4px;
        }

        ::-webkit-scrollbar-thumb:hover {
            background: #FFD814;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>Vault Agentic AI Security</h1>
            <div id="userInfo" style="display: none;" class="user-info">
                <div style="padding-bottom: 10px;">Logged in as <span id="currentUser"></span></div>
                <button id="logoutButton" class="switch-user-button">Switch User</button>
            </div>
        </header>

        <!-- Login Section -->
        <div id="loginSection" class="login-section">
            <h2>Select User</h2>
            <div class="user-select">
                <div class="user-card" data-user="alice">
                    <h3>Alice</h3>
                    <div class="role">Read-Only User</div>
                    <div class="permissions">Can list products only</div>
                </div>
                <div class="user-card" data-user="bob">
                    <h3>Bob</h3>
                    <div class="role">Admin User</div>
                    <div class="permissions">Can list and add products</div>
                </div>
            </div>
            <button id="loginButton" disabled>Login</button>
        </div>

        <!-- Main Content (hidden until logged in) -->
        <div id="mainContent" style="display: none;">
            <div class="main-content">
                <!-- Chat Panel -->
                <div class="panel">
                    <h2>AI Agent Chat</h2>
                    <div class="chat-container">
                        <div id="chatMessages" class="chat-messages">
                            <div class="message agent">
                                <div class="sender">AI Agent</div>
                                <div class="content">Hello! I'm your AI assistant. I can help you list products or add new products to the database. What would you like to do?</div>
                            </div>
                        </div>
                        <div class="chat-input-container">
                            <input type="text" id="messageInput" placeholder="Type your message..." />
                            <button id="sendButton" class="send-button">Send</button>
                        </div>
                    </div>
                </div>

                <!-- Audit Logs Panel -->
                <div class="panel">
                    <h2>Audit Logs (Prettified)</h2>
                    <div id="auditLogs" class="audit-logs">
                        <div class="loading">Loading audit logs...</div>
                    </div>
                </div>
            </div>

            <!-- Database Monitoring Panels -->
            <div class="db-monitoring-content">
                <!-- Database Logs -->
                <div class="db-panel">
                    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px;">
                        <h2 style="margin: 0;">Database Logs</h2>
                        <button id="clearDbLogsButton" class="switch-user-button" style="padding: 8px 16px; width: auto; min-width: 100px;">Clear Logs</button>
                    </div>
                    <div id="dbLogs" class="db-logs">
                        <div class="loading">Monitoring connections...</div>
                    </div>
                </div>

                <!-- Database Users -->
                <div class="db-panel">
                    <h2>Active Database Users</h2>
                    <div id="dbUsers" class="db-users">
                        <div class="loading">Loading database users...</div>
                    </div>
                </div>
            </div>
            
            <!-- Raw Vault Audit Logs Panel -->
            <div class="panel raw-logs-panel">
                <h2>Vault Audit Logs (Raw)</h2>
                <div id="rawAuditLogs" class="raw-audit-logs">
                    <div class="loading">Loading raw audit logs...</div>
                </div>
            </div>
        </div>
    </div>

    <script>
        let selectedUser = null;
        let auditLogInterval = null;

        // Check session on page load
        fetch('/api/session')
            .then(r => r.json())
            .then(data => {
                if (data.authenticated) {
                    showMainContent(data.user_id);
                }
            });

        // User selection
        document.querySelectorAll('.user-card').forEach(card => {
            card.addEventListener('click', () => {
                document.querySelectorAll('.user-card').forEach(c => c.classList.remove('selected'));
                card.classList.add('selected');
                selectedUser = card.dataset.user;
                document.getElementById('loginButton').disabled = false;
            });
        });

        // Login
        document.getElementById('loginButton').addEventListener('click', () => {
            if (!selectedUser) return;

            fetch('/api/login', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({user_id: selectedUser})
            })
            .then(r => r.json())
            .then(data => {
                if (data.success) {
                    showMainContent(data.user_id);
                }
            })
            .catch(err => console.error('Login error:', err));
        });

        // Logout
        document.getElementById('logoutButton').addEventListener('click', () => {
            fetch('/api/logout', {method: 'POST'})
                .then(() => {
                    location.reload();
                });
        });

        // Clear DB Logs
        document.getElementById('clearDbLogsButton').addEventListener('click', () => {
            fetch('/api/clear_db_logs', {method: 'POST'})
                .then(r => r.json())
                .then(data => {
                    if (data.success) {
                        const logsDiv = document.getElementById('dbLogs');
                        logsDiv.innerHTML = '<div class="loading" style="color: #888;">Logs cleared. New activity will appear here.</div>';
                        console.log('DB logs cleared at:', data.cleared_at);
                    }
                })
                .catch(err => console.error('Error clearing logs:', err));
        });

        // Send message
        function sendMessage() {
            const input = document.getElementById('messageInput');
            const message = input.value.trim();
            if (!message) return;

            // Add user message to chat
            addMessage('user', message);
            input.value = '';

            // Send to agent
            fetch('/api/chat', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({message: message})
            })
            .then(r => r.json())
            .then(data => {
                if (data.response) {
                    addMessage('agent', data.response);
                } else if (data.error) {
                    addMessage('agent', `Error: ${data.error}`, true);
                }
            })
            .catch(err => {
                addMessage('agent', `Error: ${err.message}`, true);
            });
        }

        document.getElementById('sendButton').addEventListener('click', sendMessage);
        document.getElementById('messageInput').addEventListener('keypress', (e) => {
            if (e.key === 'Enter') sendMessage();
        });

        // Add message to chat
        function addMessage(sender, content, isError = false) {
            const messagesDiv = document.getElementById('chatMessages');
            const messageDiv = document.createElement('div');
            messageDiv.className = `message ${sender}`;
            if (isError) messageDiv.style.borderColor = '#FF0000';
            
            messageDiv.innerHTML = `
                <div class="sender">${sender === 'user' ? 'You' : 'AI Agent'}</div>
                <div class="content">${content}</div>
                <div class="timestamp">${new Date().toLocaleTimeString()}</div>
            `;
            
            messagesDiv.appendChild(messageDiv);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        }

        // Load audit logs
        function loadAuditLogs() {
            fetch('/api/audit_logs')
                .then(r => r.json())
                .then(data => {
                    const logsDiv = document.getElementById('auditLogs');
                    logsDiv.innerHTML = '';
                    
                    if (data.logs.length === 0) {
                        logsDiv.innerHTML = '<div class="loading">No audit logs yet</div>';
                        return;
                    }
                    
                    data.logs.forEach(log => {
                        const logDiv = document.createElement('div');
                        logDiv.className = 'log-entry';
                        logDiv.innerHTML = `
                            <div class="log-time">${new Date(log.timestamp).toLocaleString()}</div>
                            <div>
                                <span class="log-user">${log.user}</span>
                                <span class="log-action">${log.action}</span>
                                <span class="log-status ${log.status}">${log.status}</span>
                            </div>
                            ${log.message ? `<div style="color: #888; margin-top: 5px; font-size: 12px;">${log.message}</div>` : ''}
                        `;
                        logsDiv.appendChild(logDiv);
                    });
                });
        }
        
        // Load database logs
        function loadDbLogs() {
            fetch('/api/db_logs')
                .then(r => r.json())
                .then(data => {
                    const logsDiv = document.getElementById('dbLogs');
                    logsDiv.innerHTML = '';
                    
                    if (data.error) {
                        logsDiv.innerHTML = `<div class="error">Error: ${data.error}</div>`;
                        return;
                    }
                    
                    if (data.logs.length === 0) {
                        logsDiv.innerHTML = '<div class="loading" style="color: #888;">No database activity logged</div>';
                        return;
                    }
                    
                    data.logs.forEach(log => {
                        const logDiv = document.createElement('div');
                        logDiv.className = 'db-log-entry';
                        logDiv.innerHTML = `
                            <div class="db-log-time">${new Date(log.timestamp).toLocaleString()}</div>
                            <div>
                                <span class="db-log-user">User: ${log.user}</span>
                                <span class="db-log-state ${log.state}">${log.state}</span>
                            </div>
                            ${log.query ? `<div class="db-log-query">${log.query}</div>` : ''}
                        `;
                        logsDiv.appendChild(logDiv);
                    });
                })
                .catch(err => {
                    console.error('Error loading DB logs:', err);
                    const logsDiv = document.getElementById('dbLogs');
                    logsDiv.innerHTML = '<div class="error">Failed to load database logs</div>';
                });
        }
        
        // Load database users
        function loadDbUsers() {
            fetch('/api/db_users')
                .then(r => r.json())
                .then(data => {
                    const usersDiv = document.getElementById('dbUsers');
                    usersDiv.innerHTML = '';
                    
                    if (data.error) {
                        usersDiv.innerHTML = `<div class="error">Error: ${data.error}</div>`;
                        return;
                    }
                    
                    if (data.users.length === 0) {
                        usersDiv.innerHTML = '<div class="loading">No active Vault users</div>';
                        return;
                    }
                    
                    data.users.forEach(user => {
                        const userDiv = document.createElement('div');
                        userDiv.className = 'db-user-entry';
                        userDiv.innerHTML = `
                            <div class="db-user-name">${user.username}</div>
                            <div>
                                <span class="db-user-role">Role: ${user.role}</span>
                                <span class="db-user-status ${user.status}">${user.status}</span>
                            </div>
                            <div class="db-user-expires">Expires: ${new Date(user.expires).toLocaleString()}</div>
                        `;
                        usersDiv.appendChild(userDiv);
                    });
                });
        }
        
        // Load raw Vault audit logs
        function loadRawAuditLogs() {
            fetch('/api/vault_audit_logs')
                .then(r => r.json())
                .then(data => {
                    const logsDiv = document.getElementById('rawAuditLogs');
                    logsDiv.innerHTML = '';
                    
                    if (data.error) {
                        logsDiv.innerHTML = `<div class="error">Error: ${data.error}</div>`;
                        return;
                    }
                    
                    if (data.message) {
                        logsDiv.innerHTML = `<div class="loading">${data.message}</div>`;
                        return;
                    }
                    
                    if (data.logs.length === 0) {
                        logsDiv.innerHTML = '<div class="loading">No raw audit logs yet</div>';
                        return;
                    }
                    
                    data.logs.forEach(log => {
                        const logDiv = document.createElement('div');
                        logDiv.className = 'raw-log-entry';
                        logDiv.innerHTML = syntaxHighlightJSON(log);
                        logsDiv.appendChild(logDiv);
                    });
                });
        }

        // Syntax highlight JSON with important keys in different colors
        function syntaxHighlightJSON(json) {
            const jsonStr = JSON.stringify(json, null, 2);
            
            // Important keys to highlight - all in pink for consistency
            const importantKeys = {
                'display_name': '#FF69B4',       // Pink - Agent identity
                'entity_id': '#FF69B4',          // Pink - Entity
                'metadata': '#FF69B4',           // Pink - User context
                'user_context': '#FF69B4',       // Pink - User info
                'user_groups': '#FF69B4',        // Pink - User groups
                'user_request': '#FF69B4',       // Pink - User request
                'x-agent-id': '#FF69B4',         // Pink - Agent context header
                'x-agent-type': '#FF69B4',       // Pink - Agent type header
                'x-agent-action': '#FF69B4',     // Pink - Agent action header
                'x-user-request': '#FF69B4',     // Pink - User request header
                'path': '#FF69B4',               // Pink - Vault path
                'operation': '#FF69B4',          // Pink - Operation
                'policies': '#FF69B4',           // Pink - Policies
                'granting_policies': '#FF69B4',  // Pink - Granting policies
                'policy_results': '#FF69B4'      // Pink - Policy results
            };
            
            let highlighted = jsonStr
                // Highlight strings
                .replace(/("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+\-]?\d+)?)/g, (match) => {
                    let cls = 'json-number';
                    if (/^"/.test(match)) {
                        if (/:$/.test(match)) {
                            // It's a key
                            const key = match.slice(1, -2);
                            if (importantKeys[key]) {
                                return `<span style="color: ${importantKeys[key]}; font-weight: bold;">${match}</span>`;
                            }
                            cls = 'json-key';
                        } else {
                            cls = 'json-string';
                        }
                    } else if (/true|false/.test(match)) {
                        cls = 'json-boolean';
                    } else if (/null/.test(match)) {
                        cls = 'json-null';
                    }
                    return `<span class="${cls}">${match}</span>`;
                });
            
            return `<pre>${highlighted}</pre>`;
        }

        // Show main content
        function showMainContent(userId) {
            document.getElementById('loginSection').style.display = 'none';
            document.getElementById('mainContent').style.display = 'block';
            document.getElementById('userInfo').style.display = 'inline-block';
            document.getElementById('currentUser').textContent = userId;
            
            // Start polling for all logs
            loadDbLogs();
            loadDbUsers();
            loadAuditLogs();
            loadRawAuditLogs();
            
            auditLogInterval = setInterval(() => {
                loadDbLogs();
                loadDbUsers();
                loadAuditLogs();
                loadRawAuditLogs();
            }, 5000);  // Poll every 5 seconds
        }
    </script>
</body>
</html>
'''

if __name__ == '__main__':
    # Fetch JWT private key on startup
    fetch_jwt_private_key()
    app.run(host='0.0.0.0', port=8002, debug=False)

# Made with Bob
