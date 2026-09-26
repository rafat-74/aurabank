"""Aura Bank — Accounts Service :8002"""
import os, uuid, math, random, logging, time
import psycopg2, psycopg2.extras, httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from typing import Optional

DB_URL = os.getenv("DATABASE_URL")
if not DB_URL:
    raise RuntimeError("DATABASE_URL env var is required — injected by ECS entrypoint from Secrets Manager")
NOTIFICATIONS_URL = os.getenv("NOTIFICATIONS_URL","http://notifications-service:8004")
TRANSACTIONS_URL = os.getenv("TRANSACTIONS_URL","http://transactions-service:8003")

logging.basicConfig(level=logging.INFO,
  format='{"t":"%(asctime)s","svc":"accounts","msg":"%(message)s"}')
log = logging.getLogger(__name__)

app = FastAPI(title="Accounts Service")
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
            CREATE TABLE IF NOT EXISTS accounts (
                id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                user_id         UUID NOT NULL,
                account_number  TEXT UNIQUE NOT NULL,
                account_type    TEXT NOT NULL DEFAULT 'standard',
                balance         NUMERIC(15,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
                currency        TEXT NOT NULL DEFAULT 'EGP',
                savings_balance NUMERIC(15,2) NOT NULL DEFAULT 0,
                frozen          BOOLEAN DEFAULT FALSE,
                card_number     TEXT DEFAULT '',
                first_name      TEXT DEFAULT '',
                last_name       TEXT DEFAULT '',
                email           TEXT DEFAULT '',
                phone           TEXT DEFAULT '',
                national_id     TEXT DEFAULT '',
                created_at      TIMESTAMPTZ DEFAULT NOW(),
                updated_at      TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE TABLE IF NOT EXISTS cards (
                id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                account_id         UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                user_id            UUID NOT NULL,
                card_type          TEXT NOT NULL,
                card_number_masked TEXT NOT NULL,
                expiry_month       INT DEFAULT 12,
                expiry_year        INT DEFAULT 27,
                color              TEXT DEFAULT 'vc-blue',
                frozen             BOOLEAN DEFAULT FALSE,
                created_at         TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE TABLE IF NOT EXISTS savings_goals (
                id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                account_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                name        TEXT NOT NULL,
                emoji       TEXT DEFAULT '🎯',
                target      NUMERIC(15,2) NOT NULL,
                current     NUMERIC(15,2) NOT NULL DEFAULT 0,
                deadline    DATE,
                status      TEXT DEFAULT 'active',
                created_at  TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE TABLE IF NOT EXISTS loans (
                id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                account_id         UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                loan_type          TEXT NOT NULL,
                total              NUMERIC(15,2) NOT NULL,
                monthly            NUMERIC(15,2) NOT NULL,
                paid               NUMERIC(15,2) DEFAULT 0,
                years              INT NOT NULL,
                purpose            TEXT DEFAULT '',
                status             TEXT NOT NULL DEFAULT 'pending'
                                   CHECK (status IN ('pending','approved','rejected','cancelled')),
                requested_by_role  TEXT NOT NULL DEFAULT 'customer'
                                   CHECK (requested_by_role IN ('customer','teller')),
                requested_by_id    UUID,
                reviewed_by_id     UUID,
                reviewed_by_role   TEXT,
                decision_note      TEXT,
                decided_at         TIMESTAMPTZ,
                created_at         TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE TABLE IF NOT EXISTS portfolio (
                id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                account_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                symbol      TEXT NOT NULL,
                name        TEXT NOT NULL,
                qty         INT NOT NULL,
                avg_price   NUMERIC(15,4) NOT NULL,
                total_cost  NUMERIC(15,2) NOT NULL,
                created_at  TIMESTAMPTZ DEFAULT NOW(),
                UNIQUE(account_id, symbol)
            );
            CREATE INDEX IF NOT EXISTS idx_acc_user   ON accounts(user_id);
            CREATE INDEX IF NOT EXISTS idx_card_acc   ON cards(account_id);
            CREATE INDEX IF NOT EXISTS idx_goal_acc   ON savings_goals(account_id);
            CREATE INDEX IF NOT EXISTS idx_loan_acc   ON loans(account_id);
            CREATE INDEX IF NOT EXISTS idx_port_acc   ON portfolio(account_id);
            """)
        c.commit()

def notify(user_id, title, body, ntype="system"):
    try:
        httpx.post(f"{NOTIFICATIONS_URL}/internal/create",
                   json={"user_id":user_id,"title":title,"body":body,"type":ntype},timeout=3)
    except: pass

def call_transactions(method, path, json_body=None):
    try:
        r = httpx.request(method, f"{TRANSACTIONS_URL}{path}", json=json_body, timeout=5)
        r.raise_for_status()
        return r.json()
    except httpx.HTTPStatusError as e:
        raise HTTPException(e.response.status_code, e.response.json().get("detail","خطأ في transactions-service"))
    except Exception as e:
        raise HTTPException(500, f"تعذر الاتصال بـ transactions-service: {e}")


def row2dict(row):
    if row is None: return None
    d = dict(row)
    for k,v in d.items():
        if hasattr(v,'isoformat'): d[k] = v.isoformat()
    return d

@app.on_event("startup")
def startup():
    for i in range(20):
        try: init_db(); log.info("Accounts DB ready"); return
        except Exception as e: log.warning(f"DB not ready ({i+1}/20): {e}"); time.sleep(3)
    raise RuntimeError("Accounts DB failed")

@app.get("/health")
def health(): return {"status":"ok","service":"accounts-service"}

# ── Internal: Create Account (called by auth-service) ─────────────────
@app.post("/internal/create-account")
def create_account(data: dict):
    uid       = data["user_id"]
    acc_num   = data.get("account_number","AURA-"+uuid.uuid4().hex[:8].upper())
    acc_type  = data.get("account_type","standard")
    bal       = float(data.get("balance",0))
    fn        = data.get("firstName", data.get("first_name",""))
    ln        = data.get("lastName",  data.get("last_name",""))
    email     = data.get("email","")
    phone     = data.get("phone","")
    nid       = data.get("nid", data.get("national_id",""))
    card_num  = " ".join(str(random.randint(1000,9999)) for _ in range(4))
    card_mask = card_num[:4]+" •••• •••• "+card_num[-4:]
    card_type = "Visa Gold" if acc_type=="premium" else "Visa Classic"
    card_color= "vc-gold"   if acc_type=="premium" else "vc-blue"

    with conn() as c:
        with c.cursor() as cur:
            # Upsert — avoid duplicate error on retry
            cur.execute("SELECT id FROM accounts WHERE user_id=%s OR account_number=%s",(uid,acc_num))
            existing = cur.fetchone()
            if existing:
                return {"ok":True,"accountNumber":acc_num,"accountId":str(existing["id"])}

            cur.execute("""
                INSERT INTO accounts(user_id,account_number,account_type,balance,card_number,
                    first_name,last_name,email,phone,national_id)
                VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
                (uid,acc_num,acc_type,bal,card_num,fn,ln,email,phone,nid))
            acc_id = str(cur.fetchone()["id"])
            cur.execute("""
                INSERT INTO cards(account_id,user_id,card_type,card_number_masked,expiry_month,expiry_year,color)
                VALUES(%s,%s,%s,%s,12,27,%s)""",
                (acc_id,uid,card_type,card_mask,card_color))
        c.commit()
    log.info(f"Account created: {acc_num} user={uid}")
    return {"ok":True,"accountNumber":acc_num,"accountId":acc_id}

# ── Get account by user_id ────────────────────────────────────────────
@app.get("/accounts/user/{user_id}")
def get_by_user(user_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM accounts WHERE user_id=%s",(user_id,))
            acc = cur.fetchone()
            if not acc: raise HTTPException(404,"الحساب غير موجود")
            acc_id = str(acc["id"])
            cur.execute("SELECT * FROM cards         WHERE account_id=%s",(acc_id,))
            cards = cur.fetchall()
            cur.execute("SELECT * FROM savings_goals WHERE account_id=%s AND status='active'",(acc_id,))
            goals = cur.fetchall()
            cur.execute("SELECT * FROM loans         WHERE account_id=%s",(acc_id,))
            loans = cur.fetchall()
            cur.execute("SELECT * FROM portfolio     WHERE account_id=%s",(acc_id,))
            port  = cur.fetchall()

    acc = row2dict(acc)
    return {
        "account":       acc,
        "accountId":     acc["id"],
        "accountNumber": acc["account_number"],
        "balance":       float(acc["balance"]),
        "accountType":   acc["account_type"],
        "frozen":        acc["frozen"],
        "savings":       float(acc["savings_balance"]),
        "cards":  [{"type":c["card_type"],"number":c["card_number_masked"],
                    "color":c["color"],"frozen":c["frozen"],
                    "expiry":f"{c['expiry_month']:02d}/{str(c['expiry_year'])[-2:]}"}
                   for c in cards],
        "goals":  [row2dict(g) for g in goals],
        "loans":  [row2dict(l) for l in loans],
        "portfolio": [row2dict(p) for p in port],
    }

@app.get("/accounts")
def get_all():
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM accounts ORDER BY created_at DESC")
            rows = cur.fetchall()
    return {"accounts":[row2dict(r) for r in rows]}


@app.get("/accounts/loans")
def list_all_loans(status: Optional[str] = None):
    with conn() as c:
        with c.cursor() as cur:
            if status:
                cur.execute("""
                    SELECT l.*, a.account_number, a.first_name, a.last_name
                    FROM loans l JOIN accounts a ON a.id = l.account_id
                    WHERE l.status=%s ORDER BY l.created_at DESC""",(status,))
            else:
                cur.execute("""
                    SELECT l.*, a.account_number, a.first_name, a.last_name
                    FROM loans l JOIN accounts a ON a.id = l.account_id
                    ORDER BY l.created_at DESC""")
            return {"loans":[row2dict(r) for r in cur.fetchall()]}



@app.get("/accounts/{account_id}")
def get_account(account_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM accounts WHERE id=%s OR account_number=%s",(account_id,account_id))
            acc = cur.fetchone()
            if not acc: raise HTTPException(404,"الحساب غير موجود")
    return row2dict(acc)

# ── Update Balance — ONLY called by transactions-service ──────────────
@app.post("/internal/update-balance")
def update_balance(data: dict):
    account_id = data["account_id"]
    delta      = float(data["delta"])
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT id,balance,frozen FROM accounts WHERE id=%s FOR UPDATE",(account_id,))
            acc = cur.fetchone()
            if not acc:      raise HTTPException(404,"الحساب غير موجود")
            if acc["frozen"]:raise HTTPException(403,"الحساب مجمّد")
            new_bal = round(float(acc["balance"])+delta, 2)
            if new_bal < 0:  raise HTTPException(400,f"الرصيد غير كافٍ. الرصيد الحالي: {float(acc['balance']):.2f} EGP")
            cur.execute("UPDATE accounts SET balance=%s,updated_at=NOW() WHERE id=%s RETURNING balance",
                        (new_bal,account_id))
            new_bal = float(cur.fetchone()["balance"])
        c.commit()
    return {"ok":True,"newBalance":new_bal}

# ── Freeze / Unfreeze ─────────────────────────────────────────────────
@app.post("/accounts/{account_id}/freeze")
def freeze(account_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("UPDATE accounts SET frozen=TRUE,updated_at=NOW() WHERE id=%s RETURNING user_id",(account_id,))
            r = cur.fetchone()
        c.commit()
    if r: notify(str(r["user_id"]),"❄️ تجميد الحساب","تم تجميد حسابك","security")
    return {"ok":True}

@app.post("/accounts/{account_id}/unfreeze")
def unfreeze(account_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("UPDATE accounts SET frozen=FALSE,updated_at=NOW() WHERE id=%s RETURNING user_id",(account_id,))
            r = cur.fetchone()
        c.commit()
    if r: notify(str(r["user_id"]),"✅ إلغاء التجميد","تم إلغاء تجميد حسابك","security")
    return {"ok":True}

# ── Cards ──────────────────────────────────────────────────────────────
@app.get("/accounts/{account_id}/cards")
def get_cards(account_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM cards WHERE account_id=%s",(account_id,))
            return {"cards":[row2dict(r) for r in cur.fetchall()]}

@app.post("/accounts/{account_id}/cards")
def issue_card(account_id: str, data: dict):
    num = " ".join(str(random.randint(1000,9999)) for _ in range(4))
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT user_id FROM accounts WHERE id=%s",(account_id,))
            acc = cur.fetchone()
            if not acc: raise HTTPException(404,"الحساب غير موجود")
            cur.execute("""INSERT INTO cards(account_id,user_id,card_type,card_number_masked,expiry_month,expiry_year,color)
                VALUES(%s,%s,%s,%s,12,28,%s) RETURNING *""",
                (account_id,str(acc["user_id"]),data.get("cardType","Visa Classic"),
                 num[:4]+" •••• •••• "+num[-4:],data.get("color","vc-blue")))
            card = row2dict(cur.fetchone())
        c.commit()
    return {"ok":True,"card":card}

# ── Savings Goals ──────────────────────────────────────────────────────
@app.get("/accounts/{account_id}/goals")
def get_goals(account_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM savings_goals WHERE account_id=%s AND status='active' ORDER BY created_at",(account_id,))
            return {"goals":[row2dict(r) for r in cur.fetchall()]}

@app.post("/accounts/{account_id}/goals")
def create_goal(account_id: str, data: dict):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("""INSERT INTO savings_goals(account_id,name,emoji,target,current,deadline)
                VALUES(%s,%s,%s,%s,%s,%s) RETURNING *""",
                (account_id,data["name"],data.get("emoji","🎯"),
                 data["target"],data.get("current",0),data.get("deadline")))
            g = row2dict(cur.fetchone())
        c.commit()
    return {"ok":True,"goal":g}

@app.put("/accounts/{account_id}/goals/{goal_id}")
def update_goal(account_id: str, goal_id: str, data: dict):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM savings_goals WHERE id=%s AND account_id=%s FOR UPDATE",(goal_id,account_id))
            g = cur.fetchone()
            if not g: raise HTTPException(404,"الهدف غير موجود")
            new_cur = min(float(data.get("current",g["current"])), float(g["target"]))
            diff    = new_cur - float(g["current"])
            cur.execute("UPDATE savings_goals SET current=%s WHERE id=%s RETURNING *",(new_cur,goal_id))
            updated = row2dict(cur.fetchone())
            if diff != 0:
                cur.execute("UPDATE accounts SET savings_balance=savings_balance+%s WHERE id=%s",(diff,account_id))
        c.commit()
    return {"ok":True,"goal":updated}

@app.delete("/accounts/{account_id}/goals/{goal_id}")
def delete_goal(account_id: str, goal_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("UPDATE savings_goals SET status='cancelled' WHERE id=%s AND account_id=%s",(goal_id,account_id))
        c.commit()
    return {"ok":True}

# ── Loans ──────────────────────────────────────────────────────────────
@app.get("/accounts/{account_id}/loans")
def get_loans(account_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM loans WHERE account_id=%s ORDER BY created_at DESC",(account_id,))
            return {"loans":[row2dict(r) for r in cur.fetchall()]}

@app.post("/accounts/{account_id}/loans")
def apply_loan(account_id: str, data: dict):
    amt  = float(data["amount"])
    yrs  = int(data["years"])
    r    = 0.12/12
    n    = yrs*12
    mo   = round(amt*(r*(1+r)**n)/((1+r)**n-1),2)
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("""INSERT INTO loans(account_id,loan_type,total,monthly,years,purpose)
                VALUES(%s,%s,%s,%s,%s,%s) RETURNING *""",
                (account_id,data["loanType"],amt,mo,yrs,data.get("purpose","")))
            loan = row2dict(cur.fetchone())
        c.commit()
    return {"ok":True,"loan":loan,"monthlyPayment":mo}


@app.post("/accounts/{account_id}/loans/teller-request")
def teller_apply_loan(account_id: str, data: dict):
    amt  = float(data["amount"])
    yrs  = int(data["years"])
    tid  = data.get("tellerId")
    if not tid:
        raise HTTPException(400, "بيانات الموظف مطلوبة")
    r    = 0.12/12
    n    = yrs*12
    mo   = round(amt*(r*(1+r)**n)/((1+r)**n-1),2)
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("""INSERT INTO loans(account_id,loan_type,total,monthly,years,purpose,requested_by_role,requested_by_id)
                VALUES(%s,%s,%s,%s,%s,%s,'teller',%s) RETURNING *""",
                (account_id,data["loanType"],amt,mo,yrs,data.get("purpose",""),tid))
            loan = row2dict(cur.fetchone())
        c.commit()
    return {"ok":True,"loan":loan,"monthlyPayment":mo}



@app.put("/accounts/loans/{loan_id}/cancel")
def cancel_loan(loan_id: str, data: dict):
    teller_id   = data.get("tellerId")
    teller_name = data.get("tellerName","")
    if not teller_id:
        raise HTTPException(400,"بيانات الموظف مطلوبة")

    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM loans WHERE id=%s",(loan_id,))
            loan = cur.fetchone()
            if not loan:
                raise HTTPException(404,"الطلب غير موجود")
            if loan["status"] != "pending":
                raise HTTPException(400,"لا يمكن إلغاء طلب تم البت فيه بالفعل")
            cur.execute("""UPDATE loans SET status='cancelled', reviewed_by_id=%s,
                reviewed_by_role='teller', decision_note=%s, decided_at=NOW()
                WHERE id=%s RETURNING *""",
                (teller_id, f"أُلغي بواسطة الموظف: {teller_name}" if teller_name else "أُلغي بواسطة موظف", loan_id))
            updated = row2dict(cur.fetchone())
        c.commit()

    cur_acc = None
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT user_id FROM accounts WHERE id=%s",(loan["account_id"],))
            cur_acc = cur.fetchone()
    if cur_acc:
        notify(str(cur_acc["user_id"]), "🚫 تم إلغاء طلب القرض",
               f"تم إلغاء طلب {loan['loan_type']} الخاص بك من قِبل أحد الموظفين.")

    return {"ok":True,"loan":updated}

@app.put("/accounts/loans/{loan_id}/approve")
def approve_loan(loan_id: str, data: dict):
    reviewer_id   = data.get("reviewerId")
    reviewer_role = data.get("reviewerRole")
    reviewer_name = data.get("reviewerName","")
    if reviewer_role not in ("admin","supervisor"):
        raise HTTPException(403,"مدراء ومشرفون فقط")
    if not reviewer_id:
        raise HTTPException(400,"بيانات المراجع مطلوبة")

    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM loans WHERE id=%s",(loan_id,))
            loan = cur.fetchone()
            if not loan:
                raise HTTPException(404,"الطلب غير موجود")
            if loan["status"] != "pending":
                raise HTTPException(400,"تم البت في هذا الطلب من قبل")
            cur.execute("""UPDATE loans SET status='approved', reviewed_by_id=%s,
                reviewed_by_role=%s, decided_at=NOW() WHERE id=%s RETURNING *""",
                (reviewer_id,reviewer_role,loan_id))
            updated = row2dict(cur.fetchone())
        c.commit()

    # صرف المبلغ فعليًا + تسجيله كمعاملة حقيقية في transactions-service
    call_transactions("POST","/transactions/loan-credit",{
        "accountId": str(loan["account_id"]),
        "amount": float(loan["total"]),
        "loanType": loan["loan_type"],
        "reviewerName": reviewer_name,
    })

    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT user_id FROM accounts WHERE id=%s",(loan["account_id"],))
            acc = cur.fetchone()
    if acc:
        notify(str(acc["user_id"]), "✅ تمت الموافقة على قرضك",
               f"تمت الموافقة على طلب {loan['loan_type']} بمبلغ {loan['total']} EGP وتم إضافته لرصيدك.")

    return {"ok":True,"loan":updated}


@app.put("/accounts/loans/{loan_id}/reject")
def reject_loan(loan_id: str, data: dict):
    reviewer_id   = data.get("reviewerId")
    reviewer_role = data.get("reviewerRole")
    note          = data.get("note","")
    if reviewer_role not in ("admin","supervisor"):
        raise HTTPException(403,"مدراء ومشرفون فقط")
    if not reviewer_id:
        raise HTTPException(400,"بيانات المراجع مطلوبة")

    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM loans WHERE id=%s",(loan_id,))
            loan = cur.fetchone()
            if not loan:
                raise HTTPException(404,"الطلب غير موجود")
            if loan["status"] != "pending":
                raise HTTPException(400,"تم البت في هذا الطلب من قبل")
            cur.execute("""UPDATE loans SET status='rejected', reviewed_by_id=%s,
                reviewed_by_role=%s, decision_note=%s, decided_at=NOW() WHERE id=%s RETURNING *""",
                (reviewer_id,reviewer_role,note,loan_id))
            updated = row2dict(cur.fetchone())
        c.commit()

    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT user_id FROM accounts WHERE id=%s",(loan["account_id"],))
            acc = cur.fetchone()
    if acc:
        notify(str(acc["user_id"]), "❌ تم رفض طلب القرض",
               f"للأسف تم رفض طلب {loan['loan_type']}." + (f" السبب: {note}" if note else ""))

    return {"ok":True,"loan":updated}



# ── Portfolio ──────────────────────────────────────────────────────────
@app.get("/accounts/{account_id}/portfolio")
def get_portfolio(account_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM portfolio WHERE account_id=%s",(account_id,))
            return {"portfolio":[row2dict(r) for r in cur.fetchall()]}

@app.post("/accounts/{account_id}/portfolio")
def buy_stock(account_id: str, data: dict):
    qty   = int(data["qty"])
    price = float(data["price"])
    total = round(qty*price,2)
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("""
                INSERT INTO portfolio(account_id,symbol,name,qty,avg_price,total_cost)
                VALUES(%s,%s,%s,%s,%s,%s)
                ON CONFLICT(account_id,symbol) DO UPDATE
                  SET qty=portfolio.qty+EXCLUDED.qty,
                      total_cost=portfolio.total_cost+EXCLUDED.total_cost,
                      avg_price=(portfolio.total_cost+EXCLUDED.total_cost)/(portfolio.qty+EXCLUDED.qty)
                RETURNING *""",
                (account_id,data["symbol"],data["name"],qty,price,total))
            item = row2dict(cur.fetchone())
        c.commit()
    return {"ok":True,"item":item,"totalCost":total}

# ── Lookup helpers ────────────────────────────────────────────────────
@app.get("/internal/find-account")
def find_account(account_number: str = None, user_id: str = None):
    with conn() as c:
        with c.cursor() as cur:
            if account_number:
                cur.execute("SELECT * FROM accounts WHERE account_number=%s",(account_number,))
            elif user_id:
                cur.execute("SELECT * FROM accounts WHERE user_id=%s",(user_id,))
            else:
                raise HTTPException(400,"account_number أو user_id مطلوب")
            acc = cur.fetchone()
            if not acc: raise HTTPException(404,"الحساب غير موجود")
            return row2dict(acc)

@app.put("/accounts/{account_id}")
def update_account(account_id: str, data: dict):
    with conn() as c:
        with c.cursor() as cur:
            fields = []
            vals   = []
            for f in ["first_name","last_name","email","phone","account_type"]:
                if f in data:
                    fields.append(f"{f}=%s")
                    vals.append(data[f])
            # frontend sends camelCase
            if "firstName"   in data: fields.append("first_name=%s"); vals.append(data["firstName"])
            if "lastName"    in data: fields.append("last_name=%s");  vals.append(data["lastName"])
            if "accountType" in data: fields.append("account_type=%s");vals.append(data["accountType"])
            if not fields: return {"ok":True}
            vals.append(account_id)
            cur.execute(f"UPDATE accounts SET {','.join(fields)},updated_at=NOW() WHERE id=%s",vals)
        c.commit()
    return {"ok":True}

