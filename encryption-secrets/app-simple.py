#!/usr/bin/env python3
from flask import Flask, render_template_string, jsonify, request
import psycopg2
import hvac
import os
import time
import random
import threading
from faker import Faker

fake_us = Faker('en_US')
fake_se = Faker('sv_SE')

app = Flask(__name__)

# Global state for seed operation
seed_state = {
    'running': False,
    'progress': 0,
    'total': 0,
    'message': 'Ready to seed data...',
    'current_name': ''
}
seed_lock = threading.Lock()

def get_db_connection():
    return psycopg2.connect(
        host=os.environ.get('DB_HOST', 'postgres-postgresql.postgres.svc.cluster.local'),
        port=os.environ.get('DB_PORT', '5432'),
        database=os.environ.get('DB_NAME', 'encryption_demo'),
        user=os.environ.get('DB_USER', 'encryption_user'),
        password=os.environ.get('DB_PASSWORD', 'encryption_pass')
    )

def get_vault_client():
    vault_addr = os.environ.get('VAULT_ADDR', 'https://host.minikube.internal:8200')
    vault_namespace = os.environ.get('VAULT_NAMESPACE', 'master-demo')
    vault_skip_verify = os.environ.get('VAULT_SKIP_VERIFY', 'false').lower() == 'true'
    
    # Read Kubernetes service account token
    with open('/var/run/secrets/kubernetes.io/serviceaccount/token', 'r') as f:
        jwt = f.read()
    
    # Create client and authenticate using Kubernetes auth
    client = hvac.Client(url=vault_addr, namespace=vault_namespace, verify=not vault_skip_verify)
    
    # Authenticate with Kubernetes auth method
    auth_response = client.auth.kubernetes.login(
        role='master-demo-auth-role-encryption',
        jwt=jwt,
        mount_point='master-demo-auth'
    )
    
    # Set the token from the auth response
    client.token = auth_response['auth']['client_token']
    
    return client

def extract_key_version(ciphertext):
    """Extract key version from Vault ciphertext format: vault:v{version}:..."""
    try:
        parts = ciphertext.split(':')
        if len(parts) >= 2 and parts[1].startswith('v'):
            return int(parts[1][1:])  # Remove 'v' and convert to int
    except:
        pass
    return 1  # Default to 1 if parsing fails

def encrypt_transit(plaintext):
    import base64
    client = get_vault_client()
    # Vault Transit requires base64-encoded plaintext
    plaintext_b64 = base64.b64encode(plaintext.encode('utf-8')).decode('utf-8')
    response = client.secrets.transit.encrypt_data(
        name='customer-key',
        plaintext=plaintext_b64,
        mount_point='master-demo-encryption-transit'
    )
    return response['data']['ciphertext']

def decrypt_transit(ciphertext):
    import base64
    client = get_vault_client()
    response = client.secrets.transit.decrypt_data(
        name='customer-key',
        ciphertext=ciphertext,
        mount_point='master-demo-encryption-transit'
    )
    return base64.b64decode(response['data']['plaintext']).decode('utf-8')

def tokenize_fpe(plaintext):
    client = get_vault_client()
    response = client.write(
        'master-demo-encryption-transform/encode/encryption-demo-role',
        value=plaintext,
        transformation='credit-card-fpe'
    )
    return response['data']['encoded_value']

def detokenize_fpe(token):
    client = get_vault_client()
    response = client.write(
        'master-demo-encryption-transform/decode/encryption-demo-role',
        value=token,
        transformation='credit-card-fpe'
    )
    return response['data']['decoded_value']

def generate_us_data():
    return {
        'name': fake_us.name(),
        'ssn': fake_us.ssn(),
        'address': fake_us.address().replace('\n', ', '),
        'credit_card': fake_us.credit_card_number(card_type='visa16')
    }

def generate_swedish_data():
    return {
        'name': fake_se.name(),
        'ssn': fake_se.ssn(),
        'address': fake_se.address().replace('\n', ', '),
        'credit_card': fake_se.credit_card_number(card_type='visa16')
    }

def seed_data_background(region, count):
    global seed_state
    
    try:
        with seed_lock:
            seed_state['running'] = True
            seed_state['progress'] = 0
            seed_state['total'] = count
            seed_state['message'] = 'Starting...'
        
        for i in range(count):
            # Check if we should stop
            with seed_lock:
                if not seed_state['running']:
                    seed_state['message'] = f'⚠ Stopped by user at {i}/{count} records'
                    return
            
            # Generate data
            if region == 'us':
                customer = generate_us_data()
            else:
                customer = generate_swedish_data()
            
            # Encrypt
            encrypted_ssn = encrypt_transit(customer['ssn'])
            encrypted_address = encrypt_transit(customer['address'])
            tokenized_card = tokenize_fpe(customer['credit_card'])
            
            # Extract key version from ciphertext
            key_version = extract_key_version(encrypted_ssn)
            
            # Insert
            conn = get_db_connection()
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO customers (name, ssn, address, credit_card, region, key_version) VALUES (%s, %s, %s, %s, %s, %s)",
                (customer['name'], encrypted_ssn, encrypted_address, tokenized_card, region, key_version)
            )
            conn.commit()
            cur.close()
            conn.close()
            
            # Update progress
            with seed_lock:
                seed_state['progress'] = i + 1
                seed_state['current_name'] = customer['name']
                seed_state['message'] = f"Added {i+1}/{count}: {customer['name']}"
            
        
        with seed_lock:
            seed_state['running'] = False
            seed_state['message'] = f'✓ Complete! Added {count} records'
    
    except Exception as e:
        with seed_lock:
            seed_state['running'] = False
            seed_state['message'] = f'ERROR: {str(e)}'

HTML_TEMPLATE = '''
<!DOCTYPE html>
<html>
<head>
    <title>Vault Encryption Demo</title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
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
        .header, .container {
            position: relative;
            z-index: 1;
        }
        .header {
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
            background: #1a1a1a;
            border: 2px solid #333333;
            padding: 25px;
            border-radius: 8px;
        }
        .full-width {
            grid-column: 1 / -1;
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
        label {
            display: block;
            color: #FFD814;
            margin-bottom: 8px;
            font-weight: 600;
            text-transform: uppercase;
            font-size: 12px;
            letter-spacing: 0.05em;
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
        }
        input[type="number"]::-webkit-inner-spin-button,
        input[type="number"]::-webkit-outer-spin-button {
            -webkit-appearance: none;
            margin: 0;
        }
        input[type="number"] {
            -moz-appearance: textfield;
        }
        input::placeholder {
            color: #666666;
            font-style: italic;
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
        }
        button:hover {
            background: #FFC700;
            transform: translateY(-1px);
            box-shadow: 0 4px 8px rgba(255, 216, 20, 0.3);
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
        button:disabled:hover {
            background: #333333 !important;
            transform: none !important;
            box-shadow: none !important;
        }
        button:not(:disabled):hover {
            transform: translateY(-2px);
            box-shadow: 0 0 20px rgba(255, 216, 20, 0.6);
        }
        .button-group {
            display: flex;
            gap: 10px;
            margin-top: 10px;
        }
        .button-group button {
            flex: 1;
        }
        .button-group-right {
            display: flex;
            gap: 10px;
            margin-top: 10px;
        }
        .button-group-right button {
            flex: 1;
        }
        #seed-status, #view-status {
            margin-top: 15px;
            padding: 20px;
            background: #000000;
            border: 2px solid #333333;
            border-radius: 6px;
            min-height: 50px;
            color: #FFFFFF;
            font-family: 'SF Mono', 'Monaco', 'Inconsolata', 'Roboto Mono', monospace;
            font-size: 13px;
            line-height: 1.6;
        }
        #seed-status strong, #view-status strong {
            color: #FFD814;
            display: block;
            margin-bottom: 8px;
            font-weight: 600;
        }
        .status {
            display: inline-block;
            padding: 6px 12px;
            border-radius: 4px;
            font-size: 13px;
            font-weight: 600;
            border: 1px solid #FFD814;
        }
        .status.active {
            background: rgba(255, 216, 20, 0.1);
            color: #FFD814;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #333333;
            font-size: 14px;
        }
        th {
            background: rgba(255, 216, 20, 0.1);
            color: #FFD814;
            font-weight: 600;
        }
        td {
            font-family: 'SF Mono', 'Monaco', 'Inconsolata', 'Roboto Mono', monospace;
            font-size: 13px;
        }
        .empty-state {
            text-align: center;
            padding: 40px;
            color: #888888;
            font-style: italic;
        }
        .cipher-cell {
            cursor: pointer;
            transition: all 0.2s;
            position: relative;
        }
        .cipher-cell:hover {
            outline: 2px solid #FFD814;
            outline-offset: -2px;
        }
        .cipher-cell:active {
            outline: 2px solid #FFC700;
            outline-offset: -2px;
        }
        .copy-tooltip {
            position: fixed;
            background: #FFD814;
            color: #000000;
            padding: 8px 16px;
            border-radius: 6px;
            font-size: 13px;
            font-weight: 600;
            pointer-events: none;
            z-index: 10000;
            opacity: 0;
            transition: opacity 0.2s;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
        }
        .copy-tooltip.show {
            opacity: 1;
        }
        
        /* Modal Overlay Styles */
        .modal-overlay {
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: rgba(0, 0, 0, 0.85);
            z-index: 9999;
            justify-content: center;
            align-items: center;
        }
        .modal-overlay.show {
            display: flex;
        }
        .modal-content {
            background: #1a1a1a;
            border: 2px solid #FFD814;
            border-radius: 12px;
            padding: 40px;
            min-width: 500px;
            text-align: center;
        }
        .modal-content h2 {
            color: #FFD814;
            margin-bottom: 30px;
            font-size: 24px;
        }
        .progress-info {
            font-size: 18px;
            margin: 20px 0;
            color: #FFFFFF;
        }
        .progress-bar-container {
            width: 100%;
            height: 30px;
            background: #333333;
            border-radius: 15px;
            overflow: hidden;
            margin: 20px 0;
        }
        .progress-bar {
            height: 100%;
            background: linear-gradient(90deg, #FFD814 0%, #FFA500 100%);
            transition: width 0.3s ease;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #000000;
            font-weight: 600;
        }
        .current-record {
            color: #888888;
            font-size: 14px;
            margin-top: 15px;
        }
        .modal-button {
            margin-top: 25px;
            background: #FFD814;
            color: #000000;
            border: none;
            padding: 12px 32px;
            border-radius: 6px;
            cursor: pointer;
            font-size: 15px;
            font-weight: 600;
            transition: all 0.2s;
            font-family: 'Inter', sans-serif;
        }
        .modal-button:hover {
            background: #FFC700;
            transform: translateY(-1px);
            box-shadow: 0 4px 8px rgba(255, 216, 20, 0.3);
        }
        .modal-button:active {
            transform: translateY(0);
        }
    </style>
</head>
<body>
    <!-- Modal Overlay for Seeding Progress -->
    <div id="seedModal" class="modal-overlay">
        <div class="modal-content">
            <h2>Encrypting Customer Data</h2>
            <div class="progress-info">
                <span id="modalProgress">0</span> / <span id="modalTotal">0</span> records
            </div>
            <div class="progress-bar-container">
                <div id="progressBar" class="progress-bar" style="width: 0%">0%</div>
            </div>
            <div class="current-record">
                <strong>Current:</strong> <span id="modalCurrentName">-</span>
            </div>
            <button class="modal-button" onclick="stopSeed()">Stop Seeding</button>
        </div>
    </div>

    <div class="header">
        <h1>Vault Encryption as a Service</h1>
    </div>
    
    <div class="container">
        <div class="panel">
            <h2>Data Seeding</h2>
            
            <label>Region</label>
            <select id="region">
                <option value="us">United States</option>
                <option value="sweden">Sweden</option>
            </select>
            
            <label id="rowCountLabel" style="margin-top: 15px;">Number of Customer Records</label>
            <input type="number" id="rowCount" min="1" max="1000" placeholder="Enter number of records to add. Default is 10.">
            
            <div class="button-group" style="margin-top: 48px;">
                <button id="seedBtn" onclick="startSeed()">Seed Data</button>
                <button id="clearBtn" onclick="clearData()" disabled>Clear All</button>
            </div>
        </div>
        
        <div class="panel">
            <h2 style="display: flex; justify-content: space-between; align-items: center;">
                <span>View Controls</span>
                <span style="color: #888888; font-size: 12px; font-weight: 400;">
                    Current Key: <span id="keyVersion" style="color: #FFD814; font-weight: 600;">Loading...</span>
                </span>
            </h2>
            <div style="padding-top: 20px;">
                <div class="button-group">
                    <button onclick="loadData('encrypted')">Encrypted View</button>
                    <button onclick="loadData('cleartext')">Cleartext View</button>
                    <button onclick="loadData('batch')">Cleartext (Batch)</button>
                </div>
                
                <div id="view-status">Click a view button to load data</div>
                
                <div class="button-group-right" style="margin-top: 20px;">
                    <button onclick="decryptCipher()">Decrypt Cipher</button>
                    <button onclick="rotateKey()">Rotate Key</button>
                    <button onclick="rewrapAll()">Re-wrap All (Batch)</button>
                </div>
                
                <input type="text" id="cipherInput" placeholder="Enter cipher to decrypt. Copy a cipher from the customer list below by clicking on it." style="margin-top: 15px;">
            </div>
        </div>
        
        <div class="panel full-width">
            <h2 style="display: flex; justify-content: space-between; align-items: center;">
                <span>Customer Data</span>
                <span class="status active" id="recordCount">0 records</span>
            </h2>
            <div id="dataContainer">
                <div class="empty-state">No data yet. Click "Seed Data" to generate encrypted customer records.</div>
            </div>
        </div>
    </div>
    
    <script>
        let pollInterval = null;
        let currentView = 'encrypted';
        let isLoading = false;
        
        function disableAllButtons() {
            document.querySelectorAll('button').forEach(btn => {
                // Don't disable modal buttons
                if (!btn.classList.contains('modal-button')) {
                    btn.disabled = true;
                }
            });
        }
        
        function enableAllButtons() {
            document.querySelectorAll('button').forEach(btn => {
                // Don't disable modal buttons
                if (!btn.classList.contains('modal-button')) {
                    btn.disabled = false;
                }
            });
        }
        
        function startSeed() {
            const region = document.getElementById('region').value;
            const countInput = document.getElementById('rowCount').value;
            const count = countInput ? parseInt(countInput) : 10; // Default to 10 if empty
            
            if (count < 1 || count > 1000) {
                alert('Please enter a number between 1 and 1000');
                return;
            }
            
            // Show modal
            document.getElementById('modalTotal').textContent = count;
            document.getElementById('modalProgress').textContent = '0';
            document.getElementById('progressBar').style.width = '0%';
            document.getElementById('progressBar').textContent = '0%';
            document.getElementById('modalCurrentName').textContent = 'Starting...';
            document.getElementById('seedModal').classList.add('show');
            
            disableAllButtons();
            
            fetch('/api/seed', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({region, count})
            })
            .then(r => r.json())
            .then(data => {
                if (data.success) {
                    // Start polling for progress
                    pollInterval = setInterval(checkProgress, 500);
                } else {
                    alert('ERROR: ' + data.error);
                    document.getElementById('seedModal').classList.remove('show');
                    enableAllButtons();
                }
            });
        }
        
        function checkProgress() {
            fetch('/api/seed/status')
                .then(r => r.json())
                .then(data => {
                    // Update modal
                    document.getElementById('modalProgress').textContent = data.progress || 0;
                    document.getElementById('modalCurrentName').textContent = data.current_name || '-';
                    
                    const percent = data.total > 0 ? Math.round((data.progress / data.total) * 100) : 0;
                    document.getElementById('progressBar').style.width = percent + '%';
                    document.getElementById('progressBar').textContent = percent + '%';
                    
                    if (!data.running) {
                        clearInterval(pollInterval);
                        
                        // Hide modal after a short delay
                        setTimeout(() => {
                            document.getElementById('seedModal').classList.remove('show');
                            enableAllButtons();
                            loadData(currentView);
                        }, 1500);
                    }
                });
        }
        
        function stopSeed() {
            // Tell backend to stop
            fetch('/api/seed/stop', {method: 'POST'})
                .then(r => r.json())
                .then(data => {
                    // Stop polling
                    if (pollInterval) {
                        clearInterval(pollInterval);
                        pollInterval = null;
                    }
                    
                    // Hide modal
                    document.getElementById('seedModal').classList.remove('show');
                    
                    // Re-enable buttons
                    enableAllButtons();
                    
                    // Reload data to show what was added
                    loadData(currentView);
                });
        }
        
        function clearData() {
            if (!confirm('Clear all customer data?')) return;
            
            disableAllButtons();
            
            fetch('/api/clear', {method: 'POST'})
                .then(r => r.json())
                .then(data => {
                    loadData('encrypted');
                })
                .finally(() => {
                    enableAllButtons();
                });
        }
        
        function loadData(view) {
            if (isLoading) return;
            
            currentView = view;
            isLoading = true;
            disableAllButtons();
            
            const startTime = Date.now();
            document.getElementById('view-status').innerHTML = '<strong>LOADING...</strong><br>Please wait...';
            
            fetch(`/api/data?view=${view}`)
                .then(r => r.json())
                .then(data => {
                    const elapsed = ((Date.now() - startTime) / 1000).toFixed(3);
                    
                    if (data.error) {
                        document.getElementById('view-status').innerHTML = `<strong>ERROR:</strong> ${data.error}`;
                        document.getElementById('dataContainer').innerHTML =
                            '<div class="empty-state">Error loading data. Check logs for details.</div>';
                        return;
                    }
                    
                    document.getElementById('view-status').innerHTML =
                        `<strong>${view.toUpperCase()} VIEW</strong><br>Loaded ${data.count || 0} records in ${elapsed}s`;
                    
                    document.getElementById('recordCount').textContent = `${data.count || 0} records`;
                    
                    // Enable/disable Clear All button based on record count
                    document.getElementById('clearBtn').disabled = (data.count === 0);
                    
                    if (!data.records || data.count === 0) {
                        document.getElementById('dataContainer').innerHTML =
                            '<div class="empty-state">No data yet. Click "Seed Data" to generate encrypted customer records.</div>';
                        return;
                    }
                    
                    let html = '<table><thead><tr>';
                    html += '<th>ID</th><th>Name</th><th>SSN</th><th>Address</th><th>Credit Card</th><th>Region</th>';
                    html += '</tr></thead><tbody>';
                    
                    data.records.forEach(r => {
                        html += '<tr>';
                        html += `<td>${r.id || ''}</td>`;
                        html += `<td>${r.name || ''}</td>`;
                        // Store full ciphertext in data attribute, display truncated
                        const ssnDisplay = r.ssn_full ? (r.ssn_full.length > 50 ? r.ssn_full.substring(0, 50) + '...' : r.ssn_full) : (r.ssn || '');
                        const addrDisplay = r.address_full ? (r.address_full.length > 50 ? r.address_full.substring(0, 50) + '...' : r.address_full) : (r.address || '');
                        html += `<td class="cipher-cell" onclick="copyCipher(this, event)" data-full="${r.ssn_full || r.ssn || ''}" title="Click to copy full ciphertext">${ssnDisplay}</td>`;
                        html += `<td class="cipher-cell" onclick="copyCipher(this, event)" data-full="${r.address_full || r.address || ''}" title="Click to copy full ciphertext">${addrDisplay}</td>`;
                        html += `<td>${r.credit_card || ''}</td>`;
                        html += `<td>${r.region ? r.region.toUpperCase() : ''}</td>`;
                        html += '</tr>';
                    });
                    
                    html += '</tbody></table>';
                    document.getElementById('dataContainer').innerHTML = html;
                })
                .finally(() => {
                    isLoading = false;
                    enableAllButtons();
                    // Ensure Stop button stays disabled after loading
                    document.getElementById('stopBtn').disabled = true;
                });
        }
        
        function rotateKey() {
            if (!confirm('Rotate the Transit encryption key?')) return;
            
            disableAllButtons();
            const startTime = Date.now();
            document.getElementById('view-status').innerHTML = '<strong>ROTATING KEY...</strong><br>Please wait...';
            
            fetch('/api/rotate', {method: 'POST'})
                .then(r => r.json())
                .then(data => {
                    const elapsed = ((Date.now() - startTime) / 1000).toFixed(3);
                    document.getElementById('view-status').innerHTML =
                        `<strong>KEY ROTATED</strong><br>New version: ${data.version} (${elapsed}s)`;
                    document.getElementById('keyVersion').textContent = `v${data.version}`;
                })
                .finally(() => {
                    enableAllButtons();
                });
        }
        
        function rewrapAll() {
            if (!confirm('Re-wrap all encrypted data to the latest key version?')) return;
            
            disableAllButtons();
            const startTime = Date.now();
            document.getElementById('view-status').innerHTML = '<strong>RE-WRAPPING...</strong><br>Please wait...';
            
            fetch('/api/rewrap-batch', {method: 'POST'})
                .then(r => r.json())
                .then(data => {
                    const elapsed = ((Date.now() - startTime) / 1000).toFixed(3);
                    document.getElementById('view-status').innerHTML =
                        `<strong>RE-WRAP COMPLETE</strong><br>Updated ${data.count} records in ${elapsed}s`;
                    loadData(currentView);
                })
                .finally(() => {
                    enableAllButtons();
                });
        }
        
        // Copy cipher to clipboard and paste into input
        function copyCipher(cell, event) {
            const fullText = cell.getAttribute('data-full') || cell.textContent;
            
            // Copy to clipboard
            navigator.clipboard.writeText(fullText).then(() => {
                // Also paste into cipher input field
                document.getElementById('cipherInput').value = fullText;
                
                // Create tooltip
                const tooltip = document.createElement('div');
                tooltip.className = 'copy-tooltip';
                tooltip.textContent = 'Cipher copied to clipboard and decryption field';
                document.body.appendChild(tooltip);
                
                // Center in viewport
                tooltip.style.left = '50%';
                tooltip.style.top = '50%';
                tooltip.style.transform = 'translate(-50%, -50%)';
                
                // Show tooltip
                setTimeout(() => tooltip.classList.add('show'), 10);
                
                // Remove after 2 seconds
                setTimeout(() => {
                    tooltip.classList.remove('show');
                    setTimeout(() => tooltip.remove(), 200);
                }, 2000);
            }).catch(err => {
                console.error('Failed to copy:', err);
                alert('Failed to copy to clipboard');
            });
        }
        
        function decryptCipher() {
            const ciphertext = document.getElementById('cipherInput').value.trim();
            
            if (!ciphertext) {
                alert('Please enter a ciphertext to decrypt');
                return;
            }
            
            if (!ciphertext.startsWith('vault:v')) {
                alert('Invalid ciphertext format. Must start with "vault:v"');
                return;
            }
            
            disableAllButtons();
            const startTime = Date.now();
            document.getElementById('view-status').innerHTML = '<strong>DECRYPTING...</strong><br>Please wait...';
            
            fetch('/api/decrypt', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({ciphertext: ciphertext})
            })
            .then(r => r.json())
            .then(data => {
                const elapsed = ((Date.now() - startTime) / 1000).toFixed(3);
                
                if (data.error) {
                    document.getElementById('view-status').innerHTML = `<strong>DECRYPTION ERROR:</strong><br>${data.error}`;
                } else {
                    document.getElementById('view-status').innerHTML =
                        `<strong>DECRYPTED VALUE:</strong><br>${data.plaintext}<br><br>Time: ${elapsed}s`;
                }
            })
            .catch(err => {
                document.getElementById('view-status').innerHTML = `<strong>ERROR:</strong><br>${err.message}`;
            })
            .finally(() => {
                enableAllButtons();
            });
        }
        
        // Initialize page - ensure buttons are properly disabled
        function initializePage() {
            // Force stop button to be disabled
            const stopBtn = document.getElementById('stopBtn');
            if (stopBtn) {
                stopBtn.disabled = true;
                stopBtn.setAttribute('disabled', 'disabled');
            }
            const clearBtn = document.getElementById('clearBtn');
            if (clearBtn) {
                clearBtn.disabled = true;
                clearBtn.setAttribute('disabled', 'disabled');
            }
            loadKeyVersion();
            loadData('encrypted');
        }
        
        function loadKeyVersion() {
            fetch('/api/key-version')
                .then(r => r.json())
                .then(data => {
                    document.getElementById('keyVersion').textContent = `v${data.version}`;
                })
                .catch(err => {
                    document.getElementById('keyVersion').textContent = 'Error';
                });
        }
        
        // Wait for DOM to be fully loaded before initializing
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', initializePage);
        } else {
            initializePage();
        }
    </script>
</body>
</html>
'''

@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE)

@app.route('/health')
def health():
    return jsonify({"status": "healthy"})

@app.route('/api/seed', methods=['POST'])
def api_seed():
    global seed_state
    
    with seed_lock:
        if seed_state['running']:
            return jsonify({'success': False, 'error': 'Seeding already in progress'})
    
    data = request.json
    region = data.get('region', 'us')
    count = int(data.get('count', 50))
    
    # Start background thread
    thread = threading.Thread(target=seed_data_background, args=(region, count))
    thread.daemon = True
    thread.start()
    
    return jsonify({'success': True})

@app.route('/api/seed/stop', methods=['POST'])
def api_seed_stop():
    global seed_state
    
    with seed_lock:
        if seed_state['running']:
            seed_state['running'] = False
            return jsonify({'success': True, 'message': 'Stopping seeding...'})
        else:
            return jsonify({'success': False, 'message': 'No seeding in progress'})

@app.route('/api/seed/status')
def api_seed_status():
    with seed_lock:
        return jsonify(seed_state)

@app.route('/api/data')
def api_data():
    view = request.args.get('view', 'encrypted')
    
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT id, name, ssn, address, credit_card, region, key_version FROM customers ORDER BY id DESC LIMIT 100")
        rows = cur.fetchall()
        cur.close()
        conn.close()
        
        records = []
        
        if view == 'encrypted':
            for row in rows:
                records.append({
                    'id': row[0],
                    'name': row[1],
                    'ssn': row[2][:50] + '...' if len(row[2]) > 50 else row[2],
                    'ssn_full': row[2],
                    'address': row[3][:50] + '...' if len(row[3]) > 50 else row[3],
                    'address_full': row[3],
                    'credit_card': row[4],
                    'region': row[5],
                    'key_version': row[6]
                })
        
        elif view == 'cleartext':
            for row in rows:
                records.append({
                    'id': row[0],
                    'name': row[1],
                    'ssn': decrypt_transit(row[2]),
                    'address': decrypt_transit(row[3]),
                    'credit_card': detokenize_fpe(row[4]),
                    'region': row[5],
                    'key_version': row[6]
                })
        
        elif view == 'batch':
            # Batch decrypt for better performance
            ssns = [row[2] for row in rows]
            addresses = [row[3] for row in rows]
            
            client = get_vault_client()
            
            # Batch decrypt SSNs
            ssn_response = client.secrets.transit.decrypt_data(
                name='customer-key',
                batch_input=[{'ciphertext': ssn} for ssn in ssns],
                mount_point='master-demo-encryption-transit'
            )
            
            # Batch decrypt addresses
            addr_response = client.secrets.transit.decrypt_data(
                name='customer-key',
                batch_input=[{'ciphertext': addr} for addr in addresses],
                mount_point='master-demo-encryption-transit'
            )
            
            import base64
            decrypted_ssns = [base64.b64decode(item['plaintext']).decode('utf-8') for item in ssn_response['data']['batch_results']]
            decrypted_addresses = [base64.b64decode(item['plaintext']).decode('utf-8') for item in addr_response['data']['batch_results']]
            
            for i, row in enumerate(rows):
                records.append({
                    'id': row[0],
                    'name': row[1],
                    'ssn': decrypted_ssns[i],
                    'address': decrypted_addresses[i],
                    'credit_card': detokenize_fpe(row[4]),
                    'region': row[5],
                    'key_version': row[6]
                })
        
        return jsonify({'count': len(records), 'records': records})
    
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/clear', methods=['POST'])
def api_clear():
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("DELETE FROM customers")
        conn.commit()
        cur.close()
        conn.close()
        return jsonify({'message': 'All data cleared'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/key-version')
def api_key_version():
    try:
        client = get_vault_client()
        key_info = client.secrets.transit.read_key(
            name='customer-key',
            mount_point='master-demo-encryption-transit'
        )
        return jsonify({'version': key_info['data']['latest_version']})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/rotate', methods=['POST'])
def api_rotate():
    try:
        client = get_vault_client()
        client.secrets.transit.rotate_key(
            name='customer-key',
            mount_point='master-demo-encryption-transit'
        )
        
        key_info = client.secrets.transit.read_key(
            name='customer-key',
            mount_point='master-demo-encryption-transit'
        )
        
        return jsonify({'version': key_info['data']['latest_version']})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/decrypt', methods=['POST'])
def api_decrypt():
    try:
        data = request.get_json()
        ciphertext = data.get('ciphertext', '').strip()
        
        if not ciphertext:
            return jsonify({'error': 'No ciphertext provided'}), 400
        
        if not ciphertext.startswith('vault:v'):
            return jsonify({'error': 'Invalid ciphertext format'}), 400
        
        client = get_vault_client()
        
        # Decrypt using Transit engine
        decrypt_response = client.secrets.transit.decrypt_data(
            name='customer-key',
            ciphertext=ciphertext,
            mount_point='master-demo-encryption-transit'
        )
        
        plaintext = decrypt_response['data']['plaintext']
        
        # Decode from base64
        import base64
        decoded = base64.b64decode(plaintext).decode('utf-8')
        
        return jsonify({'plaintext': decoded})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/rewrap-batch', methods=['POST'])
def api_rewrap_batch():
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT id, ssn, address FROM customers")
        rows = cur.fetchall()
        
        if not rows:
            return jsonify({'count': 0})
        
        client = get_vault_client()
        
        # Get current key version
        key_info = client.secrets.transit.read_key(
            name='customer-key',
            mount_point='master-demo-encryption-transit'
        )
        key_version = key_info['data']['latest_version']
        
        # Batch rewrap SSNs
        ssn_batch = [{'ciphertext': row[1]} for row in rows]
        ssn_response = client.write(
            f'master-demo-encryption-transit/rewrap/customer-key',
            batch_input=ssn_batch
        )
        
        # Batch rewrap addresses
        addr_batch = [{'ciphertext': row[2]} for row in rows]
        addr_response = client.write(
            f'master-demo-encryption-transit/rewrap/customer-key',
            batch_input=addr_batch
        )
        
        rewrapped_ssns = [item['ciphertext'] for item in ssn_response['data']['batch_results']]
        rewrapped_addresses = [item['ciphertext'] for item in addr_response['data']['batch_results']]
        
        # Update database - extract version from rewrapped ciphertext
        for i, row in enumerate(rows):
            # Extract the actual key version from the rewrapped ciphertext
            actual_version = extract_key_version(rewrapped_ssns[i])
            cur.execute(
                "UPDATE customers SET ssn = %s, address = %s, key_version = %s WHERE id = %s",
                (rewrapped_ssns[i], rewrapped_addresses[i], actual_version, row[0])
            )
        
        conn.commit()
        cur.close()
        conn.close()
        
        return jsonify({'success': True, 'count': len(rows)})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    print("Starting Vault Encryption Demo...")
    print(f"Vault Address: {os.environ.get('VAULT_ADDR')}")
    print(f"Vault Namespace: {os.environ.get('VAULT_NAMESPACE')}")
    app.run(host='0.0.0.0', port=8080, debug=False)

# Made with Bob
