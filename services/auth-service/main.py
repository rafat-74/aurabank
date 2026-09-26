"""Aura Bank — Auth Service :8001"""
import os, uuid, datetime, logging, time, random
from psycopg2 import pool
import bcrypt, psycopg2, psycopg2.extras, httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from jose import jwt
from pydantic import BaseModel
from typing import Optional

JWT_SECRET   = os.getenv("JWT_SECRET")
if not JWT_SECRET:
    raise RuntimeError("JWT_SECRET env var is required — set it via AWS Secrets Manager")
JWT_ALGO     = "HS256"
DB_URL = os.getenv("DATABASE_URL")
if not DB_URL:
    raise RuntimeError("DATABASE_URL env var is required — injected by ECS entrypoint from Secrets Manager")
ACCOUNTS_URL = os.getenv("ACCOUNTS_URL", "http://accounts-service:8002")

logging.basicConfig(level=logging.INFO,
  format='{"t":"%(asctime)s","svc":"auth","msg":"%(message)s"}')
log = logging.getLogger(__name__)

app = FastAPI(title="Auth Service")
# CORS: internal services only talk to api-gateway, not browser directly
# api-gateway handles CORS for public-facing routes
app.add_middleware(CORSMiddleware,
    allow_origins=[os.getenv("ALLOWED_ORIGINS", "http://localhost:3000")],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
    allow_headers=["Authorization", "Content-Type"])

from psycopg2 import pool as pg_pool
from contextlib import contextmanager

_pool = None

@contextmanager
def conn():
    c = _pool.getconn()
    try:
        yield c
    finally:
        _pool.putconn(c)

def init_db():
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                first_name    TEXT NOT NULL,
                last_name     TEXT NOT NULL,
                email         TEXT UNIQUE NOT NULL,
                phone         TEXT NOT NULL DEFAULT '',
                national_id   TEXT NOT NULL DEFAULT '',
                password_hash TEXT NOT NULL,
                status        TEXT NOT NULL DEFAULT 'active',
                created_at    TIMESTAMPTZ DEFAULT NOW(),
                updated_at    TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE TABLE IF NOT EXISTS employees (
                id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                name          TEXT NOT NULL,
                username      TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                role          TEXT NOT NULL DEFAULT 'teller',
                branch        TEXT NOT NULL DEFAULT '',
                shift         TEXT NOT NULL DEFAULT 'صباحي',
                active        BOOLEAN DEFAULT TRUE,
                created_at    TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE TABLE IF NOT EXISTS audit_log (
                id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                actor_id   UUID,
                actor_type TEXT,
                action     TEXT NOT NULL,
                ip         TEXT,
                created_at TIMESTAMPTZ DEFAULT NOW()
            );
            """)
        c.commit()

    # Seed employees if empty
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT COUNT(*) AS n FROM employees")
            if cur.fetchone()["n"] == 0:
                for name, uname, pwd, role, branch, shift in [
                    ("محمد السيد",   "m.elsayed",  "teller123", "teller",     "فرع القاهرة",     "صباحي"),
                    ("سارة أحمد",    "s.ahmed",    "teller456", "supervisor", "فرع الجيزة",      "مسائي"),
                    ("كريم عبدالله", "k.abdallah", "admin789",  "admin",      "الإدارة المركزية", "كامل"),
                ]:
                    h = bcrypt.hashpw(pwd.encode(), bcrypt.gensalt(12)).decode()
                    cur.execute(
                        "INSERT INTO employees(name,username,password_hash,role,branch,shift) VALUES(%s,%s,%s,%s,%s,%s)",
                        (name, uname, h, role, branch, shift))
                c.commit()
                log.info("Employees seeded")

    # Seed demo users if empty
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT COUNT(*) AS n FROM users")
            if cur.fetchone()["n"] == 0:
                seed_users = [
                    ("أحمد",  "محمد", "demo@aurabank.eg",     "01012345678","29901010100001","demo123",  "premium",  "AURA-DEMO0001",125750.50),
                    ("نور",   "علي",  "nour.ali@gmail.com",   "01234567890","30005151234567","nour123",  "standard", "AURA-ABC12345", 22000.00),
                    ("تامر",  "حسن",  "tamer.h@outlook.com",  "01098765432","28812121234567","tamer456", "business", "AURA-BIZ77890",480000.00),
                ]
                for fn,ln,email,phone,nid,pwd,atype,acc_num,bal in seed_users:
                    h = bcrypt.hashpw(pwd.encode(), bcrypt.gensalt(12)).decode()
                    uid = str(uuid.uuid4())
                    cur.execute(
                        "INSERT INTO users(id,first_name,last_name,email,phone,national_id,password_hash) VALUES(%s,%s,%s,%s,%s,%s,%s)",
                        (uid,fn,ln,email,phone,nid,h))
                    # Create account in accounts-service
                    try:
                        time.sleep(0.5)
                        httpx.post(f"{ACCOUNTS_URL}/internal/create-account", json={
                            "user_id":uid,"account_number":acc_num,"account_type":atype,
                            "balance":bal,"firstName":fn,"lastName":ln,
                            "email":email,"phone":phone,"nid":nid
                        }, timeout=8)
                    except Exception as e:
                        log.warning(f"Could not seed account for {email}: {e}")
                c.commit()
                log.info("Demo users seeded")

def hashpw(p): return bcrypt.hashpw(p.encode(), bcrypt.gensalt(12)).decode()
def checkpw(p,h):
    try: return bcrypt.checkpw(p.encode(), h.encode())
    except: return False
def make_token(sub, role, extra={}):
    exp = datetime.datetime.utcnow() + datetime.timedelta(hours=8)
    return jwt.encode({"sub":sub,"role":role,"exp":exp,**extra}, JWT_SECRET, algorithm=JWT_ALGO)

class LoginReq(BaseModel):
    email: str
    password: str
class EmpLoginReq(BaseModel):
    username: str
    password: str
class RegisterReq(BaseModel):
    firstName: str
    lastName: str
    email: str
    phone: str = ""
    nid: str = ""
    password: str
    accountType: str = "standard"
class ChangePwdReq(BaseModel):
    userId: str
    oldPassword: str
    newPassword: str

@app.on_event("startup")
def startup():
    global _pool
    for i in range(20):
        try:
            _pool = pg_pool.ThreadedConnectionPool(
                2, 10, DB_URL,
                cursor_factory=psycopg2.extras.RealDictCursor
            )
            init_db()
            log.info("Auth DB ready")
            return
        except Exception as e:
            log.warning(f"DB not ready ({i+1}/20): {e}")
            time.sleep(3)
    raise RuntimeError("Auth DB failed")

@app.get("/health")
def health(): return {"status":"ok","service":"auth-service"}

@app.post("/auth/login")
def login(req: LoginReq, request: Request):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM users WHERE email=%s", (req.email.lower(),))
            u = cur.fetchone()
    if not u or not checkpw(req.password, u["password_hash"]):
        raise HTTPException(401, "البريد الإلكتروني أو كلمة المرور غير صحيحة")
    if u["status"] != "active":
        raise HTTPException(403, "الحساب غير نشط")
    token = make_token(str(u["id"]), "customer", {"email":u["email"]})
    return {"ok":True,"token":token,"user":{
        "id":str(u["id"]),"firstName":u["first_name"],"lastName":u["last_name"],
        "email":u["email"],"phone":u["phone"]}}

@app.post("/auth/login-employee")
def login_emp(req: EmpLoginReq):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM employees WHERE username=%s AND active=TRUE", (req.username,))
            e = cur.fetchone()
    if not e or not checkpw(req.password, e["password_hash"]):
        raise HTTPException(401, "بيانات خاطئة أو الحساب غير نشط")
    token = make_token(str(e["id"]), e["role"], {"username":e["username"],"branch":e["branch"]})
    return {"ok":True,"token":token,"employee":{
        "id":str(e["id"]),"name":e["name"],"username":e["username"],
        "role":e["role"],"branch":e["branch"],"shift":e["shift"]}}

@app.post("/auth/register")
def register(req: RegisterReq):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT id FROM users WHERE email=%s", (req.email.lower(),))
            if cur.fetchone(): raise HTTPException(409, "البريد الإلكتروني مستخدم بالفعل")
            uid = str(uuid.uuid4())
            h   = hashpw(req.password)
            cur.execute(
                "INSERT INTO users(id,first_name,last_name,email,phone,national_id,password_hash) VALUES(%s,%s,%s,%s,%s,%s,%s)",
                (uid,req.firstName,req.lastName,req.email.lower(),req.phone,req.nid,h))
        c.commit()
    # Create account
    acc_num = "AURA-" + "".join(random.choices("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",k=8))
    try:
        r = httpx.post(f"{ACCOUNTS_URL}/internal/create-account", json={
            "user_id":uid,"account_number":acc_num,"account_type":req.accountType,
            "balance":0.0,"firstName":req.firstName,"lastName":req.lastName,
            "email":req.email,"phone":req.phone,"nid":req.nid
        }, timeout=10)
        acc_data = r.json() if r.status_code==200 else {}
        acc_num = acc_data.get("accountNumber", acc_num)
    except Exception as e:
        log.error(f"Account creation failed: {e}")
    token = make_token(uid,"customer",{"email":req.email})
    return {"ok":True,"token":token,
            "user":{"id":uid,"firstName":req.firstName,"lastName":req.lastName,"email":req.email},
            "accountNumber":acc_num}

@app.post("/auth/change-password")
def change_pwd(req: ChangePwdReq):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM users WHERE id=%s", (req.userId,))
            u = cur.fetchone()
            if not u: raise HTTPException(404, "المستخدم غير موجود")
            if not checkpw(req.oldPassword, u["password_hash"]):
                raise HTTPException(401, "كلمة المرور الحالية غير صحيحة")
            if len(req.newPassword) < 6:
                raise HTTPException(400, "كلمة المرور يجب أن تكون 6 أحرف على الأقل")
            cur.execute("UPDATE users SET password_hash=%s,updated_at=NOW() WHERE id=%s",
                        (hashpw(req.newPassword), req.userId))
        c.commit()
    return {"ok":True}

@app.post("/auth/forgot-password")
def forgot(data: dict):
    return {"ok":True,"message":"تم إرسال رابط الاسترداد"}

@app.post("/auth/logout")
def logout(): return {"ok":True}

@app.post("/auth/verify-token")
def verify_token(data: dict):
    try:
        payload = jwt.decode(data.get("token",""), JWT_SECRET, algorithms=[JWT_ALGO])
        return {"ok":True,"payload":payload}
    except Exception as e:
        raise HTTPException(401, str(e))

# ── Internal endpoints ────────────────────────────────────────────────
@app.get("/internal/employees")
def get_employees():
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT id,name,username,role,branch,shift,active FROM employees ORDER BY name")
            return {"employees":[dict(r) for r in cur.fetchall()]}

@app.post("/internal/employees")
def create_employee(data: dict):
    with conn() as c:
        with c.cursor() as cur:
            if not data.get("username") or not data.get("password"):
                raise HTTPException(400, "username و password مطلوبان")
            cur.execute("SELECT id FROM employees WHERE username=%s",(data["username"],))
            if cur.fetchone(): raise HTTPException(409,"اسم المستخدم مستخدم بالفعل")
            cur.execute(
                "INSERT INTO employees(name,username,password_hash,role,branch,shift) VALUES(%s,%s,%s,%s,%s,%s) RETURNING id",
                (data["name"],data["username"],hashpw(data["password"]),
                 data.get("role","teller"),data.get("branch",""),data.get("shift","صباحي")))
            eid = str(cur.fetchone()["id"])
        c.commit()
    return {"ok":True,"id":eid}

@app.put("/internal/employees/{eid}")
def update_employee(eid: str, data: dict):
    with conn() as c:
        with c.cursor() as cur:
            if "active" in data:
                cur.execute("UPDATE employees SET active=%s WHERE id=%s",(data["active"],eid))
        c.commit()
    return {"ok":True}

@app.delete("/internal/employees/{eid}")
def delete_employee(eid: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("DELETE FROM employees WHERE id=%s",(eid,))
        c.commit()
    return {"ok":True}

@app.get("/internal/audit-log")
def audit_log(limit: int = 200):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM audit_log ORDER BY created_at DESC LIMIT %s",(limit,))
            return {"log":[dict(r) for r in cur.fetchall()]}
