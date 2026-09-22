#!/usr/bin/env python3
from flask import Flask, render_template_string, jsonify, request
import hvac
import os
import json
import time
import requests as http_requests
from datetime import datetime

app = Flask(__name__)

# In-memory storage for demo purposes
# Both "secret" and "policy" CG requests share this store, keyed by request_id
# Each entry has a `type` field: "secret" or "policy"
requests_db = {}
request_counter = 0

def get_vault_client(role='user'):
    """Get Vault client authenticated with specified role via Kubernetes auth"""
    vault_addr = os.environ.get('VAULT_ADDR', 'https://host.minikube.internal:8200')
    vault_namespace = os.environ.get('VAULT_NAMESPACE', 'master-demo')
    vault_skip_verify = os.environ.get('VAULT_SKIP_VERIFY', 'false').lower() == 'true'

    with open('/var/run/secrets/kubernetes.io/serviceaccount/token', 'r') as f:
        jwt = f.read()

    client = hvac.Client(url=vault_addr, namespace=vault_namespace, verify=not vault_skip_verify)

    vault_role_map = {
        'user':             'master-demo-auth-role-controlgroups-user',
        'ops':              'master-demo-auth-role-controlgroups-ops',
        'security':         'master-demo-auth-role-controlgroups-security',
        'policy-admin':     'master-demo-auth-role-policy-admin',
        'policy-approver':  'master-demo-auth-role-policy-approver',
    }

    auth_response = client.auth.kubernetes.login(
        role=vault_role_map.get(role, vault_role_map['user']),
        jwt=jwt,
        mount_point='master-demo-auth'
    )
    client.token = auth_response['auth']['client_token']
    return client


def _extract_cg_accessor(response_obj):
    """
    Try to extract a Control Group accessor from a raw requests.Response or
    from an hvac exception. Returns the accessor string, or None if not found.
    """
    try:
        if hasattr(response_obj, 'json'):
            body = response_obj.json()
        elif isinstance(response_obj, dict):
            body = response_obj
        else:
            return None
        wrap_info = body.get('wrap_info') or body.get('wrapInfo')
        if wrap_info and isinstance(wrap_info, dict):
            return wrap_info.get('accessor') or wrap_info.get('token')
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# Policy-write CG routes (new)
# ---------------------------------------------------------------------------

@app.route('/api/create_policy', methods=['POST'])
def create_policy():
    """
    Policy-admin attempts to write an ACL policy.
    - Sentinel rejection (403, no wrap_info) → {"blocked": true, "reason": "..."}
    - CG wrap (403, wrap_info present)       → {"pending": true, "request_id": "..."}
    - Success                                → {"success": true}
    """
    global request_counter

    data = request.get_json(force=True, silent=True) or {}
    policy_name = data.get('name', 'master-demo-policy-demo-test')
    policy_hcl  = data.get('policy', '')

    if not policy_hcl:
        return jsonify({'error': 'policy HCL is required'}), 400

    try:
        client = get_vault_client('policy-admin')

        # Attempt the policy write. On CG-protected paths Vault returns 403
        # with wrap_info; on Sentinel violation it also returns 403 but without wrap_info.
        # hvac raises hvac.exceptions.Forbidden in both cases, so we need the raw response.
        vault_addr      = os.environ.get('VAULT_ADDR', 'https://host.minikube.internal:8200')
        vault_namespace = os.environ.get('VAULT_NAMESPACE', 'master-demo')
        vault_skip_verify = os.environ.get('VAULT_SKIP_VERIFY', 'false').lower() == 'true'

        url     = f"{vault_addr}/v1/sys/policies/acl/{policy_name}"
        headers = {
            'X-Vault-Token':     client.token,
            'X-Vault-Namespace': vault_namespace,
            'Content-Type':      'application/json',
        }
        payload = {'policy': policy_hcl}

        raw = http_requests.put(url, headers=headers, json=payload, verify=not vault_skip_verify)

        body = {}
        try:
            body = raw.json()
        except Exception:
            pass

        # Check for CG wrap_info BEFORE checking success — CG returns 200 with wrap_info
        accessor = _extract_cg_accessor(body)
        cg_token = (body.get('wrap_info') or {}).get('token')
        if accessor:
            request_counter += 1
            request_id = f"pol_{request_counter}_{int(time.time())}"
            requests_db[request_id] = {
                'id':           request_id,
                'type':         'policy',
                'policy_name':  policy_name,
                'policy_hcl':   policy_hcl,
                'user':         'policy-admin',
                'status':       'pending',
                'accessor':     accessor,
                'cg_token':     cg_token,   # used with sys/wrapping/unwrap after approval
                'approvals':    {'approver': False},
                'approval_type':'1/1',
                'created_at':   datetime.now().isoformat(),
            }
            return jsonify({
                'pending':    True,
                'request_id': request_id,
                'message':    'Policy write requires approval (Control Group)',
            })

        # No wrap_info and no errors → genuine success (no CG on this path)
        if raw.status_code in (200, 204):
            return jsonify({'success': True, 'message': f'Policy {policy_name} created successfully'})

        # Sentinel rejection or other error
        errors = body.get('errors', [])
        reason = '; '.join(errors) if errors else raw.text or 'Policy write blocked'
        return jsonify({'blocked': True, 'reason': reason})

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/clear_policy_requests', methods=['POST'])
def clear_policy_requests():
    """Remove only type=policy entries from requests_db"""
    global requests_db
    requests_db = {k: v for k, v in requests_db.items() if v.get('type') != 'policy'}
    return jsonify({'success': True})


# ---------------------------------------------------------------------------
# Secret-read CG routes (existing, now with real Vault CG calls)
# ---------------------------------------------------------------------------

@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE)


@app.route('/api/request_secret', methods=['POST'])
def request_secret():
    """
    User requests access to a secret via Control Groups (real Vault CG call).
    Vault returns 403 + wrap_info.accessor when the CG stanza is triggered.
    """
    global request_counter

    data = request.get_json(force=True, silent=True) or {}
    secret_path = data.get('path')

    if not secret_path:
        return jsonify({'error': 'Secret path is required'}), 400

    try:
        client = get_vault_client('user')

        vault_addr        = os.environ.get('VAULT_ADDR', 'https://host.minikube.internal:8200')
        vault_namespace   = os.environ.get('VAULT_NAMESPACE', 'master-demo')
        vault_skip_verify = os.environ.get('VAULT_SKIP_VERIFY', 'false').lower() == 'true'

        # Convert UI path (secret/data/dev/api-key) → KV v2 API path
        kv_path = secret_path.replace('secret/data/', '')
        url     = f"{vault_addr}/v1/master-demo-kv/data/{kv_path}"
        headers = {
            'X-Vault-Token':     client.token,
            'X-Vault-Namespace': vault_namespace,
        }

        raw = http_requests.get(url, headers=headers, verify=not vault_skip_verify)

        body = {}
        try:
            body = raw.json() or {}
        except Exception:
            pass

        # Check for CG wrap_info FIRST — Vault Enterprise returns 200 with wrap_info
        # when a Control Group stanza is triggered (not a 403 in all versions).
        accessor = _extract_cg_accessor(body)
        cg_token = (body.get('wrap_info') or {}).get('token')
        if accessor:
            # Determine approval type from path
            if 'prod' in secret_path:
                approvals     = {'ops': False, 'security': False}
                approval_type = '2/2'
            else:
                approvals     = {'ops': False, 'security': False}
                approval_type = '1/2'

            request_counter += 1
            request_id = f"req_{request_counter}_{int(time.time())}"
            requests_db[request_id] = {
                'id':              request_id,
                'type':            'secret',
                'path':            secret_path,
                'kv_path':         kv_path,
                'user':            'demo-user',
                'status':          'pending',
                'approvals':       approvals,
                'approval_type':   approval_type,
                'created_at':      datetime.now().isoformat(),
                'accessor':        accessor,
                'cg_token':        cg_token,  # used with sys/wrapping/unwrap after approval
                'secret_data':     None,
            }
            return jsonify({
                'success':    True,
                'request_id': request_id,
                'message':    f'Access request created. Requires {approval_type} approvals.',
            })

        # Not a CG response — return the error
        errors = body.get('errors', [])
        reason = '; '.join(errors) if errors else 'Failed to request secret'
        return jsonify({'error': reason}), raw.status_code

    except Exception as e:
        import traceback; traceback.print_exc()
        return jsonify({'error': str(e)}), 500


@app.route('/api/approve', methods=['POST'])
def approve_request():
    """
    Approve a pending CG request (secret or policy).
    Makes a real Vault sys/control-group/authorize call.
    """
    data       = request.json
    request_id = data.get('request_id')
    role       = data.get('role', 'ops')   # 'ops', 'security', or 'approver'

    if not request_id:
        return jsonify({'error': 'request_id is required'}), 400

    if request_id not in requests_db:
        return jsonify({'error': 'Request not found'}), 404

    try:
        req      = requests_db[request_id]
        accessor = req.get('accessor')

        if not accessor:
            return jsonify({'error': 'No accessor stored for this request'}), 400

        # Choose the right Vault role for the authorizer
        if req['type'] == 'policy':
            approver_role = 'policy-approver'
        else:
            approver_role = role  # 'ops' or 'security'

        approver_client = get_vault_client(approver_role)

        # Real Vault CG authorize call
        approver_client.write('sys/control-group/authorize', accessor=accessor)

        # Mark the local approval flag
        if req['type'] == 'policy':
            req['approvals']['approver'] = True
            req['status'] = 'approved'
        else:
            if role in req['approvals']:
                req['approvals'][role] = True
            # Check if approval threshold is met
            if req['approval_type'] == '1/2':
                if any(req['approvals'].values()):
                    req['status'] = 'approved'
            elif req['approval_type'] == '2/2':
                if all(req['approvals'].values()):
                    req['status'] = 'approved'

        return jsonify({
            'success': True,
            'message': f'Request approved by {role}',
            'status':  req['status'],
        })

    except Exception as e:
        import traceback; traceback.print_exc()
        return jsonify({'error': str(e)}), 500


@app.route('/api/deny', methods=['POST'])
def deny_request():
    """Deny a pending CG request (works for both types)"""
    data       = request.json
    request_id = data.get('request_id')
    role       = data.get('role', 'approver')

    if not request_id:
        return jsonify({'error': 'request_id is required'}), 400

    if request_id not in requests_db:
        return jsonify({'error': 'Request not found'}), 404

    try:
        req            = requests_db[request_id]
        req['status']  = 'denied'
        req['denied_by'] = role
        return jsonify({'success': True, 'message': f'Request denied by {role}'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/unwrap', methods=['POST'])
def unwrap_secret():
    """
    Re-attempt the original secret read using the CG accessor as the token.
    Vault completes the read now that approvals are met.
    For approved policy requests, re-attempt the policy write instead.
    """
    data       = request.json
    request_id = data.get('request_id')

    if not request_id:
        return jsonify({'error': 'request_id is required'}), 400

    if request_id not in requests_db:
        return jsonify({'error': 'Request not found'}), 404

    try:
        req = requests_db[request_id]

        if req['status'] != 'approved':
            return jsonify({'error': 'Request not approved yet'}), 403

        accessor = req.get('accessor')
        if not accessor:
            return jsonify({'error': 'No accessor stored for this request'}), 400

        vault_addr        = os.environ.get('VAULT_ADDR', 'https://host.minikube.internal:8200')
        vault_namespace   = os.environ.get('VAULT_NAMESPACE', 'master-demo')
        vault_skip_verify = os.environ.get('VAULT_SKIP_VERIFY', 'false').lower() == 'true'

        if req['type'] == 'secret':
            # After CG approval, complete the read via sys/wrapping/unwrap using the
            # original CG token. Vault executes the wrapped GET and returns the secret.
            cg_token = req.get('cg_token')
            if not cg_token:
                return jsonify({'error': 'No CG token stored for this request'}), 400

            url = f"{vault_addr}/v1/sys/wrapping/unwrap"
            headers = {
                'X-Vault-Token':     cg_token,
                'X-Vault-Namespace': vault_namespace,
            }
            raw = http_requests.post(url, headers=headers, json={},
                                     verify=not vault_skip_verify)

            uwbody = {}
            try:
                uwbody = raw.json() or {}
            except Exception:
                pass

            if raw.status_code == 200:
                secret_data        = (uwbody.get('data') or {}).get('data') or {}
                req['secret_data'] = secret_data
                req['status']      = 'unwrapped'
                return jsonify({'success': True, 'secret': secret_data})

            errors = uwbody.get('errors', [])
            return jsonify({'error': '; '.join(errors) or 'Failed to unwrap secret'}), raw.status_code

        elif req['type'] == 'policy':
            # After CG approval, complete the write by calling sys/wrapping/unwrap
            # with the original CG token as the bearer. Vault executes the wrapped
            # operation (the policy PUT) and returns 204 on success.
            cg_token = req.get('cg_token')
            if not cg_token:
                return jsonify({'error': 'No CG token stored for this request'}), 400

            url = f"{vault_addr}/v1/sys/wrapping/unwrap"
            headers = {
                'X-Vault-Token':     cg_token,
                'X-Vault-Namespace': vault_namespace,
            }
            raw = http_requests.post(url, headers=headers, json={},
                                     verify=not vault_skip_verify)

            if raw.status_code in (200, 204):
                req['status'] = 'unwrapped'
                return jsonify({'success': True,
                                'message': f"Policy {req['policy_name']} written successfully"})

            body   = {}
            try: body = raw.json()
            except Exception: pass
            errors = body.get('errors', [])
            return jsonify({'error': '; '.join(errors) or 'Failed to write policy'}), raw.status_code

    except Exception as e:
        import traceback; traceback.print_exc()
        return jsonify({'error': str(e)}), 500


@app.route('/api/requests')
def get_requests():
    return jsonify({'requests': list(requests_db.values())})


@app.route('/api/user_requests')
def get_user_requests():
    secret_reqs = [r for r in requests_db.values() if r.get('type') == 'secret']
    return jsonify({'requests': list(reversed(secret_reqs))})


@app.route('/api/pending_requests')
def get_pending_requests():
    pending = [r for r in requests_db.values() if r['status'] == 'pending']
    return jsonify({'requests': list(reversed(pending))})


@app.route('/api/clear_requests', methods=['POST'])
def clear_requests():
    global requests_db, request_counter
    requests_db     = {}
    request_counter = 0
    return jsonify({'success': True})


# ---------------------------------------------------------------------------
# HTML Template
# ---------------------------------------------------------------------------

HTML_TEMPLATE = '''
<!DOCTYPE html>
<html>
<head>
    <title>Vault Policy Governance</title>
    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMjggMTI4Ij48cGF0aCBmaWxsPSIjZmZkODE0IiBkPSJtMCAxLjk1MyA2My43NiAxMjQuMDk0TDEyOCAxLjk1M1ptNTMuODQxIDQ5LjI1NEg0My42ODRWNDEuMDZINTMuODR6bTAtMTUuMjI3SDQzLjY4NFYyNS44MjJINTMuODRaTTY5LjA4IDY2LjQ0NEg1OC45N1Y1Ni4yODZoMTAuMTA4em0wLTE1LjIzN0g1OC45N1Y0MS4wNmgxMC4xMDh6bTAtMTUuMjI3SDU4Ljk3VjI1LjgyMmgxMC4xMDhabTE1LjE0NyAxNS4yMjdINzQuMDI3VjQxLjA2aDEwLjE1OVpNNzQuMDI3IDM1Ljk4VjI1LjgyMmgxMC4xNTlWMzUuOTh6Ii8+PC9zdmc+">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
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
        .header, .container, .panel { position: relative; z-index: 1; }
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
            margin: 0 auto 20px auto;
        }
        .panel {
            background: #1a1a1a;
            border: 2px solid #333333;
            padding: 25px;
            border-radius: 8px;
            position: relative;
            z-index: 1;
        }
        .full-width { grid-column: 1 / -1; }
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
        textarea {
            width: 100%;
            padding: 12px;
            background: #0a0a0a;
            border: 1px solid #333333;
            border-radius: 6px;
            color: #FFFFFF;
            font-size: 13px;
            font-family: 'SF Mono', 'Monaco', 'Inconsolata', 'Roboto Mono', monospace;
            resize: vertical;
            min-height: 110px;
            line-height: 1.6;
        }
        textarea:focus {
            outline: none;
            border-color: #FFD814;
            box-shadow: 0 0 0 2px rgba(255, 216, 20, 0.1);
        }
        textarea[readonly] { cursor: default; opacity: 0.85; }
        button {
            background: #FFD814;
            color: #000000;
            border: none;
            padding: 12px 24px;
            border-radius: 6px;
            cursor: pointer;
            font-size: 15px;
            font-weight: 600;
            margin: 5px 0;
            transition: all 0.2s;
            font-family: 'Inter', sans-serif;
            width: 100%;
        }
        button:hover:not(:disabled):not(.btn-clear):not(.btn-deny):not(.btn-approve) {
            background: #FFC700;
            transform: translateY(-1px);
            box-shadow: 0 4px 8px rgba(255, 216, 20, 0.3);
        }
        button:disabled {
            background: #333333 !important;
            color: #666666 !important;
            cursor: not-allowed !important;
            transform: none !important;
            opacity: 0.5;
        }
        .btn-waiting {
            background: #333333 !important;
            color: #FFD814 !important;
            cursor: not-allowed !important;
            opacity: 1 !important;
        }
        .btn-clear {
            padding: 6px 12px !important;
            font-size: 12px !important;
            background: #666666 !important;
            margin: 0 !important;
            width: auto !important;
            color: #FFFFFF !important;
        }
        .btn-clear:hover { background: #555555 !important; transform: none !important; box-shadow: none !important; }
        .btn-approve { background: #00CC44 !important; color: #000000 !important; }
        .btn-approve:hover { background: #00AA33 !important; }
        .btn-deny   { background: #CC2200 !important; color: #FFFFFF !important; }
        .btn-deny:hover   { background: #AA1100 !important; }

        /* Result boxes */
        .result-box {
            padding: 12px 16px;
            border-radius: 6px;
            margin-top: 14px;
            font-size: 13px;
            line-height: 1.5;
            font-family: 'SF Mono', 'Monaco', monospace;
            word-break: break-word;
            display: none;
        }
        .result-blocked {
            background: rgba(204, 34, 0, 0.12);
            border: 1px solid #CC2200;
            color: #FF6644;
        }
        .result-pending {
            background: rgba(255, 216, 20, 0.08);
            border: 1px solid #FFD814;
            color: #FFD814;
        }
        .result-success {
            background: rgba(0, 204, 68, 0.1);
            border: 1px solid #00CC44;
            color: #00EE55;
        }

        /* Role switcher */
        .role-switcher { display: flex; gap: 10px; margin-bottom: 20px; justify-content: center; }
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
            width: auto;
        }
        .role-btn.active { background: #FFD814; color: #000000; border-color: #FFD814; }
        .role-btn:hover:not(.active) { border-color: #FFD814; }

        /* Request cards */
        .request-card {
            background: #0a0a0a;
            border: 2px solid #333333;
            padding: 15px;
            margin: 10px 0;
            border-radius: 6px;
            transition: all 0.2s;
        }
        .request-card:hover { border-color: #555555; }
        .request-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; flex-wrap: wrap; gap: 6px; }
        .request-id { font-family: 'SF Mono', 'Monaco', monospace; font-size: 11px; color: #666666; }
        .request-path { font-family: 'SF Mono', 'Monaco', monospace; font-size: 13px; color: #FFFFFF; margin: 8px 0; }
        .status-badge {
            display: inline-block;
            padding: 3px 9px;
            border-radius: 4px;
            font-size: 11px;
            font-weight: 600;
        }
        .status-pending  { background: rgba(255,216,20,0.1);  color: #FFD814; border: 1px solid #FFD814; }
        .status-approved { background: rgba(0,204,68,0.1);    color: #00CC44; border: 1px solid #00CC44; }
        .status-denied   { background: rgba(204,34,0,0.1);    color: #FF4422; border: 1px solid #CC2200; }
        .status-unwrapped{ background: rgba(0,180,255,0.1);   color: #00B4FF; border: 1px solid #00B4FF; }
        .type-badge {
            display: inline-block;
            padding: 3px 9px;
            border-radius: 4px;
            font-size: 11px;
            font-weight: 700;
            margin-left: 6px;
        }
        .type-policy { background: rgba(255,216,20,0.15); color: #FFD814; border: 1px solid #FFD814; }
        .type-secret { background: rgba(0,180,255,0.12);  color: #00B4FF; border: 1px solid #00B4FF; }
        .approval-status { display: flex; gap: 15px; margin: 10px 0; font-size: 13px; flex-wrap: wrap; }
        .approval-item   { display: flex; align-items: center; gap: 5px; }
        .approval-check  { color: #00CC44; font-weight: bold; }
        .approval-pending{ color: #FFD814; }
        .button-group    { display: flex; gap: 10px; margin-top: 10px; }
        .button-group button { flex: 1; margin: 0; }
        .secret-display {
            background: #000000;
            border: 1px solid #333333;
            padding: 12px;
            border-radius: 4px;
            margin-top: 10px;
            font-family: 'SF Mono', 'Monaco', monospace;
            font-size: 12px;
            word-break: break-all;
            color: #00CC44;
        }
        .empty-state { text-align: center; color: #888888; padding: 30px 20px; font-size: 14px; }
        .scrollable { max-height: 500px; overflow-y: auto; }
        .scrollable::-webkit-scrollbar { width: 6px; }
        .scrollable::-webkit-scrollbar-track { background: #0a0a0a; }
        .scrollable::-webkit-scrollbar-thumb { background: #FFD814; border-radius: 3px; }

        /* Flow diagram */
        .flow-diagram {
            display: flex;
            align-items: stretch;
            justify-content: flex-start;
            gap: 16px;
            padding: 15px;
            background: #0a0a0a;
            border: 2px solid #333333;
            border-radius: 6px;
        }
        .flow-step {
            flex: 0 1 160px;
            min-height: 90px;
            display: flex;
            flex-direction: column;
            justify-content: center;
            text-align: center;
            padding: 12px 8px;
            background: #0a0a0a;
            border: 2px solid #333333;
            border-radius: 6px;
            transition: all 0.3s;
            opacity: 0.5;
        }
        .flow-step.active    { opacity: 1; border-color: #FFD814; box-shadow: 0 0 20px rgba(255,216,20,0.3); }
        .flow-step.completed { opacity: 1; border-color: #00CC44; }
        .flow-number {
            width: 28px; height: 28px;
            background: #333333; color: #888888;
            border-radius: 50%;
            display: flex; align-items: center; justify-content: center;
            font-weight: 700; font-size: 14px;
            margin: 0 auto 8px auto;
            transition: all 0.3s;
        }
        .flow-step.active .flow-number    { background: #FFD814; color: #000000; }
        .flow-step.completed .flow-number { background: #00CC44; color: #FFFFFF; }
        .flow-label { color: #FFFFFF; font-weight: 600; font-size: 13px; margin-bottom: 4px; }
        .flow-desc  { color: #888888; font-size: 11px; line-height: 1.3; }
        .flow-arrow { color: #FFD814; font-size: 20px; font-weight: 700; flex-shrink: 0; display: flex; align-items: center; }

        /* Audit log */
        .audit-log {
            background: #0a0a0a;
            border: 2px solid #333333;
            border-radius: 6px;
            padding: 15px;
            height: 160px;
            overflow-y: auto;
            font-family: 'SF Mono', 'Monaco', 'Inconsolata', monospace;
            font-size: 12px;
            line-height: 1.6;
            display: flex;
            flex-direction: column-reverse;
        }
        .audit-log-entry { color: #888888; padding: 4px 0; border-bottom: 1px solid #1a1a1a; }
        .audit-log-entry:last-child { border-bottom: none; }
        .audit-log-entry .timestamp { color: #555555; margin-right: 10px; }
        .audit-log-entry .event { }
        .audit-log-entry .event-blocked  { color: #FF4422; }
        .audit-log-entry .event-pending  { color: #FFD814; }
        .audit-log-entry .event-approved { color: #00CC44; }
        .audit-log-entry .event-info     { color: #00B4FF; }
        .audit-log-entry .details        { color: #AAAAAA; }

        /* Section divider */
        .section-divider {
            max-width: 1400px;
            margin: 0 auto 20px auto;
            border: none;
            border-top: 1px solid #2a2a2a;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>Vault Policy Governance</h1>
    </div>

    <!-- ================================================================ -->
    <!-- TOP ROW: Sentinel Block (left) + Control Group Gate (right)      -->
    <!-- ================================================================ -->
    <div class="container">
        <!-- Left: Sentinel Policy Block -->
        <div class="panel">
            <h2>Sentinel Policy Block</h2>
            <p style="color:#CCCCCC; font-size:13px; margin-bottom:16px; line-height:1.6;">
                A Sentinel EGP policy is attached to <code style="color:#FFD814">sys/policies/acl/*</code>.
                Any attempt to create a policy containing a root wildcard path
                <code style="color:#FFD814">path "*"</code> is hard-blocked before the write reaches storage.
            </p>
            <label>Policy HCL (root wildcard — blocked by Sentinel)</label>
            <textarea id="sentinelHcl" readonly>path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}</textarea>
            <button id="btnSentinel" onclick="createSentinelPolicy()" style="margin-top:14px;">
                Create Policy
            </button>
            <div id="sentinelResult" class="result-box"></div>
        </div>

        <!-- Right: Control Group Gate -->
        <div class="panel">
            <h2>Control Group Policy Gate</h2>
            <p style="color:#CCCCCC; font-size:13px; margin-bottom:16px; line-height:1.6;">
                The policy-admin role can write policies under
                <code style="color:#FFD814">master-demo-policy-*</code>, but every write
                is gated by a Control Group requiring 1 approval from the
                <code style="color:#FFD814">policy-approvers</code> group.
            </p>
            <label>Policy HCL (partial wildcard — gated by Control Group)</label>
            <textarea id="cgHcl" readonly>path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}</textarea>
            <button id="btnCG" onclick="createCGPolicy()" style="margin-top:14px;">
                Create Policy
            </button>
            <div id="cgResult" class="result-box"></div>
        </div>
    </div>

    <!-- ================================================================ -->
    <!-- CG FLOW + AUDIT LOG ROW                                          -->
    <!-- ================================================================ -->
    <hr class="section-divider">
    <div class="panel full-width" style="max-width:1400px; margin:0 auto 20px auto; padding:20px;">
        <h2 style="margin-bottom:15px;">Control Groups Flow</h2>

        <!-- Policy CG flow -->
        <div style="margin-bottom:12px;">
            <div style="font-size:12px; color:#FFD814; font-weight:600; text-transform:uppercase; letter-spacing:0.05em; margin-bottom:8px;">Policy Write</div>
            <div class="flow-diagram">
                <div class="flow-step" id="pol-flow-step-1">
                    <div class="flow-number">1</div>
                    <div class="flow-label">Request</div>
                    <div class="flow-desc">Policy write attempt</div>
                </div>
                <div class="flow-arrow">&#8594;</div>
                <div class="flow-step" id="pol-flow-step-2">
                    <div class="flow-number">2</div>
                    <div class="flow-label">Control Group</div>
                    <div class="flow-desc">Write gated</div>
                </div>
                <div class="flow-arrow">&#8594;</div>
                <div class="flow-step" id="pol-flow-step-3">
                    <div class="flow-number">3</div>
                    <div class="flow-label">Approve</div>
                    <div class="flow-desc">Admin approves</div>
                </div>
                <div class="flow-arrow">&#8594;</div>
                <div class="flow-step" id="pol-flow-step-4">
                    <div class="flow-number">4</div>
                    <div class="flow-label">Written</div>
                    <div class="flow-desc">Policy saved</div>
                </div>
            </div>
        </div>

        <!-- Secret CG flow -->
        <div style="margin-bottom:12px;">
            <div style="font-size:12px; color:#00B4FF; font-weight:600; text-transform:uppercase; letter-spacing:0.05em; margin-bottom:8px;">Secret Read</div>
            <div class="flow-diagram">
                <div class="flow-step" id="flow-step-1">
                    <div class="flow-number">1</div>
                    <div class="flow-label">Request</div>
                    <div class="flow-desc">User requests secret</div>
                </div>
                <div class="flow-arrow">&#8594;</div>
                <div class="flow-step" id="flow-step-2">
                    <div class="flow-number">2</div>
                    <div class="flow-label">Control Group</div>
                    <div class="flow-desc">Accessor returned</div>
                </div>
                <div class="flow-arrow">&#8594;</div>
                <div class="flow-step" id="flow-step-3">
                    <div class="flow-number">3</div>
                    <div class="flow-label">Approve</div>
                    <div class="flow-desc">Required approvals</div>
                </div>
                <div class="flow-arrow">&#8594;</div>
                <div class="flow-step" id="flow-step-4">
                    <div class="flow-number">4</div>
                    <div class="flow-label">Unwrap</div>
                    <div class="flow-desc">Access granted</div>
                </div>
            </div>
        </div>

        <!-- Audit Log -->
        <div>
            <div style="font-size:12px; color:#888888; font-weight:600; text-transform:uppercase; letter-spacing:0.05em; margin-bottom:8px;">Audit Log</div>
            <div class="audit-log" id="auditLog">
                <div class="audit-log-entry">
                    <span class="timestamp">[--:--:--]</span>
                    <span class="event event-info">System Ready</span>
                    <span class="details">- Vault Policy Governance demo loaded</span>
                </div>
            </div>
        </div>
    </div>

    <!-- User Panel + My Requests -->
    <div class="panel full-width" style="max-width:1400px; margin:0 auto 20px auto; padding:25px;">
        <h2>User Panel</h2>
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:20px; align-items:start;">
            <div>
                <label>Request Secret Access</label>
                <select id="secretPath">
                    <option value="">Select a secret...</option>
                    <option value="secret/data/dev/api-key">dev/api-key (1/2 approval)</option>
                    <option value="secret/data/dev/database">dev/database (1/2 approval)</option>
                    <option value="secret/data/prod/db-password">prod/db-password (2/2 approvals)</option>
                    <option value="secret/data/prod/encryption-key">prod/encryption-key (2/2 approvals)</option>
                </select>
                <button onclick="requestSecret()" style="margin-top:8px;">Request Access</button>
            </div>
            <div>
                <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:15px;">
                    <h3 style="color:#FFD814; font-size:16px; margin:0;">My Requests</h3>
                    <button id="clearSecretBtn" class="btn-clear" onclick="clearAllRequests()" disabled>Clear</button>
                </div>
                <div id="userRequests" class="scrollable"></div>
            </div>
        </div>
    </div>

    <!-- ================================================================ -->
    <!-- UNIFIED ADMIN PANEL                                              -->
    <!-- ================================================================ -->
    <div class="panel full-width" style="max-width:1400px; margin:0 auto 20px auto; padding:25px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:20px;">
            <h2 style="margin-bottom:0; border-bottom:none; padding-bottom:0;">Admin Panel</h2>
            <div class="role-switcher" style="margin-bottom:0;">
                <button class="role-btn active" onclick="switchRole('ops')"      id="opsBtn">Ops Team</button>
                <button class="role-btn"        onclick="switchRole('security')" id="securityBtn">Security Team</button>
            </div>
        </div>
        <p style="color:#888888; font-size:13px; margin-bottom:20px;">
            Pending approval requests from both the <span style="color:#FFD814">Policy Write</span>
            and <span style="color:#00B4FF">Secret Read</span> flows appear here.
        </p>
        <div id="pendingRequests" class="scrollable"></div>
    </div>

    <script>
        let currentRole = 'ops';
        let pendingCGPolicyId = null;   // request_id of the in-flight CG policy request

        // ---------------------------------------------------------------
        // Role switcher
        // ---------------------------------------------------------------
        function switchRole(role) {
            currentRole = role;
            document.getElementById('opsBtn').classList.toggle('active', role === 'ops');
            document.getElementById('securityBtn').classList.toggle('active', role === 'security');
            loadPendingRequests();
        }

        // ---------------------------------------------------------------
        // Audit log
        // ---------------------------------------------------------------
        function addAuditLog(event, details, level) {
            const auditLog = document.getElementById('auditLog');
            const ts   = new Date().toLocaleTimeString();
            const entry = document.createElement('div');
            entry.className = 'audit-log-entry';
            const levelClass = {
                'blocked':  'event-blocked',
                'pending':  'event-pending',
                'approved': 'event-approved',
                'info':     'event-info',
            }[level] || 'event-info';
            entry.innerHTML = `
                <span class="timestamp">[${ts}]</span>
                <span class="event ${levelClass}">${event}</span>
                <span class="details"> - ${details}</span>
            `;
            auditLog.insertBefore(entry, auditLog.firstChild);
            while (auditLog.children.length > 20) {
                auditLog.removeChild(auditLog.lastChild);
            }
        }

        function clearAuditLog() {
            const auditLog = document.getElementById('auditLog');
            auditLog.innerHTML = '<div class="audit-log-entry"><span class="timestamp">[--:--:--]</span><span class="event event-info">Log cleared</span></div>';
        }

        // ---------------------------------------------------------------
        // Flow diagram
        // ---------------------------------------------------------------
        function updateFlowDiagram(step) {
            for (let i = 1; i <= 4; i++) {
                const el = document.getElementById('flow-step-' + i);
                el.classList.remove('active', 'completed');
            }
            for (let i = 1; i < step; i++) {
                document.getElementById('flow-step-' + i).classList.add('completed');
            }
            if (step >= 1 && step <= 4) {
                document.getElementById('flow-step-' + step).classList.add('active');
            }
        }

        function updatePolicyFlowDiagram(step) {
            for (let i = 1; i <= 4; i++) {
                const el = document.getElementById('pol-flow-step-' + i);
                el.classList.remove('active', 'completed');
            }
            for (let i = 1; i < step; i++) {
                document.getElementById('pol-flow-step-' + i).classList.add('completed');
            }
            if (step >= 1 && step <= 4) {
                document.getElementById('pol-flow-step-' + step).classList.add('active');
            }
        }

        // ---------------------------------------------------------------
        // Policy demo — Sentinel block
        // ---------------------------------------------------------------
        async function createSentinelPolicy() {
            const btn    = document.getElementById('btnSentinel');
            const result = document.getElementById('sentinelResult');
            const hcl    = document.getElementById('sentinelHcl').value;

            btn.disabled = true;
            result.style.display = 'none';

            try {
                const resp = await fetch('/api/create_policy', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({name: 'master-demo-policy-demo-sentinel-test', policy: hcl}),
                });
                const data = await resp.json();

                if (data.blocked) {
                    result.className = 'result-box result-blocked';
                    result.textContent = 'DENIED by Sentinel: ' + data.reason;
                    result.style.display = 'block';
                    addAuditLog('Sentinel Block', 'Root wildcard policy rejected: ' + data.reason, 'blocked');
                } else if (data.pending) {
                    result.className = 'result-box result-pending';
                    result.textContent = 'Pending approval (unexpected — root wildcard should be blocked by Sentinel)';
                    result.style.display = 'block';
                    addAuditLog('Unexpected CG', 'Root wildcard was not blocked by Sentinel', 'pending');
                } else if (data.success) {
                    result.className = 'result-box result-success';
                    result.textContent = data.message || 'Policy created (unexpected — should have been blocked)';
                    result.style.display = 'block';
                    addAuditLog('Policy Created', 'Root wildcard unexpectedly succeeded', 'approved');
                } else if (data.error) {
                    result.className = 'result-box result-blocked';
                    result.textContent = 'Error: ' + data.error;
                    result.style.display = 'block';
                    addAuditLog('Error', data.error, 'blocked');
                }
            } catch(e) {
                result.className = 'result-box result-blocked';
                result.textContent = 'Network error: ' + e.message;
                result.style.display = 'block';
            } finally {
                btn.disabled = false;
            }
        }

        // ---------------------------------------------------------------
        // Policy demo — Control Group gate
        // ---------------------------------------------------------------
        async function createCGPolicy() {
            const btn    = document.getElementById('btnCG');
            const result = document.getElementById('cgResult');
            const hcl    = document.getElementById('cgHcl').value;

            btn.disabled = true;
            btn.className = 'btn-waiting';
            btn.textContent = 'Waiting for approval...';
            result.style.display = 'none';

            try {
                const resp = await fetch('/api/create_policy', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({name: 'master-demo-policy-demo-cg-test', policy: hcl}),
                });
                const data = await resp.json();

                if (data.pending) {
                    pendingCGPolicyId = data.request_id;
                    updatePolicyFlowDiagram(1);
                    setTimeout(() => {
                        updatePolicyFlowDiagram(2);
                        addAuditLog('CG Token Issued', 'Policy write gated, request: ' + data.request_id, 'pending');
                        setTimeout(() => updatePolicyFlowDiagram(3), 500);
                    }, 500);
                    result.className = 'result-box result-pending';
                    result.textContent = 'Control Group triggered — waiting for admin approval (request: ' + data.request_id + ')';
                    result.style.display = 'block';
                    addAuditLog('CG Policy Request', 'Policy write gated, awaiting approval: ' + data.request_id, 'pending');
                    loadPendingRequests();
                    // Button stays frozen — polling will detect completion
                } else if (data.blocked) {
                    resetCGButton();
                    result.className = 'result-box result-blocked';
                    result.textContent = 'DENIED: ' + data.reason;
                    result.style.display = 'block';
                    addAuditLog('Policy Blocked', data.reason, 'blocked');
                } else if (data.success) {
                    resetCGButton();
                    result.className = 'result-box result-success';
                    result.textContent = data.message || 'Policy created successfully';
                    result.style.display = 'block';
                    addAuditLog('Policy Created', 'Policy write succeeded directly', 'approved');
                } else if (data.error) {
                    resetCGButton();
                    result.className = 'result-box result-blocked';
                    result.textContent = 'Error: ' + data.error;
                    result.style.display = 'block';
                    addAuditLog('Error', data.error, 'blocked');
                }
            } catch(e) {
                resetCGButton();
                result.className = 'result-box result-blocked';
                result.textContent = 'Network error: ' + e.message;
                result.style.display = 'block';
            }
        }

        function resetCGButton() {
            const btn = document.getElementById('btnCG');
            btn.disabled  = false;
            btn.className = '';
            btn.textContent = 'Create Policy';
            pendingCGPolicyId = null;
            updatePolicyFlowDiagram(0);
        }

        // ---------------------------------------------------------------
        // Secret request
        // ---------------------------------------------------------------
        async function requestSecret() {
            const path = document.getElementById('secretPath').value;
            if (!path) return;

            try {
                const resp = await fetch('/api/request_secret', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({path}),
                });
                const data = await resp.json();

                if (data.success) {
                    updateFlowDiagram(1);
                    addAuditLog('Secret Request', 'Path: ' + path, 'pending');
                    setTimeout(() => {
                        updateFlowDiagram(2);
                        addAuditLog('CG Token Issued', 'Request ID: ' + data.request_id, 'pending');
                        setTimeout(() => {
                            updateFlowDiagram(3);
                            addAuditLog('Awaiting Approvals', 'Pending authorization', 'pending');
                        }, 500);
                    }, 500);
                    loadUserRequests();
                    loadPendingRequests();
                } else if (data.error) {
                    addAuditLog('Request Error', data.error, 'blocked');
                }
            } catch(e) {
                console.error('Error:', e);
            }
        }

        // ---------------------------------------------------------------
        // Approve / Deny / Unwrap
        // ---------------------------------------------------------------
        async function approveRequest(requestId, reqType) {
            const role = reqType === 'policy' ? 'approver' : currentRole;
            try {
                const resp = await fetch('/api/approve', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({request_id: requestId, role}),
                });
                const data = await resp.json();

                if (data.success) {
                    addAuditLog('Approved', (reqType === 'policy' ? 'Policy write' : 'Secret read') + ' approved by ' + role, 'approved');
                    if (data.status === 'approved') {
                        if (reqType === 'secret') {
                            updateFlowDiagram(4);
                            addAuditLog('All Approvals Met', 'Ready to unwrap secret', 'approved');
                        }
                        // For policy type: trigger the unwrap automatically
                        if (reqType === 'policy') {
                            await completePolicyWrite(requestId);
                        }
                    }
                    loadUserRequests();
                    loadPendingRequests();
                } else if (data.error) {
                    addAuditLog('Approve Error', data.error, 'blocked');
                }
            } catch(e) {
                console.error('Error:', e);
            }
        }

        async function completePolicyWrite(requestId) {
            try {
                const resp = await fetch('/api/unwrap', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({request_id: requestId}),
                });
                const data = await resp.json();

                const result = document.getElementById('cgResult');
                if (data.success) {
                    updatePolicyFlowDiagram(4);
                    setTimeout(() => resetCGButton(), 3000);
                    result.className = 'result-box result-success';
                    result.textContent = data.message || 'Policy written successfully after approval';
                    result.style.display = 'block';
                    addAuditLog('Policy Written', 'Policy write completed after CG approval', 'approved');
                } else if (data.error) {
                    resetCGButton();
                    result.className = 'result-box result-blocked';
                    result.textContent = 'Write failed after approval: ' + data.error;
                    result.style.display = 'block';
                    addAuditLog('Policy Write Failed', data.error, 'blocked');
                }
            } catch(e) {
                console.error('Error completing policy write:', e);
            }
        }

        async function denyRequest(requestId, reqType) {
            const role = reqType === 'policy' ? 'approver' : currentRole;
            try {
                const resp = await fetch('/api/deny', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({request_id: requestId, role}),
                });
                const data = await resp.json();

                if (data.success) {
                    addAuditLog('Denied', (reqType === 'policy' ? 'Policy write' : 'Secret read') + ' denied by ' + role, 'blocked');
                    if (reqType === 'policy') {
                        const result = document.getElementById('cgResult');
                        resetCGButton();
                        result.className = 'result-box result-blocked';
                        result.textContent = 'Policy write denied by admin';
                        result.style.display = 'block';
                    } else {
                        updateFlowDiagram(1);
                    }
                    loadUserRequests();
                    loadPendingRequests();
                }
            } catch(e) {
                console.error('Error:', e);
            }
        }

        async function unwrapSecret(requestId) {
            try {
                const resp = await fetch('/api/unwrap', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({request_id: requestId}),
                });
                const data = await resp.json();
                if (data.success) {
                    addAuditLog('Secret Unwrapped', 'Access granted for request ' + requestId, 'approved');
                    updateFlowDiagram(0);
                    loadUserRequests();
                } else if (data.error) {
                    addAuditLog('Unwrap Error', data.error, 'blocked');
                }
            } catch(e) {
                console.error('Error:', e);
            }
        }

        async function clearAllRequests() {
            try {
                await fetch('/api/clear_requests', {method: 'POST'});
                await fetch('/api/clear_policy_requests', {method: 'POST'});
                addAuditLog('Requests Cleared', 'All requests removed', 'info');
                updateFlowDiagram(0);
                resetCGButton();
                document.getElementById('cgResult').style.display = 'none';
                loadUserRequests();
                loadPendingRequests();
            } catch(e) {
                console.error('Error:', e);
            }
        }

        // ---------------------------------------------------------------
        // Load functions
        // ---------------------------------------------------------------
        async function loadUserRequests() {
            try {
                const resp = await fetch('/api/user_requests');
                const data = await resp.json();
                const container = document.getElementById('userRequests');
                const clearBtn  = document.getElementById('clearSecretBtn');

                clearBtn.disabled = data.requests.length === 0;

                if (data.requests.length === 0) {
                    container.innerHTML = '<div class="empty-state">No secret requests yet</div>';
                    return;
                }

                container.innerHTML = data.requests.map(req => `
                    <div class="request-card">
                        <div class="request-header">
                            <span class="request-id">${req.id}</span>
                            <div>
                                <span class="type-badge type-secret">Secret Read</span>
                                <span class="status-badge status-${req.status}">${req.status.toUpperCase()}</span>
                            </div>
                        </div>
                        <div class="request-path">${req.path}</div>
                        <div class="approval-status">
                            <div class="approval-item">
                                <span>Ops:</span>
                                <span class="${req.approvals.ops ? 'approval-check' : 'approval-pending'}">${req.approvals.ops ? '&#10003;' : '&#9203;'}</span>
                            </div>
                            <div class="approval-item">
                                <span>Security:</span>
                                <span class="${req.approvals.security ? 'approval-check' : 'approval-pending'}">${req.approvals.security ? '&#10003;' : '&#9203;'}</span>
                            </div>
                            <div style="margin-left:auto; color:#888888;">${req.approval_type}</div>
                        </div>
                        ${req.status === 'approved' ? `<button onclick="unwrapSecret('${req.id}')">Unwrap Secret</button>` : ''}
                        ${req.secret_data ? `<div class="secret-display">${JSON.stringify(req.secret_data, null, 2)}</div>` : ''}
                    </div>
                `).join('');
            } catch(e) {
                console.error('Error loading user requests:', e);
            }
        }

        async function loadPendingRequests() {
            try {
                const resp = await fetch('/api/pending_requests');
                const data = await resp.json();
                const container = document.getElementById('pendingRequests');

                // Check if our pending CG policy request has been resolved
                if (pendingCGPolicyId) {
                    const still = data.requests.find(r => r.id === pendingCGPolicyId);
                    if (!still) {
                        // It was resolved (approved/denied) — handled by completePolicyWrite or deny
                        // If it disappeared without our explicit action, just reset the button
                        const cgResult = document.getElementById('cgResult');
                        if (cgResult.style.display === 'none') {
                            resetCGButton();
                        }
                    }
                }

                if (data.requests.length === 0) {
                    container.innerHTML = '<div class="empty-state">No pending requests</div>';
                    return;
                }

                container.innerHTML = data.requests.map(req => {
                    const isPolicy  = req.type === 'policy';
                    const typeLabel = isPolicy ? 'Policy Write' : 'Secret Read';
                    const typeClass = isPolicy ? 'type-policy' : 'type-secret';
                    const approverRole = isPolicy ? 'approver' : currentRole;

                    let approvalHtml = '';
                    if (isPolicy) {
                        const checked = req.approvals && req.approvals.approver;
                        approvalHtml = `<div class="approval-status">
                            <div class="approval-item">
                                <span>Approver:</span>
                                <span class="${checked ? 'approval-check' : 'approval-pending'}">${checked ? '&#10003;' : '&#9203;'}</span>
                            </div>
                            <div style="margin-left:auto; color:#888888;">${req.approval_type}</div>
                        </div>`;
                    } else {
                        const opsChecked = req.approvals && req.approvals.ops;
                        const secChecked = req.approvals && req.approvals.security;
                        approvalHtml = `<div class="approval-status">
                            <div class="approval-item">
                                <span>Ops:</span>
                                <span class="${opsChecked ? 'approval-check' : 'approval-pending'}">${opsChecked ? '&#10003;' : '&#9203;'}</span>
                            </div>
                            <div class="approval-item">
                                <span>Security:</span>
                                <span class="${secChecked ? 'approval-check' : 'approval-pending'}">${secChecked ? '&#10003;' : '&#9203;'}</span>
                            </div>
                            <div style="margin-left:auto; color:#888888;">${req.approval_type}</div>
                        </div>`;
                    }

                    const pathLine = isPolicy
                        ? `<div class="request-path">Policy: ${req.policy_name || 'unknown'}</div>`
                        : `<div class="request-path">${req.path}</div>`;

                    const alreadyApproved = isPolicy
                        ? (req.approvals && req.approvals.approver)
                        : (req.approvals && req.approvals[currentRole]);

                    return `
                        <div class="request-card">
                            <div class="request-header">
                                <span class="request-id">${req.id}</span>
                                <div>
                                    <span class="type-badge ${typeClass}">${typeLabel}</span>
                                    <span class="status-badge status-${req.status}">${req.status.toUpperCase()}</span>
                                </div>
                            </div>
                            ${pathLine}
                            <div style="font-size:12px; color:#888888; margin:4px 0;">Requested by: ${req.user}</div>
                            ${approvalHtml}
                            ${alreadyApproved ? `
                                <div style="text-align:center; color:#00CC44; margin-top:10px; font-weight:600; font-size:13px;">Already approved</div>
                            ` : `
                                <div class="button-group">
                                    <button class="btn-approve" onclick="approveRequest('${req.id}', '${req.type}')">Approve</button>
                                    <button class="btn-deny"    onclick="denyRequest('${req.id}', '${req.type}')">Deny</button>
                                </div>
                            `}
                        </div>
                    `;
                }).join('');
            } catch(e) {
                console.error('Error loading pending requests:', e);
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
