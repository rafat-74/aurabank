"""Aura Bank — API Gateway :8000"""
import os, time, logging, uuid
from fastapi import FastAPI, Request, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from jose import jwt, JWTError
import httpx
from collections import defaultdict

JWT_SECRET = os.getenv("JWT_SECRET")
if not JWT_SECRET:
    raise RuntimeError("JWT_SECRET env var is required — set it via AWS Secrets Manager")
JWT_ALGO          = "HS256"
AUTH_URL          = os.getenv("AUTH_URL",          "http://auth-service:8001")
ACCOUNTS_URL      = os.getenv("ACCOUNTS_URL",      "http://accounts-service:8002")
TRANSACTIONS_URL  = os.getenv("TRANSACTIONS_URL",  "http://transactions-service:8003")
NOTIFICATIONS_URL = os.getenv("NOTIFICATIONS_URL", "http://notifications-service:8004")

# External n8n chatbot webhook — proxied server-to-server to avoid browser CORS
# restrictions, since the n8n instance is a third-party service we don't control.
N8N_CHAT_WEBHOOK_URL = os.getenv("N8N_CHAT_WEBHOOK_URL", "https://n8ncourse.nourn8n.cfd/webhook/bank")

logging.basicConfig(level=logging.INFO,
  format='{"t":"%(asctime)s","svc":"gateway","msg":"%(message)s"}')
log = logging.getLogger(__name__)

app = FastAPI(title="API Gateway")
_ORIGINS = [o.strip() for o in os.getenv("ALLOWED_ORIGINS", "http://localhost:3000,http://localhost:5173").split(",") if o.strip()]
app.add_middleware(CORSMiddleware,
    allow_origins=_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-Request-ID"])

_rl: dict = defaultdict(list)
def rate_limit(key, limit=60, window=60):
    now = time.time()
    _rl[key] = [t for t in _rl[key] if t > now-window]
    if len(_rl[key]) >= limit:
        raise HTTPException(429,"Too many requests")
    _rl[key].append(now)

def decode_token(request: Request):
    h = request.headers.get("Authorization","")
    if not h.startswith("Bearer "): return None
    try: return jwt.decode(h[7:], JWT_SECRET, algorithms=[JWT_ALGO])
    except JWTError: return None

def require_auth(request: Request):
    p = decode_token(request)
    if not p: raise HTTPException(401,"مطلوب تسجيل الدخول")
    return p

def require_employee(request: Request):
    p = require_auth(request)
    if p.get("role") not in ("teller","supervisor","admin"):
        raise HTTPException(403,"موظفون فقط")
    return p

def require_admin(request: Request):
    p = require_auth(request)
    if p.get("role") != "admin":
        raise HTTPException(403,"مدير النظام فقط")
    return p

def require_admin_or_supervisor(request: Request):
    p = require_auth(request)
    if p.get("role") not in ("admin","supervisor"):
        raise HTTPException(403,"مدراء ومشرفون فقط")
    return p

@app.middleware("http")
async def log_req(request: Request, call_next):
    rid   = uuid.uuid4().hex[:6]
    start = time.time()
    p     = decode_token(request)
    uid   = p.get("sub","anon") if p else "anon"
    log.info(f"{rid} {request.method} {request.url.path} u={uid}")
    resp  = await call_next(request)
    log.info(f"{rid} → {resp.status_code} {round((time.time()-start)*1000)}ms")
    resp.headers["X-Request-ID"] = rid
    return resp

async def proxy(request: Request, base: str, path: str):
    url     = base+path
    headers = {k:v for k,v in request.headers.items() if k.lower() not in ("host","content-length")}
    headers["X-Forwarded-For"] = request.client.host
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            if request.method in ("POST","PUT","PATCH","DELETE"):
                body = await request.body()
                r = await client.request(request.method, url, content=body,
                                          headers=headers, params=dict(request.query_params))
            else:
                r = await client.request(request.method, url, headers=headers,
                                          params=dict(request.query_params))
        try:    content = r.json()
        except: content = {"detail": r.text}
        return JSONResponse(content=content, status_code=r.status_code)
    except httpx.ConnectError:
        raise HTTPException(503,"الخدمة غير متاحة")
    except httpx.TimeoutException:
        raise HTTPException(504,"انتهت مهلة الخادم")

# ── Health ────────────────────────────────────────────────────────────
@app.get("/health")
def health(): return {"status":"ok","service":"api-gateway"}

@app.get("/ready")
async def ready():
    svcs = {"auth":AUTH_URL,"accounts":ACCOUNTS_URL,
            "transactions":TRANSACTIONS_URL,"notifications":NOTIFICATIONS_URL}
    results = {}
    async with httpx.AsyncClient(timeout=3) as client:
        for name,url in svcs.items():
            try:
                r = await client.get(f"{url}/health")
                results[name] = "ok" if r.status_code==200 else "error"
            except: results[name] = "unreachable"
    return {"status":"ready" if all(v=="ok" for v in results.values()) else "degraded",
            "services":results}

# ── PUBLIC ────────────────────────────────────────────────────────────
@app.post("/api/auth/login")
async def login(request: Request):
    ip = request.client.host
    rate_limit(f"login:{ip}", 10, 60)
    return await proxy(request, AUTH_URL, "/auth/login")

@app.post("/api/auth/login-employee")
async def login_emp(request: Request):
    ip = request.client.host
    rate_limit(f"login:{ip}", 10, 60)
    return await proxy(request, AUTH_URL, "/auth/login-employee")

@app.post("/api/auth/register")
async def register(request: Request):
    return await proxy(request, AUTH_URL, "/auth/register")

@app.post("/api/auth/forgot-password")
async def forgot(request: Request):
    return await proxy(request, AUTH_URL, "/auth/forgot-password")

@app.get("/api/transactions/rates")
async def rates(request: Request):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/rates")

# ── CHATBOT (n8n proxy) ────────────────────────────────────────────────
@app.post("/api/bank-chat")
async def bank_chat(request: Request, _=Depends(require_auth)):
    """Proxy لخدمة الشات بوت الخارجية (n8n) — بيتجنب مشكلة CORS
    لأن المتصفح بيكلم نفس الـ origin (api-gateway)، والـ gateway هو اللي
    بيكلم n8n من السيرفر (server-to-server، مفيش قيود CORS هناك)."""
    body = await request.body()
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            r = await client.post(
                N8N_CHAT_WEBHOOK_URL,
                content=body,
                headers={"Content-Type": "application/json"},
            )
        try:
            content = r.json()
        except Exception:
            content = {"detail": r.text}
        return JSONResponse(content=content, status_code=r.status_code)
    except httpx.ConnectError:
        raise HTTPException(503, "خدمة الدردشة غير متاحة حاليًا")
    except httpx.TimeoutException:
        raise HTTPException(504, "انتهت مهلة الاتصال بخدمة الدردشة")

# ── AUTH (protected) ──────────────────────────────────────────────────
@app.post("/api/auth/logout")
async def logout(request: Request, _=Depends(require_auth)):
    return await proxy(request, AUTH_URL, "/auth/logout")

@app.post("/api/auth/change-password")
async def change_pwd(request: Request, _=Depends(require_auth)):
    return await proxy(request, AUTH_URL, "/auth/change-password")

# ── ACCOUNTS (customer) ───────────────────────────────────────────────
@app.get("/api/accounts/me")
async def my_account(request: Request, user=Depends(require_auth)):
    rate_limit(f"u:{user['sub']}")
    return await proxy(request, ACCOUNTS_URL, f"/accounts/user/{user['sub']}")

@app.get("/api/accounts/{account_id}")
async def get_account(request: Request, account_id: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}")

@app.put("/api/accounts/{account_id}")
async def update_account(request: Request, account_id: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}")

@app.get("/api/accounts/{account_id}/cards")
async def cards(request: Request, account_id: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/cards")

@app.post("/api/accounts/{account_id}/cards")
async def issue_card(request: Request, account_id: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/cards")

@app.get("/api/accounts/{account_id}/goals")
async def goals(request: Request, account_id: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/goals")

@app.post("/api/accounts/{account_id}/goals")
async def create_goal(request: Request, account_id: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/goals")

@app.put("/api/accounts/{account_id}/goals/{gid}")
async def update_goal(request: Request, account_id: str, gid: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/goals/{gid}")

@app.delete("/api/accounts/{account_id}/goals/{gid}")
async def delete_goal(request: Request, account_id: str, gid: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/goals/{gid}")

@app.get("/api/accounts/{account_id}/loans")
async def loans(request: Request, account_id: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/loans")

@app.post("/api/accounts/{account_id}/loans")
async def apply_loan(request: Request, account_id: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/loans")


@app.get("/api/teller/loans")
async def list_all_loans_gw(request: Request, _=Depends(require_employee)):
    return await proxy(request, ACCOUNTS_URL, "/accounts/loans")

@app.post("/api/teller/loans/{account_id}")
async def teller_create_loan_gw(request: Request, account_id: str, p=Depends(require_employee)):
    if p.get("role") != "teller":
        raise HTTPException(403,"التيلر فقط يقدر يقدم طلب نيابة عن العميل")
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/loans/teller-request")

@app.put("/api/teller/loans/{loan_id}/cancel")
async def cancel_loan_gw(request: Request, loan_id: str, p=Depends(require_employee)):
    if p.get("role") != "teller":
        raise HTTPException(403,"التيلر فقط يقدر يلغي طلب قرض")
    return await proxy(request, ACCOUNTS_URL, f"/accounts/loans/{loan_id}/cancel")

@app.put("/api/teller/loans/{loan_id}/approve")
async def approve_loan_gw(request: Request, loan_id: str, _=Depends(require_admin_or_supervisor)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/loans/{loan_id}/approve")

@app.put("/api/teller/loans/{loan_id}/reject")
async def reject_loan_gw(request: Request, loan_id: str, _=Depends(require_admin_or_supervisor)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/loans/{loan_id}/reject")

@app.get("/api/accounts/{account_id}/portfolio")
async def portfolio(request: Request, account_id: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/portfolio")

@app.post("/api/accounts/{account_id}/portfolio")
async def buy_stock(request: Request, account_id: str, _=Depends(require_auth)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/portfolio")

# ── TRANSACTIONS (customer) ───────────────────────────────────────────
@app.get("/api/transactions/{account_id}")
async def get_tx(request: Request, account_id: str, _=Depends(require_auth)):
    return await proxy(request, TRANSACTIONS_URL, f"/transactions/{account_id}")

@app.post("/api/transactions/deposit")
async def deposit(request: Request, _=Depends(require_auth)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/deposit")

@app.post("/api/transactions/withdraw")
async def withdraw(request: Request, _=Depends(require_auth)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/withdraw")

@app.post("/api/transactions/transfer")
async def transfer(request: Request, _=Depends(require_auth)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/transfer")

@app.post("/api/transactions/pay-bill")
async def pay_bill(request: Request, _=Depends(require_auth)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/pay-bill")

@app.post("/api/transactions/exchange")
async def exchange(request: Request, _=Depends(require_auth)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/exchange")

# ── NOTIFICATIONS (customer) ──────────────────────────────────────────
@app.get("/api/notifications/{user_id}")
async def notifs(request: Request, user_id: str, _=Depends(require_auth)):
    return await proxy(request, NOTIFICATIONS_URL, f"/notifications/{user_id}")

@app.put("/api/notifications/{user_id}/read/{nid}")
async def mark_read(request: Request, user_id: str, nid: str, _=Depends(require_auth)):
    return await proxy(request, NOTIFICATIONS_URL, f"/notifications/{user_id}/read/{nid}")

@app.put("/api/notifications/{user_id}/read-all")
async def mark_all(request: Request, user_id: str, _=Depends(require_auth)):
    return await proxy(request, NOTIFICATIONS_URL, f"/notifications/{user_id}/read-all")

# ══ TELLER ROUTES (employee only) ════════════════════════════════════
@app.get("/api/teller/accounts")
async def teller_accounts(request: Request, _=Depends(require_employee)):
    return await proxy(request, ACCOUNTS_URL, "/accounts")

@app.post("/api/teller/create-customer")
async def teller_create_customer(request: Request, _=Depends(require_employee)):
    return await proxy(request, AUTH_URL, "/auth/register")

@app.post("/api/teller/accounts/{account_id}/freeze")
async def teller_freeze(request: Request, account_id: str, _=Depends(require_employee)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/freeze")

@app.post("/api/teller/accounts/{account_id}/unfreeze")
async def teller_unfreeze(request: Request, account_id: str, _=Depends(require_employee)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}/unfreeze")

@app.put("/api/teller/accounts/{account_id}")
async def teller_update_account(request: Request, account_id: str, _=Depends(require_employee)):
    return await proxy(request, ACCOUNTS_URL, f"/accounts/{account_id}")

@app.post("/api/teller/deposit")
async def teller_deposit(request: Request, _=Depends(require_employee)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/deposit")

@app.post("/api/teller/withdraw")
async def teller_withdraw(request: Request, _=Depends(require_employee)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/withdraw")

@app.post("/api/teller/transfer")
async def teller_transfer(request: Request, _=Depends(require_employee)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/transfer")

@app.post("/api/teller/pay-bill")
async def teller_pay_bill(request: Request, _=Depends(require_employee)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/pay-bill")

# Teller log - persisted in PostgreSQL
@app.get("/api/teller/teller-log")
async def teller_log(request: Request, _=Depends(require_employee)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/teller-log")

@app.get("/api/teller/teller-log-today")
async def teller_log_today(request: Request, _=Depends(require_employee)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/teller-log-today")

@app.get("/api/teller/weekly-stats")
async def teller_weekly(request: Request, _=Depends(require_employee)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/teller-weekly")

@app.get("/api/teller/transactions/{account_id}")
async def teller_tx(request: Request, account_id: str, _=Depends(require_employee)):
    return await proxy(request, TRANSACTIONS_URL, f"/transactions/{account_id}")

# Audit log - persisted in PostgreSQL (transactions DB)
@app.post("/api/teller/audit-log")
async def teller_add_audit(request: Request, _=Depends(require_employee)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/audit-log")

@app.get("/api/teller/audit-log")
async def teller_get_audit(request: Request, _=Depends(require_employee)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/audit-log")

@app.delete("/api/teller/audit-log")
async def teller_clear_audit(request: Request, _=Depends(require_employee)):
    return await proxy(request, TRANSACTIONS_URL, "/transactions/audit-log")

# ══ ADMIN ROUTES ══════════════════════════════════════════════════════
@app.get("/api/admin/employees")
async def admin_employees(request: Request, _=Depends(require_admin_or_supervisor)):
    return await proxy(request, AUTH_URL, "/internal/employees")

@app.post("/api/admin/employees")
async def admin_create_emp(request: Request, _=Depends(require_admin)):
    return await proxy(request, AUTH_URL, "/internal/employees")

@app.put("/api/admin/employees/{eid}")
async def admin_update_emp(request: Request, eid: str, _=Depends(require_admin)):
    return await proxy(request, AUTH_URL, f"/internal/employees/{eid}")

@app.delete("/api/admin/employees/{eid}")
async def admin_delete_emp(request: Request, eid: str, _=Depends(require_admin)):
    return await proxy(request, AUTH_URL, f"/internal/employees/{eid}")

@app.get("/api/admin/audit-log")
async def admin_audit(request: Request, _=Depends(require_admin)):
    return await proxy(request, AUTH_URL, "/internal/audit-log")

@app.get("/api/admin/all-accounts")
async def admin_all_accounts(request: Request, _=Depends(require_admin_or_supervisor)):
    return await proxy(request, ACCOUNTS_URL, "/accounts")
