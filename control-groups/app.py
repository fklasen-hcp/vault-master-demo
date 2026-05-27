#!/usr/bin/env python3
from flask import Flask, render_template_string, jsonify, request
import hvac
import os
import json
import time
from datetime import datetime

app = Flask(__name__)

# In-memory storage for demo purposes (in production, use a database)
requests_db = {}
request_counter = 0

def get_vault_client(role='user'):
    """Get Vault client authenticated with specified role"""
    vault_addr = os.environ.get('VAULT_ADDR', 'https://host.minikube.internal:8200')
    vault_namespace = os.environ.get('VAULT_NAMESPACE', 'master-demo')
    vault_skip_verify = os.environ.get('VAULT_SKIP_VERIFY', 'false').lower() == 'true'
    
    # Read Kubernetes service account token
    with open('/var/run/secrets/kubernetes.io/serviceaccount/token', 'r') as f:
        jwt = f.read()
    
    # Create client and authenticate using Kubernetes auth
    client = hvac.Client(url=vault_addr, namespace=vault_namespace, verify=not vault_skip_verify)
    
    # Map role to Vault auth role
    vault_role_map = {
        'user': 'master-demo-auth-role-controlgroups-user',
        'ops': 'master-demo-auth-role-controlgroups-ops',
        'security': 'master-demo-auth-role-controlgroups-security'
    }
    
    # Authenticate with Kubernetes auth method
    auth_response = client.auth.kubernetes.login(
        role=vault_role_map.get(role, vault_role_map['user']),
        jwt=jwt,
        mount_point='master-demo-auth'
    )
    
    # Set the token from the auth response
    client.token = auth_response['auth']['client_token']
    
    return client

@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE)

@app.route('/api/request_secret', methods=['POST'])
def request_secret():
    """User requests access to a secret - simulates Control Groups workflow"""
    global request_counter
    
    data = request.json
    secret_path = data.get('path')
    
    if not secret_path:
        return jsonify({'error': 'Secret path is required'}), 400
    
    try:
        # Simulate Control Groups workflow without requiring Vault Enterprise feature
        # In a real Control Groups setup, Vault would return a wrapped response
        # Here we simulate that behavior for demo purposes
        
        request_counter += 1
        request_id = f"req_{request_counter}_{int(time.time())}"
        
        # Determine required approvals based on path
        if 'prod' in secret_path:
            required_approvals = {'ops': False, 'security': False}
            approval_type = '2/2'
        else:
            required_approvals = {'ops': False, 'security': False}
            approval_type = '1/2'
        
        requests_db[request_id] = {
            'id': request_id,
            'path': secret_path,
            'user': 'demo-user',
            'status': 'pending',
            'approvals': required_approvals,
            'approval_type': approval_type,
            'created_at': datetime.now().isoformat(),
            'wrapped_token': f'hvs.wrapped.{request_id}',  # Simulated wrapped token
            'secret_data': None
        }
        
        return jsonify({
            'success': True,
            'request_id': request_id,
            'message': f'Access request created. Requires {approval_type} approvals.'
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/approve', methods=['POST'])
def approve_request():
    """Admin approves a request"""
    data = request.json
    request_id = data.get('request_id')
    role = data.get('role')  # 'ops' or 'security'
    
    if not request_id or not role:
        return jsonify({'error': 'request_id and role are required'}), 400
    
    if request_id not in requests_db:
        return jsonify({'error': 'Request not found'}), 404
    
    try:
        req = requests_db[request_id]
        
        # Mark approval
        if role in req['approvals']:
            req['approvals'][role] = True
        
        # Check if all required approvals are met
        if req['approval_type'] == '1/2':
            # Need at least one approval
            if any(req['approvals'].values()):
                req['status'] = 'approved'
        elif req['approval_type'] == '2/2':
            # Need both approvals
            if all(req['approvals'].values()):
                req['status'] = 'approved'
        
        return jsonify({
            'success': True,
            'message': f'Request approved by {role}',
            'status': req['status']
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/deny', methods=['POST'])
def deny_request():
    """Admin denies a request"""
    data = request.json
    request_id = data.get('request_id')
    role = data.get('role')
    
    if not request_id or not role:
        return jsonify({'error': 'request_id and role are required'}), 400
    
    if request_id not in requests_db:
        return jsonify({'error': 'Request not found'}), 404
    
    try:
        req = requests_db[request_id]
        req['status'] = 'denied'
        req['denied_by'] = role
        
        return jsonify({
            'success': True,
            'message': f'Request denied by {role}'
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/unwrap', methods=['POST'])
def unwrap_secret():
    """User unwraps an approved secret - simulates unwrapping the wrapped token"""
    data = request.json
    request_id = data.get('request_id')
    
    if not request_id:
        return jsonify({'error': 'request_id is required'}), 400
    
    if request_id not in requests_db:
        return jsonify({'error': 'Request not found'}), 404
    
    try:
        req = requests_db[request_id]
        
        if req['status'] != 'approved':
            return jsonify({'error': 'Request not approved yet'}), 403
        
        # After approval, use an authorized token (ops) to read the secret
        # In a real Control Groups setup, we'd use the wrapped token to unwrap
        # Here we use an ops token to simulate the unwrapped result after approval
        try:
            # Use ops token since the request has been approved
            client = get_vault_client('ops')
            
            secret_path = req['path'].replace('secret/data/', '')
            response = client.secrets.kv.v2.read_secret_version(
                path=secret_path,
                mount_point='master-demo-kv'
            )
            
            secret_data = response['data']['data']
            req['secret_data'] = secret_data
            req['status'] = 'unwrapped'
            
            return jsonify({
                'success': True,
                'secret': secret_data
            })
        except Exception as vault_error:
            # Log the actual error for debugging
            import traceback
            error_details = {
                'error_type': type(vault_error).__name__,
                'error_message': str(vault_error),
                'traceback': traceback.format_exc()
            }
            print(f"ERROR reading secret: {error_details}")
            
            # If secret doesn't exist, return simulated data for demo
            secret_name = req['path'].split('/')[-1]
            simulated_secret = {
                'note': f'Simulated secret data (Error: {str(vault_error)})',
                'path': req['path'],
                'secret_path_used': secret_path,
                'mount_point': 'master-demo-kv',
                'value': f'secret-value-for-{secret_name}'
            }
            req['secret_data'] = simulated_secret
            req['status'] = 'unwrapped'
            
            return jsonify({
                'success': True,
                'secret': simulated_secret
            })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/requests')
def get_requests():
    """Get all requests"""
    return jsonify({
        'requests': list(requests_db.values())
    })

@app.route('/api/user_requests')
def get_user_requests():
    """Get requests for current user"""
    # In a real app, filter by authenticated user
    # Return in reverse order (newest first)
    return jsonify({
        'requests': list(reversed(list(requests_db.values())))
    })

@app.route('/api/pending_requests')
def get_pending_requests():
    """Get pending requests for admin"""
    # Return in reverse order (newest first)
    pending = [req for req in requests_db.values() if req['status'] == 'pending']
    return jsonify({
        'requests': list(reversed(pending))
    })

@app.route('/api/clear_requests', methods=['POST'])
def clear_requests():
    """Clear all requests"""
    global requests_db, request_counter
    requests_db = {}
    request_counter = 0
    return jsonify({'success': True})

HTML_TEMPLATE = '''
<!DOCTYPE html>
<html>
<head>
    <title>Vault Control Groups Demo</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
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
            min-height: 100vh;
            padding: 20px;
            font-size: 16px;
            line-height: 1.5;
            position: relative;
            zoom: 0.8;
        }
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
        .header, .container, .panel {
            position: relative;
            z-index: 1;
        }
        .header {
            background: #1a1a1a !important;
            border: 2px solid #333333;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            max-width: 1400px;
            margin: 0 auto 20px auto;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .header h1 {
            color: #FFFFFF;
            font-size: 28px;
            margin: 0;
            font-weight: 700;
            letter-spacing: -0.02em;
            text-align: center;
        }
        .container {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            margin-bottom: 20px;
            max-width: 1400px;
            margin: 0 auto;
        }
        .panel {
            background: #1a1a1a !important;
            border: 2px solid #333333;
            padding: 25px;
            border-radius: 8px;
        }
        .full-width {
            grid-column: 1 / -1;
            background: #1a1a1a !important;
        }
        h2 {
            color: #FFFFFF;
            font-size: 18px;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 2px solid #333333;
            font-weight: 700;
            letter-spacing: -0.01em;
        }
        .role-switcher {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
            justify-content: center;
        }
        .role-btn {
            background: #333333;
            color: #FFFFFF;
            border: 2px solid #333333;
            padding: 10px 20px;
            border-radius: 6px;
            cursor: pointer;
            font-size: 14px;
            font-weight: 600;
            transition: all 0.2s;
        }
        .role-btn.active {
            background: #FFD814;
            color: #000000;
            border-color: #FFD814;
        }
        .role-btn:hover:not(.active) {
            border-color: #FFD814;
        }
        label {
            display: block;
            color: #FFD814;
            font-size: 12px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-bottom: 8px;
            margin-top: 15px;
        }
        select, input {
            width: 100%;
            padding: 12px;
            margin: 8px 0;
            background: #0a0a0a;
            border: 1px solid #333333;
            border-radius: 6px;
            color: #FFFFFF;
            font-size: 14px;
            font-family: 'Inter', sans-serif;
        }
        select:focus, input:focus {
            outline: none;
            border-color: #FFD814;
            box-shadow: 0 0 0 2px rgba(255, 216, 20, 0.1);
        }
        button {
            background: #FFD814;
            color: #000000;
            border: none;
            padding: 12px 24px;
            border-radius: 6px;
            cursor: pointer;
            font-size: 15px;
            font-weight: 600;
            margin: 5px;
            transition: all 0.2s;
            font-family: 'Inter', sans-serif;
            width: 100%;
        }
        button:hover:not(:disabled):not(.btn-clear) {
            background: #FFC700;
            transform: translateY(-1px);
            box-shadow: 0 4px 8px rgba(255, 216, 20, 0.3);
        }
        .btn-clear {
            padding: 6px 12px !important;
            font-size: 12px !important;
            background: #666666 !important;
            margin: 0 !important;
            width: auto !important;
        }
        .btn-clear:hover {
            background: #666666 !important;
            transform: none !important;
            box-shadow: none !important;
        }
        .btn-clear:disabled {
            opacity: 0.5;
            cursor: not-allowed;
        }
        button:active {
            transform: translateY(0);
        }
        button:disabled {
            background: #333333 !important;
            color: #666666 !important;
            cursor: not-allowed !important;
            transform: none !important;
            opacity: 0.5;
        }
        .request-card {
            background: #0a0a0a;
            border: 2px solid #333333;
            padding: 15px;
            margin: 10px 0;
            border-radius: 6px;
            transition: all 0.2s;
        }
        .request-card:hover {
            border-color: #FFD814;
            box-shadow: 0 0 15px rgba(255, 216, 20, 0.1);
        }
        .request-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 10px;
        }
        .request-id {
            font-family: 'SF Mono', 'Monaco', monospace;
            font-size: 12px;
            color: #888888;
        }
        .status-badge {
            display: inline-block;
            padding: 4px 10px;
            border-radius: 4px;
            font-size: 12px;
            font-weight: 600;
        }
        .status-pending {
            background: rgba(255, 216, 20, 0.1);
            color: #FFD814;
            border: 1px solid #FFD814;
        }
        .status-approved {
            background: rgba(0, 255, 0, 0.1);
            color: #00FF00;
            border: 1px solid #00FF00;
        }
        .status-denied {
            background: rgba(255, 0, 0, 0.1);
            color: #FF0000;
            border: 1px solid #FF0000;
        }
        .status-unwrapped {
            background: rgba(0, 200, 255, 0.1);
            color: #00C8FF;
            border: 1px solid #00C8FF;
        }
        .request-path {
            font-family: 'SF Mono', 'Monaco', monospace;
            font-size: 13px;
            color: #FFFFFF;
            margin: 8px 0;
        }
        .approval-status {
            display: flex;
            gap: 15px;
            margin: 10px 0;
            font-size: 13px;
        }
        .approval-item {
            display: flex;
            align-items: center;
            gap: 5px;
        }
        .approval-check {
            color: #00FF00;
            font-weight: bold;
        }
        .approval-pending {
            color: #FFD814;
        }
        .button-group {
            display: flex;
            gap: 10px;
            margin-top: 10px;
        }
        .button-group button {
            flex: 1;
            margin: 0;
        }
        .btn-approve {
            background: #00FF00;
            color: #000000;
        }
        .btn-approve:hover {
            background: #00DD00;
        }
        .btn-deny {
            background: #FF0000;
            color: #FFFFFF;
        }
        .btn-deny:hover {
            background: #DD0000;
        }
        .secret-display {
            background: #000000;
            border: 1px solid #333333;
            padding: 12px;
            border-radius: 4px;
            margin-top: 10px;
            font-family: 'SF Mono', 'Monaco', monospace;
            font-size: 12px;
            word-break: break-all;
            color: #00FF00;
        }
        .empty-state {
            text-align: center;
            color: #888888;
            padding: 40px 20px;
            font-size: 14px;
        }
        .scrollable {
            max-height: 600px;
            overflow-y: auto;
        }
        .scrollable::-webkit-scrollbar {
            width: 8px;
        }
        .scrollable::-webkit-scrollbar-track {
            background: #0a0a0a;
        }
        .scrollable::-webkit-scrollbar-thumb {
            background: #FFD814;
            border-radius: 4px;
        }
        .scrollable::-webkit-scrollbar-thumb:hover {
            background: #FFC700;
        }
        .flow-diagram {
            display: flex;
            align-items: stretch;
            justify-content: flex-start;
            gap: 16.5px;
            padding: 15px;
            background: #0a0a0a;
            border: 2px solid #333333;
            border-radius: 6px;
        }
        .flow-step {
            flex: 0 1 180px;
            min-height: 90px;
            display: flex;
            flex-direction: column;
            justify-content: center;
            text-align: center;
            padding: 12px 8px;
            background: #0a0a0a !important;
            border: 2px solid #333333;
            border-radius: 6px;
            transition: all 0.3s;
            opacity: 0.5;
        }
        .flow-step.active {
            opacity: 1;
            border-color: #FFD814;
            box-shadow: 0 0 20px rgba(255, 216, 20, 0.3);
            background: #1f1f1f;
        }
        .flow-step.completed {
            opacity: 1;
            border-color: #4CAF50;
        }
        .flow-step:hover {
            opacity: 1;
        }
        .flow-number {
            width: 28px;
            height: 28px;
            background: #333333;
            color: #888888;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: 700;
            font-size: 14px;
            margin: 0 auto 8px auto;
            transition: all 0.3s;
        }
        .flow-step.active .flow-number {
            background: #FFD814;
            color: #000000;
        }
        .flow-step.completed .flow-number {
            background: #4CAF50;
            color: #FFFFFF;
        }
        .flow-label {
            color: #FFFFFF;
            font-weight: 600;
            font-size: 13px;
            margin-bottom: 4px;
        }
        .flow-desc {
            color: #888888;
            font-size: 11px;
            line-height: 1.3;
        }
        .flow-arrow {
            color: #FFD814;
            font-size: 20px;
            font-weight: 700;
            flex-shrink: 0;
            display: flex;
            align-items: center;
        }
        .audit-log {
            background: #0a0a0a;
            border: 2px solid #333333;
            border-radius: 6px;
            padding: 15px;
            height: 150px;
            overflow-y: auto;
            font-family: 'SF Mono', 'Monaco', 'Inconsolata', 'Roboto Mono', monospace;
            font-size: 12px;
            line-height: 1.6;
            display: flex;
            flex-direction: column-reverse;
        }
        .audit-log-entry {
            color: #888888;
            padding: 4px 0;
            border-bottom: 1px solid #1a1a1a;
        }
        .audit-log-entry:last-child {
            border-bottom: none;
        }
        .audit-log-entry .timestamp {
            color: #666666;
            margin-right: 10px;
        }
        .audit-log-entry .event {
            color: #FFD814;
        }
        .audit-log-entry .details {
            color: #CCCCCC;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>Vault Control Groups</h1>
    </div>
    
    <!-- Full-width Control Groups Flow & Audit Log -->
    <div class="panel full-width" style="max-width: 1400px; margin: 0 auto 20px auto; padding: 20px;">
        <h2 style="margin-bottom: 15px;">Control Groups Flow</h2>
        <div style="display: flex; gap: 20px; align-items: flex-start;">
            <!-- Left: Flow Diagram -->
            <div class="flow-diagram" style="flex: 0 0 auto;">
                <div class="flow-step" id="flow-step-1">
                    <div class="flow-number">1</div>
                    <div class="flow-label">Request</div>
                    <div class="flow-desc">User requests secret</div>
                </div>
                <div class="flow-arrow">→</div>
                <div class="flow-step" id="flow-step-2">
                    <div class="flow-number">2</div>
                    <div class="flow-label">Control Group</div>
                    <div class="flow-desc">Authorizers assigned</div>
                </div>
                <div class="flow-arrow">→</div>
                <div class="flow-step" id="flow-step-3">
                    <div class="flow-number">3</div>
                    <div class="flow-label">Approve</div>
                    <div class="flow-desc">Required approvals</div>
                </div>
                <div class="flow-arrow">→</div>
                <div class="flow-step" id="flow-step-4">
                    <div class="flow-number">4</div>
                    <div class="flow-label">Unwrap</div>
                    <div class="flow-desc">Access granted</div>
                </div>
            </div>
            
            <!-- Right: Audit Log -->
            <div style="flex: 1; min-width: 0;">
                <div class="audit-log" id="auditLog" style="max-height: 150px;">
                    <div class="audit-log-entry">
                        <span class="timestamp">[--:--:--]</span>
                        <span class="event">System Ready</span>
                        <span class="details">- Waiting for requests...</span>
                    </div>
                </div>
            </div>
        </div>
    </div>
    
    <div class="container">
        <!-- Left Column: User Panel -->
        <div class="panel">
            <h2>User Panel</h2>
            
            <label>Request Secret Access</label>
            <select id="secretPath">
                <option value="">Select a secret...</option>
                <option value="secret/data/dev/api-key">dev/api-key (1/2 approval)</option>
                <option value="secret/data/dev/database">dev/database (1/2 approval)</option>
                <option value="secret/data/prod/db-password">prod/db-password (2/2 approvals)</option>
                <option value="secret/data/prod/encryption-key">prod/encryption-key (2/2 approvals)</option>
            </select>
            
            <button onclick="requestSecret()">Request Access</button>
            
            <div style="margin-top: 30px;">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px;">
                    <h3 style="color: #FFD814; font-size: 16px; margin: 0;">My Requests</h3>
                    <button id="clearBtn" class="btn-clear" onclick="clearRequests()" disabled>Clear</button>
                </div>
                <div id="userRequests" class="scrollable"></div>
            </div>
        </div>
        
        <!-- Right Column: Admin Panel -->
        <div class="panel">
            <h2>Admin Panel</h2>
            
            <div class="role-switcher">
                <button class="role-btn active" onclick="switchRole('ops')" id="opsBtn">Ops Team</button>
                <button class="role-btn" onclick="switchRole('security')" id="securityBtn">Security Team</button>
            </div>
            
            <div style="margin-top: 20px;">
                <h3 style="color: #FFD814; font-size: 16px; margin-bottom: 15px;">Pending Approvals</h3>
                <div id="pendingRequests" class="scrollable"></div>
            </div>
            
        </div>
    </div>
    
    <script>
        let currentRole = 'ops';
        
        function switchRole(role) {
            currentRole = role;
            document.getElementById('opsBtn').classList.toggle('active', role === 'ops');
            document.getElementById('securityBtn').classList.toggle('active', role === 'security');
            loadPendingRequests();
        }
        
        function updateFlowDiagram(step) {
            // Reset all steps
            for (let i = 1; i <= 4; i++) {
                const stepEl = document.getElementById(`flow-step-${i}`);
                stepEl.classList.remove('active', 'completed');
            }
            
            // Mark completed steps
            for (let i = 1; i < step; i++) {
                document.getElementById(`flow-step-${i}`).classList.add('completed');
            }
            
            // Mark current step
            if (step <= 4) {
                document.getElementById(`flow-step-${step}`).classList.add('active');
            }
        }
        
        function addAuditLog(event, details) {
            const auditLog = document.getElementById('auditLog');
            const timestamp = new Date().toLocaleTimeString();
            const entry = document.createElement('div');
            entry.className = 'audit-log-entry';
            entry.innerHTML = `
                <span class="timestamp">[${timestamp}]</span>
                <span class="event">${event}</span>
                <span class="details">- ${details}</span>
            `;
            auditLog.insertBefore(entry, auditLog.firstChild);
            
            // Keep only last 10 entries
            while (auditLog.children.length > 10) {
                auditLog.removeChild(auditLog.lastChild);
            }
        }
        
        async function requestSecret() {
            const path = document.getElementById('secretPath').value;
            if (!path) {
                return;
            }
            
            try {
                const response = await fetch('/api/request_secret', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({path})
                });
                
                const data = await response.json();
                if (data.success) {
                    updateFlowDiagram(1);
                    addAuditLog('Request Created', `Secret: ${path}`);
                    setTimeout(() => {
                        updateFlowDiagram(2);
                        addAuditLog('Control Group Created', `Request ID: ${data.request_id}`);
                        setTimeout(() => {
                            updateFlowDiagram(3);
                            addAuditLog('Awaiting Approvals', 'Pending authorization');
                        }, 500);
                    }, 500);
                    loadUserRequests();
                    loadPendingRequests();
                }
            } catch (error) {
                console.error('Error:', error);
            }
        }
        
        async function approveRequest(requestId) {
            try {
                const response = await fetch('/api/approve', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({request_id: requestId, role: currentRole})
                });
                
                const data = await response.json();
                if (data.success) {
                    addAuditLog('Approval Granted', `${currentRole} team approved request ${requestId}`);
                    if (data.message.includes('approved')) {
                        updateFlowDiagram(4);
                        addAuditLog('All Approvals Met', 'Ready to unwrap secret');
                    }
                    loadUserRequests();
                    loadPendingRequests();
                }
            } catch (error) {
                console.error('Error:', error);
            }
        }
        
        async function denyRequest(requestId) {
            try {
                const response = await fetch('/api/deny', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({request_id: requestId, role: currentRole})
                });
                
                const data = await response.json();
                if (data.success) {
                    addAuditLog('Request Denied', `${currentRole} team denied request ${requestId}`);
                    updateFlowDiagram(1);
                    loadUserRequests();
                    loadPendingRequests();
                }
            } catch (error) {
                console.error('Error:', error);
            }
        }
        
        async function unwrapSecret(requestId) {
            try {
                const response = await fetch('/api/unwrap', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({request_id: requestId})
                });
                
                const data = await response.json();
                if (data.success) {
                    addAuditLog('Secret Unwrapped', `Access granted for request ${requestId}`);
                    updateFlowDiagram(0);
                    loadUserRequests();
                }
            } catch (error) {
                console.error('Error:', error);
            }
        }
        
        async function clearRequests() {
            try {
                const response = await fetch('/api/clear_requests', {
                    method: 'POST'
                });
                const data = await response.json();
                if (data.success) {
                    addAuditLog('Requests Cleared', 'All requests removed');
                    updateFlowDiagram(0);
                    loadUserRequests();
                    loadPendingRequests();
                }
            } catch (error) {
                console.error('Error:', error);
            }
        }
        
        async function loadUserRequests() {
            try {
                const response = await fetch('/api/user_requests');
                const data = await response.json();
                
                const container = document.getElementById('userRequests');
                const clearBtn = document.getElementById('clearBtn');
                
                // Enable/disable clear button based on requests
                clearBtn.disabled = data.requests.length === 0;
                if (data.requests.length === 0) {
                    container.innerHTML = '<div class="empty-state">No requests yet</div>';
                    return;
                }
                
                container.innerHTML = data.requests.map(req => `
                    <div class="request-card">
                        <div class="request-header">
                            <span class="request-id">${req.id}</span>
                            <span class="status-badge status-${req.status}">${req.status.toUpperCase()}</span>
                        </div>
                        <div class="request-path">${req.path}</div>
                        <div class="approval-status">
                            <div class="approval-item">
                                <span>Ops:</span>
                                <span class="${req.approvals.ops ? 'approval-check' : 'approval-pending'}">
                                    ${req.approvals.ops ? '✓' : '⏳'}
                                </span>
                            </div>
                            <div class="approval-item">
                                <span>Security:</span>
                                <span class="${req.approvals.security ? 'approval-check' : 'approval-pending'}">
                                    ${req.approvals.security ? '✓' : '⏳'}
                                </span>
                            </div>
                            <div style="margin-left: auto; color: #888888;">
                                ${req.approval_type}
                            </div>
                        </div>
                        ${req.status === 'approved' ? `
                            <button onclick="unwrapSecret('${req.id}')">Unwrap Secret</button>
                        ` : ''}
                        ${req.secret_data ? `
                            <div class="secret-display">${JSON.stringify(req.secret_data, null, 2)}</div>
                        ` : ''}
                    </div>
                `).join('');
            } catch (error) {
                console.error('Error loading user requests:', error);
            }
        }
        
        async function loadPendingRequests() {
            try {
                const response = await fetch('/api/pending_requests');
                const data = await response.json();
                
                const container = document.getElementById('pendingRequests');
                if (data.requests.length === 0) {
                    container.innerHTML = '<div class="empty-state">No pending requests</div>';
                    return;
                }
                
                container.innerHTML = data.requests.map(req => {
                    const alreadyApproved = req.approvals[currentRole];
                    return `
                        <div class="request-card">
                            <div class="request-header">
                                <span class="request-id">${req.id}</span>
                                <span class="status-badge status-${req.status}">${req.status.toUpperCase()}</span>
                            </div>
                            <div class="request-path">${req.path}</div>
                            <div style="font-size: 13px; color: #CCCCCC; margin: 8px 0;">
                                User: ${req.user}
                            </div>
                            <div class="approval-status">
                                <div class="approval-item">
                                    <span>Ops:</span>
                                    <span class="${req.approvals.ops ? 'approval-check' : 'approval-pending'}">
                                        ${req.approvals.ops ? '✓' : '⏳'}
                                    </span>
                                </div>
                                <div class="approval-item">
                                    <span>Security:</span>
                                    <span class="${req.approvals.security ? 'approval-check' : 'approval-pending'}">
                                        ${req.approvals.security ? '✓' : '⏳'}
                                    </span>
                                </div>
                                <div style="margin-left: auto; color: #888888;">
                                    ${req.approval_type}
                                </div>
                            </div>
                            ${alreadyApproved ? `
                                <div style="text-align: center; color: #00FF00; margin-top: 10px; font-weight: 600;">
                                    ✓ Already approved by ${currentRole}
                                </div>
                            ` : `
                                <div class="button-group">
                                    <button class="btn-approve" onclick="approveRequest('${req.id}')">Approve</button>
                                    <button class="btn-deny" onclick="denyRequest('${req.id}')">Deny</button>
                                </div>
                            `}
                        </div>
                    `;
                }).join('');
            } catch (error) {
                console.error('Error loading pending requests:', error);
            }
        }
        
        // Auto-refresh every 2 seconds
        setInterval(() => {
            loadUserRequests();
            loadPendingRequests();
        }, 2000);
        
        // Initial load
        loadUserRequests();
        loadPendingRequests();
    </script>
</body>
</html>
'''

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)

# Made with Bob
