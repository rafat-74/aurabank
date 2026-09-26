"""Aura Bank — Notifications Service :8004"""
import os, logging, time, json, threading
import psycopg2, psycopg2.extras
import boto3
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

DB_URL = os.getenv("DATABASE_URL")
if not DB_URL:
    raise RuntimeError("DATABASE_URL env var is required")

AWS_REGION    = os.getenv("AWS_REGION", "us-east-1")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")
SES_SENDER    = os.getenv("SES_SENDER", "ahmedhassana3063850z@gmail.com")

logging.basicConfig(level=logging.INFO,
  format='{"t":"%(asctime)s","svc":"notifications","msg":"%(message)s"}')
log = logging.getLogger(__name__)

app = FastAPI(title="Notifications Service")
app.add_middleware(CORSMiddleware,
    allow_origins=[os.getenv("ALLOWED_ORIGINS", "http://localhost:3000")],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
    allow_headers=["Authorization", "Content-Type"])

sqs = boto3.client("sqs", region_name=AWS_REGION)
ses = boto3.client("ses", region_name=AWS_REGION)

def conn():
    return psycopg2.connect(DB_URL, cursor_factory=psycopg2.extras.RealDictCursor)

def init_db():
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("""
            CREATE TABLE IF NOT EXISTS notifications (
                id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                user_id    UUID NOT NULL,
                title      TEXT NOT NULL,
                body       TEXT NOT NULL,
                type       TEXT DEFAULT 'system',
                read       BOOLEAN DEFAULT FALSE,
                created_at TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_notif_user ON notifications(user_id);
            """)
        c.commit()

def row2dict(r):
    d = dict(r)
    for k,v in d.items():
        if hasattr(v,'isoformat'): d[k] = v.isoformat()
    return d

def save_notification(user_id, title, body, ntype="transaction"):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute(
                "INSERT INTO notifications(user_id,title,body,type) VALUES(%s,%s,%s,%s) RETURNING *",
                (user_id, title, body, ntype))
            n = row2dict(cur.fetchone())
        c.commit()
    return n

def send_email(email: str, title: str, message: str):
    """Send Email via SES"""
    if not email:
        return
    try:
        ses.send_email(
            Source=SES_SENDER,
            Destination={"ToAddresses": [email]},
            Message={
                "Subject": {"Data": f"AuraBank - {title}", "Charset": "UTF-8"},
                "Body": {
                    "Html": {
                        "Data": f"""
                        <div dir="rtl" style="font-family:Arial;padding:20px;background:#f5f5f5;">
                          <div style="background:white;padding:20px;border-radius:8px;max-width:500px;margin:auto;">
                            <h2 style="color:#1a56db;">🏦 AuraBank</h2>
                            <h3>{title}</h3>
                            <p style="font-size:16px;">{message}</p>
                            <hr/>
                            <small style="color:#888;">هذا إشعار تلقائي من AuraBank - لا ترد على هذا البريد</small>
                          </div>
                        </div>""",
                        "Charset": "UTF-8"
                    },
                    "Text": {"Data": f"{title}\n{message}", "Charset": "UTF-8"}
                }
            }
        )
        log.info(f"Email sent to {email}")
    except Exception as e:
        log.error(f"Email failed: {e}")

def process_sqs_message(msg):
    """Process one SQS message → save to DB + send SMS"""
    try:
        body = json.loads(msg["Body"])
        user_id  = body.get("user_id")
        title    = body.get("title", "إشعار من بنك أورا")
        text     = body.get("body", "")
        ntype    = body.get("type", "transaction")
        phone    = body.get("phone")

        # Save to DB
        if user_id:
            save_notification(user_id, title, text, ntype)
            log.info(f"Notification saved for user {user_id}")

        # Send Email
        email = body.get("email")
        if email:
            send_email(email, title, text)

    except Exception as e:
        log.error(f"Error processing SQS message: {e}")
        raise

def sqs_worker():
    """Background thread: poll SQS continuously"""
    if not SQS_QUEUE_URL:
        log.warning("SQS_QUEUE_URL not set — SMS worker disabled")
        return

    log.info(f"SQS worker started, polling: {SQS_QUEUE_URL}")
    while True:
        try:
            resp = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
                AttributeNames=["All"]
            )
            messages = resp.get("Messages", [])
            for msg in messages:
                try:
                    process_sqs_message(msg)
                    sqs.delete_message(
                        QueueUrl=SQS_QUEUE_URL,
                        ReceiptHandle=msg["ReceiptHandle"]
                    )
                except Exception as e:
                    log.error(f"Failed to process message: {e}")
        except Exception as e:
            log.error(f"SQS receive error: {e}")
            time.sleep(5)

@app.on_event("startup")
def startup():
    for i in range(20):
        try: init_db(); log.info("Notifications DB ready"); break
        except Exception as e: log.warning(f"DB not ready ({i+1}/20): {e}"); time.sleep(3)
    # Start SQS worker in background
    t = threading.Thread(target=sqs_worker, daemon=True)
    t.start()

@app.get("/health")
def health(): return {"status":"ok","service":"notifications-service"}

@app.get("/notifications/{user_id}")
def get_notifications(user_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("SELECT * FROM notifications WHERE user_id=%s ORDER BY created_at DESC",(user_id,))
            rows = [row2dict(r) for r in cur.fetchall()]
    unread = sum(1 for r in rows if not r["read"])
    return {"notifications":rows,"unreadCount":unread}

@app.put("/notifications/{user_id}/read/{notif_id}")
def mark_read(user_id: str, notif_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("UPDATE notifications SET read=TRUE WHERE id=%s AND user_id=%s",(notif_id,user_id))
            if cur.rowcount==0: raise HTTPException(404,"الإشعار غير موجود")
        c.commit()
    return {"ok":True}

@app.put("/notifications/{user_id}/read-all")
def mark_all_read(user_id: str):
    with conn() as c:
        with c.cursor() as cur:
            cur.execute("UPDATE notifications SET read=TRUE WHERE user_id=%s",(user_id,))
        c.commit()
    return {"ok":True}

@app.post("/internal/create")
def create(data: dict):
    """Direct HTTP create (backward compat) — no SMS"""
    n = save_notification(
        data["user_id"], data["title"], data["body"], data.get("type","system"))
    return {"ok":True,"notification":n}
