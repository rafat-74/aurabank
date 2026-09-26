"""Aura Bank — Transactions Service :8003"""
import os, uuid, logging, time, json
import psycopg2, psycopg2.extras, httpx, boto3
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from typing import Optional

DB_URL = os.getenv("DATABASE_URL")
if not DB_URL:
    raise RuntimeError("DATABASE_URL env var is required — injected by ECS entrypoint from Secrets Manager")
ACCOUNTS_URL      = os.getenv("ACCOUNTS_URL","http://accounts-service:8002")
NOTIFICATIONS_URL = os.getenv("NOTIFICATIONS_URL","http://notifications-service:8004")

RATES = {"EGP":1,"USD":0.0204,"EUR":0.0188,"GBP":0.016,"SAR":0.0765,"AED":0.0749,"KWD":0.00626}

AWS_REGION    = os.getenv("AWS_REGION", "us-east-1")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")
sqs_client    = boto3.client("sqs", region_name=AWS_REGION)

logging.basicConfig(level=logging.INFO,
  format='{"t":"%(asctime)s","svc":"transactions","msg":"%(message)s"}')
log = logging.getLogger(__name__)

app = FastAPI(title="Transactions Service")
# CORS: internal services only talk to api-gateway, not browser directly
# api-gateway handles CORS for public-facing routes
app.add_middleware(CORSMiddleware,
    allow_origins=[os.getenv("ALLOWED_ORIGINS", "http://localhost:3000")],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
    allow_headers=["Authorization", "Content-Type"])

def conn():
    return psycopg2.connect(DB_URL, cursor_factory=psycopg2.extras.RealDictCursor)

def init_db():
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("""
            CREATE TABLE IF NOT EXISTS transactions (
                id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                account_id       UUID NOT NULL,
                from_account_id  UUID,
                to_account_id    UUID,
                type             TEXT NOT NULL,
                sub_type         TEXT NOT NULL,
                description      TEXT NOT NULL,
                amount           NUMERIC(15,2) NOT NULL CHECK(amount>0),
                currency         TEXT DEFAULT 'EGP',
                balance_after    NUMERIC(15,2) NOT NULL,
                status           TEXT DEFAULT 'completed',
                performed_by     TEXT DEFAULT 'customer',
                performed_by_id  UUID,
                reference_number TEXT UNIQUE,
                created_at       TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE TABLE IF NOT EXISTS teller_log (
                id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                teller_id    UUID,
                teller_name  TEXT NOT NULL,
                account_id   UUID NOT NULL,
                customer_name TEXT DEFAULT '',
                operation    TEXT NOT NULL,
                amount       NUMERIC(15,2) NOT NULL,
                description  TEXT DEFAULT '',
                created_at   TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE TABLE IF NOT EXISTS audit_log (
                id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                actor_name  TEXT NOT NULL,
                actor_id    TEXT,
                actor_role  TEXT DEFAULT 'teller',
                action      TEXT NOT NULL,
                created_at  TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_tx_account   ON transactions(account_id);
            CREATE INDEX IF NOT EXISTS idx_tx_date      ON transactions(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_tlog_date    ON teller_log(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_audit_date   ON audit_log(created_at DESC);
            """)
        c.commit()

def call_accounts(method, path, body=None):
    url = ACCOUNTS_URL+path
    try:
        if method=="GET":
            r = httpx.get(url, params=body, timeout=10)
        else:
            r = httpx.post(url, json=body, timeout=10)
        if r.status_code >= 400:
            detail = r.json().get("detail", r.text) if r.content else "accounts error"
            raise HTTPException(r.status_code, detail)
        return r.json()
    except HTTPException: raise
    except Exception as e: raise HTTPException(503, f"accounts-service error: {e}")

def notify(uid, title, body_text, ntype="transaction", phone=None, email=None):
    """Send notification via SQS (preferred) or HTTP fallback"""
    if SQS_QUEUE_URL:
        try:
            msg = {"user_id": uid, "title": title, "body": body_text, "type": ntype}
            if phone:
                msg["phone"] = phone
            if email:
                msg["email"] = email
            sqs_client.send_message(
                QueueUrl=SQS_QUEUE_URL,
                MessageBody=json.dumps(msg, ensure_ascii=False)
            )
            log.info(f"Notification queued via SQS for user {uid}")
            return
        except Exception as e:
            log.warning(f"SQS failed, falling back to HTTP: {e}")
    # HTTP fallback
    try:
        httpx.post(f"{NOTIFICATIONS_URL}/internal/create",
                   json={"user_id":uid,"title":title,"body":body_text,"type":ntype},timeout=3)
    except: pass

def row2dict(row):
    if row is None: return None
    d = dict(row)
    for k,v in d.items():
        if hasattr(v,'isoformat'): d[k] = v.isoformat()
    return d

def record(cur, account_id, tx_type, sub_type, desc, amount, balance_after,
           from_acc=None, to_acc=None, currency="EGP",
           performed_by="customer", performed_by_id=None):
    ref = "REF-"+uuid.uuid4().hex[:8].upper()
    cur.execute("""
        INSERT INTO transactions(account_id,from_account_id,to_account_id,type,sub_type,
            description,amount,currency,balance_after,performed_by,performed_by_id,reference_number)
        VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
        (account_id,from_acc,to_acc,tx_type,sub_type,desc,amount,
         currency,balance_after,performed_by,performed_by_id,ref))
    return row2dict(cur.fetchone())

@app.on_event("startup")
def startup():
    for i in range(20):
        try: init_db(); log.info("Transactions DB ready"); return
        except Exception as e: log.warning(f"DB not ready ({i+1}/20): {e}"); time.sleep(3)
    raise RuntimeError("Transactions DB failed")

@app.get("/health")
def health(): return {"status":"ok","service":"transactions-service"}



# ── Deposit ───────────────────────────────────────────────────────────
@app.post("/transactions/deposit")
def deposit(data: dict):
    amt    = float(data.get("amount",0))
    if amt<=0: raise HTTPException(400,"المبلغ يجب أن يكون أكبر من صفر")
    acc_id = data["accountId"]
    note   = data.get("note","إيداع نقدي")
    tname  = data.get("tellerName")
    tid    = data.get("tellerId")
    cname  = data.get("customerName","")

    result  = call_accounts("POST","/internal/update-balance",{"account_id":acc_id,"delta":amt,"operation":"deposit"})
    new_bal = result["newBalance"]

    by   = "teller" if tname else "customer"
    desc = note+(f" (الموظف: {tname})" if tname else "")
    with conn() as c:
        with c.cursor() as cur:
            tx = record(cur,acc_id,"credit","deposit",desc,amt,new_bal,
                        to_acc=acc_id,performed_by=by,performed_by_id=tid)
            if tname:
                cur.execute("""INSERT INTO teller_log(teller_id,teller_name,account_id,customer_name,operation,amount,description)
                    VALUES(%s,%s,%s,%s,'deposit',%s,%s)""",
                    (tid or str(uuid.uuid4()),tname,acc_id,cname,amt,note))
        c.commit()
    log.info(f"Deposit {amt} → {acc_id}")
    # Send notification to customer
    try:
        acc_info = call_accounts("GET", f"/accounts/{acc_id}")
        if acc_info and acc_info.get("user_id"):
            notify(str(acc_info["user_id"]), "💵 إيداع ناجح",
                   f"تم إيداع {amt:.2f} EGP في حسابك. الرصيد: {new_bal:.2f} EGP",
                   phone=acc_info.get("phone"), email=acc_info.get("email"))
    except: pass
    return {"ok":True,"newBalance":new_bal,"transaction":tx}


# ── Loan Credit (يُستدعى من accounts-service عند الموافقة على قرض) ──
@app.post("/transactions/loan-credit")
def loan_credit(data: dict):
    amt      = float(data["amount"])
    acc_id   = data["accountId"]
    ltype    = data.get("loanType","قرض")
    reviewer = data.get("reviewerName","")
    result   = call_accounts("POST","/internal/update-balance",{"account_id":acc_id,"delta":amt,"operation":"loan_credit"})
    new_bal  = result["newBalance"]
    desc = f"صرف قرض {ltype}" + (f" (اعتماد: {reviewer})" if reviewer else "")
    with conn() as c:
        with c.cursor() as cur:
            tx = record(cur,acc_id,"credit","loan",desc,amt,new_bal,
                        to_acc=acc_id,performed_by="system",performed_by_id=None)
        c.commit()
    return {"ok":True,"transaction":tx,"newBalance":new_bal}




# ── Withdraw ──────────────────────────────────────────────────────────
@app.post("/transactions/withdraw")
def withdraw(data: dict):
    amt    = float(data.get("amount",0))
    if amt<=0: raise HTTPException(400,"المبلغ يجب أن يكون أكبر من صفر")
    acc_id = data["accountId"]
    note   = data.get("note","سحب نقدي")
    tname  = data.get("tellerName")
    tid    = data.get("tellerId")
    cname  = data.get("customerName","")

    result  = call_accounts("POST","/internal/update-balance",{"account_id":acc_id,"delta":-amt,"operation":"withdrawal"})
    new_bal = result["newBalance"]

    by   = "teller" if tname else "customer"
    desc = note+(f" (الموظف: {tname})" if tname else "")
    with conn() as c:
        with c.cursor() as cur:
            tx = record(cur,acc_id,"debit","withdrawal",desc,amt,new_bal,
                        from_acc=acc_id,performed_by=by,performed_by_id=tid)
            if tname:
                cur.execute("""INSERT INTO teller_log(teller_id,teller_name,account_id,customer_name,operation,amount,description)
                    VALUES(%s,%s,%s,%s,'withdrawal',%s,%s)""",
                    (tid or str(uuid.uuid4()),tname,acc_id,cname,amt,note))
        c.commit()
    log.info(f"Withdraw {amt} ← {acc_id}")
    # Send notification to customer
    try:
        acc_info = call_accounts("GET", f"/accounts/{acc_id}")
        if acc_info and acc_info.get("user_id"):
            notify(str(acc_info["user_id"]), "💸 سحب ناجح",
                   f"تم سحب {amt:.2f} EGP من حسابك. الرصيد: {new_bal:.2f} EGP",
                   phone=acc_info.get("phone"), email=acc_info.get("email"))
    except: pass
    return {"ok":True,"newBalance":new_bal,"transaction":tx}

# ── Transfer ──────────────────────────────────────────────────────────
@app.post("/transactions/transfer")
def transfer(data: dict):
    amt     = float(data.get("amount",0))
    if amt<=0: raise HTTPException(400,"المبلغ يجب أن يكون أكبر من صفر")
    from_id = data["fromAccountId"]
    to_id   = data.get("toAccountId")
    to_num  = data.get("toAccountNumber")
    note    = data.get("note","تحويل")
    by      = data.get("performedBy","customer")
    by_id   = data.get("performedById")
    tname   = data.get("tellerName")
    cname   = data.get("customerName","")

    # Find receiver
    recv = None
    if to_id:
        try: recv = call_accounts("GET",f"/accounts/{to_id}")
        except: pass
    if not recv and to_num:
        try: recv = call_accounts("GET","/internal/find-account",{"account_number":to_num})
        except: pass
    if not recv and to_num:
        # try by email via user lookup
        try: recv = call_accounts("GET","/internal/find-account",{"account_number":to_num})
        except: pass

    # Debit sender
    res_s = call_accounts("POST","/internal/update-balance",{"account_id":from_id,"delta":-amt,"operation":"transfer_out"})

    # Credit receiver
    res_r = None
    if recv:
        try:
            res_r = call_accounts("POST","/internal/update-balance",{"account_id":str(recv["id"]),"delta":amt,"operation":"transfer_in"})
        except Exception as e:
            call_accounts("POST","/internal/update-balance",{"account_id":from_id,"delta":amt,"operation":"rollback"})
            raise HTTPException(500,f"فشل التحويل: {e}")

    to_name = recv["account_number"] if recv else (to_num or "خارجي")
    to_full = f"{recv.get('first_name','')} {recv.get('last_name','')}" if recv else to_name

    with conn() as c:
        with c.cursor() as cur:
            tx = record(cur,from_id,"debit","transfer",f"تحويل إلى {to_name}: {note}",
                        amt,res_s["newBalance"],from_acc=from_id,
                        to_acc=str(recv["id"]) if recv else None,
                        performed_by=by,performed_by_id=by_id)
            if recv and res_r:
                record(cur,str(recv["id"]),"credit","transfer",f"تحويل وارد: {note}",
                       amt,res_r["newBalance"],from_acc=from_id,to_acc=str(recv["id"]),
                       performed_by=by,performed_by_id=by_id)
            if tname:
                cur.execute("""INSERT INTO teller_log(teller_id,teller_name,account_id,customer_name,operation,amount,description)
                    VALUES(%s,%s,%s,%s,'transfer',%s,%s)""",
                    (by_id or str(uuid.uuid4()),tname,from_id,
                     cname or f"→ {to_full}",amt,f"إلى {to_name}: {note}"))
        c.commit()

    if recv:
        notify(str(recv["user_id"]),"💰 تحويل مالي وارد",f"استلمت {amt:.2f} EGP")
    return {"ok":True,"newBalance":res_s["newBalance"],"receiverFound":recv is not None}

# ── Pay Bill ──────────────────────────────────────────────────────────
@app.post("/transactions/pay-bill")
def pay_bill(data: dict):
    amt    = float(data.get("amount",0))
    if amt<=0: raise HTTPException(400,"المبلغ يجب أن يكون أكبر من صفر")
    acc_id = data["accountId"]
    btype  = data.get("billType","فاتورة")
    bnum   = data.get("billNumber","")
    tname  = data.get("tellerName")
    tid    = data.get("tellerId")
    cname  = data.get("customerName","")

    result = call_accounts("POST","/internal/update-balance",{"account_id":acc_id,"delta":-amt,"operation":"bill"})
    by     = "teller" if tname else "customer"
    desc   = f"دفع فاتورة {btype} - {bnum}"
    with conn() as c:
        with c.cursor() as cur:
            tx = record(cur,acc_id,"debit","bill",desc,amt,result["newBalance"],
                        from_acc=acc_id,performed_by=by,performed_by_id=tid)
            if tname:
                cur.execute("""INSERT INTO teller_log(teller_id,teller_name,account_id,customer_name,operation,amount,description)
                    VALUES(%s,%s,%s,%s,'bill',%s,%s)""",
                    (tid or str(uuid.uuid4()),tname,acc_id,cname,amt,desc))
        c.commit()
    # Send notification to customer
    try:
        acc_info = call_accounts("GET", f"/accounts/{acc_id}")
        if acc_info and acc_info.get("user_id"):
            notify(str(acc_info["user_id"]), f"🧾 دفع فاتورة {btype}", f"تم دفع {amt:.2f} EGP لفاتورة {btype}. الرصيد: {result['newBalance']:.2f} EGP")
    except: pass
    return {"ok":True,"newBalance":result["newBalance"],"transaction":tx}

# ── Exchange ──────────────────────────────────────────────────────────
@app.post("/transactions/exchange")
def exchange(data: dict):
    amt    = float(data.get("amount",0))
    frm    = data.get("fromCurrency","EGP")
    to     = data.get("toCurrency","USD")
    acc_id = data["accountId"]
    if frm not in RATES or to not in RATES: raise HTTPException(400,"عملة غير مدعومة")
    rate     = RATES[to]/RATES[frm]
    result_v = round(amt*rate,4)
    cost     = amt if frm=="EGP" else round(amt/RATES[frm],2)
    res      = call_accounts("POST","/internal/update-balance",{"account_id":acc_id,"delta":-cost,"operation":"exchange"})
    with conn() as c:
        with c.cursor() as cur:
            tx = record(cur,acc_id,"debit","exchange",
                        f"صرف {amt} {frm} → {result_v} {to}",
                        cost,res["newBalance"],from_acc=acc_id,currency=frm)
        c.commit()
    # Notify customer
    try:
        acc_info = call_accounts("GET", f"/accounts/{acc_id}")
        if acc_info and acc_info.get("user_id"):
            notify(str(acc_info["user_id"]), "💱 صرف عملة ناجح", f"تم صرف {amt} {frm} إلى {result_v} {to}")
    except: pass
    return {"ok":True,"result":result_v,"rate":rate,"newBalance":res["newBalance"]}

# ── Exchange Rates ────────────────────────────────────────────────────
@app.get("/transactions/rates")
def get_rates(): return {"rates":RATES}

# ── Teller Log (persisted in PostgreSQL) ─────────────────────────────
@app.get("/transactions/teller-log")
def get_teller_log(limit: int=200):
    with conn() as c:
        with c.cursor() as cur:
            # FIX: Removed cross-DB JOIN with `accounts` table.
            # `accounts` lives in accounts-db (a separate database/service).
            # Cross-DB JOINs are impossible in microservices architecture.
            # account_number is available via HTTP call to accounts-service if needed.
            cur.execute("""
                SELECT *
                FROM teller_log
                ORDER BY created_at DESC LIMIT %s
            """, (limit,))
            rows = cur.fetchall()
    result = []
    for r in rows:
        d = row2dict(r)
        d["type"]     = d.get("operation","")
        d["amount"]   = float(d.get("amount",0))
        d["customer"] = d.get("customer_name","")
        d["emp"]      = d.get("teller_name","")
        d["time"]     = d.get("created_at","")
        d["desc"]     = d.get("description","")
        result.append(d)
    return {"log": result}

# ── Teller Log for today only ─────────────────────────────────────────
@app.get("/transactions/teller-log-today")
def get_teller_log_today():
    with conn() as c:
        with c.cursor() as cur:
            # FIX: Removed cross-DB JOIN with `accounts` table.
            # `accounts` lives in accounts-db (a separate database/service).
            cur.execute("""
                SELECT *
                FROM teller_log
                WHERE created_at >= CURRENT_DATE
                ORDER BY created_at DESC
            """)
            rows = cur.fetchall()
    result = []
    for r in rows:
        d = row2dict(r)
        d["type"]     = d.get("operation","")
        d["amount"]   = float(d.get("amount",0))
        d["customer"] = d.get("customer_name","")
        d["emp"]      = d.get("teller_name","")
        d["time"]     = d.get("created_at","")
        d["desc"]     = d.get("description","")
        result.append(d)
    return {"log": result}

# ── 7-day chart data ──────────────────────────────────────────────────
@app.get("/transactions/teller-weekly")
def get_teller_weekly():
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("""
                SELECT
                    DATE(created_at) as day,
                    operation,
                    SUM(amount) as total,
                    COUNT(*) as count
                FROM teller_log
                WHERE created_at >= CURRENT_DATE - INTERVAL '6 days'
                GROUP BY DATE(created_at), operation
                ORDER BY day ASC
            """)
            rows = cur.fetchall()
    result = [row2dict(r) for r in rows]
    for r in result:
        r["total"] = float(r["total"] or 0)
        r["day"]   = str(r.get("day",""))
    return {"weekly": result}

# ── Audit Log (persisted in PostgreSQL) ──────────────────────────────
@app.post("/transactions/audit-log")
def add_audit(data: dict):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("""INSERT INTO audit_log(actor_name,actor_id,actor_role,action)
                VALUES(%s,%s,%s,%s)""",
                (data.get("actorName","نظام"),
                 data.get("actorId",""),
                 data.get("actorRole","teller"),
                 data["action"]))
        c.commit()
    return {"ok":True}

@app.get("/transactions/audit-log")
def get_audit_log(limit: int=200):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM audit_log ORDER BY created_at DESC LIMIT %s",(limit,))
            rows = cur.fetchall()
    result = []
    for r in rows:
        d = row2dict(r)
        d["time"]   = d.get("created_at","")
        d["action"] = d.get("action","")
        d["by"]     = d.get("actor_name","")
        result.append(d)
    return {"log": result}

@app.delete("/transactions/audit-log")
def clear_audit_log():
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("DELETE FROM audit_log")
        c.commit()
    return {"ok":True}


# ── Get transactions for account ─────────────────────────────────────
# IMPORTANT: This dynamic route MUST be defined LAST among all GET /transactions/*
# routes. FastAPI matches routes in definition order, so if this appeared first,
# it would capture static paths like "teller-log-today", "rates", "audit-log", etc.
# as the {account_id} parameter, causing a UUID parse error.
@app.get("/transactions/{account_id}")
def get_transactions(account_id: str, limit: int = 50):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM transactions WHERE account_id=%s ORDER BY created_at DESC LIMIT %s",
                        (account_id,limit))
            rows = cur.fetchall()
    txs = [row2dict(r) for r in rows]
    for t in txs:
        t["desc"] = t.get("description","")
        t["date"] = t.get("created_at","")[:10] if t.get("created_at") else ""
    return {"transactions":txs,"count":len(txs)}
