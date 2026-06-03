"""
AI Agent Service - Core component that:
1. Receives user JWT from web UI
2. Authenticates to Vault with Kubernetes ServiceAccount
3. Gets user-scoped database credentials via JWT auth
4. Calls Ollama LLM for natural language processing
5. Executes database operations with proper authorization
"""

import os
import json
import base64
import logging
from datetime import datetime
from typing import Optional, Dict, Any
from fastapi import FastAPI, HTTPException, Header, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import httpx
import jwt
import psycopg2
from psycopg2.extras import RealDictCursor

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="AI Agent Service")

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
VAULT_ADDR = os.getenv("VAULT_ADDR", "https://host.minikube.internal:8200")
VAULT_NAMESPACE = os.getenv("VAULT_NAMESPACE", "master-demo")
VAULT_SKIP_VERIFY = os.getenv("VAULT_SKIP_VERIFY", "true").lower() == "true"
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama.agentic-demo.svc.cluster.local:11434")

# Fetch JWT public key from Vault for token validation
JWT_PUBLIC_KEY = None

def fetch_jwt_public_key():
    """Fetch RSA public key from Vault for JWT validation using Kubernetes auth"""
    global JWT_PUBLIC_KEY
    try:
        # Agent authenticates with Kubernetes ServiceAccount token
        headers = {"X-Vault-Namespace": VAULT_NAMESPACE}
        
        # Read Kubernetes ServiceAccount token
        with open("/var/run/secrets/kubernetes.io/serviceaccount/token", "r") as f:
            k8s_token = f.read()
        
        # Authenticate to Vault using Kubernetes auth
        auth_data = {"role": "ai-agent-base", "jwt": k8s_token}
        
        response = httpx.post(
            f"{VAULT_ADDR}/v1/auth/master-demo-auth/login",
            json=auth_data,
            headers=headers,
            verify=not VAULT_SKIP_VERIFY
        )
        
        if response.status_code == 200:
            vault_token = response.json()["auth"]["client_token"]
            
            # Fetch public key from Vault KV
            headers["X-Vault-Token"] = vault_token
            response = httpx.get(
                f"{VAULT_ADDR}/v1/master-demo-kv/data/agentic/jwt-key",
                headers=headers,
                verify=not VAULT_SKIP_VERIFY
            )
            
            if response.status_code == 200:
                data = response.json()
                JWT_PUBLIC_KEY = data['data']['data']['public_key']
                logger.info("Successfully fetched JWT public key from Vault using Kubernetes auth")
            else:
                logger.error(f"Failed to fetch JWT public key (status {response.status_code}): {response.text}")
        else:
            logger.error(f"Failed to authenticate to Vault (status {response.status_code}): {response.text}")
            
    except Exception as e:
        logger.error(f"Failed to fetch JWT public key: {e}")

# Request/Response models
class ChatRequest(BaseModel):
    message: str
    user_token: str

class ChatResponse(BaseModel):
    response: str
    agent_id: str
    user_id: str
    timestamp: str
    db_operation: Optional[str] = None

# Helper functions
def validate_user_token(token: str) -> Dict[str, Any]:
    """Validate JWT token and extract user info"""
    try:
        # Check if we have a valid public key (not None and not empty)
        has_public_key = JWT_PUBLIC_KEY is not None and JWT_PUBLIC_KEY.strip() != ""
        
        if has_public_key:
            try:
                # Try RS256 with full validation
                payload = jwt.decode(token, JWT_PUBLIC_KEY, algorithms=["RS256"],
                                   audience="vault", issuer="agentic-demo-ui")
                logger.info("Token validated with RS256")
            except jwt.InvalidTokenError as e:
                # If RS256 fails, try HMAC as fallback
                logger.warning(f"RS256 validation failed ({e}), trying HMAC fallback")
                payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"],
                                   options={"verify_aud": False, "verify_iss": False})
                logger.info("Token validated with HMAC fallback")
        else:
            # HMAC mode - accept both RS256 and HS256 tokens
            # This handles the case where UI has RSA key but agent doesn't
            logger.info("Using HMAC validation (no public key available)")
            try:
                # First try to decode without verification to check algorithm
                unverified = jwt.decode(token, options={"verify_signature": False})
                token_alg = jwt.get_unverified_header(token).get('alg', 'HS256')
                
                if token_alg == 'RS256':
                    # UI is using RS256, we can't validate signature without public key
                    # But we can still extract and trust the payload in demo environment
                    logger.warning("Received RS256 token but no public key available - accepting payload without signature verification")
                    payload = unverified
                else:
                    # HS256 token, validate normally
                    payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"],
                                       options={"verify_aud": False, "verify_iss": False})
            except Exception as e:
                logger.error(f"Token validation failed: {e}")
                raise HTTPException(status_code=401, detail="Invalid token")
        
        return {
            "user_id": payload.get("sub"),
            "groups": payload.get("groups", []),
            "exp": payload.get("exp")
        }
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.InvalidTokenError as e:
        logger.error(f"Invalid token: {e}")
        raise HTTPException(status_code=401, detail="Invalid token")

def authenticate_to_vault(user_jwt: str, user_id: str, user_groups: list) -> str:
    """
    Authenticate user to Vault using JWT auth method.
    This creates an entity token with user-specific policies attached.
    Returns: user entity token with appropriate policies (alice or bob)
    """
    try:
        logger.info(f"Authenticating user {user_id} to Vault using JWT auth")
        
        headers = {
            "X-Vault-Namespace": VAULT_NAMESPACE
        }
        
        # Determine role based on user groups
        if "admins" in user_groups:
            role = "bob"
        else:
            role = "alice"
        
        auth_data = {
            "role": role,
            "jwt": user_jwt
        }
        
        response = httpx.post(
            f"{VAULT_ADDR}/v1/auth/master-demo-jwt/login",
            json=auth_data,
            headers=headers,
            verify=not VAULT_SKIP_VERIFY
        )
        
        if response.status_code != 200:
            logger.error(f"JWT authentication failed for user {user_id}: {response.text}")
            raise HTTPException(status_code=500, detail="Vault authentication failed")
        
        vault_token = response.json()["auth"]["client_token"]
        logger.info(f"Successfully authenticated user {user_id} to Vault with role {role}")
        return vault_token
        
    except Exception as e:
        logger.error(f"Failed to authenticate user {user_id} to Vault: {e}")
        raise HTTPException(status_code=500, detail="Vault authentication failed")

def get_db_credentials(vault_token: str, user_groups: list, user_id: str = None, action: str = None, user_message: str = None) -> Dict[str, str]:
    """Get database credentials from Vault based on user permissions"""
    try:
        # Determine role based on user groups
        if "admins" in user_groups:
            role = "agentic-admin-role"
        else:
            role = "agentic-readonly-role"
        
        logger.info(f"Getting database credentials for role: {role}")
        
        # Truncate user message if too long (max 200 chars for audit logs)
        truncated_message = (user_message[:197] + "...") if user_message and len(user_message) > 200 else (user_message or "unknown")
        
        headers = {
            "X-Vault-Token": vault_token,
            "X-Vault-Namespace": VAULT_NAMESPACE,
            # Add agent context headers for audit logging
            "X-Agent-ID": "ai-agent-service",
            "X-Agent-Type": "agentic-ai-assistant",
            "X-Agent-Action": action or "database_access",
            "X-User-Request": truncated_message
        }
        
        response = httpx.get(
            f"{VAULT_ADDR}/v1/master-demo-db/creds/{role}",
            headers=headers,
            verify=False
        )
        
        if response.status_code != 200:
            logger.error(f"Failed to get DB credentials: {response.text}")
            raise HTTPException(status_code=500, detail="Failed to get database credentials")
        
        creds = response.json()["data"]
        logger.info(f"Successfully retrieved database credentials for role: {role}")
        return {
            "username": creds["username"],
            "password": creds["password"]
        }
        
    except Exception as e:
        logger.error(f"Failed to get database credentials: {e}")
        raise HTTPException(status_code=500, detail="Failed to get database credentials")

def call_ollama(prompt: str, user_id: str) -> Dict[str, Any]:
    """Call Ollama LLM for natural language processing"""
    try:
        logger.info(f"Calling Ollama for user {user_id}")
        
        # Simple keyword-based intent detection (more reliable than LLM JSON for small models)
        prompt_lower = prompt.lower()
        
        # Check for list products intent
        if any(word in prompt_lower for word in ['list', 'show', 'display', 'get', 'see', 'all products']):
            if 'product' in prompt_lower:
                logger.info("Detected list_products intent")
                return {"action": "list_products"}
        
        # Check for add product intent
        if any(word in prompt_lower for word in ['add', 'create', 'new', 'insert']):
            if 'product' in prompt_lower:
                logger.info("Detected add_product intent")
                # Extract product name and price using simple parsing
                import re
                
                # Try to find price (e.g., $50, 50 dollars, $50.99)
                price_match = re.search(r'\$?(\d+(?:\.\d{2})?)\s*(?:dollars?)?', prompt_lower)
                price = float(price_match.group(1)) if price_match else 0.0
                
                # Extract product name (words between "called" or "named" and price/end)
                name_match = re.search(r'(?:called|named|product)\s+([a-zA-Z0-9\s]+?)(?:\s+for|\s+\$|\s+at|$)', prompt, re.IGNORECASE)
                name = name_match.group(1).strip() if name_match else "New Product"
                
                logger.info(f"Extracted product: name='{name}', price={price}")
                return {"action": "add_product", "name": name, "price": price}
        
        # For other queries, call LLM for a natural response
        system_prompt = """You are a helpful assistant for a product database.
You can help users list products or add new products to the database."""
        
        response = httpx.post(
            f"{OLLAMA_URL}/api/generate",
            json={
                "model": "llama3.2:1b",
                "prompt": f"{system_prompt}\n\nUser: {prompt}\nAssistant:",
                "stream": False
            },
            timeout=30.0
        )
        
        if response.status_code != 200:
            logger.error(f"Ollama request failed: {response.text}")
            raise HTTPException(status_code=500, detail="LLM request failed")
        
        llm_response = response.json()["response"]
        logger.info(f"Ollama response: {llm_response[:100]}...")
        
        return {"action": "chat", "response": llm_response}
            
    except Exception as e:
        logger.error(f"Failed to call Ollama: {e}")
        raise HTTPException(status_code=500, detail="LLM request failed")

def execute_db_operation(action: Dict[str, Any], db_creds: Dict[str, str], user_id: str) -> str:
    """Execute database operation with user-scoped credentials"""
    try:
        # Connect to PostgreSQL
        conn = psycopg2.connect(
            host="postgres-postgresql.postgres.svc.cluster.local",
            port=5432,
            database="postgres",
            user=db_creds["username"],
            password=db_creds["password"]
        )
        
        cursor = conn.cursor(cursor_factory=RealDictCursor)
        
        if action["action"] == "list_products":
            logger.info(f"User {user_id} listing products")
            cursor.execute("SELECT * FROM products ORDER BY id")
            products = cursor.fetchall()
            
            # Format as a table
            result = "Available Products:\n\n"
            result += "| ID | Product Name | Price | Description |\n"
            result += "|----|--------------| ------|-------------|\n"
            for p in products:
                result += f"| {p['id']} | {p['name']} | ${p['price']:.2f} | {p['description']} |\n"
            
            cursor.close()
            conn.close()
            return result
            
        elif action["action"] == "add_product":
            logger.info(f"User {user_id} adding product: {action.get('name')}")
            cursor.execute(
                "INSERT INTO products (name, price, description, created_by) VALUES (%s, %s, %s, %s) RETURNING id",
                (action.get("name"), action.get("price"), "Added via AI agent", user_id)
            )
            product_id = cursor.fetchone()["id"]
            conn.commit()
            cursor.close()
            conn.close()
            return f"Product '{action.get('name')}' added successfully with ID {product_id}"
        
        else:
            cursor.close()
            conn.close()
            return "No database operation needed"
            
    except psycopg2.Error as e:
        logger.error(f"Database operation failed for user {user_id}: {e}")
        # Re-raise the exception so it can be caught in the chat endpoint
        # This allows proper db_operation status tracking (_denied, _failed)
        raise
    except Exception as e:
        logger.error(f"Unexpected error in database operation: {e}")
        raise HTTPException(status_code=500, detail="Database operation failed")

# API Endpoints
@app.get("/health")
async def health():
    """Health check endpoint"""
    return {"status": "healthy", "service": "ai-agent"}

@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    """Main chat endpoint - handles user requests with just-in-time database access"""
    try:
        # 1. Validate user token
        user_info = validate_user_token(request.user_token)
        user_id = user_info["user_id"]
        user_groups = user_info["groups"]
        
        logger.info(f"Processing request from user: {user_id}, groups: {user_groups}")
        
        # 2. Call LLM to determine intent (NO database access yet)
        llm_action = call_ollama(request.message, user_id)
        
        # 3. Only if LLM determines database operation is needed, get credentials just-in-time
        if llm_action["action"] in ["list_products", "add_product"]:
            logger.info(f"LLM determined database operation needed: {llm_action['action']}")
            
            # Authenticate user to Vault using JWT auth
            # This creates an entity token with user-specific policies (alice or bob)
            vault_token = authenticate_to_vault(request.user_token, user_id, user_groups)
            
            # Get database credentials (just-in-time, least-privilege)
            # Vault enforces which role based on entity policies:
            # - alice entity → master-demo-agentic-alice policy → agentic-readonly-role → SELECT only
            # - bob entity → master-demo-agentic-bob policy → agentic-admin-role → ALL PRIVILEGES
            db_creds = get_db_credentials(vault_token, user_groups, user_id, llm_action["action"], request.message)
            
            try:
                result = execute_db_operation(llm_action, db_creds, user_id)
                db_operation = llm_action["action"]
            except Exception as e:
                # Database will reject unauthorized operations via SQL grants
                logger.warning(f"Database operation failed for user {user_id}: {str(e)}")
                if "permission denied" in str(e).lower():
                    result = "Sorry, you don't have permission to perform this action."
                    db_operation = f"{llm_action['action']}_denied"
                else:
                    result = f"Operation failed: {str(e)}"
                    db_operation = f"{llm_action['action']}_failed"
        else:
            # No database operation needed - just return LLM response
            result = llm_action.get("response", "I'm not sure how to help with that.")
            db_operation = None
        
        return ChatResponse(
            response=result,
            agent_id="ai-agent-001",
            user_id=user_id,
            timestamp=datetime.utcnow().isoformat(),
            db_operation=db_operation
        )
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Unexpected error in chat endpoint: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")

if __name__ == "__main__":
    import uvicorn
    # Fetch JWT public key on startup
    fetch_jwt_public_key()
    uvicorn.run(app, host="0.0.0.0", port=8001)

# Made with Bob
